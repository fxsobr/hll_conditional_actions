defmodule HllConditionalActions.VipShop.Storefront do
  @moduledoc """
  What the public shop shows beyond packages and orders: the servers live,
  how customers can pay, when a player's VIP ends, the gift message, the
  customer's email preferences and account changes, and where a delivery
  stands.

  Everything here reads the shop's own tables, CRCON through
  `HllConditionalActions.Crcon`, or Oban's job table - nothing is invented
  for the page.
  """

  import Ecto.Query

  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Repo
  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.{Coupon, Customer, CustomerToken, Grant, Order, Package}
  alias HllConditionalActions.VipShop.LiveServers
  alias HllConditionalActions.VipShop.Storefront.{OrderNote, Preference}

  # ── Servers ────────────────────────────────────────────────────────────────

  @doc "The distinct servers the packages grant VIP on, in the order first seen."
  @spec servers([Package.t()]) :: [map()]
  def servers(packages) do
    packages |> Enum.flat_map(& &1.servers) |> Enum.uniq_by(& &1.id)
  end

  @doc """
  Each server with its live state (see `LiveServers`) and how busy it is:
  `:live` with players, `:seeding` under half full, `:offline` when it did
  not answer. With `cached_only: true` nothing is asked: servers without a
  fresh answer are `:loading`.
  """
  @spec live_servers([map()], keyword()) :: [map()]
  def live_servers(servers, opts \\ [])
  def live_servers([], _opts), do: []

  def live_servers(servers, opts) do
    {live, missing} =
      if Keyword.get(opts, :cached_only, false),
        do: {LiveServers.cached(servers), :loading},
        else: {LiveServers.fetch(servers), :error}

    Enum.map(servers, fn server ->
      state = Map.get(live, server.id, missing)
      %{server: server, live: state, status: status(state)}
    end)
  end

  defp status(:loading), do: :loading
  defp status(:error), do: :offline

  defp status(%{players: players, max_players: max}) when is_integer(max) and max > 0,
    do: if(players * 2 < max, do: :seeding, else: :live)

  defp status(%{players: players}), do: if(players > 0, do: :live, else: :seeding)

  @doc """
  The server to feature on the storefront's hero: the busiest one that
  answered, or nil.
  """
  @spec featured([map()]) :: map() | nil
  def featured(live_servers) do
    live_servers
    |> Enum.reject(&(&1.status in [:offline, :loading]))
    |> Enum.max_by(&{&1.live.queue || 0, &1.live.players}, fn -> nil end)
  end

  @doc "When the oldest of these live readings was taken, or nil."
  @spec read_at([map()]) :: DateTime.t() | nil
  def read_at(live_servers) do
    live_servers
    |> Enum.flat_map(fn
      %{live: %{read_at: at}} -> [at]
      _offline -> []
    end)
    |> Enum.min(DateTime, fn -> nil end)
  end

  # ── Paying ─────────────────────────────────────────────────────────────────

  @doc """
  The ways to pay the enabled providers accept, in a fixed order: `:pix`,
  `:card`, `:boleto`.
  """
  @spec payment_methods([map()]) :: [atom()]
  def payment_methods(providers) do
    methods = providers |> Enum.flat_map(&methods(&1.provider)) |> MapSet.new()
    Enum.filter([:pix, :card, :boleto], &(&1 in methods))
  end

  @doc "What a provider's checkout page accepts."
  @spec methods(String.t()) :: [atom()]
  def methods("mercado_pago"), do: [:pix, :card, :boleto]
  def methods("dodo"), do: [:pix, :card]
  def methods("stripe"), do: [:card]
  def methods(_provider), do: [:card]

  @doc "Whether any coupon can be used right now."
  @spec coupons_available?() :: boolean()
  def coupons_available? do
    from(c in Coupon, where: c.active == true)
    |> Repo.all()
    |> Enum.any?(&Coupon.usable?/1)
  end

  @doc """
  Checks a coupon code for a package, like `VipShop.apply_coupon/2`, and also
  refuses a coupon limited to other packages.
  """
  @spec apply_coupon(String.t() | nil, Package.t()) ::
          {:ok, Coupon.t() | nil, non_neg_integer()} | {:error, :invalid_coupon}
  def apply_coupon(code, %Package{} = package) do
    case VipShop.apply_coupon(code, package) do
      {:ok, %Coupon{} = coupon, discount} ->
        if Coupon.covers?(coupon, package.id),
          do: {:ok, coupon, discount},
          else: {:error, :invalid_coupon}

      other ->
        other
    end
  end

  # ── Players and their VIP ──────────────────────────────────────────────────

  @doc """
  When the shop's VIP of each player ends, by player id: `:permanent`, or
  the latest expiry still in the future. Players without one are left out.
  """
  @spec vip_until([String.t()]) :: %{String.t() => DateTime.t() | :permanent}
  def vip_until([]), do: %{}

  def vip_until(player_ids) do
    now = DateTime.utc_now()

    from(g in Grant,
      join: o in Order,
      on: o.id == g.order_id,
      where: o.player_id in ^player_ids and g.status == "granted",
      select: {o.player_id, g.expires_at}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {player_id, expiries} -> active_vip(player_id, expiries, now) end)
    |> Map.new()
  end

  defp active_vip(player_id, expiries, now) do
    if Enum.any?(expiries, &is_nil/1) do
      [{player_id, :permanent}]
    else
      latest = Enum.max(expiries, DateTime)
      if DateTime.compare(latest, now) == :gt, do: [{player_id, latest}], else: []
    end
  end

  @doc """
  Until when a package bought now would run for a player: nil for a
  permanent package, otherwise the package's days from now - or, when the
  shop adds the days to what is left, from the VIP the player already has.
  """
  @spec valid_until(Package.t(), DateTime.t() | :permanent | nil, String.t()) ::
          DateTime.t() | :permanent
  def valid_until(%Package{duration_days: nil}, _current, _stacking), do: :permanent
  def valid_until(_package, :permanent, "extend"), do: :permanent

  def valid_until(%Package{duration_days: days}, current, stacking) do
    now = DateTime.utc_now(:second)

    base =
      case current do
        %DateTime{} = at when stacking == "extend" ->
          if DateTime.compare(at, now) == :gt, do: at, else: now

        _other ->
          now
      end

    DateTime.add(base, days * 86_400, :second)
  end

  @doc """
  Searches the players CRCON has seen by name, on the first shop server
  that answers: `[%{player_id, name, last_seen, online?}]`, most recently
  seen first.
  """
  @spec search_players(String.t()) :: {:ok, [map()]} | {:error, term()}
  def search_players(term) do
    term = String.trim(term || "")

    if String.length(term) < 2,
      do: {:ok, []},
      else:
        Enum.reduce_while(VipShop.shop_servers(), {:error, :no_server}, &search_on(&1, term, &2))
  end

  defp search_on(server, term, _previous) do
    case safely(fn -> Crcon.search_players_history(server, term) end) do
      {:ok, %{"players" => players}} when is_list(players) ->
        results =
          players
          |> Enum.map(&player_result/1)
          |> Enum.sort_by(&(&1.last_seen && DateTime.to_unix(&1.last_seen)), :desc)

        {:halt, {:ok, results}}

      {:ok, _other} ->
        {:halt, {:ok, []}}

      {:error, error} ->
        {:cont, {:error, error}}
    end
  end

  @doc """
  When each player was last seen in the game, by player id, from CRCON's
  profile on the first shop server that answers: `%{last_seen, online?}`.
  """
  @spec last_seen([String.t()]) :: %{String.t() => map()}
  def last_seen([]), do: %{}

  def last_seen(player_ids) do
    case VipShop.shop_servers() do
      [] ->
        %{}

      [server | _rest] ->
        player_ids
        |> Task.async_stream(&{&1, safely(fn -> Crcon.get_player_profile(server, &1) end)},
          timeout: 10_000,
          on_timeout: :kill_task,
          max_concurrency: 4
        )
        |> Enum.flat_map(fn
          {:ok, {id, {:ok, profile}}} when is_map(profile) -> [{id, player_result(profile)}]
          _failed -> []
        end)
        |> Map.new()
    end
  end

  # A CRCON that cannot be reached is an answer like any other here.
  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc false
  def player_result(player) do
    name =
      case player["names"] do
        [%{"name" => name} | _rest] -> name
        [name | _rest] when is_binary(name) -> name
        _none -> player["player_id"]
      end

    last_seen =
      case player["last_seen_timestamp_ms"] do
        ms when is_integer(ms) -> DateTime.from_unix!(ms, :millisecond)
        _none -> nil
      end

    online? =
      is_integer(player["current_playtime_seconds"]) and player["current_playtime_seconds"] > 0 and
        not is_nil(last_seen) and DateTime.diff(DateTime.utc_now(), last_seen) < 300

    %{player_id: player["player_id"], name: name, last_seen: last_seen, online?: online?}
  end

  # ── Gift message ───────────────────────────────────────────────────────────

  @doc "The message left on an order, or nil."
  @spec order_note(term()) :: OrderNote.t() | nil
  def order_note(order_id), do: Repo.get_by(OrderNote, order_id: order_id)

  @doc """
  Leaves a message on an order and queues its delivery in the game. A blank
  message leaves nothing.
  """
  @spec put_order_note(Order.t(), String.t() | nil) ::
          {:ok, OrderNote.t() | nil} | {:error, Ecto.Changeset.t()}
  def put_order_note(%Order{} = order, message) do
    if String.trim(message || "") == "" do
      {:ok, nil}
    else
      with {:ok, note} <-
             %OrderNote{order_id: order.id}
             |> OrderNote.changeset(%{message: message})
             |> Repo.insert() do
        %{order_id: order.id}
        |> HllConditionalActions.Workers.DeliverGiftMessage.new(schedule_in: 30)
        |> Oban.insert()

        {:ok, note}
      end
    end
  end

  @doc "Records that the message reached the player on a server."
  @spec mark_note_delivered(OrderNote.t(), String.t()) :: {:ok, OrderNote.t()}
  def mark_note_delivered(%OrderNote{} = note, server_name) do
    note
    |> Ecto.Changeset.change(
      delivered_at: DateTime.utc_now(:second),
      delivered_server: server_name
    )
    |> Repo.update()
  end

  # ── Delivery ───────────────────────────────────────────────────────────────

  @doc """
  The next automatic try of an order's delivery, while one is waiting:
  `%{attempt, max_attempts, at}` from Oban's queue, or nil.
  """
  @spec next_delivery_try(term()) :: map() | nil
  def next_delivery_try(order_id) do
    worker = inspect(HllConditionalActions.Workers.FulfillVipOrder)

    from(j in Oban.Job,
      where:
        j.worker == ^worker and fragment("(?->>'order_id')::bigint", j.args) == ^order_id and
          j.state in ["retryable", "scheduled", "available", "executing"],
      order_by: [desc: j.id],
      limit: 1,
      select: %{attempt: j.attempt, max_attempts: j.max_attempts, at: j.scheduled_at}
    )
    |> Repo.one()
  rescue
    _error -> nil
  end

  @doc "How many of an order's servers took the VIP, and how many it has."
  @spec delivery_count(Order.t()) :: {non_neg_integer(), non_neg_integer()}
  def delivery_count(%Order{} = order) do
    granted = Enum.count(order.grants, &(&1.status == "granted"))

    total =
      case order do
        %{package: %Package{servers: servers}} when is_list(servers) -> length(servers)
        _other -> max(length(order.grants), 1)
      end

    {granted, max(total, granted)}
  end

  # ── Customers ──────────────────────────────────────────────────────────────

  @doc "The customer's email preferences (every email until they change it)."
  @spec preferences(Customer.t()) :: Preference.t()
  def preferences(%Customer{id: id}),
    do: Repo.get_by(Preference, customer_id: id) || %Preference{customer_id: id}

  @doc """
  Whether a customer wants an email: `:expiry_reminders` or `:receipts`.
  For the senders of those emails to consult.
  """
  @spec wants_email?(term(), :expiry_reminders | :receipts) :: boolean()
  def wants_email?(customer_id, kind) when kind in [:expiry_reminders, :receipts] do
    case Repo.get_by(Preference, customer_id: customer_id) do
      nil -> true
      preference -> Map.fetch!(preference, kind)
    end
  end

  @doc "Changes a customer's email preferences."
  @spec update_preferences(Customer.t(), map()) ::
          {:ok, Preference.t()} | {:error, Ecto.Changeset.t()}
  def update_preferences(%Customer{} = customer, attrs) do
    customer
    |> preferences()
    |> Preference.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "A changeset for a new email, checked like the sign up's."
  @spec change_email(Customer.t(), map()) :: Ecto.Changeset.t()
  def change_email(%Customer{} = customer, attrs \\ %{}) do
    customer
    |> Ecto.Changeset.cast(attrs, [:email])
    |> Ecto.Changeset.update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> Ecto.Changeset.validate_required([:email])
    |> Ecto.Changeset.validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email"
    )
    |> Ecto.Changeset.validate_length(:email, max: 160)
    |> Ecto.Changeset.unsafe_validate_unique(:email, Repo)
    |> Ecto.Changeset.unique_constraint(:email, name: :vip_customers_email_index)
  end

  @doc """
  Changes a customer's email. An account with a password must confirm it
  with the password.
  """
  @spec update_email(Customer.t(), map()) ::
          {:ok, Customer.t()} | {:error, Ecto.Changeset.t()}
  def update_email(%Customer{} = customer, attrs) do
    changeset = change_email(customer, attrs)

    if customer.hashed_password && not Customer.valid_password?(customer, attrs["password"] || "") do
      {:error,
       changeset
       |> Ecto.Changeset.add_error(:password, "is not correct")
       |> Map.put(:action, :update)}
    else
      Repo.update(changeset)
    end
  end

  @doc """
  Unlinks the Discord account. Refused while it is the only way in (no
  email and password).
  """
  @spec disconnect_discord(Customer.t()) ::
          {:ok, Customer.t()} | {:error, :only_sign_in | Ecto.Changeset.t()}
  def disconnect_discord(%Customer{hashed_password: nil}), do: {:error, :only_sign_in}
  def disconnect_discord(%Customer{email: nil}), do: {:error, :only_sign_in}

  def disconnect_discord(%Customer{} = customer) do
    customer
    |> Ecto.Changeset.change(discord_id: nil, discord_username: nil)
    |> Repo.update()
  end

  @doc "When a password reset link stops working, or nil when it already did."
  @spec reset_expires_at(String.t()) :: DateTime.t() | nil
  def reset_expires_at(token) when is_binary(token) do
    token
    |> CustomerToken.valid_query("reset")
    |> select([t], t.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      at -> DateTime.add(at, reset_validity_minutes() * 60, :second)
    end
  end

  def reset_expires_at(_token), do: nil

  @doc "How long a password reset link works, in minutes."
  @spec reset_validity_minutes() :: pos_integer()
  def reset_validity_minutes,
    do: HllConditionalActions.VipShop.CustomerToken.reset_validity_minutes()

  @doc "What a customer paid in total, per currency, over paid orders."
  @spec spent([Order.t()]) :: [{String.t(), integer()}]
  def spent(orders) do
    orders
    |> Enum.filter(&(&1.status in ~w(paid fulfilled partial failed) and not &1.test))
    |> Enum.group_by(& &1.currency, & &1.amount_cents)
    |> Enum.map(fn {currency, amounts} -> {currency, Enum.sum(amounts)} end)
  end
end
