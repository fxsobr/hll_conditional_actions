defmodule HllConditionalActions.Briefing do
  @moduledoc """
  The numbers behind the Briefing (`HllConditionalActionsWeb.DashboardLive`)
  that no other context keeps:

    * `activity/4` - what the rules did over a period, split by the series
      the chart shows (every fire, live ones, simulated ones), with a daily
      row for each of the four metrics and the period before to compare
    * `simulation_digest/2` - what a rule in simulation *would* have done,
      action by action
    * `ticket_counts/1` - open tickets and how many have nobody on them
    * `last_events/1`, `recent_events/2`, `event_stats/1` - the latest
      events a server's stream delivered, from the saved samples
    * `ticket_quotes/1` - the first thing the player wrote on a ticket
    * `seeding_threshold/2` - the player count under which a server's
      seeding reward pays out
    * `team_without/2` - teammates restricted to other servers

  Everything is scoped to the servers the user may see.
  """

  import Ecto.Query

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.User
  alias HllConditionalActions.Engine.SavedEvent
  alias HllConditionalActions.Engine.SavedEvents
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Tickets.Message
  alias HllConditionalActions.Tickets.Ticket

  @series ~w(all live simulated)

  @doc "The series the chart can show."
  @spec series() :: [String.t()]
  def series, do: @series

  # ── Activity ───────────────────────────────────────────────────────────────

  @doc """
  What the rules did over the last `days` days, for one series (`"all"`,
  `"live"` or `"simulated"`):

    * `:totals` / `:previous` - `fired`, `live`, `simulated`, `failed`,
      `players` (distinct), `duration_ms` (average) and `success_rate` (of
      the live runs, one decimal) for the period and the one before it
    * `:daily` - one row per day, oldest first, with `fired`, `failed`,
      `players` and `duration_ms`

  Days are bucketed in UTC.
  """
  @spec activity(map() | nil, pos_integer(), String.t(), keyword()) :: map()
  def activity(user, days, series \\ "all", opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    since = DateTime.add(now, -days, :day)
    before = DateTime.add(since, -days, :day)
    scope = user |> Rules.scoped_executions() |> only(series)

    %{
      days: days,
      series: series,
      since: since,
      until: now,
      totals: totals(scope, since, now),
      previous: totals(scope, before, since),
      daily: daily(scope, since, days)
    }
  end

  defp only(query, "live"), do: where(query, [e], e.status != :simulated)
  defp only(query, "simulated"), do: where(query, [e], e.status == :simulated)
  defp only(query, _all), do: query

  defp window(query, from, to),
    do: where(query, [e], e.executed_at >= ^from and e.executed_at < ^to)

  defp totals(scope, from, to) do
    row =
      scope
      |> window(from, to)
      |> select([e], %{
        fired: count(e.id),
        simulated: filter(count(e.id), e.status == :simulated),
        failed: filter(count(e.id), e.status in [:failed, :partial]),
        players: count(e.player_id, :distinct),
        duration: avg(fragment("CAST(? ->> 'duration_ms' AS double precision)", e.trace))
      })
      |> Repo.one()

    live = row.fired - row.simulated

    %{
      fired: row.fired,
      live: live,
      simulated: row.simulated,
      failed: row.failed,
      players: row.players,
      duration_ms: row.duration && round(row.duration),
      success_rate: if(live > 0, do: Float.round((live - row.failed) * 100 / live, 1))
    }
  end

  defp daily(scope, since, days) do
    rows =
      scope
      |> window(since, DateTime.add(since, days + 1, :day))
      |> group_by([e], fragment("date_trunc('day', ?)::date", e.executed_at))
      |> select([e], {
        fragment("date_trunc('day', ?)::date", e.executed_at),
        count(e.id),
        filter(count(e.id), e.status in [:failed, :partial]),
        count(e.player_id, :distinct),
        avg(fragment("CAST(? ->> 'duration_ms' AS double precision)", e.trace))
      })
      |> Repo.all()
      |> Map.new(fn {date, fired, failed, players, duration} ->
        {date,
         %{
           fired: fired,
           failed: failed,
           players: players,
           duration_ms: duration && round(duration)
         }}
      end)

    first = DateTime.to_date(since)

    Enum.map(0..days, fn offset ->
      date = Date.add(first, offset)

      rows
      |> Map.get(date, %{fired: 0, failed: 0, players: 0, duration_ms: nil})
      |> Map.put(:date, date)
    end)
  end

  # ── Simulation ─────────────────────────────────────────────────────────────

  @doc """
  What a rule recorded while simulating: how many runs, on how many
  players, since when, and each action it would have taken with how many
  times (most frequent first).
  """
  @spec simulation_digest(map() | nil, map()) :: map()
  def simulation_digest(user, rule) do
    rows =
      user
      |> Rules.scoped_executions()
      |> where([e], e.rule_id == ^rule.id and e.status == :simulated)
      |> order_by([e], desc: e.id)
      |> limit(5_000)
      |> select([e], {e.player_id, e.results, e.executed_at})
      |> Repo.all()

    actions =
      rows
      |> Enum.flat_map(fn {_player, results, _at} -> results || [] end)
      |> Enum.filter(&(result_value(&1, "status") == "simulated"))
      |> Enum.frequencies_by(&result_value(&1, "type"))
      |> Enum.reject(fn {type, _count} -> is_nil(type) end)
      |> Enum.sort_by(fn {_type, count} -> -count end)

    first_at = rows |> Enum.map(&elem(&1, 2)) |> Enum.min(DateTime, fn -> nil end)

    %{
      runs: length(rows),
      players:
        rows |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length(),
      since: first_at,
      days: days_since(first_at),
      actions: actions
    }
  end

  defp result_value(result, key) when is_map(result) do
    case Map.get(result, key, Map.get(result, String.to_existing_atom(key))) do
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      value -> value
    end
  end

  defp result_value(_result, _key), do: nil

  defp days_since(nil), do: 0
  defp days_since(at), do: max(DateTime.diff(DateTime.utc_now(), at, :day), 1)

  # ── Tickets ────────────────────────────────────────────────────────────────

  @doc "Tickets not closed yet, and how many of them nobody took."
  @spec ticket_counts(User.t()) :: %{active: non_neg_integer(), unassigned: non_neg_integer()}
  def ticket_counts(user) do
    user
    |> tickets_scope()
    |> where([t], t.status != :closed)
    |> select([t], %{
      active: count(t.id),
      unassigned: filter(count(t.id), is_nil(t.assigned_to_id))
    })
    |> Repo.one()
  end

  defp tickets_scope(user) do
    case Accounts.server_scope(user) do
      :all -> from(t in Ticket)
      ids -> from(t in Ticket, where: t.server_id in ^ids)
    end
  end

  @doc "The first message a player wrote on each ticket, by ticket id."
  @spec ticket_quotes([term()]) :: %{term() => String.t()}
  def ticket_quotes([]), do: %{}

  def ticket_quotes(ticket_ids) do
    Message
    |> where([m], m.ticket_id in ^ticket_ids and m.author == :player)
    |> order_by([m], asc: m.id)
    |> select([m], {m.ticket_id, m.body})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {id, body}, acc -> Map.put_new(acc, id, body) end)
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @doc "When each server's stream last delivered an event, by server id."
  @spec last_events([term()]) :: %{term() => DateTime.t()}
  def last_events([]), do: %{}

  def last_events(server_ids) do
    SavedEvent
    |> where([e], e.server_id in ^server_ids)
    |> group_by([e], e.server_id)
    |> select([e], {e.server_id, max(e.occurred_at)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "How many events of a server are on record, and when the first arrived."
  @spec event_stats(term()) :: %{count: non_neg_integer(), first_at: DateTime.t() | nil}
  def event_stats(server_id) do
    SavedEvent
    |> where([e], e.server_id == ^server_id)
    |> select([e], %{count: count(e.id), first_at: min(e.occurred_at)})
    |> Repo.one()
  end

  @doc """
  A server's latest events as `%{at, event}`, newest first. A kill is saved
  once for the killer and once for the victim; it is listed once.
  """
  @spec recent_events(term(), pos_integer()) :: [map()]
  def recent_events(server_id, limit) do
    [server_id]
    |> SavedEvents.list(limit: limit * 2)
    |> Enum.map(fn saved -> %{at: saved.occurred_at, event: sample_event(saved.sample)} end)
    |> Enum.reject(&is_nil(&1.event))
    |> Enum.uniq_by(&event_key/1)
    |> Enum.take(limit)
  end

  defp sample_event(%{event: %{type: _type} = event}), do: event
  defp sample_event(_sample), do: nil

  defp event_key(%{at: at, event: event}),
    do: {Map.get(event, :raw) || at, Map.get(event, :type)}

  # ── Seeding ────────────────────────────────────────────────────────────────

  @doc """
  The player count at or under which a server hands out its seeding reward:
  the threshold of an enabled, live rule that grants VIP while the server's
  player count is low. `nil` when the server has no such rule.
  """
  @spec seeding_threshold([map()], term()) :: pos_integer() | nil
  def seeding_threshold(rules, server_id) do
    rules
    |> Enum.filter(fn rule ->
      rule.enabled and not rule.simulation and rule.server_id in [nil, server_id] and
        Enum.any?(rule.actions, &(&1.type == :grant_vip))
    end)
    |> Enum.flat_map(fn rule -> Enum.flat_map(rule.conditions, &threshold/1) end)
    |> Enum.max(fn -> nil end)
  end

  defp threshold(%{field: :server_player_count, operator: operator, value: value})
       when operator in [:less_than, :less_than_or_equal] do
    case Integer.parse(to_string(value)) do
      {number, _rest} when operator == :less_than -> [number - 1]
      {number, _rest} -> [number]
      :error -> []
    end
  end

  defp threshold(_condition), do: []

  # ── Team ───────────────────────────────────────────────────────────────────

  @doc """
  Active teammates restricted to other servers, who cannot see this one yet.
  Unrestricted users see every server already and are left out.
  """
  @spec team_without(User.t(), map()) :: [User.t()]
  def team_without(%User{} = viewer, server) do
    if Accounts.can?(viewer, :manage_users) do
      Accounts.list_users()
      |> Enum.filter(fn user ->
        user.id != viewer.id and user.active and user.servers != [] and
          not Enum.any?(user.servers, &(&1.id == server.id))
      end)
    else
      []
    end
  end

  def team_without(_viewer, _server), do: []

  @doc "Gives each of these users access to a server, on top of theirs."
  @spec grant_server([User.t()], map()) :: :ok
  def grant_server(users, server) do
    Enum.each(users, fn user ->
      {:ok, _user} =
        Accounts.set_user_servers(user, [server.id | Enum.map(user.servers, & &1.id)])
    end)
  end
end
