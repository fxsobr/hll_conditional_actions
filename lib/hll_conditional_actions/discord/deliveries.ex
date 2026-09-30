defmodule HllConditionalActions.Discord.Deliveries do
  @moduledoc """
  What each Discord webhook delivered lately, and who posts to it.

  Rules do not post to Discord directly: the engine queues the message
  (`HllConditionalActions.Workers.DeliverWebhook`) and the job writes how it
  ended into the execution's `deliveries`, under the index of the action.
  This module reads those entries back and attributes each one to its
  webhook through the rule's action at that index, which gives:

    * a delivery log per webhook, for the last seven days;
    * the current streak of failures, and when it started;
    * who posts to each webhook: rules, the Tickets module, the VIP shop.

  Only rule deliveries are recorded per message. Ticket announcements, VIP
  shop alerts and test messages update the webhook's last success or error
  (`HllConditionalActions.Discord.record_success/1`) but leave no log entry.
  """

  import Ecto.Query

  alias HllConditionalActions.Discord
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules.Action
  alias HllConditionalActions.Rules.Execution
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Tickets.Settings, as: TicketSettings
  alias HllConditionalActions.VipShop.Settings, as: ShopSettings

  @retention_days 7
  # How far back a streak that fills the whole log window is followed.
  @streak_days 60

  @type entry :: %{
          at: DateTime.t(),
          status: :delivered | :failed,
          http: integer() | nil,
          detail: String.t() | nil,
          execution_id: integer(),
          rule_id: integer(),
          rule_name: String.t(),
          player_name: String.t() | nil,
          command: String.t() | nil,
          server_id: integer() | nil
        }

  @type summary :: %{
          log: [entry()],
          last: entry() | nil,
          streak: non_neg_integer(),
          streak_since: DateTime.t() | nil
        }

  @type user :: %{kind: :rule | :tickets | :vip_shop, id: integer() | nil, name: String.t() | nil}

  @doc "How many days of deliveries the log shows."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @doc """
  The delivery summary of every webhook that has an entry, by webhook id:
  its log (newest first), its last delivery, and the failures in a row that
  end the log with the time of the first one.
  """
  @spec summaries(DateTime.t()) :: %{integer() => summary()}
  def summaries(now \\ DateTime.utc_now()) do
    since = DateTime.add(now, -@retention_days, :day)
    by_webhook = entries(since)

    Map.new(by_webhook, fn {webhook_id, log} ->
      {streak, streak_since} = streak(webhook_id, log, now)
      {webhook_id, %{log: log, last: List.first(log), streak: streak, streak_since: streak_since}}
    end)
  end

  @doc "The summary of one webhook, empty when nothing was delivered lately."
  @spec summary(%{integer() => summary()}, integer()) :: summary()
  def summary(summaries, webhook_id) do
    Map.get(summaries, webhook_id, %{log: [], last: nil, streak: 0, streak_since: nil})
  end

  @doc """
  Every delivery entry since `since`, grouped by webhook id, newest first.
  """
  @spec entries(DateTime.t()) :: %{integer() => [entry()]}
  def entries(since) do
    rules = discord_rules()

    if rules == %{} do
      %{}
    else
      from(e in Execution,
        where: e.rule_id in ^Map.keys(rules) and e.executed_at >= ^since,
        where: e.deliveries != ^%{},
        select: %{
          id: e.id,
          rule_id: e.rule_id,
          server_id: e.server_id,
          player_name: e.player_name,
          trace: e.trace,
          results: e.results,
          deliveries: e.deliveries,
          executed_at: e.executed_at
        }
      )
      |> Repo.all()
      |> Enum.flat_map(&expand(&1, Map.fetch!(rules, &1.rule_id)))
      |> Enum.sort_by(fn {_webhook_id, entry} -> entry.at end, {:desc, DateTime})
      |> Enum.group_by(fn {webhook_id, _entry} -> webhook_id end, fn {_id, entry} -> entry end)
    end
  end

  @doc """
  Who posts to each webhook, by webhook id: the rules with a Discord action
  aimed at it (by name), the Tickets module when a server announces new
  tickets there, and the VIP shop when its alerts go there.
  """
  @spec users() :: %{integer() => [user()]}
  def users do
    rule_users =
      Rule
      |> Repo.all()
      |> Enum.sort_by(&String.downcase(&1.name || ""))
      |> Enum.flat_map(fn rule ->
        rule.actions
        |> Enum.map(&webhook_of/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.map(&{&1, %{kind: :rule, id: rule.id, name: rule.name}})
      end)

    ticket_users =
      from(s in TicketSettings,
        where: not is_nil(s.discord_webhook_id),
        distinct: true,
        select: s.discord_webhook_id
      )
      |> Repo.all()
      |> Enum.map(&{&1, %{kind: :tickets, id: nil, name: nil}})

    shop_users =
      from(s in ShopSettings, where: not is_nil(s.alert_webhook_id), select: s.alert_webhook_id)
      |> Repo.all()
      |> Enum.uniq()
      |> Enum.map(&{&1, %{kind: :vip_shop, id: nil, name: nil}})

    Enum.group_by(rule_users ++ ticket_users ++ shop_users, &elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  The HTTP status in a delivery error ("... with HTTP 404 ..."), if any.

      iex> HllConditionalActions.Discord.Deliveries.http_status("Discord rejected the message with HTTP 404 (Unknown Webhook)")
      404

      iex> HllConditionalActions.Discord.Deliveries.http_status("timeout")
      nil
  """
  @spec http_status(String.t() | nil) :: integer() | nil
  def http_status(detail) when is_binary(detail) do
    case Regex.run(~r/HTTP (\d{3})/, detail) do
      [_match, code] -> String.to_integer(code)
      nil -> nil
    end
  end

  def http_status(_detail), do: nil

  @doc """
  Discord's own words in a delivery error, without the part the app added:
  "Unknown Webhook" out of "Discord rejected the message with HTTP 404
  (Unknown Webhook)". The whole detail when it carries no such part.

      iex> HllConditionalActions.Discord.Deliveries.reason("Discord rejected the message with HTTP 404 (Unknown Webhook)")
      "Unknown Webhook"

      iex> HllConditionalActions.Discord.Deliveries.reason("Discord rejected the message with HTTP 404: Unknown Webhook")
      "Unknown Webhook"
  """
  @spec reason(String.t() | nil) :: String.t() | nil
  def reason(detail) when is_binary(detail) do
    case Regex.run(~r/HTTP \d{3}(?:: | \()(.+?)\)?$/, detail) do
      [_match, reason] -> reason
      nil -> detail
    end
  end

  def reason(_detail), do: nil

  # ── Attribution ────────────────────────────────────────────────────────────

  # Rules with at least one Discord action, by id.
  defp discord_rules do
    Rule
    |> Repo.all()
    |> Enum.filter(fn rule -> Enum.any?(rule.actions, &webhook_of/1) end)
    |> Map.new(&{&1.id, &1})
  end

  defp webhook_of(%Action{type: :send_discord_webhook} = action),
    do: Discord.to_id(Action.param(action, :webhook_id))

  defp webhook_of(_action), do: nil

  defp expand(execution, rule) do
    Enum.flat_map(execution.deliveries, fn {index, delivery} ->
      with {index, ""} <- Integer.parse(to_string(index)),
           %{} = delivery <- delivery,
           webhook_id when is_integer(webhook_id) <- webhook_at(rule, execution, index),
           {:ok, at} <- delivered_at(delivery, execution) do
        [{webhook_id, entry(execution, rule, delivery, at)}]
      else
        _other -> []
      end
    end)
  end

  # The index counts the actions that ran. An escalating rule runs a single
  # step, recorded in the trace, so its index 0 is that step's action.
  defp webhook_at(rule, %{trace: %{"step" => step}}, 0) when is_integer(step) and step > 0,
    do: rule.actions |> Enum.at(step - 1) |> webhook_of()

  defp webhook_at(rule, _execution, index), do: rule.actions |> Enum.at(index) |> webhook_of()

  defp delivered_at(%{"at" => at}, _execution) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> {:ok, at}
      _error -> :error
    end
  end

  defp delivered_at(_delivery, %{executed_at: %DateTime{} = at}), do: {:ok, at}
  defp delivered_at(_delivery, _execution), do: :error

  defp entry(execution, rule, delivery, at) do
    status = if delivery["status"] == "delivered", do: :delivered, else: :failed
    detail = delivery["detail"]

    %{
      at: at,
      status: status,
      http: delivery["http"] || http_status(detail),
      detail: detail,
      execution_id: execution.id,
      rule_id: rule.id,
      rule_name: rule.name,
      player_name: execution.player_name,
      command: command(execution.trace),
      server_id: execution.server_id
    }
  end

  # The chat command that fired the rule, as the trace saw it.
  defp command(%{"conditions" => conditions}) when is_list(conditions) do
    Enum.find_value(conditions, fn
      %{"field" => "command", "actual" => command} when is_binary(command) and command != "" ->
        String.trim_leading(command, "!")

      _condition ->
        nil
    end)
  end

  defp command(_trace), do: nil

  # ── Streak ─────────────────────────────────────────────────────────────────

  defp streak(webhook_id, log, now) do
    failures = Enum.take_while(log, &(&1.status == :failed))

    # Every entry of the window failed: the streak may have started earlier.
    failures =
      if failures != [] and length(failures) == length(log) do
        now
        |> DateTime.add(-@streak_days, :day)
        |> entries()
        |> Map.get(webhook_id, [])
        |> Enum.take_while(&(&1.status == :failed))
      else
        failures
      end

    case List.last(failures) do
      nil -> {0, nil}
      first -> {length(failures), first.at}
    end
  end
end
