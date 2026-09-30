defmodule HllConditionalActions.Rules.Evaluations do
  @moduledoc """
  Every time a rule looked at an event, not only the times it fired.

  The executions table records a rule when it fires. The events it looked at
  and let pass - a condition that did not hold, a player still in cooldown,
  an exempt VIP - leave no row of their own, but the recent real events are
  kept (`HllConditionalActions.Engine.SavedEvents`), so each of them can be
  judged again with the checks the engine makes:

    1. the player is exempt
    2. the cooldown or the per-player cap holds the rule back (judged
       against the runs recorded before the event, as they stood then)
    3. the conditions do not hold

  An event the rule fired for is matched to its execution instead, which
  then carries the event's details (the victim, the weapon, the text).

  Only the latest events of each trigger are kept per server, so on a busy
  server the non-firing rows cover a shorter stretch than the executions.
  """

  import Ecto.Query

  alias HllConditionalActions.Engine
  alias HllConditionalActions.Engine.Evaluator
  alias HllConditionalActions.Engine.Samples
  alias HllConditionalActions.Engine.SavedEvents
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActions.Rules.Execution
  alias HllConditionalActions.Rules.Rule

  @day 24 * 60 * 60

  @type outcome ::
          :executed
          | :simulated
          | :partial
          | :failed
          | :no_match
          | :waiting
          | :capped
          | :exempt
          | :inactive
          | :unrecorded

  @doc """
  The rule's evaluations in a window, newest first, with a count per
  outcome.

  Options: `:from`, `:to` (DateTimes), `:server_id`, `:player` (an id or part
  of a name) and `:outcomes` (a list to keep; every one when empty).

  Returns `%{rows: [row], counts: %{outcome => n}, total: n}` where a row is
  `%{id, at, outcome, detail, player_id, player_name, server, execution,
  event, step, steps}`.
  """
  @spec list(Rule.t(), [struct()], keyword()) :: %{
          rows: [map()],
          counts: %{outcome() => non_neg_integer()},
          total: non_neg_integer()
        }
  def list(%Rule{} = rule, servers, opts \\ []) do
    servers = in_scope(rule, servers, opts[:server_id])
    server_ids = Enum.map(servers, & &1.id)
    to = opts[:to] || DateTime.utc_now()
    opts = Keyword.put(opts, :to, to)

    executions = executions(rule, server_ids, opts)
    {matched, loose} = match(saved_events(rule, server_ids, opts), executions)
    prior = prior_runs(rule, loose, opts[:from] || DateTime.add(to, -7 * @day, :second), to)
    servers_by_id = Map.new(servers, &{&1.id, &1})

    run_rows = Enum.map(executions, &execution_row(&1, Map.get(matched, &1.id)))

    event_rows =
      for saved <- loose, server = Map.get(servers_by_id, saved.server_id), server != nil do
        event_row(rule, saved, server, Map.get(prior, saved.sample.player_id, []))
      end

    rows = Enum.sort_by(run_rows ++ event_rows, & &1.at, {:desc, DateTime})

    %{
      rows: keep(rows, opts[:outcomes]),
      counts: Enum.frequencies_by(rows, & &1.outcome),
      total: length(rows)
    }
  end

  defp keep(rows, [_ | _] = outcomes), do: Enum.filter(rows, &(&1.outcome in outcomes))
  defp keep(rows, _all), do: rows

  defp executions(_rule, [], _opts), do: []

  defp executions(rule, server_ids, opts) do
    [rule_id: rule.id, player: opts[:player], from: opts[:from], until: opts[:to], limit: 2000]
    |> Rules.list_executions()
    |> Enum.filter(&(&1.server_id in server_ids))
  end

  defp saved_events(_rule, [], _opts), do: []

  defp saved_events(rule, server_ids, opts) do
    if Catalog.trigger_scope(rule.trigger_event) == :player do
      SavedEvents.list(server_ids,
        trigger: rule.trigger_event,
        player: opts[:player],
        from: opts[:from],
        to: opts[:to],
        limit: 300
      )
    else
      []
    end
  end

  @doc """
  How two versions of a rule would have answered the same recent real
  events: for each, how many events its conditions accept (exemptions
  included, limits left out) and how many distinct players that is.
  """
  @spec replay(Rule.t(), Rule.t(), [struct()], pos_integer()) :: %{
          events: non_neg_integer(),
          before: %{fires: non_neg_integer(), players: non_neg_integer()},
          after: %{fires: non_neg_integer(), players: non_neg_integer()}
        }
  def replay(%Rule{} = before, %Rule{} = now, servers, days \\ 7) do
    since = DateTime.add(DateTime.utc_now(), -days * @day, :second)

    samples =
      for trigger <- Enum.uniq([before.trigger_event, now.trigger_event]),
          server_ids = Enum.map(in_scope(now, servers, nil), & &1.id),
          server_ids != [],
          saved <- SavedEvents.list(server_ids, trigger: trigger, from: since, limit: 500),
          server = Enum.find(servers, &(&1.id == saved.server_id)),
          do: {saved.sample, Samples.to_context(saved.sample, server)}

    %{
      events: length(samples),
      before: tally(before, samples),
      after: tally(now, samples)
    }
  end

  defp tally(rule, samples) do
    accepted =
      Enum.filter(samples, fn {sample, context} ->
        sample.trigger == rule.trigger_event and not Engine.exempt?(rule, context) and
          Evaluator.explain(rule, context).result
      end)

    %{
      fires: length(accepted),
      players: accepted |> Enum.map(fn {sample, _context} -> sample.player_id end) |> uniq_count()
    }
  end

  defp uniq_count(ids), do: ids |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()

  @doc """
  Why a player was exempt from a rule: `{:vip}`, `{:flag, flag}` or
  `{:listed}`, or `nil`.
  """
  @spec exempt_reason(Rule.t(), struct()) :: {:vip} | {:flag, String.t()} | {:listed} | nil
  def exempt_reason(%Rule{exemptions: nil}, _context), do: nil

  def exempt_reason(%Rule{exemptions: exemptions}, context) do
    vip? = Evaluator.field_value(:is_vip, context) in [true, "true"]
    flags = List.wrap(Evaluator.field_value(:flags, context))
    wanted = MapSet.new(exemptions.exempt_flags, &normalize/1)

    cond do
      exemptions.exempt_vip and vip? -> {:vip}
      flag = Enum.find(flags, &(normalize(&1) in wanted)) -> {:flag, to_string(flag)}
      context.player_id in exemptions.exempt_player_ids -> {:listed}
      true -> nil
    end
  end

  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()

  # ── Rows ───────────────────────────────────────────────────────────────────

  defp execution_row(%Execution{} = execution, saved) do
    trace = execution.trace || %{}

    %{
      id: "run-#{execution.id}",
      at: execution.executed_at,
      outcome: execution.status,
      detail: execution.error,
      player_id: execution.player_id,
      player_name: execution.player_name,
      server: execution.server,
      execution: execution,
      event: saved && saved.sample,
      step: trace["step"],
      steps: trace["steps"]
    }
  end

  defp event_row(rule, saved, server, prior) do
    sample = saved.sample
    context = Samples.to_context(sample, server)
    {outcome, detail} = judge(rule, context, saved.occurred_at, prior)

    %{
      id: "event-#{saved.id}",
      at: saved.occurred_at,
      outcome: outcome,
      detail: detail,
      player_id: sample.player_id,
      player_name: sample.player_name,
      server: server,
      execution: nil,
      event: sample,
      saved_id: saved.id,
      step: nil,
      steps: nil
    }
  end

  # The engine's checks for a player event, in the engine's order, with the
  # limits judged against the runs recorded before the event.
  defp judge(rule, context, at, prior) do
    before = Enum.filter(prior, &(DateTime.compare(&1, at) == :lt))

    cond do
      not rule.enabled -> {:inactive, nil}
      Engine.exempt?(rule, context) -> {:exempt, exempt_reason(rule, context)}
      held = held_back(rule, before, at) -> held
      not Evaluator.explain(rule, context).result -> {:no_match, nil}
      true -> {:unrecorded, nil}
    end
  end

  # The cooldown or the per-player cap, as they stood when the event came.
  defp held_back(rule, before, at) do
    last = Enum.max(before, DateTime, fn -> nil end)
    waited = last && DateTime.diff(at, last, :second)
    in_cap = Enum.count(before, &(DateTime.diff(at, &1, :second) < @day))

    cond do
      rule.cooldown_seconds > 0 and waited != nil and waited < rule.cooldown_seconds ->
        {:waiting, rule.cooldown_seconds - waited}

      rule.max_executions_per_player > 0 and in_cap >= rule.max_executions_per_player ->
        {:capped, in_cap}

      true ->
        nil
    end
  end

  # Each saved event the rule fired for, matched to the first unclaimed
  # execution of the same player recorded within a minute after it (a
  # connect is handled a few seconds late on purpose).
  defp match(events, executions) do
    by_player = Enum.group_by(executions, & &1.player_id)

    {matched, loose, _claimed} =
      events
      |> Enum.sort_by(& &1.occurred_at, DateTime)
      |> Enum.reduce({%{}, [], MapSet.new()}, fn saved, {matched, loose, claimed} ->
        candidate =
          by_player
          |> Map.get(saved.sample.player_id, [])
          |> Enum.find(fn execution ->
            diff = DateTime.diff(execution.executed_at, saved.occurred_at, :millisecond)

            diff >= -2_000 and diff <= 60_000 and not MapSet.member?(claimed, execution.id)
          end)

        case candidate do
          nil ->
            {matched, [saved | loose], claimed}

          execution ->
            {Map.put(matched, execution.id, saved), loose, MapSet.put(claimed, execution.id)}
        end
      end)

    {matched, Enum.reverse(loose)}
  end

  # When each player in the loose events ran this rule, from a day before the
  # window on, as `%{player_id => [DateTime]}`.
  defp prior_runs(_rule, [], _from, _to), do: %{}

  defp prior_runs(%Rule{id: id}, events, from, to) do
    players = events |> Enum.map(& &1.sample.player_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    since = DateTime.add(from, -@day, :second)

    Repo.all(
      from e in Execution,
        where:
          e.rule_id == ^id and e.player_id in ^players and e.executed_at >= ^since and
            e.executed_at <= ^to,
        select: {e.player_id, e.executed_at}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # The servers a rule runs on, narrowed to one when asked.
  defp in_scope(%Rule{} = rule, servers, server_id) do
    Enum.filter(servers, fn server ->
      server.game == rule.game and (is_nil(rule.server_id) or server.id == rule.server_id) and
        (is_nil(server_id) or to_string(server.id) == to_string(server_id))
    end)
  end
end
