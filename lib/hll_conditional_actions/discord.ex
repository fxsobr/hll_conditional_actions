defmodule HllConditionalActions.Discord do
  @moduledoc """
  The Discord webhooks rules post to, and what the app remembers about the
  messages it posted.

  A webhook is registered once, with its URL encrypted, and rules pick it by
  id. That keeps the token out of rule JSON, exports and the audit trail, lets
  one webhook serve many rules, and gives a single place to replace a URL
  that was rotated on Discord's side.
  """

  import Ecto.Query

  require Logger

  alias HllConditionalActions.Discord.Client
  alias HllConditionalActions.Discord.PostedMessage
  alias HllConditionalActions.Discord.Webhook
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules.Action
  alias HllConditionalActions.Rules.Execution
  alias HllConditionalActions.Rules.Rule

  # ── Webhooks ───────────────────────────────────────────────────────────────

  @doc "Every webhook, by name."
  @spec list_webhooks() :: [Webhook.t()]
  def list_webhooks,
    do: Repo.all(from w in Webhook, order_by: [asc: fragment("lower(?)", w.name)])

  @doc "`{name, id}` pairs for a select."
  @spec webhook_options() :: [{String.t(), integer()}]
  def webhook_options, do: Enum.map(list_webhooks(), &{&1.name, &1.id})

  @spec get_webhook(term()) :: Webhook.t() | nil
  def get_webhook(nil), do: nil

  def get_webhook(id) do
    case to_id(id) do
      nil -> nil
      id -> Repo.get(Webhook, id)
    end
  end

  @spec get_webhook!(term()) :: Webhook.t()
  def get_webhook!(id), do: Repo.get!(Webhook, id)

  @doc "The webhook with a name, ignoring case, for rule imports."
  @spec get_webhook_by_name(String.t() | nil) :: Webhook.t() | nil
  def get_webhook_by_name(name) when is_binary(name) do
    Repo.one(from w in Webhook, where: fragment("lower(?)", w.name) == ^String.downcase(name))
  end

  def get_webhook_by_name(_name), do: nil

  @spec change_webhook(Webhook.t(), map()) :: Ecto.Changeset.t()
  def change_webhook(%Webhook{} = webhook, attrs \\ %{}), do: Webhook.changeset(webhook, attrs)

  @doc """
  Registers a webhook, after asking Discord whether it exists.
  """
  @spec create_webhook(map()) :: {:ok, Webhook.t()} | {:error, Ecto.Changeset.t()}
  def create_webhook(attrs) do
    %Webhook{}
    |> Webhook.changeset(attrs)
    |> verify()
    |> Repo.insert()
  end

  @doc """
  Updates a webhook. Discord is only asked again when the URL changes.
  """
  @spec update_webhook(Webhook.t(), map()) :: {:ok, Webhook.t()} | {:error, Ecto.Changeset.t()}
  def update_webhook(%Webhook{} = webhook, attrs) do
    webhook
    |> Webhook.changeset(attrs)
    |> verify()
    |> Repo.update()
  end

  # A deleted webhook or a mistyped token answers 401/404 and is refused. A
  # Discord outage is not the admin's fault: the webhook is saved and the
  # error shown on it.
  defp verify(%Ecto.Changeset{valid?: true, changes: %{url: url}} = changeset) do
    case Client.get(url) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        Ecto.Changeset.change(changeset, %{
          remote_name: body["name"],
          channel_id: body["channel_id"],
          guild_id: body["guild_id"],
          last_error: nil,
          last_error_at: nil
        })

      {:ok, %Req.Response{status: status}} when status in [401, 403, 404] ->
        Ecto.Changeset.add_error(changeset, :url, "Discord does not know this webhook")

      {:ok, %Req.Response{status: status}} ->
        unverified(changeset, "Discord answered with HTTP #{status}")

      {:error, exception} ->
        unverified(changeset, Exception.message(exception))
    end
  end

  defp verify(changeset), do: changeset

  defp unverified(changeset, reason) do
    Ecto.Changeset.change(changeset, %{last_error: reason, last_error_at: now()})
  end

  @doc """
  Removes a webhook, unless a rule still posts to it.
  """
  @spec delete_webhook(Webhook.t()) ::
          {:ok, Webhook.t()} | {:error, :in_use} | {:error, Ecto.Changeset.t()}
  def delete_webhook(%Webhook{} = webhook) do
    if Map.get(usage(), webhook.id, 0) > 0,
      do: {:error, :in_use},
      else: Repo.delete(webhook)
  end

  @doc """
  How many rules post to each webhook, by webhook id.
  """
  @spec usage() :: %{integer() => non_neg_integer()}
  def usage do
    Rule
    |> Repo.all()
    |> Enum.flat_map(fn rule ->
      rule.actions
      |> Enum.filter(&(&1.type == :send_discord_webhook))
      |> Enum.map(&to_id(Action.param(&1, :webhook_id)))
      |> Enum.uniq()
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  @doc """
  Posts a test message right away and reports what Discord said.
  """
  @spec send_test(Webhook.t(), String.t()) :: :ok | {:error, String.t()}
  def send_test(%Webhook{} = webhook, text) do
    payload = %{
      "content" => text,
      "allowed_mentions" => %{"parse" => []},
      "username" => webhook.username,
      "avatar_url" => webhook.avatar_url
    }

    payload = Map.reject(payload, fn {_key, value} -> is_nil(value) end)

    case Client.post(webhook.url, payload) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        record_success(webhook.id)

      {:ok, %Req.Response{status: status}} ->
        reason = "Discord answered with HTTP #{status}"
        record_failure(webhook.id, reason)
        {:error, reason}

      {:error, exception} ->
        reason = Exception.message(exception)
        record_failure(webhook.id, reason)
        {:error, reason}
    end
  end

  @doc "Notes a successful delivery on the webhook."
  @spec record_success(integer()) :: :ok
  def record_success(webhook_id) do
    from(w in Webhook, where: w.id == ^webhook_id)
    |> Repo.update_all(set: [last_delivered_at: now(), last_error: nil, last_error_at: nil])

    :ok
  end

  @doc "Notes why a delivery failed on the webhook, for its page."
  @spec record_failure(integer(), String.t()) :: :ok
  def record_failure(webhook_id, reason) do
    from(w in Webhook, where: w.id == ^webhook_id)
    |> Repo.update_all(set: [last_error: String.slice(reason, 0, 255), last_error_at: now()])

    :ok
  end

  # ── Posted messages ────────────────────────────────────────────────────────

  @doc "The message or thread stored under a key, if any."
  @spec get_posted(integer(), String.t()) :: PostedMessage.t() | nil
  def get_posted(webhook_id, key) do
    Repo.get_by(PostedMessage, webhook_id: webhook_id, key: key)
  end

  @doc "Stores (or replaces) what lives under a key."
  @spec put_posted(integer(), String.t(), map()) :: :ok
  def put_posted(webhook_id, key, attrs) do
    now = now()

    row =
      Map.merge(
        %{webhook_id: webhook_id, key: key, inserted_at: now, updated_at: now},
        Map.take(attrs, [:message_id, :thread_id])
      )

    Repo.insert_all(PostedMessage, [row],
      on_conflict: {:replace, [:message_id, :thread_id, :updated_at]},
      conflict_target: [:webhook_id, :key]
    )

    :ok
  end

  @doc "Forgets a key, when Discord says its message or thread is gone."
  @spec delete_posted(integer(), String.t()) :: :ok
  def delete_posted(webhook_id, key) do
    Repo.delete_all(from p in PostedMessage, where: p.webhook_id == ^webhook_id and p.key == ^key)
    :ok
  end

  # ── Delivery status ────────────────────────────────────────────────────────

  @doc """
  Stores how a queued Discord action ended, under its index in the
  execution's `deliveries`.
  """
  @spec record_delivery(integer() | nil, integer() | nil, :delivered | :failed, String.t() | nil) ::
          :ok
  def record_delivery(nil, _index, _status, _detail), do: :ok
  def record_delivery(_execution_id, nil, _status, _detail), do: :ok

  def record_delivery(execution_id, index, status, detail) do
    entry = %{
      "status" => to_string(status),
      "detail" => detail,
      "at" => DateTime.to_iso8601(now())
    }

    from(e in Execution,
      where: e.id == ^execution_id,
      update: [
        set: [
          deliveries:
            fragment(
              "? || jsonb_build_object(?::text, ?::jsonb)",
              e.deliveries,
              ^to_string(index),
              type(^entry, :map)
            )
        ]
      ]
    )
    |> Repo.update_all([])

    :ok
  end

  # ── Rules written before webhooks were registered ──────────────────────────

  @doc """
  Moves the URLs rules used to carry in their actions into registered
  webhooks, one per distinct URL, and points the actions at them.

  Runs at boot and does nothing once no action carries a URL any more.
  """
  @spec adopt_legacy_urls() :: :ok
  def adopt_legacy_urls do
    rules =
      Enum.filter(Repo.all(Rule), fn rule -> Enum.any?(rule.actions, &legacy_url/1) end)

    if rules != [] do
      Repo.transaction(fn -> Enum.reduce(rules, %{}, &adopt_rule/2) end)

      Logger.info("[discord] moved the webhook URLs of #{length(rules)} rule(s) to webhooks")
    end

    :ok
  end

  # `known` maps each URL already moved to its webhook id, so rules sharing
  # a URL end up sharing the webhook.
  defp adopt_rule(rule, known) do
    {actions, known} = Enum.map_reduce(rule.actions, known, &adopt_action/2)

    rule
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(:actions, actions)
    |> Repo.update!()

    known
  end

  defp legacy_url(%Action{type: :send_discord_webhook, parameters: %{"webhook_url" => url}})
       when is_binary(url),
       do: url

  defp legacy_url(_action), do: nil

  defp adopt_action(action, known) do
    case legacy_url(action) do
      nil ->
        {action, known}

      url ->
        {id, known} = legacy_webhook_id(url, known)

        parameters =
          action.parameters |> Map.delete("webhook_url") |> Map.put("webhook_id", id)

        {%{action | parameters: parameters}, known}
    end
  end

  defp legacy_webhook_id(url, known) do
    case Map.fetch(known, url) do
      {:ok, id} ->
        {id, known}

      :error ->
        existing = Enum.find(list_webhooks(), &(&1.url == url))

        webhook =
          existing ||
            Repo.insert!(%Webhook{name: free_name(map_size(known) + 1), url: url})

        {webhook.id, Map.put(known, url, webhook.id)}
    end
  end

  defp free_name(n) do
    name = "Discord #{n}"
    if get_webhook_by_name(name), do: free_name(n + 1), else: name
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @doc false
  @spec to_id(term()) :: integer() | nil
  def to_id(id) when is_integer(id), do: id

  def to_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {int, ""} -> int
      _other -> nil
    end
  end

  def to_id(_id), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
