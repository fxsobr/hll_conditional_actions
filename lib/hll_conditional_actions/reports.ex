defmodule HllConditionalActions.Reports do
  @moduledoc """
  The numbers behind the overview: what the rules did over a period, compared
  with the period before it.

  Everything is read from `rule_executions`, scoped to the servers the user
  may see, so the overview never shows activity from a server the history
  would hide. Days are bucketed in UTC; at a day's resolution that is close
  enough for a fleet that spans time zones anyway.
  """

  import Ecto.Query

  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Rule

  @periods [7, 30, 90]

  @doc "The periods the overview offers, in days."
  @spec periods() :: [pos_integer()]
  def periods, do: @periods

  @doc """
  Everything the overview shows for the last `days` days.

    * `:totals` / `:previous` - counts for this period and the one before it
    * `:daily` - one entry per day, oldest first, with fired/failed/simulated
    * `:by_trigger` - executions per trigger, largest first
    * `:rules` - the busiest rules with their success rate and reach
  """
  @spec overview(map() | nil, pos_integer(), keyword()) :: map()
  def overview(user, days, opts \\ []) when days in @periods do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    since = DateTime.add(now, -days, :day)
    before = DateTime.add(since, -days, :day)
    scope = Rules.scoped_executions(user)

    %{
      days: days,
      since: since,
      until: now,
      totals: totals(scope, since, now),
      previous: totals(scope, before, since),
      daily: daily(scope, since, now, days),
      by_trigger: by_trigger(scope, since, now),
      rules: busiest_rules(scope, since, now)
    }
  end

  @doc """
  The relative change between two numbers, in whole percent, or `nil` when
  there is nothing to compare against.

      iex> HllConditionalActions.Reports.change(120, 100)
      20
      iex> HllConditionalActions.Reports.change(5, 0)
      nil
  """
  @spec change(number() | nil, number() | nil) :: integer() | nil
  def change(_current, previous) when previous in [nil, 0], do: nil
  def change(nil, _previous), do: nil
  def change(current, previous), do: round((current - previous) * 100 / previous)

  # ── Queries ────────────────────────────────────────────────────────────────

  defp window(scope, from, to) do
    where(scope, [e], e.executed_at >= ^from and e.executed_at < ^to)
  end

  defp totals(scope, from, to) do
    counts =
      scope
      |> window(from, to)
      |> group_by([e], e.status)
      |> select([e], {e.status, count(e.id)})
      |> Repo.all()
      |> Map.new()

    stats =
      scope
      |> window(from, to)
      |> select([e], %{
        players: count(e.player_id, :distinct),
        duration: avg(fragment("CAST(? ->> 'duration_ms' AS double precision)", e.trace))
      })
      |> Repo.one()

    live =
      Map.get(counts, :executed, 0) + Map.get(counts, :partial, 0) + Map.get(counts, :failed, 0)

    failed = Map.get(counts, :failed, 0) + Map.get(counts, :partial, 0)

    %{
      fired: live + Map.get(counts, :simulated, 0),
      live: live,
      failed: failed,
      simulated: Map.get(counts, :simulated, 0),
      success_rate: if(live > 0, do: round((live - failed) * 100 / live)),
      players: stats.players,
      duration_ms: stats.duration && round(stats.duration)
    }
  end

  defp daily(scope, from, to, days) do
    rows =
      scope
      |> window(from, to)
      |> group_by([e], [fragment("date_trunc('day', ?)::date", e.executed_at), e.status])
      |> select(
        [e],
        {fragment("date_trunc('day', ?)::date", e.executed_at), e.status, count(e.id)}
      )
      |> Repo.all()

    first = DateTime.to_date(from)

    Enum.map(0..days, fn offset ->
      date = Date.add(first, offset)
      on_day = for {^date, status, count} <- rows, do: {status, count}

      %{
        date: date,
        fired: on_day |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
        failed:
          for({status, count} <- on_day, status in [:failed, :partial], do: count) |> Enum.sum(),
        simulated: for({:simulated, count} <- on_day, do: count) |> Enum.sum()
      }
    end)
  end

  defp by_trigger(scope, from, to) do
    scope
    |> window(from, to)
    |> group_by([e], e.trigger_event)
    |> select([e], {e.trigger_event, count(e.id)})
    |> order_by([e], desc: count(e.id))
    |> Repo.all()
  end

  defp busiest_rules(scope, from, to) do
    scope
    |> window(from, to)
    |> join(:inner, [e], r in Rule, on: r.id == e.rule_id)
    |> group_by([e, r], [r.id, r.name, r.trigger_event, r.enabled, r.simulation])
    |> select([e, r], %{
      id: r.id,
      name: r.name,
      trigger: r.trigger_event,
      enabled: r.enabled,
      simulation: r.simulation,
      fired: count(e.id),
      failed: filter(count(e.id), e.status in [:failed, :partial]),
      simulated: filter(count(e.id), e.status == :simulated),
      players: count(e.player_id, :distinct),
      last_at: max(e.executed_at)
    })
    |> order_by([e], desc: count(e.id))
    |> limit(8)
    |> Repo.all()
  end
end
