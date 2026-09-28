defmodule HllConditionalActions.Engine.Simulator do
  @moduledoc """
  Runs one event past every rule of a server, the way the engine would, and
  reports what each would do - without recording or sending anything.

  Besides the per-rule diagnosis it points out **conflicts** between the
  rules that would fire together:

    * `:double_punishment` - more than one rule punishes, kicks or bans the
      same player for the same event
    * `:message_then_removed` - one rule messages the player while another
      kicks or bans them, so the message is likely never read
  """

  alias HllConditionalActions.Engine
  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Diagnosis
  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActions.Rules.Rule

  @removals [:kick_player, :temp_ban_player, :perma_ban_player, :blacklist_player]
  @player_messages [:message_player]

  @type conflict :: %{kind: :double_punishment | :message_then_removed, rules: [Rule.t()]}

  @doc """
  Simulates an event against rules. Only enabled, unpaused rules listening
  for the event's trigger are considered, in priority order.

  Returns `%{results: [%{rule: rule, diagnosis: diagnosis}], conflicts: [conflict]}`.
  """
  @spec simulate([Rule.t()], Context.t()) :: %{results: [map()], conflicts: [conflict()]}
  def simulate(rules, %Context{} = context) do
    results =
      rules
      |> Engine.rules_for(context.trigger)
      |> Enum.map(&%{rule: &1, diagnosis: Diagnosis.diagnose(&1, context)})

    %{results: results, conflicts: conflicts(results)}
  end

  @doc """
  The conflicts among simulated results; see the moduledoc.
  """
  @spec conflicts([map()]) :: [conflict()]
  def conflicts(results) do
    firing = Enum.filter(results, &(&1.diagnosis.outcome == :fires))
    punishing = Enum.filter(firing, &runs_any?(&1, Catalog.actions_in_group(:punishment)))
    removing = Enum.filter(firing, &runs_any?(&1, @removals))
    messaging = Enum.filter(firing, &runs_any?(&1, @player_messages))

    double =
      if length(punishing) > 1,
        do: [%{kind: :double_punishment, rules: Enum.map(punishing, & &1.rule)}],
        else: []

    # A rule that warns and then removes on its own escalation ladder is
    # not a conflict: only one rung runs per event.
    contradiction =
      case {removing, Enum.reject(messaging, &(&1 in removing))} do
        {[_ | _], [_ | _] = messengers} ->
          [
            %{
              kind: :message_then_removed,
              rules: Enum.map(messengers ++ removing, & &1.rule)
            }
          ]

        _other ->
          []
      end

    double ++ contradiction
  end

  defp runs_any?(%{diagnosis: diagnosis}, types) do
    Enum.any?(diagnosis.actions, &(&1.type in types and &1.status == :simulated))
  end
end
