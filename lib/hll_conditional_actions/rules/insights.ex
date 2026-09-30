defmodule HllConditionalActions.Rules.Insights do
  @moduledoc """
  The numbers the Regras pages show about rules, computed in the database.

  The rules list needs a week of runs per rule and what failed; the rule
  page needs what a simulation recorded and how often each rung of an
  escalation ladder ran; the history needs a month of outcomes compared with
  the month before. Every query here is scoped to what the user may see
  (`HllConditionalActions.Rules.scoped_executions/1`), and each answers for
  a whole page in one or two round trips rather than a query per row.
  """

  import Ecto.Query

  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Rule

  @day 24 * 60 * 60

  # ── The rules list ─────────────────────────────────────────────────────────

  @doc """
  Runs per rule for each of the last seven days (UTC, oldest first) and how
  many of them failed, as `%{rule_id => %{days: [7 counts], total, failed}}`.
  Rules that did not run are absent.
  """
  @spec week_activity(map() | nil, [term()]) :: %{
          term() => %{
            days: [non_neg_integer()],
            total: non_neg_integer(),
            failed: non_neg_integer()
          }
        }
  def week_activity(_user, []), do: %{}

  def week_activity(user, rule_ids) do
    today = Date.utc_today()
    days = Enum.map(-6..0//1, &Date.add(today, &1))
    since = DateTime.new!(List.first(days), ~T[00:00:00], "Etc/UTC")

    user
    |> Rules.scoped_executions()
    |> where([e], e.rule_id in ^rule_ids and e.executed_at >= ^since)
    |> group_by([e], [e.rule_id, fragment("(?)::date", e.executed_at)])
    |> select([e], {
      e.rule_id,
      fragment("(?)::date", e.executed_at),
      count(e.id),
      filter(count(e.id), e.status in [^:failed, ^:partial])
    })
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {rule_id, rows} ->
      by_day = Map.new(rows, fn {_id, day, runs, _failed} -> {day, runs} end)
      counts = Enum.map(days, &Map.get(by_day, &1, 0))

      {rule_id,
       %{
         days: counts,
         total: Enum.sum(counts),
         failed: rows |> Enum.map(&elem(&1, 3)) |> Enum.sum()
       }}
    end)
  end

  @doc """
  What went wrong with each rule in the last 24 hours: how many runs failed
  (in whole or in part) and the error of the latest one, as
  `%{rule_id => %{count, error, at}}`. Rules without a failure are absent.
  """
  @spec failures(map() | nil, [term()]) :: %{
          term() => %{count: pos_integer(), error: String.t() | nil, at: DateTime.t()}
        }
  def failures(_user, []), do: %{}

  def failures(user, rule_ids) do
    since = DateTime.add(DateTime.utc_now(), -@day, :second)

    failed =
      user
      |> Rules.scoped_executions()
      |> where(
        [e],
        e.rule_id in ^rule_ids and e.executed_at >= ^since and e.status in [^:failed, ^:partial]
      )

    counts =
      failed
      |> group_by([e], e.rule_id)
      |> select([e], {e.rule_id, count(e.id)})
      |> Repo.all()
      |> Map.new()

    latest =
      failed
      |> distinct([e], e.rule_id)
      |> order_by([e], asc: e.rule_id, desc: e.executed_at, desc: e.id)
      |> select([e], {e.rule_id, e.error, e.executed_at})
      |> Repo.all()

    Map.new(latest, fn {rule_id, error, at} ->
      {rule_id, %{count: Map.get(counts, rule_id, 0), error: error, at: at}}
    end)
  end

  @doc """
  The whole list's last week against the week before: runs, the previous
  week's runs, failed runs and how many rules those failures came from.
  """
  @spec week_summary(map() | nil, [term()]) :: %{
          runs: non_neg_integer(),
          previous: non_neg_integer(),
          failures: non_neg_integer(),
          failing_rules: non_neg_integer()
        }
  def week_summary(_user, []), do: %{runs: 0, previous: 0, failures: 0, failing_rules: 0}

  def week_summary(user, rule_ids) do
    now = DateTime.utc_now()
    week_ago = DateTime.add(now, -7 * @day, :second)
    two_weeks_ago = DateTime.add(now, -14 * @day, :second)

    base =
      user
      |> Rules.scoped_executions()
      |> where([e], e.rule_id in ^rule_ids and e.executed_at >= ^two_weeks_ago)

    totals =
      base
      |> select([e], %{
        runs: filter(count(e.id), e.executed_at >= ^week_ago),
        previous: filter(count(e.id), e.executed_at < ^week_ago),
        failures:
          filter(count(e.id), e.executed_at >= ^week_ago and e.status in [^:failed, ^:partial])
      })
      |> Repo.one()

    failing_rules =
      base
      |> where([e], e.executed_at >= ^week_ago and e.status in [^:failed, ^:partial])
      |> select([e], count(e.rule_id, :distinct))
      |> Repo.one()

    Map.put(totals, :failing_rules, failing_rules || 0)
  end

  @doc """
  A change in percent from `previous` to `current`, rounded, or `nil` when
  there is nothing to compare with.

      iex> HllConditionalActions.Rules.Insights.delta(108, 100)
      8
      iex> HllConditionalActions.Rules.Insights.delta(5, 0)
      nil
  """
  @spec delta(non_neg_integer(), non_neg_integer()) :: integer() | nil
  def delta(_current, 0), do: nil
  def delta(current, previous), do: round((current - previous) * 100 / previous)

  # ── The rule page ──────────────────────────────────────────────────────────

  @doc """
  What a simulating rule's simulated runs recorded: how many, since when,
  how many players they would have reached, on how many servers, and how
  many runs failed since the first of them. `nil` for a rule that is not
  simulating.
  """
  @spec simulation(Rule.t()) :: map() | nil
  def simulation(%Rule{simulation: true, id: id}) when not is_nil(id) do
    runs =
      nil
      |> Rules.scoped_executions()
      |> where([e], e.rule_id == ^id and e.status == ^:simulated)
      |> select([e], %{
        runs: count(e.id),
        since: min(e.executed_at),
        players: count(e.player_id, :distinct),
        servers: count(e.server_id, :distinct)
      })
      |> Repo.one()

    failures =
      case runs.since do
        nil ->
          0

        since ->
          nil
          |> Rules.scoped_executions()
          |> where(
            [e],
            e.rule_id == ^id and e.executed_at >= ^since and e.status in [^:failed, ^:partial]
          )
          |> select([e], count(e.id))
          |> Repo.one()
      end

    days =
      case runs.since do
        nil -> 0
        since -> div(DateTime.diff(DateTime.utc_now(), since, :second), @day)
      end

    Map.merge(runs, %{failures: failures, days: days})
  end

  def simulation(_rule), do: nil

  @doc """
  How many runs landed on each step of an escalation ladder, from the step
  the engine wrote into each execution's trace, as `%{step => runs}`. Steps
  past the end of the list run the last action, so they count towards it.
  """
  @spec step_counts(Rule.t()) :: %{pos_integer() => non_neg_integer()}
  def step_counts(%Rule{escalation_window_seconds: window, actions: actions, id: id})
      when window > 0 and actions != [] and not is_nil(id) do
    last = length(actions)

    nil
    |> Rules.scoped_executions()
    |> where([e], e.rule_id == ^id and not is_nil(fragment("? ->> 'step'", e.trace)))
    |> group_by([e], fragment("(? ->> 'step')::int", e.trace))
    |> select([e], {fragment("(? ->> 'step')::int", e.trace), count(e.id)})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {step, runs}, acc ->
      Map.update(acc, step |> max(1) |> min(last), runs, &(&1 + runs))
    end)
  end

  def step_counts(_rule), do: %{}

  @doc """
  A player's runs of a rule in the 24 hours before `at`, oldest first: what
  the cooldown and the per-player cap judged that run against.
  """
  @spec runs_before(Rule.t(), String.t() | nil, DateTime.t()) :: [struct()]
  def runs_before(_rule, nil, _at), do: []

  def runs_before(%Rule{id: id}, player_id, %DateTime{} = at) do
    Rules.executions_between(id, player_id, DateTime.add(at, -@day, :second), at)
  end

  # ── The history ────────────────────────────────────────────────────────────

  @doc """
  A month of executions (or `days`) against the month before, for the
  history's header: runs and their outcomes, the success rate, the players
  and servers reached, and the rule most of the failures came from.
  """
  @spec overview(map() | nil, pos_integer()) :: map()
  def overview(user, days \\ 30) do
    now = DateTime.utc_now()
    since = DateTime.add(now, -days * @day, :second)
    before = DateTime.add(now, -2 * days * @day, :second)
    scoped = Rules.scoped_executions(user)

    by_status =
      scoped
      |> where([e], e.executed_at >= ^since)
      |> group_by([e], e.status)
      |> select([e], {e.status, count(e.id)})
      |> Repo.all()
      |> Map.new()

    reach =
      scoped
      |> where([e], e.executed_at >= ^since)
      |> select([e], %{
        players: count(e.player_id, :distinct),
        servers: count(e.server_id, :distinct)
      })
      |> Repo.one()

    previous =
      scoped
      |> where([e], e.executed_at >= ^before and e.executed_at < ^since)
      |> select([e], count(e.id))
      |> Repo.one()

    top_failing =
      scoped
      |> where([e], e.executed_at >= ^since and e.status in [^:failed, ^:partial])
      |> join(:inner, [e], r in assoc(e, :rule))
      |> group_by([e, r], [r.id, r.name])
      |> order_by([e], desc: count(e.id))
      |> limit(1)
      |> select([e, r], %{id: r.id, name: r.name, count: count(e.id)})
      |> Repo.one()

    fired = by_status |> Map.values() |> Enum.sum()
    failed = Map.get(by_status, :failed, 0) + Map.get(by_status, :partial, 0)

    %{
      fired: fired,
      previous: previous || 0,
      by_status: by_status,
      failed: failed,
      success_rate: if(fired > 0, do: Float.round((fired - failed) * 100 / fired, 1)),
      players: reach.players,
      servers: reach.servers,
      top_failing: top_failing
    }
  end
end
