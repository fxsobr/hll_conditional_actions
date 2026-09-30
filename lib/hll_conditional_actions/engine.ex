defmodule HllConditionalActions.Engine do
  @moduledoc """
  Evaluates rules and runs their actions.

  This module holds the decision logic and is deliberately free of process
  concerns, so it can be driven by `HllConditionalActions.Engine.Runner` in
  production and called directly from tests.

  ## Order of checks

  For each rule, in priority order:

    1. the rule's trigger matches the event
    2. the player is not exempt (`HllConditionalActions.Rules.Exemptions`)
    3. the rate limits allow it (`HllConditionalActions.Engine.Limiter`)
    4. the conditions hold (`HllConditionalActions.Engine.Evaluator`)

  Limits are checked before conditions because they are a cheap indexed query,
  while evaluating conditions may need the player's profile.

  ## Recording

  An execution row is inserted *before* the actions run. That row is what the
  cooldown check reads, so two events arriving back to back cannot both slip
  past the limit while the first one's actions are still in flight. The row is
  updated with the per-action results once they finish.
  """

  require Logger

  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Escalation
  alias HllConditionalActions.Engine.Evaluator
  alias HllConditionalActions.Engine.Executor
  alias HllConditionalActions.Engine.Limiter
  alias HllConditionalActions.Engine.Samples
  alias HllConditionalActions.Engine.Snapshot
  alias HllConditionalActions.PubSub
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActions.Rules.Exemptions
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Servers.Server

  @topic_prefix "engine"

  @doc """
  Subscribes the calling process to `{:rule_fired, execution}` messages for a
  server.
  """
  @spec subscribe(term()) :: :ok | {:error, term()}
  def subscribe(server_id), do: Phoenix.PubSub.subscribe(PubSub, topic(server_id))

  @doc """
  The PubSub topic carrying a server's rule executions.
  """
  @spec topic(term()) :: String.t()
  def topic(server_id), do: "#{@topic_prefix}:#{server_id}"

  @doc """
  Runs the rules for a trigger that concerns a single player.

  Returns the executions that were recorded.
  """
  @spec process_player_trigger(Server.t(), [Rule.t()], atom(), keyword()) :: [term()]
  def process_player_trigger(%Server{} = server, rules, trigger, opts) do
    player_id = Keyword.get(opts, :player_id)
    snapshot = Keyword.get(opts, :snapshot)
    matching = rules_for(rules, trigger)

    context =
      Context.build(server, trigger,
        player_id: player_id,
        player_name: Keyword.get(opts, :player_name),
        player: player_for(snapshot, player_id, opts),
        player_profile: maybe_player_profile(server, player_id, matching, snapshot),
        gamestate: snapshot && snapshot.gamestate,
        roster: roster(snapshot),
        event: Keyword.get(opts, :event)
      )

    Samples.record(context)

    run_rules(matching, context)
  end

  @doc """
  Keeps a sample of a player trigger nobody listens for, so the builder can
  replay a new rule against it. Uses only the snapshot passed in and never
  fetches a profile: an unheard event must not cost a CRCON call.
  """
  @spec record_sample(Server.t(), atom(), keyword()) :: :ok
  def record_sample(%Server{} = server, trigger, opts) do
    player_id = Keyword.get(opts, :player_id)
    snapshot = Keyword.get(opts, :snapshot)

    server
    |> Context.build(trigger,
      player_id: player_id,
      player_name: Keyword.get(opts, :player_name),
      player: player_for(snapshot, player_id, opts),
      player_profile: embedded_profile(snapshot, player_id),
      gamestate: snapshot && snapshot.gamestate,
      roster: roster(snapshot),
      event: Keyword.get(opts, :event)
    )
    |> Samples.record()
  end

  @doc """
  Runs the rules for a trigger that sweeps every connected player, such as
  `:match_end` or `:periodic`.
  """
  @spec process_batch_trigger(Server.t(), [Rule.t()], atom(), keyword()) :: [term()]
  def process_batch_trigger(%Server{} = server, rules, trigger, opts) do
    snapshot = Keyword.get(opts, :snapshot)
    event = Keyword.get(opts, :event)
    matching = rules_for(rules, trigger)

    # A sweep evaluates each rule once per player, but an action aimed at the
    # whole server - a message to everybody, the broadcast, Discord - must go
    # out once per event, not once per player who matched. The set carries the
    # rules that already fired in this sweep, and the executor skips their
    # server wide actions from then on.
    # Discord actions marked "one message for the whole sweep" collect a line
    # per player here and are posted once the sweep is over.
    {:ok, batch} = Agent.start_link(fn -> %{} end)

    {executions, _fired} =
      snapshot
      |> Snapshot.players()
      |> Enum.flat_map_reduce(MapSet.new(), fn {player_id, player}, fired ->
        context =
          Context.build(server, trigger,
            player_id: player_id,
            player_name: Map.get(player, "name"),
            player: player,
            player_profile: maybe_player_profile(server, player_id, matching, snapshot),
            gamestate: snapshot && snapshot.gamestate,
            roster: roster(snapshot),
            event: event,
            extra: %{server_wide_fired: fired, discord_batch: batch}
          )

        Samples.record(context)

        executions = run_rules(matching, context)
        {executions, Enum.reduce(executions, fired, &MapSet.put(&2, &1.rule_id))}
      end)

    Executor.flush_batch(batch)
    Agent.stop(batch)

    executions
  end

  @doc """
  Evaluates a rule against a context and, if it holds, runs its actions.

  Returns `{:ok, execution}`, `{:skip, reason}` or `{:error, changeset}`.
  """
  @spec run_rule(Rule.t(), Context.t()) ::
          {:ok, term()} | {:skip, atom()} | {:error, Ecto.Changeset.t()}
  def run_rule(%Rule{} = rule, %Context{} = context) do
    with :ok <- check_exemptions(rule, context),
         :ok <- Limiter.check(rule, context.player_id),
         true <- Evaluator.evaluate(rule, context) do
      record_and_execute(rule, context)
    else
      false -> skip(rule, context, :conditions_not_met)
      {:skip, reason} -> skip(rule, context, reason)
    end
  end

  @doc """
  Whether the player of a context is exempt from a rule: a VIP, a player
  carrying one of its exempt flags, or one listed by id.
  """
  @spec exempt?(Rule.t(), Context.t()) :: boolean()
  def exempt?(%Rule{exemptions: exemptions}, %Context{} = context) do
    Exemptions.active?(exemptions) and
      Exemptions.exempt?(exemptions, %{
        player_id: context.player_id,
        is_vip: Evaluator.field_value(:is_vip, context),
        flags: Evaluator.field_value(:flags, context)
      })
  end

  defp check_exemptions(rule, context) do
    if exempt?(rule, context), do: {:skip, :exempt}, else: :ok
  end

  defp skip(rule, context, reason) do
    :telemetry.execute(
      [:hll_conditional_actions, :rule, :skipped],
      %{count: 1},
      %{rule_id: rule.id, server_id: context.server.id, trigger: context.trigger, reason: reason}
    )

    {:skip, reason}
  end

  defp emit_fired(rule, context, execution, duration) do
    :telemetry.execute(
      [:hll_conditional_actions, :rule, :fired],
      %{duration: duration, count: 1},
      %{
        rule_id: rule.id,
        rule_name: rule.name,
        server_id: context.server.id,
        trigger: context.trigger,
        status: execution.status,
        simulation: rule.simulation
      }
    )
  end

  @doc """
  Evaluates a rule without running anything, for the builder's preview.
  """
  @spec explain(Rule.t(), Context.t()) :: %{result: boolean(), conditions: [map()]}
  def explain(%Rule{} = rule, %Context{} = context), do: Evaluator.explain(rule, context)

  @doc """
  The rules of a list that subscribe to a trigger, in evaluation order.
  """
  @spec rules_for([Rule.t()], atom()) :: [Rule.t()]
  def rules_for(rules, trigger) do
    rules
    |> Enum.filter(&(&1.enabled and &1.trigger_event == trigger and not Rule.paused?(&1)))
    |> Rule.sort()
  end

  @doc """
  Whether a periodic rule is due, given when it last ran.
  """
  @spec periodic_due?(Rule.t(), integer() | nil, integer()) :: boolean()
  def periodic_due?(%Rule{trigger_interval_seconds: interval}, last_run_ms, now_ms) do
    is_nil(last_run_ms) or now_ms - last_run_ms >= interval * 1_000
  end

  # ── Internals ──────────────────────────────────────────────────────────────

  defp run_rules(rules, context) do
    Enum.flat_map(rules, fn rule ->
      case run_rule(rule, with_strikes(rule, context)) do
        {:ok, execution} -> [execution]
        _skipped -> []
      end
    end)
  end

  # The `strikes` condition field costs a query, so it is only counted for
  # rules that either escalate or actually read it.
  defp with_strikes(rule, context) do
    if Escalation.escalating?(rule) or reads_strikes?(rule) do
      strikes = Escalation.strikes(rule, context.player_id)

      %{context | extra: Map.put(context.extra, :strikes, strikes)}
    else
      context
    end
  end

  defp reads_strikes?(rule), do: Enum.any?(rule.conditions, &(&1.field == :strikes))

  defp roster(nil), do: %{}
  defp roster(snapshot), do: snapshot.players

  defp record_and_execute(rule, context) do
    started_at = System.monotonic_time()

    # Which rung of the ladder this firing is on, decided *before* the row
    # below is inserted - otherwise the execution we are recording right now
    # would count as one of the player's earlier offences.
    steps = Escalation.steps_for(rule, context.player_id)

    fired = Map.get(context.extra, :server_wide_fired, MapSet.new())
    context = put_in(context.extra[:server_wide_sent?], MapSet.member?(fired, rule.id))

    with {:ok, execution} <- record(rule, context, trace(rule, context)) do
      # Queued deliveries report back to this row, and an edited Discord
      # message is keyed by the rule by default.
      context =
        update_in(context.extra, &Map.merge(&1, %{execution_id: execution.id, rule_id: rule.id}))

      results =
        if rule.simulation do
          Executor.preview(steps, context)
        else
          Executor.run(steps, context)
        end

      duration = System.monotonic_time() - started_at
      execution = finalize(execution, results, context, rule, duration)
      emit_fired(rule, context, execution, duration)

      {:ok, execution}
    end
  end

  defp record(rule, context, trace) do
    Rules.record_execution(%{
      trace: trace,
      rule_id: rule.id,
      server_id: context.server.id,
      player_id: context.player_id,
      player_name: context.player_name,
      trigger_event: to_string(context.trigger),
      status: if(rule.simulation, do: :simulated, else: :executed),
      results: []
    })
  end

  defp finalize(execution, results, context, rule, duration) do
    attrs = %{
      results: Enum.map(results, &stringify_result/1),
      trace:
        Map.put(
          execution.trace,
          "duration_ms",
          System.convert_time_unit(duration, :native, :millisecond)
        ),
      status: overall_status(results, rule),
      error: first_error(results)
    }

    case Rules.update_execution(execution, attrs) do
      {:ok, updated} ->
        Phoenix.PubSub.broadcast(PubSub, topic(context.server.id), {:rule_fired, updated})
        HllConditionalActions.Attention.notify_changed()
        updated

      {:error, changeset} ->
        Logger.warning("[engine] could not store execution results: #{inspect(changeset.errors)}")
        execution
    end
  end

  # The history's "why did this fire": every condition with the value the
  # engine read, plus the escalation rung. Stored as plain JSON, so values are
  # flattened to text here rather than trusted to encode.
  #
  #     %{"logical_operator" => "and",
  #       "conditions" => [%{"field" => "kills", "operator" => "greater_than",
  #                          "expected" => "10", "actual" => "12", "result" => true}],
  #       "step" => 2, "steps" => 3, "duration_ms" => 140}
  defp trace(rule, context) do
    explained = Evaluator.explain(rule, context)

    base = %{
      "logical_operator" => to_string(rule.logical_operator),
      "conditions" =>
        Enum.map(explained.conditions, fn condition ->
          %{
            "field" => to_string(condition.field),
            "operator" => condition.operator && to_string(condition.operator),
            "expected" => condition.expected,
            "actual" => trace_value(condition.actual),
            "result" => condition.result
          }
        end)
    }

    # The log line that made the rule act, so the live feed can show the
    # rule beside it (see `HllConditionalActions.LiveFeed`).
    base =
      case HllConditionalActions.LiveFeed.event_key(context.event) do
        nil -> base
        key -> Map.put(base, "event_key", key)
      end

    if Escalation.escalating?(rule) and context.player_id do
      Map.merge(base, %{
        "step" => Escalation.step_index(rule, context.player_id) + 1,
        "steps" => length(rule.actions)
      })
    else
      base
    end
  end

  defp trace_value(nil), do: nil
  defp trace_value(value) when is_binary(value), do: String.slice(value, 0, 200)
  defp trace_value(value) when is_number(value) or is_boolean(value), do: value
  defp trace_value(value) when is_atom(value), do: to_string(value)

  defp trace_value(value) when is_list(value),
    do: value |> Enum.map_join(", ", &to_string(trace_value(&1))) |> String.slice(0, 200)

  defp trace_value(value), do: value |> inspect() |> String.slice(0, 200)

  defp overall_status(_results, %Rule{simulation: true}), do: :simulated

  defp overall_status(results, _rule) do
    statuses = Enum.map(results, & &1.status)

    cond do
      statuses == [] -> :executed
      Enum.all?(statuses, &(&1 == :error)) -> :failed
      Enum.any?(statuses, &(&1 == :error)) -> :partial
      true -> :executed
    end
  end

  defp first_error(results) do
    Enum.find_value(results, fn
      %{status: :error, detail: detail} -> detail
      _other -> nil
    end)
  end

  defp stringify_result(%{type: type, status: status, detail: detail}) do
    %{"type" => to_string(type), "status" => to_string(status), "detail" => detail}
  end

  # On a connect event the player is not in `get_detailed_players` yet, so fall
  # back to what the log line told us. Conditions on live stats will read nil
  # and fail, which is correct: those stats do not exist yet.
  defp player_for(snapshot, player_id, opts) do
    case Snapshot.player(snapshot, player_id) do
      nil ->
        case Keyword.get(opts, :player_name) do
          nil -> nil
          name -> %{"name" => name, "player_id" => player_id}
        end

      player ->
        player
    end
  end

  defp maybe_player_profile(server, player_id, rules, snapshot) do
    cond do
      is_nil(player_id) ->
        nil

      not Context.needs_player_profile?(rules) ->
        nil

      profile = embedded_profile(snapshot, player_id) ->
        profile

      true ->
        fetch_player_profile(server, player_id)
    end
  end

  defp embedded_profile(snapshot, player_id) do
    case Snapshot.player(snapshot, player_id) do
      %{"profile" => profile} when is_map(profile) -> profile
      _other -> nil
    end
  end

  defp fetch_player_profile(server, player_id) do
    case HllConditionalActions.Crcon.get_player_profile(server, player_id) do
      {:ok, profile} when is_map(profile) ->
        profile

      {:error, error} ->
        Logger.warning(
          "[engine] #{server.name}: could not read profile of #{player_id} - #{Exception.message(error)}"
        )

        nil

      _other ->
        nil
    end
  end

  @doc """
  Triggers that sweep every player, exposed for the runner.
  """
  @spec batch_triggers() :: [atom()]
  defdelegate batch_triggers(), to: Catalog
end
