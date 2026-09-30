defmodule HllConditionalActions.Rules.Snapshot do
  @moduledoc """
  A rule's full definition as a plain, string-keyed map.

  Used for two things that must survive a rule being edited under them:
  a draft (pending edits to a live rule) and a version's snapshot (what the
  rule looked like right after a change, so it can be restored).

  The map has the shape `Rule.changeset/2` accepts, so turning a snapshot back
  into a rule goes through the same validation as the form. State that is not
  part of the definition - `enabled`, a pause - is deliberately left out:
  publishing a draft written last week must not switch a rule back on.
  """

  alias HllConditionalActions.Rules.Rule

  @fields ~w(
    name description simulation priority group game server_id trigger_event
    trigger_interval_seconds logical_operator cooldown_seconds
    max_executions_per_player escalation_window_seconds
  )a

  @doc """
  The snapshot of a rule.
  """
  @spec take(Rule.t()) :: map()
  def take(%Rule{} = rule) do
    rule
    |> Map.take(@fields)
    |> Map.new(fn {key, value} -> {to_string(key), plain(value)} end)
    |> Map.put("conditions", Enum.map(rule.conditions || [], &condition/1))
    |> Map.put("actions", Enum.map(rule.actions || [], &action/1))
    |> Map.put("exemptions", exemptions(rule.exemptions))
  end

  @doc """
  The rule a snapshot describes, applied over `rule` without saving, or `nil`
  when the snapshot no longer validates (a server since deleted, say).
  """
  @spec to_rule(Rule.t(), map() | nil) :: Rule.t() | nil
  def to_rule(_rule, nil), do: nil

  def to_rule(%Rule{} = rule, snapshot) do
    changeset = Rule.changeset(rule, snapshot)

    if changeset.valid?, do: Ecto.Changeset.apply_changes(changeset), else: nil
  end

  # Group keys only when the condition is in a group of its own, so a flat
  # rule's snapshot reads exactly as it did before groups existed.
  defp condition(condition) do
    %{
      "field" => to_string(condition.field),
      "operator" => to_string(condition.operator),
      "value" => condition.value
    }
    |> put_group(condition)
  end

  defp put_group(map, %{group: group, group_operator: operator})
       when (is_integer(group) and group > 0) or not is_nil(operator) do
    map
    |> Map.put("group", group || 0)
    |> Map.put("group_operator", operator && to_string(operator))
  end

  defp put_group(map, _condition), do: map

  defp action(action), do: %{"type" => to_string(action.type), "parameters" => action.parameters}

  defp exemptions(nil), do: %{}

  defp exemptions(exemptions) do
    %{
      "exempt_vip" => exemptions.exempt_vip,
      "exempt_flags" => exemptions.exempt_flags,
      "exempt_player_ids" => exemptions.exempt_player_ids
    }
  end

  defp plain(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  defp plain(value), do: value
end
