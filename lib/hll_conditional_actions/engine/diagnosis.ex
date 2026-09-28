defmodule HllConditionalActions.Engine.Diagnosis do
  @moduledoc """
  Walks a rule through the same checks `HllConditionalActions.Engine.run_rule/2`
  makes, in the same order, and reports where it stopped - without recording
  or sending anything.

  It powers the builder's "try it" panel, the rule page's "why didn't it
  fire?" and the event simulator. The checks:

    1. the rule is enabled
    2. it is not paused
    3. it listens for the event's trigger
    4. the player is not exempt
    5. the limits allow it (cooldown, then the per-player cap)
    6. the conditions hold

  Enabled, paused and exempt are judged as the rule stands *now*. The limits
  are judged against the executions recorded before `:at` when that option is
  given, so an old event is explained with the cooldown it actually met.
  """

  alias HllConditionalActions.Engine
  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Escalation
  alias HllConditionalActions.Engine.Evaluator
  alias HllConditionalActions.Engine.Executor
  alias HllConditionalActions.Engine.Limiter
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Rule

  @type outcome ::
          :fires
          | :disabled
          | :paused
          | :wrong_trigger
          | :exempt
          | :cooldown
          | :max_executions
          | :conditions_not_met

  @type t :: %{
          outcome: outcome(),
          exempt?: boolean(),
          limits: :ok | :cooldown | :max_executions | :not_checked,
          conditions: [map()],
          conditions_hold?: boolean(),
          actions: [map()]
        }

  @cap_window_seconds 24 * 60 * 60

  @doc """
  Diagnoses a rule against a context.

  Options:

    * `:at` - when the event happened; limits are judged as of then
    * `:limits` - `false` skips the limit checks (an unsaved rule has no
      history to check against)
  """
  @spec diagnose(Rule.t(), Context.t(), keyword()) :: t()
  def diagnose(%Rule{} = rule, %Context{} = context, opts \\ []) do
    explained = Evaluator.explain(rule, context)
    exempt? = Engine.exempt?(rule, context)
    limits = limits(rule, context.player_id, opts)

    outcome =
      cond do
        not rule.enabled -> :disabled
        Rule.paused?(rule) -> :paused
        rule.trigger_event != context.trigger -> :wrong_trigger
        exempt? -> :exempt
        limits in [:cooldown, :max_executions] -> limits
        not explained.result -> :conditions_not_met
        true -> :fires
      end

    %{
      outcome: outcome,
      exempt?: exempt?,
      limits: limits,
      conditions: explained.conditions,
      conditions_hold?: explained.result,
      actions: actions(rule, context)
    }
  end

  # The actions the rule would run - the escalation rung included - with
  # their messages rendered for this player. Nothing is sent.
  defp actions(rule, context) do
    rule
    |> Escalation.steps_for(context.player_id)
    |> Executor.preview(context)
  end

  defp limits(rule, player_id, opts) do
    cond do
      Keyword.get(opts, :limits, true) == false -> :not_checked
      is_nil(rule.id) or is_nil(player_id) -> :not_checked
      at = Keyword.get(opts, :at) -> limits_at(rule, player_id, at)
      true -> verdict(Limiter.check(rule, player_id))
    end
  end

  defp verdict(:ok), do: :ok
  defp verdict({:skip, reason}), do: reason

  defp limits_at(%Rule{cooldown_seconds: 0, max_executions_per_player: 0}, _player_id, _at),
    do: :ok

  defp limits_at(rule, player_id, at) do
    window = max(rule.cooldown_seconds, @cap_window_seconds)
    before = Rules.executions_between(rule.id, player_id, DateTime.add(at, -window, :second), at)

    cooldown_from = DateTime.add(at, -rule.cooldown_seconds, :second)
    cap_from = DateTime.add(at, -@cap_window_seconds, :second)

    cond do
      rule.cooldown_seconds > 0 and
          Enum.any?(before, &(DateTime.compare(&1.executed_at, cooldown_from) != :lt)) ->
        :cooldown

      rule.max_executions_per_player > 0 and
          Enum.count(before, &(DateTime.compare(&1.executed_at, cap_from) != :lt)) >=
            rule.max_executions_per_player ->
        :max_executions

      true ->
        :ok
    end
  end

  @doc """
  The execution a past event led to, if the rule fired for it: the first one
  for the player recorded within a minute after the event (a connect is
  handled a few seconds late on purpose).
  """
  @spec execution_for(Rule.t(), String.t() | nil, DateTime.t()) :: struct() | nil
  def execution_for(_rule, nil, _at), do: nil

  def execution_for(%Rule{id: id}, player_id, at) do
    id
    |> Rules.executions_between(player_id, DateTime.add(at, -2, :second), DateTime.add(at, 60))
    |> List.first()
  end
end
