defmodule HllConditionalActions.Rules.Expression do
  @moduledoc """
  A rule's *when* and *if*, as text an admin can read and type.

      # When: the player kills a teammate
      event.type eq "player_team_kill"
      and server.game eq "hll"
      and (
          player.is_vip eq false
          and history.flags not_contains "admin"
      )

  The text says exactly what the builder's visual mode says - the trigger,
  the game, the conditions and how they combine - so it round-trips:
  `to_text/1` writes a rule, `parse/1` reads it back into the attributes the
  rule changeset takes. The combinations map onto the rule's
  `logical_operator`: conditions joined with `and` (`:and`), with `or`
  (`:or`), and `not (…)` around either (`:nand`, `:nor`). A group mixing
  `and` with `or` has no equivalent in a rule and is refused.

  Field names are the catalog's, prefixed with their group
  (`player.level`, `match.teamkills`, `server.player_count`), and operators
  are short (`eq`, `ge`, `not_contains`, `in`).
  """

  alias HllConditionalActions.Rules.Catalog

  @group_prefix %{
    general: "rule",
    player: "player",
    squad: "squad",
    match_stats: "match",
    leaderboard: "rank",
    profile: "history",
    server: "server",
    schedule: "time",
    event: "event"
  }

  # Words already said by the prefix are dropped: `player_level` reads
  # `player.level`, `server_player_count` reads `server.player_count`.
  @strip %{player: "player_", squad: "squad_", leaderboard: "rank_", server: "server_"}

  @names (for field <- Catalog.fields(), field != :always_true, into: %{} do
            group = Catalog.field_group(field)
            short = String.replace_prefix(to_string(field), Map.get(@strip, group, ""), "")
            {field, "#{Map.fetch!(@group_prefix, group)}.#{short}"}
          end)

  @fields_by_name Map.new(@names, fn {field, name} -> {name, field} end)

  if map_size(@fields_by_name) != map_size(@names) do
    raise "two condition fields share an expression name"
  end

  @operators [
    equal: "eq",
    not_equal: "ne",
    greater_than: "gt",
    greater_than_or_equal: "ge",
    less_than: "lt",
    less_than_or_equal: "le",
    contains: "contains",
    not_contains: "not_contains",
    starts_with: "starts_with",
    ends_with: "ends_with",
    regex_match: "matches",
    in_list: "in",
    not_in_list: "not_in"
  ]

  @operators_by_name Map.new(@operators, fn {operator, name} -> {name, operator} end)

  @keywords ~w(and or not)
  @indent "    "

  @type error ::
          {atom() | {atom(), String.t()}, pos_integer(), pos_integer()}

  # ── Names ──────────────────────────────────────────────────────────────────

  @doc """
  A condition field's name in an expression.

      iex> HllConditionalActions.Rules.Expression.field_name(:player_level)
      "player.level"
      iex> HllConditionalActions.Rules.Expression.field_name(:teamkills)
      "match.teamkills"
  """
  @spec field_name(atom()) :: String.t()
  def field_name(field), do: Map.get(@names, field, to_string(field))

  @doc "The condition field an expression name stands for, or `nil`."
  @spec field(String.t()) :: atom() | nil
  def field(name), do: Map.get(@fields_by_name, name)

  @doc """
  An operator's short name.

      iex> HllConditionalActions.Rules.Expression.operator_name(:greater_than_or_equal)
      "ge"
  """
  @spec operator_name(atom()) :: String.t()
  def operator_name(operator), do: Keyword.get(@operators, operator, to_string(operator))

  @doc "Every operator's short name, in the catalog's order."
  @spec operator_names() :: [String.t()]
  def operator_names, do: Keyword.values(@operators)

  @doc "Every field name, grouped by the catalog's groups, in their order."
  @spec field_names() :: [{atom(), [{String.t(), atom()}]}]
  def field_names do
    for group <- Catalog.field_groups(),
        fields = Enum.reject(Catalog.fields_in_group(group), &(&1 == :always_true)),
        fields != [] do
      {group, Enum.map(fields, &{field_name(&1), Catalog.field_type(&1)})}
    end
  end

  # ── Writing ────────────────────────────────────────────────────────────────

  @doc """
  A rule (or anything with its fields: a struct or a snapshot map) written
  as an expression, with `comment` as its first line.
  """
  @spec to_text(map(), String.t() | nil) :: String.t()
  def to_text(rule, comment \\ nil) do
    trigger = get(rule, :trigger_event)
    game = get(rule, :game)
    operator = get(rule, :logical_operator) |> atomize() || :and

    conditions =
      rule
      |> get(:conditions)
      |> List.wrap()
      |> Enum.map(&condition_map/1)
      |> Enum.reject(&(&1.field == :always_true))

    header = if comment, do: ["# " <> comment], else: []

    head = [
      ~s(event.type eq "#{trigger}"),
      ~s(and server.game eq "#{game}")
    ]

    body =
      case {conditions, operator} do
        {[], _operator} ->
          []

        {[single], operator} when operator in [:and, :or] ->
          ["and " <> condition_text(single)]

        {conditions, operator} ->
          joiner = if operator in [:and, :nand], do: "and ", else: "or "
          negated = operator in [:nand, :nor]

          lines =
            conditions
            |> Enum.map(&condition_text/1)
            |> Enum.with_index()
            |> Enum.map(fn
              {text, 0} -> @indent <> text
              {text, _index} -> @indent <> joiner <> text
            end)

          [if(negated, do: "and not (", else: "and (")] ++ lines ++ [")"]
      end

    Enum.join(header ++ head ++ body, "\n")
  end

  defp condition_text(%{field: field, operator: operator, value: value}) do
    "#{field_name(field)} #{operator_name(operator)} #{value_text(field, operator, value)}"
  end

  defp value_text(field, operator, value) do
    value = to_string(value || "")

    if operator in [:in_list, :not_in_list] do
      items =
        value
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&scalar_text(field, &1))

      "[" <> Enum.join(items, ", ") <> "]"
    else
      scalar_text(field, value)
    end
  end

  defp scalar_text(field, value) do
    case {safe_type(field), value} do
      {:boolean, value} ->
        if truthy?(value), do: "true", else: "false"

      {type, value} when type in [:integer, :float] ->
        if number?(value), do: value, else: quote_text(value)

      {_type, value} ->
        quote_text(value)
    end
  end

  defp safe_type(field) do
    Catalog.field_type(field)
  rescue
    _unknown -> :string
  end

  defp truthy?(value), do: String.downcase(String.trim(value)) in ~w(true 1 yes)

  defp number?(value), do: Regex.match?(~r/^-?\d+(\.\d+)?$/, value)

  defp quote_text(value) do
    ~s(") <> String.replace(value, ["\\", ~s(")], fn char -> "\\" <> char end) <> ~s(")
  end

  defp condition_map(%{__struct__: _} = condition),
    do: %{field: condition.field, operator: condition.operator, value: condition.value}

  defp condition_map(map) when is_map(map) do
    %{
      field: atomize(map["field"] || map[:field]),
      operator: atomize(map["operator"] || map[:operator]),
      value: map["value"] || map[:value]
    }
  end

  defp get(%{__struct__: _} = rule, key), do: Map.get(rule, key)
  defp get(map, key) when is_map(map), do: Map.get(map, to_string(key), Map.get(map, key))

  defp atomize(value) when is_atom(value), do: value

  defp atomize(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp atomize(_value), do: nil

  # ── Reading ────────────────────────────────────────────────────────────────

  @doc """
  Reads an expression into rule attributes, or says where it went wrong.

      iex> alias HllConditionalActions.Rules.Expression
      iex> {:ok, attrs} = Expression.parse(~s(event.type eq "player_kill"\\nand server.game eq "hll"\\nand player.level ge 10))
      iex> {attrs.trigger_event, attrs.logical_operator, attrs.conditions}
      {:player_kill, :and, [%{"field" => "player_level", "operator" => "greater_than_or_equal", "value" => "10"}]}
  """
  @spec parse(String.t()) :: {:ok, map()} | {:error, error()}
  def parse(text) when is_binary(text) do
    with {:ok, tokens} <- tokenize(text),
         {:ok, clauses} <- clauses(Enum.reject(tokens, &(elem(&1, 0) == :comment)), []) do
      assemble(clauses)
    end
  end

  # Clauses joined by `and`: the trigger, the game and the conditions.
  defp clauses([], acc), do: {:ok, Enum.reverse(acc)}

  defp clauses(tokens, acc) do
    tokens = if acc != [], do: expect_and(tokens), else: {:ok, tokens}

    with {:ok, tokens} <- tokens,
         {:ok, clause, rest} <- clause(tokens) do
      clauses(rest, [clause | acc])
    end
  end

  defp expect_and([{:word, "and", _pos} | rest]), do: {:ok, rest}

  defp expect_and([{_kind, text, {line, col}} | _rest]),
    do: {:error, {{:expected_and, text}, line, col}}

  defp clause([{:word, "event.type", pos}, {:word, "eq", _p}, {:string, value, vpos} | rest]) do
    case Enum.find(Catalog.triggers(), &(to_string(&1) == value)) do
      nil -> {:error, {{:unknown_trigger, value}, elem(vpos, 0), elem(vpos, 1)}}
      trigger -> {:ok, {:trigger, trigger, pos}, rest}
    end
  end

  defp clause([{:word, "server.game", pos}, {:word, "eq", _p}, {:string, value, vpos} | rest]) do
    case value do
      "hll" -> {:ok, {:game, :hll, pos}, rest}
      "hllv" -> {:ok, {:game, :hllv, pos}, rest}
      _other -> {:error, {{:unknown_game, value}, elem(vpos, 0), elem(vpos, 1)}}
    end
  end

  defp clause([{:word, "not", _pos}, {:punct, "(", pos} | rest]) do
    with {:ok, conditions, joiner, rest} <- group(rest, pos) do
      {:ok, {:conditions, if(joiner == "or", do: :nor, else: :nand), conditions, pos}, rest}
    end
  end

  defp clause([{:punct, "(", pos} | rest]) do
    with {:ok, conditions, joiner, rest} <- group(rest, pos) do
      {:ok, {:conditions, if(joiner == "or", do: :or, else: :and), conditions, pos}, rest}
    end
  end

  defp clause(tokens) do
    with {:ok, condition, pos, rest} <- condition(tokens) do
      {:ok, {:conditions, :and, [condition], pos}, rest}
    end
  end

  # Conditions inside parentheses, all joined by the same word.
  defp group(tokens, {line, col}) do
    with {:ok, first, _pos, rest} <- condition(tokens) do
      group_rest(rest, [first], nil, {line, col})
    end
  end

  defp group_rest([{:punct, ")", _pos} | rest], conditions, joiner, _open),
    do: {:ok, Enum.reverse(conditions), joiner || "and", rest}

  defp group_rest([{:word, word, {line, col}} | rest], conditions, joiner, open)
       when word in ["and", "or"] do
    if joiner != nil and joiner != word do
      {:error, {:mixed, line, col}}
    else
      with {:ok, condition, _pos, rest} <- condition(rest) do
        group_rest(rest, [condition | conditions], word, open)
      end
    end
  end

  defp group_rest([], _conditions, _joiner, {line, col}), do: {:error, {:unclosed, line, col}}

  defp group_rest([{_kind, text, {line, col}} | _rest], _conditions, _joiner, _open),
    do: {:error, {{:unexpected, text}, line, col}}

  defp condition([{:word, name, {line, col} = pos} | rest]) do
    case field(name) do
      nil when name in @keywords ->
        {:error, {{:unexpected, name}, line, col}}

      nil ->
        {:error, {{:unknown_field, name}, line, col}}

      field ->
        with {:ok, operator, rest} <- operator(rest, field, pos),
             {:ok, value, rest} <- value(rest, operator, pos) do
          condition = %{
            "field" => to_string(field),
            "operator" => to_string(operator),
            "value" => value
          }

          {:ok, condition, pos, rest}
        end
    end
  end

  defp condition([{_kind, text, {line, col}} | _rest]),
    do: {:error, {{:unexpected, text}, line, col}}

  defp condition([]), do: {:error, {:unexpected_end, 1, 1}}

  defp operator([{:word, name, {line, col}} | rest], field, _pos) do
    case Map.get(@operators_by_name, name) do
      nil ->
        {:error, {{:unknown_operator, name}, line, col}}

      operator ->
        if operator in Catalog.operators_for_field(field),
          do: {:ok, operator, rest},
          else: {:error, {{:operator_not_for_field, name}, line, col}}
    end
  end

  defp operator([{_kind, text, {line, col}} | _rest], _field, _pos),
    do: {:error, {{:unexpected, text}, line, col}}

  defp operator([], _field, {line, col}), do: {:error, {:unexpected_end, line, col}}

  defp value([{:punct, "[", {line, col}} | rest], operator, _pos)
       when operator in [:in_list, :not_in_list] do
    list_items(rest, [], {line, col})
  end

  defp value([{kind, text, _pos} | rest], operator, _pos2)
       when kind in [:string, :number, :bool] and operator not in [:in_list, :not_in_list] do
    {:ok, text, rest}
  end

  defp value([{_kind, text, {line, col}} | _rest], _operator, _pos),
    do: {:error, {{:expected_value, text}, line, col}}

  defp value([], _operator, {line, col}), do: {:error, {:unexpected_end, line, col}}

  defp list_items([{:punct, "]", _pos} | rest], items, _open),
    do: {:ok, items |> Enum.reverse() |> Enum.join(", "), rest}

  defp list_items([{:punct, ",", _pos} | rest], items, open) when items != [],
    do: list_items(rest, items, open)

  defp list_items([{kind, text, _pos} | rest], items, open) when kind in [:string, :number],
    do: list_items(rest, [text | items], open)

  defp list_items([], _items, {line, col}), do: {:error, {:unclosed, line, col}}

  defp list_items([{_kind, text, {line, col}} | _rest], _items, _open),
    do: {:error, {{:unexpected, text}, line, col}}

  defp assemble(clauses) do
    triggers = for {:trigger, trigger, pos} <- clauses, do: {trigger, pos}
    games = for {:game, game, pos} <- clauses, do: {game, pos}

    groups =
      for {:conditions, operator, conditions, pos} <- clauses, do: {operator, conditions, pos}

    with :ok <- once(triggers, :missing_trigger, :two_triggers),
         :ok <- at_most_once(games, :two_games),
         {:ok, operator, conditions} <- combined(groups) do
      attrs = %{
        trigger_event: triggers |> hd() |> elem(0),
        logical_operator: operator,
        conditions: always_if_empty(conditions)
      }

      {:ok, put_game(attrs, games)}
    end
  end

  defp once([], missing, _twice), do: {:error, {missing, 1, 1}}
  defp once([_one], _missing, _twice), do: :ok

  defp once([_first, {_value, {line, col}} | _rest], _missing, twice),
    do: {:error, {twice, line, col}}

  defp at_most_once([], _twice), do: :ok
  defp at_most_once(values, twice), do: once(values, nil, twice)

  defp combined(groups) do
    case combine(groups) do
      {:mixed, _conditions} ->
        {_operator, _conditions, {line, col}} = Enum.at(groups, 1)
        {:error, {:mixed, line, col}}

      {operator, conditions} ->
        {:ok, operator, conditions}
    end
  end

  defp always_if_empty([]),
    do: [%{"field" => "always_true", "operator" => "equal", "value" => ""}]

  defp always_if_empty(conditions), do: conditions

  defp put_game(attrs, [{game, _pos}]), do: Map.put(attrs, :game, game)
  defp put_game(attrs, []), do: attrs

  # Loose conditions all join with `and`; a parenthesised group may say how
  # its own conditions join, but only when it is the only group.
  defp combine([]), do: {:and, []}
  defp combine([{operator, conditions, _pos}]), do: {operator, conditions}

  defp combine(groups) do
    if Enum.all?(groups, fn {operator, conditions, _pos} ->
         operator == :and or (length(conditions) == 1 and operator == :or)
       end) do
      {:and, Enum.flat_map(groups, &elem(&1, 1))}
    else
      {:mixed, []}
    end
  end

  # ── Tokens ─────────────────────────────────────────────────────────────────

  @doc """
  An expression as tokens, `{kind, text, {line, column}}`, with kinds
  `:word`, `:string`, `:number`, `:bool`, `:punct` and `:comment`.
  """
  @spec tokenize(String.t()) :: {:ok, [tuple()]} | {:error, error()}
  def tokenize(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, number}, {:ok, acc} ->
      case scan(line, number, 1, []) do
        {:ok, tokens} -> {:cont, {:ok, acc ++ tokens}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  One line of an expression as `{class, text}` pieces for highlighting:
  `:comment`, `:field`, `:keyword`, `:operator`, `:string`, `:number`,
  `:bool`, `:punct`, `:space` and `:error`. Never fails: what cannot be read is an
  `:error` piece.
  """
  @spec highlight(String.t()) :: [{atom(), String.t()}]
  def highlight(line) do
    case scan(line, 1, 1, [], true) do
      {:ok, tokens} -> Enum.map(tokens, &classify/1)
    end
  end

  defp classify({:comment, text, _pos}), do: {:comment, text}
  defp classify({:space, text, _pos}), do: {:space, text}
  defp classify({:string, text, _pos}), do: {:string, text}
  defp classify({:number, text, _pos}), do: {:number, text}
  defp classify({:bool, text, _pos}), do: {:bool, text}
  defp classify({:punct, text, _pos}), do: {:punct, text}
  defp classify({:error, text, _pos}), do: {:error, text}
  defp classify({:word, text, _pos}) when text in @keywords, do: {:keyword, text}

  defp classify({:word, text, _pos}) do
    cond do
      Map.has_key?(@operators_by_name, text) ->
        {:operator, text}

      text in ["event.type", "server.game"] or Map.has_key?(@fields_by_name, text) ->
        {:field, text}

      true ->
        {:error, text}
    end
  end

  # `raw?` keeps spaces and the quotes of strings, for highlighting.
  defp scan(line, number, col, acc, raw? \\ false)

  defp scan("", _number, _col, acc, _raw?), do: {:ok, Enum.reverse(acc)}

  defp scan("#" <> _rest = comment, number, col, acc, _raw?),
    do: {:ok, Enum.reverse([{:comment, comment, {number, col}} | acc])}

  defp scan(<<char::utf8, _rest::binary>> = line, number, col, acc, raw?)
       when char in [?\s, ?\t, ?\r] do
    [spaces] = Regex.run(~r/^[\s]+/u, line)
    rest = binary_part(line, byte_size(spaces), byte_size(line) - byte_size(spaces))
    acc = if raw?, do: [{:space, spaces, {number, col}} | acc], else: acc
    scan(rest, number, col + String.length(spaces), acc, raw?)
  end

  defp scan(<<char::utf8, rest::binary>>, number, col, acc, raw?)
       when char in [?(, ?), ?[, ?], ?,] do
    scan(rest, number, col + 1, [{:punct, <<char::utf8>>, {number, col}} | acc], raw?)
  end

  defp scan(~s(") <> rest, number, col, acc, raw?) do
    case read_string(rest, "") do
      {:ok, value, consumed, rest} ->
        text = if raw?, do: ~s(") <> consumed, else: value

        scan(
          rest,
          number,
          col + 1 + String.length(consumed),
          [{:string, text, {number, col}} | acc],
          raw?
        )

      :unclosed when raw? ->
        {:ok, Enum.reverse([{:string, ~s(") <> rest, {number, col}} | acc])}

      :unclosed ->
        {:error, {:unclosed_string, number, col}}
    end
  end

  defp scan(line, number, col, acc, raw?) do
    cond do
      match = Regex.run(~r/^-?\d+(\.\d+)?(?![\w.])/, line) ->
        take(line, hd(match), :number, number, col, acc, raw?)

      match = Regex.run(~r/^(true|false)(?![\w.])/, line) ->
        take(line, hd(match), :bool, number, col, acc, raw?)

      match = Regex.run(~r/^[a-z_][a-z0-9_]*(\.[a-z_][a-z0-9_]*)*/, line) ->
        take(line, hd(match), :word, number, col, acc, raw?)

      raw? ->
        <<char::utf8, rest::binary>> = line
        scan(rest, number, col + 1, [{:error, <<char::utf8>>, {number, col}} | acc], raw?)

      true ->
        {:error, {{:unexpected, String.first(line)}, number, col}}
    end
  end

  defp take(line, text, kind, number, col, acc, raw?) do
    rest = binary_part(line, byte_size(text), byte_size(line) - byte_size(text))
    scan(rest, number, col + String.length(text), [{kind, text, {number, col}} | acc], raw?)
  end

  # A string's value and the raw text it took (closing quote included).
  defp read_string("", _value), do: :unclosed

  defp read_string(~s(\\) <> <<char::utf8, rest::binary>>, value) do
    case read_string(rest, value <> <<char::utf8>>) do
      {:ok, final, consumed, rest} -> {:ok, final, "\\" <> <<char::utf8>> <> consumed, rest}
      :unclosed -> :unclosed
    end
  end

  defp read_string(~s(") <> rest, value), do: {:ok, value, ~s("), rest}

  defp read_string(<<char::utf8, rest::binary>>, value) do
    case read_string(rest, value <> <<char::utf8>>) do
      {:ok, final, consumed, rest} -> {:ok, final, <<char::utf8>> <> consumed, rest}
      :unclosed -> :unclosed
    end
  end

  @doc """
  How much an expression holds, for the status line: conditions and groups
  (a group being one run of conditions joined the same way).
  """
  @spec stats(map()) :: %{conditions: non_neg_integer(), groups: non_neg_integer()}
  def stats(%{conditions: conditions}) do
    count = Enum.count(conditions, &(&1["field"] != "always_true"))
    %{conditions: count, groups: if(count > 0, do: 1, else: 0)}
  end
end
