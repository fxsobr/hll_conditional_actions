defmodule HllConditionalActions.Engine do
  @moduledoc """
  Evaluates rules and runs their actions.

  This module holds the decision logic and is deliberately free of process
  concerns, so it can be driven by `HllConditionalActions.Engine.Runner` in
  production and called directly from tests.

  ## Order of checks

  For each rule, in priority order:

    1. the rule's trigger matches the event
    2. the rate limits allow it (`HllConditionalActions.Engine.Limiter`)
    3. the conditions hold (`HllConditionalActions.Engine.Evaluator`)

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
  alias HllConditionalActions.Engine.Snapshot
  alias HllConditionalActions.PubSub
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Catalog
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

    case rules_for(rules, trigger) do
      [] ->
        []

      matching ->
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

        run_rules(matching, context)
    end
  end

  @doc """
  Runs the rules for a trigger that sweeps every connected player, such as
  `:match_end` or `:periodic`.
  """
  @spec process_batch_trigger(Server.t(), [Rule.t()], atom(), keyword()) :: [term()]
  def process_batch_trigger(%Server{} = server, rules, trigger, opts) do
    snapshot = Keyword.get(opts, :snapshot)
    event = Keyword.get(opts, :event)

    case rules_for(rules, trigger) do
      [] ->
        []

      matching ->
        snapshot
        |> Snapshot.players()
        |> Enum.flat_map(fn {player_id, player} ->
          context =
            Context.build(server, trigger,
              player_id: player_id,
              player_name: Map.get(player, "name"),
              player: player,
              player_profile: maybe_player_profile(server, player_id, matching, snapshot),
              gamestate: snapshot && snapshot.gamestate,
              roster: roster(snapshot),
              event: event
            )

          run_rules(matching, context)
        end)
    end
  end

  @doc """
  Evaluates a rule against a context and, if it holds, runs its actions.

  Returns `{:ok, execution}`, `{:skip, reason}` or `{:error, changeset}`.
  """
  @spec run_rule(Rule.t(), Context.t()) ::
          {:ok, term()} | {:skip, atom()} | {:error, Ecto.Changeset.t()}
  def run_rule(%Rule{} = rule, %Context{} = context) do
    with :ok <- Limiter.check(rule, context.player_id),
         true <- Evaluator.evaluate(rule, context) do
      record_and_execute(rule, context)
    else
      false -> skip(rule, context, :conditions_not_met)
      {:skip, reason} -> skip(rule, context, reason)
    end
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
    |> Enum.filter(&(&1.enabled and &1.trigger_event == trigger))
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

    with {:ok, execution} <- record(rule, context) do
      results =
        if rule.simulation do
          Executor.preview(steps, context)
        else
          Executor.run(steps, context)
        end

      execution = finalize(execution, results, context, rule)
      emit_fired(rule, context, execution, System.monotonic_time() - started_at)

      {:ok, execution}
    end
  end

  defp record(rule, context) do
    Rules.record_execution(%{
      rule_id: rule.id,
      server_id: context.server.id,
      player_id: context.player_id,
      player_name: context.player_name,
      trigger_event: to_string(context.trigger),
      status: if(rule.simulation, do: :simulated, else: :executed),
      results: []
    })
  end

  defp finalize(execution, results, context, rule) do
    attrs = %{
      results: Enum.map(results, &stringify_result/1),
      status: overall_status(results, rule),
      error: first_error(results)
    }

    case Rules.update_execution(execution, attrs) do
      {:ok, updated} ->
        Phoenix.PubSub.broadcast(PubSub, topic(context.server.id), {:rule_fired, updated})
        updated

      {:error, changeset} ->
        Logger.warning("[engine] could not store execution results: #{inspect(changeset.errors)}")
        execution
    end
  end

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
