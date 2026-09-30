defmodule HllConditionalActions.Tickets.Stats do
  @moduledoc """
  The numbers behind the ticket pages: the metrics page (tickets per day,
  first answers, the weekday-by-hour heatmap, who answered, categories, who
  calls and who is reported the most, each against the period before), the
  Caixa's "today" line, and the counts the settings page shows next to each
  category and quick reply.

  Everything is counted from stored tickets and messages, on the servers the
  user sees, with days and hours in the time zone given.
  """

  import Ecto.Query

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.User
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Tickets.Message
  alias HllConditionalActions.Tickets.Ticket

  # The first-answer buckets of the metrics page, in seconds: {label key, from, until}.
  @buckets [
    {:under_1, 0, 60},
    {:from_1_to_3, 60, 180},
    {:from_3_to_5, 180, 300},
    {:from_5_to_15, 300, 900},
    {:over_15, 900, nil}
  ]

  @doc "The keys of the first-answer buckets, in order."
  @spec bucket_keys() :: [atom()]
  def bucket_keys, do: Enum.map(@buckets, &elem(&1, 0))

  # ── Metrics page ───────────────────────────────────────────────────────────

  @doc """
  The metrics page over the last `:days` (7, 30 or 90), on `:server_ids`
  (nil for every server the user sees), in `:timezone`.
  """
  @spec metrics(User.t(), keyword()) :: map()
  def metrics(user, opts \\ []) do
    days = Keyword.get(opts, :days, 30)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    now = Keyword.get(opts, :now, DateTime.utc_now())
    today = local_date(now, timezone)
    first_day = Date.add(today, -(days - 1))
    since = start_of_day(first_day, timezone)
    previous_since = start_of_day(Date.add(first_day, -days), timezone)

    rows = rows(user, Keyword.get(opts, :server_ids), previous_since)
    {current, previous} = Enum.split_with(rows, &(DateTime.compare(&1.inserted_at, since) != :lt))

    responders = first_responders(Enum.map(current, & &1.id))

    %{
      days: days,
      timezone: timezone,
      first_day: first_day,
      today: today,
      total: length(current),
      previous_total: length(previous),
      per_day: per_day(current, first_day, today, timezone),
      busiest_weekday: busiest_weekday(current, timezone),
      first_response: first_response(current, previous),
      heatmap: heatmap(current, timezone),
      responders: responder_rows(current, responders),
      auto_answered: Enum.count(current, & &1.outside_hours),
      unanswered: unanswered(current),
      categories: categories(current),
      category_growth: category_growth(current, previous),
      top_players: top_players(current),
      most_cited: most_cited(current)
    }
  end

  defp rows(user, server_ids, since) do
    user
    |> scoped()
    |> then(fn query ->
      if is_list(server_ids), do: where(query, [t], t.server_id in ^server_ids), else: query
    end)
    |> where([t], t.inserted_at >= ^since)
    |> select([t], %{
      id: t.id,
      inserted_at: t.inserted_at,
      first_response_at: t.first_response_at,
      closed_at: t.closed_at,
      status: t.status,
      close_reason: t.close_reason,
      category: t.category,
      player_id: t.player_id,
      player_name: t.player_name,
      source: t.source,
      outside_hours: t.outside_hours,
      reported_player_id: t.reported_player_id,
      reported_player_name: t.reported_player_name
    })
    |> Repo.all()
  end

  @doc """
  Tickets opened per local day, from `first_day` to `today`, as
  `[{date, count}]`.
  """
  @spec per_day([map()], Date.t(), Date.t(), String.t()) :: [{Date.t(), non_neg_integer()}]
  def per_day(rows, first_day, today, timezone) do
    counts = Enum.frequencies_by(rows, &local_date(&1.inserted_at, timezone))

    first_day
    |> Date.range(today)
    |> Enum.map(&{&1, Map.get(counts, &1, 0)})
  end

  # The weekday most tickets come in on, and its share of them.
  defp busiest_weekday([], _timezone), do: nil

  defp busiest_weekday(rows, timezone) do
    {day, count} =
      rows
      |> Enum.frequencies_by(&Date.day_of_week(local_date(&1.inserted_at, timezone)))
      |> Enum.max_by(fn {_day, count} -> count end)

    %{weekday: day, count: count, one_in: max(1, round(length(rows) / count))}
  end

  # From a player's call to the first admin answer, for tickets players
  # opened inside office hours (an auto reply at night is not an answer).
  defp first_response(current, previous) do
    times = response_times(current)
    before = response_times(previous)

    %{
      count: length(times),
      median: percentile(times, 50),
      p90: percentile(times, 90),
      previous_median: percentile(before, 50),
      previous_p90: percentile(before, 90),
      buckets:
        Enum.map(@buckets, fn {key, from, until} ->
          {key, Enum.count(times, &(&1 >= from and (is_nil(until) or &1 < until)))}
        end)
    }
  end

  defp response_times(rows) do
    rows
    |> Enum.filter(&(&1.source == :chat and not &1.outside_hours and &1.first_response_at))
    |> Enum.map(&DateTime.diff(&1.first_response_at, &1.inserted_at))
    |> Enum.map(&max(&1, 0))
    |> Enum.sort()
  end

  @doc """
  The value at a percentile of a sorted list (nearest rank), or nil.

      iex> HllConditionalActions.Tickets.Stats.percentile([10, 20, 30, 40], 50)
      20
      iex> HllConditionalActions.Tickets.Stats.percentile([10, 20, 30, 40, 50, 60, 70, 80, 90, 100], 90)
      90
      iex> HllConditionalActions.Tickets.Stats.percentile([], 50)
      nil
  """
  @spec percentile([number()], number()) :: number() | nil
  def percentile([], _percent), do: nil

  def percentile(sorted, percent) do
    rank = max(1, ceil(percent / 100 * length(sorted)))
    Enum.at(sorted, rank - 1)
  end

  @doc """
  Tickets per weekday (1 Monday .. 7 Sunday) and hour, as a map of
  `{weekday, hour} => count`.
  """
  @spec heatmap([map()], String.t()) :: %{{1..7, 0..23} => pos_integer()}
  def heatmap(rows, timezone) do
    Enum.frequencies_by(rows, fn row ->
      local = shift(row.inserted_at, timezone)
      {Date.day_of_week(local), local.hour}
    end)
  end

  # Who gave the first answer on each ticket: ticket id => user.
  defp first_responders([]), do: %{}

  defp first_responders(ids) do
    Repo.all(
      from m in Message,
        join: u in assoc(m, :user),
        where: m.author == :admin and m.ticket_id in ^ids,
        distinct: m.ticket_id,
        order_by: [asc: m.ticket_id, asc: m.inserted_at, asc: m.id],
        select: {m.ticket_id, %{id: u.id, name: coalesce(u.name, u.username)}}
    )
    |> Map.new()
  end

  defp responder_rows(rows, responders) do
    rows
    |> Enum.filter(&Map.has_key?(responders, &1.id))
    |> Enum.group_by(&responders[&1.id])
    |> Enum.map(fn {user, tickets} ->
      times =
        tickets
        |> Enum.filter(& &1.first_response_at)
        |> Enum.map(&max(DateTime.diff(&1.first_response_at, &1.inserted_at), 0))
        |> Enum.sort()

      %{user_id: user.id, name: user.name, count: length(tickets), median: percentile(times, 50)}
    end)
    |> Enum.sort_by(&(-&1.count))
  end

  # Closed without any admin answer, and the reason most of them closed for.
  defp unanswered(rows) do
    closed = Enum.filter(rows, &(&1.status == :closed and is_nil(&1.first_response_at)))

    reason =
      closed
      |> Enum.map(& &1.close_reason)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.max_by(fn {_reason, count} -> count end, fn -> {nil, 0} end)
      |> elem(0)

    %{count: length(closed), reason: reason}
  end

  defp categories(rows) do
    rows
    |> Enum.frequencies_by(& &1.category)
    |> Enum.sort_by(fn {name, count} -> {is_nil(name), -count, name} end)
  end

  # The category that grew the most against the period before, if any grew.
  defp category_growth(current, previous) do
    before = Enum.frequencies_by(previous, & &1.category)

    current
    |> Enum.frequencies_by(& &1.category)
    |> Enum.reject(fn {name, _count} -> is_nil(name) end)
    |> Enum.map(fn {name, count} -> {name, count - Map.get(before, name, 0)} end)
    |> Enum.filter(fn {_name, growth} -> growth > 0 end)
    |> Enum.max_by(fn {_name, growth} -> growth end, fn -> nil end)
  end

  defp top_players(rows) do
    rows
    |> Enum.filter(&(&1.source == :chat))
    |> Enum.group_by(& &1.player_id)
    |> Enum.map(fn {player_id, tickets} ->
      {category, in_category} =
        tickets
        |> Enum.map(& &1.category)
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies()
        |> Enum.max_by(fn {_name, count} -> count end, fn -> {nil, 0} end)

      %{
        player_id: player_id,
        name: tickets |> Enum.map(& &1.player_name) |> Enum.find(& &1) || player_id,
        count: length(tickets),
        category: category,
        in_category: in_category
      }
    end)
    |> Enum.sort_by(&{-&1.count, &1.name})
    |> Enum.take(3)
  end

  defp most_cited(rows) do
    rows
    |> Enum.filter(& &1.reported_player_id)
    |> Enum.group_by(& &1.reported_player_id)
    |> Enum.max_by(fn {_id, tickets} -> length(tickets) end, fn -> nil end)
    |> case do
      nil ->
        nil

      {id, tickets} ->
        %{
          player_id: id,
          name: tickets |> Enum.map(& &1.reported_player_name) |> Enum.find(& &1) || id,
          tickets: length(tickets),
          callers: tickets |> Enum.map(& &1.player_id) |> Enum.uniq() |> length()
        }
    end
  end

  # ── The Caixa ──────────────────────────────────────────────────────────────

  @doc """
  Today's work in the Caixa's servers: tickets closed today and the median
  first answer of the tickets opened today, in seconds.
  """
  @spec today(User.t(), [term()], String.t()) :: %{
          resolved: non_neg_integer(),
          median_response: integer() | nil
        }
  def today(user, server_ids, timezone) do
    since = start_of_day(local_date(DateTime.utc_now(), timezone), timezone)
    base = user |> scoped() |> where([t], t.server_id in ^server_ids)

    resolved =
      base |> where([t], t.status == :closed and t.closed_at >= ^since) |> Repo.aggregate(:count)

    times =
      base
      |> where([t], t.inserted_at >= ^since and not is_nil(t.first_response_at))
      |> where([t], t.source == :chat)
      |> select([t], {t.inserted_at, t.first_response_at})
      |> Repo.all()
      |> Enum.map(fn {opened, answered} -> max(DateTime.diff(answered, opened), 0) end)
      |> Enum.sort()

    %{resolved: resolved, median_response: percentile(times, 50)}
  end

  # ── Settings page ──────────────────────────────────────────────────────────

  @doc """
  Tickets per category on a server since the first of this month.
  """
  @spec category_counts_this_month(term(), String.t()) :: %{String.t() => pos_integer()}
  def category_counts_this_month(server_id, timezone) do
    today = local_date(DateTime.utc_now(), timezone)
    since = start_of_day(Date.beginning_of_month(today), timezone)

    Repo.all(
      from t in Ticket,
        where: t.server_id == ^server_id and t.inserted_at >= ^since and not is_nil(t.category),
        group_by: fragment("lower(?)", t.category),
        select: {fragment("lower(?)", t.category), count(t.id)}
    )
    |> Map.new()
  end

  @doc """
  How many answers each quick reply started, on a server: title => count.
  """
  @spec reply_uses(term()) :: %{String.t() => pos_integer()}
  def reply_uses(server_id) do
    Repo.all(
      from m in Message,
        join: t in assoc(m, :ticket),
        where: t.server_id == ^server_id and not is_nil(m.quick_reply),
        group_by: m.quick_reply,
        select: {m.quick_reply, count(m.id)}
    )
    |> Map.new()
  end

  @doc """
  The last ticket announced on Discord for a server: `{at, ticket_id}`.
  """
  @spec last_announcement(term()) :: {DateTime.t(), term()} | nil
  def last_announcement(server_id) do
    Repo.one(
      from t in Ticket,
        where: t.server_id == ^server_id and not is_nil(t.announced_at),
        order_by: [desc: t.announced_at],
        limit: 1,
        select: {t.announced_at, t.id}
    )
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp scoped(user) do
    case Accounts.server_scope(user) do
      :all -> Ticket
      ids -> where(Ticket, [t], t.server_id in ^ids)
    end
  end

  @doc false
  def local_date(%DateTime{} = at, timezone), do: at |> shift(timezone) |> DateTime.to_date()

  defp shift(at, timezone) do
    case DateTime.shift_zone(at, timezone || "Etc/UTC") do
      {:ok, local} -> local
      {:error, _reason} -> at
    end
  end

  @doc false
  def start_of_day(%Date{} = date, timezone) do
    case DateTime.new(date, ~T[00:00:00], timezone || "Etc/UTC") do
      {:ok, at} -> DateTime.shift_zone!(at, "Etc/UTC")
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _before, after_gap} -> DateTime.shift_zone!(after_gap, "Etc/UTC")
      {:error, _reason} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end
end
