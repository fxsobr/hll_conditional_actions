defmodule HllConditionalActions.VipShop.Stats do
  @moduledoc """
  The numbers the shop's admin pages show: revenue and orders over a window,
  the VIPs the shop keeps active, what is waiting to be delivered, sales per
  package, how orders split between payment methods, what coupons gave, and
  the traces payments and emails leave.

  Admin test purchases never count. Money is summed in the shop's currency.
  """

  import Ecto.Query

  alias HllConditionalActions.Repo
  alias HllConditionalActions.VipShop

  alias HllConditionalActions.VipShop.{
    Coupon,
    EmailLog,
    Grant,
    Order,
    WebhookEvent
  }

  # An order whose payment went through, whatever happened to the VIP after.
  @paid ~w(paid fulfilled partial failed)

  @doc "The statuses of an order whose payment went through."
  @spec paid_statuses() :: [String.t()]
  def paid_statuses, do: @paid

  @doc """
  The overview's four numbers:

    * `:revenue` over the last 30 days and `:revenue_before`, the 30 days
      before, with `:before_month` naming the month those fell mostly in
    * `:paid_orders` and how many of them were `:gifts`
    * `:active_vips` - players with VIP from the shop now - and
      `:expiring_week`, those whose VIP ends within 7 days
    * `:pending_delivery` - paid orders whose VIP has not reached every
      server - with the `:failing_servers` holding them up
  """
  @spec overview(DateTime.t()) :: map()
  def overview(now \\ DateTime.utc_now(:second)) do
    currency = VipShop.settings().currency || "BRL"
    since = DateTime.add(now, -30 * 86_400, :second)
    before = DateTime.add(now, -60 * 86_400, :second)

    paid_window =
      from o in Order,
        where: o.status in @paid and not o.test and o.provider != "manual",
        where: o.paid_at >= ^since and o.paid_at <= ^now

    pending =
      Repo.all(
        from o in Order,
          where: o.status in ~w(paid partial failed) and not o.test,
          preload: :grants
      )

    %{
      currency: currency,
      revenue: revenue(since, now, currency),
      revenue_before: revenue(before, since, currency),
      before_month: DateTime.add(now, -45 * 86_400, :second) |> DateTime.to_date(),
      paid_orders: Repo.aggregate(paid_window, :count),
      gifts: Repo.aggregate(where(paid_window, [o], o.gift), :count),
      active_vips: active_vips(now),
      expiring_week: expiring_vips(now, 7),
      pending_delivery: length(pending),
      failing_servers:
        pending
        |> Enum.flat_map(&latest_grants(&1.grants))
        |> Enum.filter(&(&1.status == "failed"))
        |> Enum.map(& &1.server_name)
        |> Enum.uniq()
    }
  end

  @doc "Revenue in cents between two moments, in one currency."
  @spec revenue(DateTime.t(), DateTime.t(), String.t()) :: non_neg_integer()
  def revenue(from, to, currency) do
    Repo.one(
      from o in Order,
        where: o.status in @paid and not o.test and o.currency == ^currency,
        where: o.paid_at > ^from and o.paid_at <= ^to,
        select: coalesce(sum(o.amount_cents), 0)
    )
  end

  @doc "Players with VIP from the shop right now, on at least one server."
  @spec active_vips(DateTime.t()) :: non_neg_integer()
  def active_vips(now \\ DateTime.utc_now(:second)) do
    Repo.one(
      from g in Grant,
        join: o in assoc(g, :order),
        where: g.status == "granted" and (is_nil(g.expires_at) or g.expires_at > ^now),
        select: count(o.player_id, :distinct)
    )
  end

  @doc "Players whose VIP from the shop ends within the next `days`."
  @spec expiring_vips(DateTime.t(), pos_integer()) :: non_neg_integer()
  def expiring_vips(now, days) do
    until = DateTime.add(now, days * 86_400, :second)

    Repo.one(
      from g in Grant,
        join: o in assoc(g, :order),
        where: g.status == "granted" and g.expires_at > ^now and g.expires_at <= ^until,
        select: count(o.player_id, :distinct)
    )
  end

  @doc "How many times each package sold (paid, not tests), by package id."
  @spec package_sales() :: %{optional(integer()) => non_neg_integer()}
  def package_sales do
    from(o in Order,
      where: o.status in @paid and not o.test and o.provider != "manual",
      where: not is_nil(o.package_id),
      group_by: o.package_id,
      select: {o.package_id, count(o.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "The share of paid orders each payment method took in the last `days`, in percent."
  @spec provider_share(pos_integer()) :: %{optional(String.t()) => non_neg_integer()}
  def provider_share(days \\ 30) do
    since = DateTime.add(DateTime.utc_now(:second), -days * 86_400, :second)

    counts =
      Repo.all(
        from o in Order,
          where: o.status in @paid and not o.test and o.provider != "manual",
          where: o.paid_at >= ^since,
          group_by: o.provider,
          select: {o.provider, count(o.id)}
      )

    total = counts |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    if total == 0,
      do: %{},
      else: Map.new(counts, fn {provider, n} -> {provider, round(n * 100 / total)} end)
  end

  @doc """
  Shop servers whose latest VIP grant failed, with when the failures began
  (the first failure after their last success): `%{server_id => since}`.
  """
  @spec failing_servers() :: %{optional(integer()) => DateTime.t()}
  def failing_servers do
    from(g in Grant,
      where: not is_nil(g.server_id),
      order_by: [asc: g.updated_at, asc: g.id],
      select: {g.server_id, g.status, g.updated_at}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn
      {id, "failed", at}, acc -> Map.update(acc, id, {:failing, at}, &keep_first_failure(&1, at))
      {id, "granted", _at}, acc -> Map.put(acc, id, :ok)
      {_id, _status, _at}, acc -> acc
    end)
    |> Enum.flat_map(fn
      {id, {:failing, since}} -> [{id, since}]
      _ok -> []
    end)
    |> Map.new()
  end

  defp keep_first_failure({:failing, since}, _at), do: {:failing, since}
  defp keep_first_failure(:ok, at), do: {:failing, at}

  # ── Purchases ──────────────────────────────────────────────────────────────

  @doc """
  An order's grants, one per server: each attempt leaves a row, and the
  latest says where the server stands. `:attempts` counts the failed rows.
  """
  @spec latest_grants([Grant.t()]) :: [Grant.t()]
  def latest_grants(grants) do
    grants
    |> Enum.group_by(&(&1.server_id || &1.server_name))
    |> Enum.map(fn {_server, rows} -> Enum.max_by(rows, & &1.id) end)
    |> Enum.sort_by(&{&1.server_id || 0, &1.server_name})
  end

  @doc "How many times a server refused an order's VIP."
  @spec attempts([Grant.t()], Grant.t()) :: non_neg_integer()
  def attempts(grants, %Grant{} = grant) do
    Enum.count(
      grants,
      &(&1.status == "failed" and
          (&1.server_id || &1.server_name) == (grant.server_id || grant.server_name))
    )
  end

  @doc "When the next automatic delivery attempt of an order runs, or nil."
  @spec next_retry(integer()) :: DateTime.t() | nil
  def next_retry(order_id) do
    worker = "HllConditionalActions.Workers.FulfillVipOrder"

    Repo.one(
      from j in Oban.Job,
        where: j.worker == ^worker and j.state in ~w(scheduled retryable available),
        where: fragment("(?->>'order_id')::bigint = ?", j.args, ^order_id),
        order_by: [asc: j.scheduled_at],
        limit: 1,
        select: j.scheduled_at
    )
    |> case do
      nil -> nil
      %NaiveDateTime{} = at -> DateTime.from_naive!(at, "Etc/UTC")
      %DateTime{} = at -> at
    end
  end

  @doc """
  The purchases page's buckets: `:all`, `:paid` (the payment went through),
  `:pending` (waiting for it), `:failed` (refused or expired), `:refunded`
  and `:delivery` (paid, VIP not on every server yet).
  """
  @spec bucket_statuses(atom()) :: [String.t()] | nil
  def bucket_statuses(:all), do: nil
  def bucket_statuses(:paid), do: @paid
  def bucket_statuses(:pending), do: ~w(pending)
  def bucket_statuses(:failed), do: ~w(canceled)
  def bucket_statuses(:refunded), do: ~w(refunded)
  def bucket_statuses(:delivery), do: ~w(paid partial failed)

  @doc """
  Orders for the purchases page, newest first. Options: `:bucket`,
  `:provider`, `:days` (nil for all time), `:search` (player, customer, or
  order number), `:limit`.
  """
  @spec orders(keyword()) :: [Order.t()]
  def orders(opts) do
    opts
    |> orders_query()
    |> maybe_bucket(Keyword.get(opts, :bucket, :all))
    |> order_by([o], desc: o.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 20))
    |> preload([:customer, :grants])
    |> Repo.all()
  end

  @doc "How many orders each bucket holds under the same filters (except the bucket)."
  @spec bucket_counts(keyword()) :: %{atom() => non_neg_integer()}
  def bucket_counts(opts) do
    base = orders_query(opts)

    Map.new([:all, :paid, :pending, :failed, :refunded, :delivery], fn bucket ->
      {bucket, base |> maybe_bucket(bucket) |> Repo.aggregate(:count)}
    end)
  end

  defp orders_query(opts) do
    from(o in Order, where: not o.test)
    |> by_provider(Keyword.get(opts, :provider))
    |> by_days(Keyword.get(opts, :days))
    |> by_search(String.trim(Keyword.get(opts, :search) || ""))
  end

  defp by_provider(query, blank) when blank in [nil, ""], do: query
  defp by_provider(query, provider), do: where(query, [o], o.provider == ^provider)

  defp by_days(query, nil), do: query

  defp by_days(query, days) do
    since = DateTime.add(DateTime.utc_now(:second), -days * 86_400, :second)
    where(query, [o], o.inserted_at >= ^since)
  end

  defp by_search(query, ""), do: query

  defp by_search(query, term) do
    like = "%" <> String.replace(term, ~w(% _ \\), &("\\" <> &1)) <> "%"
    number = term |> String.trim_leading("#") |> String.replace(~r/^V-/i, "")

    id =
      case Integer.parse(number) do
        {id, ""} -> id
        _other -> -1
      end

    from o in query,
      left_join: c in assoc(o, :customer),
      where:
        o.id == ^id or ilike(o.player_name, ^like) or ilike(o.player_id, ^like) or
          ilike(c.name, ^like) or ilike(c.email, ^like)
  end

  defp maybe_bucket(query, bucket) do
    case bucket_statuses(bucket) do
      nil -> query
      statuses -> where(query, [o], o.status in ^statuses)
    end
  end

  # ── Coupons ────────────────────────────────────────────────────────────────

  @doc """
  What coupons did in the last `days`: paid orders with a coupon out of all
  paid orders, the discount they gave, the revenue it compares to, and the
  code used most.
  """
  @spec coupon_summary(pos_integer()) :: map()
  def coupon_summary(days \\ 30) do
    since = DateTime.add(DateTime.utc_now(:second), -days * 86_400, :second)

    paid =
      from o in Order,
        where: o.status in @paid and not o.test and o.provider != "manual",
        where: o.paid_at >= ^since

    with_coupon = where(paid, [o], not is_nil(o.coupon_code))

    top =
      Repo.one(
        from o in with_coupon,
          group_by: o.coupon_code,
          order_by: [desc: count(o.id)],
          limit: 1,
          select: {o.coupon_code, count(o.id)}
      )

    %{
      orders: Repo.aggregate(with_coupon, :count),
      paid_orders: Repo.aggregate(paid, :count),
      discount: Repo.one(from o in with_coupon, select: coalesce(sum(o.discount_cents), 0)),
      revenue: Repo.one(from o in paid, select: coalesce(sum(o.amount_cents), 0)),
      top: top
    }
  end

  @doc """
  One coupon's record: its uses per package, the discount it gave and what
  the orders with it paid.
  """
  @spec coupon_detail(Coupon.t()) :: map()
  def coupon_detail(%Coupon{id: id}) do
    orders = from o in Order, where: o.coupon_id == ^id and o.status in @paid and not o.test

    %{
      uses: Repo.aggregate(orders, :count),
      by_package:
        Repo.all(
          from o in orders,
            group_by: o.package_name,
            order_by: [desc: count(o.id)],
            select: {o.package_name, count(o.id)}
        ),
      discount: Repo.one(from o in orders, select: coalesce(sum(o.discount_cents), 0)),
      sales: Repo.one(from o in orders, select: coalesce(sum(o.amount_cents), 0))
    }
  end

  # ── Payments and email ─────────────────────────────────────────────────────

  @doc "The latest webhooks every provider sent, newest first."
  @spec webhooks(non_neg_integer()) :: [WebhookEvent.t()]
  def webhooks(limit \\ 10) do
    Repo.all(from w in WebhookEvent, order_by: [desc: w.inserted_at, desc: w.id], limit: ^limit)
  end

  @doc "Webhooks accepted and refused in the last `hours`."
  @spec webhook_counts(pos_integer()) :: %{ok: non_neg_integer(), refused: non_neg_integer()}
  def webhook_counts(hours \\ 24) do
    since = DateTime.add(DateTime.utc_now(:second), -hours * 3600, :second)

    counts =
      Repo.all(
        from w in WebhookEvent,
          where: w.inserted_at >= ^since,
          group_by: w.ok,
          select: {w.ok, count(w.id)}
      )
      |> Map.new()

    %{ok: Map.get(counts, true, 0), refused: Map.get(counts, false, 0)}
  end

  @doc "Emails sent and failed in the last `days`."
  @spec email_counts(pos_integer()) :: %{sent: non_neg_integer(), failed: non_neg_integer()}
  def email_counts(days \\ 30) do
    since = DateTime.add(DateTime.utc_now(:second), -days * 86_400, :second)

    counts =
      Repo.all(
        from e in EmailLog,
          where: e.inserted_at >= ^since,
          group_by: e.ok,
          select: {e.ok, count(e.id)}
      )
      |> Map.new()

    %{sent: Map.get(counts, true, 0), failed: Map.get(counts, false, 0)}
  end

  @doc "The latest email sent to an address, or nil."
  @spec last_email_to(String.t() | nil) :: EmailLog.t() | nil
  def last_email_to(nil), do: nil

  def last_email_to(to) do
    Repo.one(from e in EmailLog, where: e.to == ^to, order_by: [desc: e.id], limit: 1)
  end

  @doc "Records an email the shop tried to send."
  @spec log_email(String.t(), String.t(), :ok | {:error, term()}, non_neg_integer()) :: :ok
  def log_email(template, to, result, duration_ms) do
    Repo.insert!(%EmailLog{
      template: template,
      to: to,
      ok: result == :ok,
      error:
        case result do
          :ok -> nil
          {:error, reason} -> reason |> inspect() |> String.slice(0, 250)
        end,
      duration_ms: duration_ms
    })

    :ok
  end
end
