defmodule HllConditionalActions.Rules.ConditionRuns do
  @moduledoc """
  Consecutive conditions that ask the same question of the same field, read
  as one: ninety `weapon is not "…"` rows joined by *and* are one list of
  ninety weapons the event's weapon must not be.

  Nothing here changes how a rule is stored or evaluated. The pages fold a
  rule's conditions into runs so a long list reads as one line ("Weapon is
  none of 86 weapons") instead of a wall of chips, and `contradictions/2`
  finds the lists that can never hold (`message is "a"` *and* `message is
  "b"`), which `HllConditionalActions.Rules.Health` reports.

  ## Runs

  A run is a map:

    * `:field`, `:operator` - what every member compares;
    * `:joiner` - how the members combine (`:and` or `:or`; the rule's
      `logical_operator` for a flat rule, the group's operator otherwise);
    * `:group` - the condition group the members sit in;
    * `:members` - `[{condition, index}]`, the index in the list given;
    * `:values` - the members' values, duplicates removed, in first-seen
      order;
    * `:counts` - `%{value => times}` for every value;
    * `:reading` - how the run reads, see `reading/3`. A run of one
      condition, or of one value repeated, is `:single`.
  """

  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActions.Rules.ConditionGroups

  # Only comparisons whose list reads naturally: "is one of", "is none of",
  # "contains one of". Numeric bounds (`kills > 3 and kills > 5`) stay apart.
  @foldable [:equal, :not_equal, :contains, :not_contains]

  @type reading ::
          :single
          | :none_of
          | :one_of
          | :all_at_once
          | :not_all
          | :contains_any
          | :contains_all
          | :contains_none
          | :lacks_any

  @type run :: %{
          field: atom(),
          operator: atom(),
          joiner: atom(),
          group: integer(),
          members: [{map(), non_neg_integer()}],
          values: [String.t()],
          counts: %{String.t() => pos_integer()},
          reading: reading()
        }

  @doc """
  Folds conditions into runs, in order. Every condition lands in exactly one
  run; `logical_operator` is the rule's.

      iex> alias HllConditionalActions.Rules.{Condition, ConditionRuns}
      iex> conditions = [
      ...>   %Condition{field: :kill_death_ratio, operator: :greater_than, value: "3"},
      ...>   %Condition{field: :weapon, operator: :not_equal, value: "A"},
      ...>   %Condition{field: :weapon, operator: :not_equal, value: "B"},
      ...>   %Condition{field: :weapon, operator: :not_equal, value: "A"}
      ...> ]
      iex> conditions |> ConditionRuns.fold(:and) |> Enum.map(&{&1.reading, &1.values, length(&1.members)})
      [{:single, ["3"], 1}, {:none_of, ["A", "B"], 3}]
  """
  @spec fold([map()], atom()) :: [run()]
  def fold(conditions, logical_operator) do
    joiners = joiners(conditions, logical_operator)

    conditions
    |> Enum.with_index()
    |> Enum.reduce([], fn {_condition, index} = member, runs ->
      add_member(runs, member, Map.get(joiners, index, logical_operator))
    end)
    |> Enum.reverse()
    |> Enum.map(&(&1 |> Enum.reverse() |> to_run(joiners, logical_operator)))
  end

  # Runs and their members are built newest first.
  defp add_member([run | rest] = runs, {condition, _index} = member, joiner) do
    if joins?(run, condition, joiner),
      do: [[member | run] | rest],
      else: [[member] | runs]
  end

  defp add_member([], member, _joiner), do: [[member]]

  @doc """
  How a run reads, from its operator, how its members combine and how many
  different values it holds.

      iex> alias HllConditionalActions.Rules.ConditionRuns
      iex> {ConditionRuns.reading(:not_equal, :and, 2), ConditionRuns.reading(:equal, :or, 2)}
      {:none_of, :one_of}
      iex> {ConditionRuns.reading(:equal, :and, 2), ConditionRuns.reading(:equal, :and, 1)}
      {:all_at_once, :single}
  """
  @spec reading(atom(), atom(), non_neg_integer()) :: reading()
  def reading(_operator, _joiner, distinct) when distinct < 2, do: :single
  def reading(:not_equal, :and, _distinct), do: :none_of
  def reading(:not_equal, :or, _distinct), do: :not_all
  def reading(:equal, :or, _distinct), do: :one_of
  def reading(:equal, :and, _distinct), do: :all_at_once
  def reading(:contains, :or, _distinct), do: :contains_any
  def reading(:contains, :and, _distinct), do: :contains_all
  def reading(:not_contains, :and, _distinct), do: :contains_none
  def reading(:not_contains, :or, _distinct), do: :lacks_any
  def reading(_operator, _joiner, _distinct), do: :single

  @doc """
  The runs a rule's conditions fold into, without the `always` placeholder.
  """
  @spec for_rule(map()) :: [run()]
  def for_rule(rule) do
    rule.conditions
    |> Enum.reject(&(&1.field == :always_true))
    |> fold(rule.logical_operator)
  end

  @doc """
  The `equal` conditions that must all hold at once on one field while
  asking for different values - which no event can satisfy. Found within
  each scope that joins with *and* (the whole rule when it is flat, each
  group otherwise), whether or not the conditions sit next to each other.

  Returns `[%{field, count, values}]`, `count` being the conditions
  involved, repeats included.

      iex> alias HllConditionalActions.Rules.{Condition, ConditionRuns}
      iex> conditions = [
      ...>   %Condition{field: :message_content, operator: :equal, value: "a"},
      ...>   %Condition{field: :message_content, operator: :equal, value: "b"},
      ...>   %Condition{field: :message_content, operator: :equal, value: "b"}
      ...> ]
      iex> ConditionRuns.contradictions(conditions, :and)
      [%{field: :message_content, count: 3, values: ["a", "b"]}]
      iex> ConditionRuns.contradictions(conditions, :or)
      []
  """
  @spec contradictions([map()], atom()) :: [map()]
  def contradictions(conditions, logical_operator) do
    conditions = Enum.reject(conditions, &(&1.field == :always_true))

    scopes =
      if ConditionGroups.grouped?(conditions) do
        conditions
        |> ConditionGroups.groups()
        |> Enum.map(fn group -> {group.operator, Enum.map(group.conditions, &elem(&1, 0))} end)
      else
        [{logical_operator, conditions}]
      end

    for {:and, members} <- scopes,
        {field, equal} <- equal_by_field(members),
        values = equal |> Enum.map(&value_of/1) |> Enum.uniq(),
        length(values) > 1 do
      %{field: field, count: length(equal), values: values}
    end
  end

  defp equal_by_field(members) do
    members
    |> Enum.filter(&(&1.operator == :equal))
    |> Enum.group_by(& &1.field)
    |> Enum.sort_by(fn {_field, [first | _rest]} ->
      Enum.find_index(members, &(&1 == first))
    end)
  end

  # ── Folding ────────────────────────────────────────────────────────────────

  defp joins?([{last, _index} | _rest], condition, joiner) do
    joiner in [:and, :or] and
      condition.field == last.field and
      condition.operator == last.operator and
      condition.operator in @foldable and
      group_of(condition) == group_of(last) and
      not boolean_field?(condition.field)
  end

  defp to_run([{first, first_index} | _rest] = members, joiners, logical_operator) do
    values = Enum.map(members, fn {condition, _index} -> value_of(condition) end)
    distinct = Enum.uniq(values)
    joiner = Map.get(joiners, first_index, logical_operator)

    %{
      field: first.field,
      operator: first.operator,
      joiner: joiner,
      group: group_of(first),
      members: members,
      values: distinct,
      counts: Enum.frequencies(values),
      reading:
        if(length(members) > 1,
          do: reading(first.operator, joiner, length(distinct)),
          else: :single
        )
    }
  end

  # How each condition combines with its neighbours: the rule's operator
  # when the rule is flat, its group's operator otherwise.
  defp joiners(conditions, logical_operator) do
    if ConditionGroups.grouped?(conditions) do
      for group <- ConditionGroups.groups(conditions),
          {_condition, index} <- group.conditions,
          into: %{},
          do: {index, group.operator}
    else
      Map.new(Enum.with_index(conditions), fn {_condition, index} -> {index, logical_operator} end)
    end
  end

  defp value_of(%{value: value}), do: to_string(value)
  defp value_of(%{expected: value}), do: to_string(value)
  defp value_of(_condition), do: ""

  defp group_of(%{group: group}) when is_integer(group), do: group
  defp group_of(_condition), do: 0

  defp boolean_field?(field) when is_atom(field) do
    field in Catalog.fields() and Catalog.field_type(field) == :boolean
  end

  defp boolean_field?(_field), do: false
end
