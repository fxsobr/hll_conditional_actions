defmodule HllConditionalActions.Rules.ConditionGroups do
  @moduledoc """
  Conditions gathered into groups, each with its own "all / any / none", and
  the groups combined by the rule's `logical_operator`.

  The builder draws a rule's conditions as coloured groups - "*any* of these
  groups holds; group 1: *all* of these hold, group 2: ..." - which is how an
  admin writes "not a VIP and not staff, or three team kills whoever you are"
  without parentheses.

  ## Storage

  Every condition carries the `group` it belongs to (an integer, `0` by
  default) and the group's operator in `group_operator`. A rule whose
  conditions all sit in one group is an ordinary flat rule: its conditions
  are combined by `logical_operator`, exactly as before groups existed, and
  `group_operator` is ignored. That keeps every rule written before groups -
  and every API client that never sends them - meaning what it meant.

  With two or more groups, each group combines its own conditions with the
  `group_operator` of its first condition (`:and` when unset), and
  `logical_operator` combines the groups.
  """

  alias HllConditionalActions.Engine.Evaluator
  alias HllConditionalActions.Rules.Condition

  @type group :: %{
          id: integer(),
          operator: atom(),
          conditions: [{Condition.t(), non_neg_integer()}]
        }

  @doc """
  The groups of a list of conditions, in the order they first appear, each
  with its conditions and their index in the rule's list.

      iex> alias HllConditionalActions.Rules.{Condition, ConditionGroups}
      iex> conditions = [
      ...>   %Condition{field: :kills, group: 0},
      ...>   %Condition{field: :deaths, group: 1, group_operator: :or},
      ...>   %Condition{field: :player_level, group: 0}
      ...> ]
      iex> conditions |> ConditionGroups.groups() |> Enum.map(&{&1.id, &1.operator, length(&1.conditions)})
      [{0, :and, 2}, {1, :or, 1}]
  """
  @spec groups([Condition.t() | map()]) :: [group()]
  def groups(conditions) do
    conditions
    |> Enum.with_index()
    |> Enum.group_by(fn {condition, _index} -> group_of(condition) end)
    |> Enum.map(fn {id, [{first, _index} | _rest] = members} ->
      %{id: id, operator: operator_of(first), conditions: members}
    end)
    |> Enum.sort_by(fn %{conditions: [{_condition, index} | _rest]} -> index end)
  end

  @doc """
  Whether the conditions form more than one group.

      iex> alias HllConditionalActions.Rules.{Condition, ConditionGroups}
      iex> ConditionGroups.grouped?([%Condition{group: 0}, %Condition{group: 0}])
      false
      iex> ConditionGroups.grouped?([%Condition{group: 0}, %Condition{group: 2}])
      true
  """
  @spec grouped?([Condition.t() | map()]) :: boolean()
  def grouped?(conditions) do
    conditions |> Enum.map(&group_of/1) |> Enum.uniq() |> length() > 1
  end

  @doc """
  Combines per-condition results, given in the order of `conditions`, into
  the rule's verdict.

      iex> alias HllConditionalActions.Rules.{Condition, ConditionGroups}
      iex> conditions = [
      ...>   %Condition{group: 0, group_operator: :and},
      ...>   %Condition{group: 0, group_operator: :and},
      ...>   %Condition{group: 1, group_operator: :and}
      ...> ]
      iex> ConditionGroups.combine(:or, conditions, [true, false, true])
      true
      iex> ConditionGroups.combine(:or, conditions, [true, false, false])
      false
      iex> ConditionGroups.combine(:or, Enum.take(conditions, 2), [true, false])
      true
  """
  @spec combine(atom(), [Condition.t() | map()], [boolean()]) :: boolean()
  def combine(logical_operator, conditions, results) do
    if grouped?(conditions) do
      conditions
      |> group_results(results)
      |> Enum.map(& &1.result)
      |> then(&Evaluator.combine(logical_operator, &1))
    else
      Evaluator.combine(logical_operator, results)
    end
  end

  @doc """
  Each group with its verdict, for the builder's "group matched / did not
  match" and the history's trace. `results` are per condition, in order.

  For a flat rule the one group is judged with `logical_operator`, since that
  is what combines its conditions.
  """
  @spec group_results([Condition.t() | map()], [boolean()], atom() | nil) :: [map()]
  def group_results(conditions, results, flat_operator \\ nil) do
    grouped? = grouped?(conditions)

    Enum.map(groups(conditions), fn group ->
      operator = if grouped? or is_nil(flat_operator), do: group.operator, else: flat_operator
      own = Enum.map(group.conditions, fn {_condition, index} -> Enum.at(results, index) end)

      Map.put(group, :result, Evaluator.combine(operator, Enum.map(own, &(&1 == true))))
    end)
  end

  defp group_of(%{group: group}) when is_integer(group), do: group
  defp group_of(_condition), do: 0

  defp operator_of(%{group_operator: operator}) when is_atom(operator) and not is_nil(operator),
    do: operator

  defp operator_of(_condition), do: :and
end
