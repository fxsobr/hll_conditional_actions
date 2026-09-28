defmodule HllConditionalActions.Rules.RecipeAnswers do
  @moduledoc """
  The recipe wizard's questions: a recipe may declare two or three
  (`:questions` in `HllConditionalActions.Rules.Recipes`), each pointing at
  the part of the rule it fills in:

    * `{:action_param, index, key}` - a parameter of one action, such as the
      message text or the VIP duration
    * `{:condition_value, index}` - the value a condition compares against
    * `{:ladder, filler_index}` - how many rungs an escalation ladder has; the
      first and last rungs are kept and the middle is filled with the action
      at `filler_index`
    * `:final_action` - the type of the ladder's last rung

  Answers are read from and written into the attribute map
  `Recipes.to_attrs/2` produces, so everything downstream - the full form,
  validation - is the same as for a recipe opened without the wizard.
  """

  alias HllConditionalActions.Rules.Catalog

  @doc "The questions a recipe asks; empty for most."
  @spec questions(map() | nil) :: [map()]
  def questions(nil), do: []
  def questions(recipe), do: Map.get(recipe, :questions, [])

  @doc """
  The answers already written in a recipe's attributes, used as defaults.

      iex> alias HllConditionalActions.Rules.{RecipeAnswers, Recipes}
      iex> recipe = Recipes.fetch(:team_kill_ladder)
      iex> attrs = Recipes.to_attrs(recipe, name: "x")
      iex> RecipeAnswers.defaults(recipe, attrs) |> Map.take([:limit, :final_action])
      %{limit: 4, final_action: :temp_ban_player}
  """
  @spec defaults(map(), map()) :: map()
  def defaults(recipe, attrs) do
    Map.new(questions(recipe), &{&1.id, read(attrs, &1)})
  end

  @doc """
  Casts submitted answers (string keys and values) over the defaults.
  Values that do not parse or fall outside the question's bounds keep the
  default.
  """
  @spec cast(map(), map(), map()) :: map()
  def cast(recipe, defaults, params) when is_map(params) do
    Map.new(questions(recipe), fn question ->
      raw = Map.get(params, to_string(question.id))
      {question.id, cast_value(question, raw, Map.get(defaults, question.id))}
    end)
  end

  defp cast_value(%{type: :integer} = question, raw, default) when is_binary(raw) do
    case Integer.parse(String.trim(raw)) do
      {value, ""} -> value |> max(question[:min] || value) |> min(question[:max] || value)
      _other -> default
    end
  end

  defp cast_value(%{type: :choice, options: options}, raw, default) when is_binary(raw) do
    Enum.find(options, default, &(to_string(&1) == raw))
  end

  defp cast_value(%{type: :text}, raw, default) when is_binary(raw) do
    case String.trim(raw) do
      "" -> default
      text -> String.slice(text, 0, 500)
    end
  end

  defp cast_value(_question, _raw, default), do: default

  @doc """
  Writes answers into a recipe's attributes, in question order.

      iex> alias HllConditionalActions.Rules.{RecipeAnswers, Recipes}
      iex> recipe = Recipes.fetch(:team_kill_ladder)
      iex> attrs = Recipes.to_attrs(recipe, name: "x")
      iex> applied = RecipeAnswers.apply(attrs, recipe, %{limit: 3, final_action: :kick_player})
      iex> Enum.map(applied.actions, & &1.type)
      [:message_player, :punish_player, :kick_player]
  """
  @spec apply(map(), map(), map()) :: map()
  def apply(attrs, recipe, answers) do
    Enum.reduce(questions(recipe), attrs, fn question, attrs ->
      case Map.fetch(answers, question.id) do
        {:ok, value} when not is_nil(value) -> write(attrs, question.target, value)
        _missing -> attrs
      end
    end)
  end

  # ── Targets ────────────────────────────────────────────────────────────────

  defp read(attrs, %{target: {:action_param, index, key}}) do
    attrs.actions |> Enum.at(index, %{}) |> Map.get(:parameters, %{}) |> Map.get(key)
  end

  defp read(attrs, %{target: {:condition_value, index}}) do
    case attrs.conditions |> Enum.at(index, %{}) |> Map.get(:value) do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _other -> value
        end

      value ->
        value
    end
  end

  defp read(attrs, %{target: {:ladder, _filler}}), do: length(attrs.actions)

  defp read(attrs, %{target: :final_action}) do
    case List.last(attrs.actions) do
      %{type: type} -> type
      nil -> nil
    end
  end

  defp write(attrs, {:action_param, index, key}, value) do
    update_in(attrs.actions, fn actions ->
      List.update_at(actions, index, fn action ->
        Map.update(action, :parameters, %{key => value}, &Map.put(&1, key, value))
      end)
    end)
  end

  defp write(attrs, {:condition_value, index}, value) do
    update_in(attrs.conditions, fn conditions ->
      List.update_at(conditions, index, &Map.put(&1, :value, to_string(value)))
    end)
  end

  defp write(%{actions: actions} = attrs, {:ladder, filler_index}, steps)
       when length(actions) >= 2 and steps >= 2 do
    if steps == length(actions) do
      attrs
    else
      filler = Enum.at(actions, filler_index)
      middle = List.duplicate(filler, steps - 2)
      %{attrs | actions: [hd(actions)] ++ middle ++ [List.last(actions)]}
    end
  end

  defp write(%{actions: [_ | _] = actions} = attrs, :final_action, type) do
    last = List.last(actions)

    if last.type == type do
      attrs
    else
      kept = Map.take(Map.get(last, :parameters, %{}), ["reason"])

      parameters =
        for {key, _kind, opts} <- Catalog.action_params(type),
            Keyword.has_key?(opts, :default),
            into: %{},
            do: {to_string(key), opts[:default]}

      parameters = Map.merge(parameters, kept)

      %{attrs | actions: List.replace_at(actions, -1, %{type: type, parameters: parameters})}
    end
  end

  defp write(attrs, _target, _value), do: attrs
end
