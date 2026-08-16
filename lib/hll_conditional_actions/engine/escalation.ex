defmodule HllConditionalActions.Engine.Escalation do
  @moduledoc """
  Turns a rule's action list into a per-player punishment ladder.

  A rule with `escalation_window_seconds` at `0` runs every action every time
  it fires. Set the window, and the list becomes steps instead: the engine
  counts how many times the rule already fired for that player inside the
  window and runs only the matching one.

      actions: [warn, warn again, punish, kick]

      1st offence -> warn
      2nd offence -> warn again
      3rd offence -> punish
      4th and beyond -> kick

  Past the end of the list the last step repeats, which is what makes "…and
  keep kicking" the natural ending rather than a special case. The count comes
  from the `rule_executions` table (the same source the limiter uses), so a
  restart or a deploy does not hand a repeat offender a clean slate, and the
  window rolls: stop offending for long enough and the ladder resets on its
  own.

  Rules that fire without a player - a match-wide broadcast, say - have nobody
  to escalate against, so they always run the whole list.
  """

  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Action
  alias HllConditionalActions.Rules.Rule

  @doc """
  The actions to run for this firing.

  Returns the whole list for a rule that does not escalate, and a single
  step for one that does.

      iex> alias HllConditionalActions.Engine.Escalation
      iex> alias HllConditionalActions.Rules.{Action, Rule}
      iex> actions = [%Action{type: :message_player}, %Action{type: :kick_player}]
      iex> Escalation.steps_for(%Rule{escalation_window_seconds: 0, actions: actions}, "76561")
      ...> |> length()
      2
  """
  @spec steps_for(Rule.t(), String.t() | nil) :: [Action.t()]
  def steps_for(%Rule{escalation_window_seconds: window} = rule, _player_id)
      when not is_integer(window) or window <= 0,
      do: rule.actions

  def steps_for(%Rule{} = rule, nil), do: rule.actions
  def steps_for(%Rule{actions: []} = _rule, _player_id), do: []

  def steps_for(%Rule{} = rule, player_id) do
    case Enum.at(rule.actions, step_index(rule, player_id)) do
      nil -> []
      action -> [action]
    end
  end

  @doc """
  Which step a player is on, zero based, capped at the last action.

  Exposed so the "try it" panel and the rule overview can say *what would
  happen next* rather than only what the rule contains.
  """
  @spec step_index(Rule.t(), String.t() | nil) :: non_neg_integer()
  def step_index(%Rule{escalation_window_seconds: window}, _player_id)
      when not is_integer(window) or window <= 0,
      do: 0

  def step_index(%Rule{}, nil), do: 0

  def step_index(%Rule{} = rule, player_id) do
    min(strikes(rule, player_id), max(length(rule.actions) - 1, 0))
  end

  @doc """
  How many times this rule already fired for a player inside its escalation
  window. `0` when the rule does not escalate.

  Also the value behind the `strikes` condition field, so a rule can branch
  on a repeat offender without escalating.
  """
  @spec strikes(Rule.t(), String.t() | nil) :: non_neg_integer()
  def strikes(%Rule{escalation_window_seconds: window}, _player_id)
      when not is_integer(window) or window <= 0,
      do: 0

  def strikes(%Rule{}, nil), do: 0
  def strikes(%Rule{id: nil}, _player_id), do: 0

  def strikes(%Rule{} = rule, player_id) do
    since = DateTime.add(DateTime.utc_now(), -rule.escalation_window_seconds, :second)

    Rules.count_executions_since(rule.id, player_id, since)
  end

  @doc """
  Whether a rule escalates at all.
  """
  @spec escalating?(Rule.t()) :: boolean()
  def escalating?(%Rule{escalation_window_seconds: window}),
    do: is_integer(window) and window > 0
end
