defmodule HllConditionalActions.Engine.Evaluator do
  @moduledoc """
  Decides whether a rule's conditions hold for a player.

  Evaluation is deliberately total: a field the current snapshot cannot answer
  (a stat that is missing, a game state that failed to load) yields `nil`, and
  a condition on `nil` is false. A rule never fires on incomplete data, which
  is the safe default when the actions include kicks and bans.
  """

  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActions.Rules.Condition
  alias HllConditionalActions.Rules.Rule

  @doc """
  Evaluates every condition of a rule and combines the results with its
  logical operator.

      iex> alias HllConditionalActions.Engine.{Context, Evaluator}
      iex> alias HllConditionalActions.Rules.{Condition, Rule}
      iex> server = %HllConditionalActions.Servers.Server{id: 1, name: "EU", game: :hll}
      iex> context = Context.build(server, :periodic, player: %{"kills" => 12})
      iex> rule = %Rule{logical_operator: :and, conditions: [
      ...>   %Condition{field: :kills, operator: :greater_than, value: "10"}
      ...> ]}
      iex> Evaluator.evaluate(rule, context)
      true
  """
  @spec evaluate(Rule.t(), Context.t()) :: boolean()
  def evaluate(%Rule{} = rule, %Context{} = context) do
    results = Enum.map(rule.conditions, &evaluate_condition(&1, context))
    combine(rule.logical_operator, results)
  end

  @doc """
  Evaluates a rule and returns the per-condition results alongside the verdict,
  for the "test this rule" view in the builder.
  """
  @spec explain(Rule.t(), Context.t()) :: %{result: boolean(), conditions: [map()]}
  def explain(%Rule{} = rule, %Context{} = context) do
    conditions =
      Enum.map(rule.conditions, fn condition ->
        actual = field_value(condition.field, context)

        %{
          field: condition.field,
          operator: condition.operator,
          expected: condition.value,
          actual: actual,
          result: compare(actual, condition.operator, condition.value, condition.field)
        }
      end)

    %{
      result: combine(rule.logical_operator, Enum.map(conditions, & &1.result)),
      conditions: conditions
    }
  end

  @doc """
  Evaluates a single condition.
  """
  @spec evaluate_condition(Condition.t(), Context.t()) :: boolean()
  def evaluate_condition(%Condition{field: :always_true}, %Context{}), do: true

  def evaluate_condition(%Condition{} = condition, %Context{} = context) do
    condition.field
    |> field_value(context)
    |> compare(condition.operator, condition.value, condition.field)
  end

  @doc """
  Combines condition results.

      iex> alias HllConditionalActions.Engine.Evaluator
      iex> {Evaluator.combine(:and, [true, false]), Evaluator.combine(:nand, [true, false])}
      {false, true}
  """
  @spec combine(atom(), [boolean()]) :: boolean()
  def combine(:and, results), do: Enum.all?(results)
  def combine(:or, results), do: Enum.any?(results)
  def combine(:nand, results), do: not Enum.all?(results)
  def combine(:nor, results), do: not Enum.any?(results)

  # ── Field extraction ───────────────────────────────────────────────────────

  @doc """
  Reads the current value of a condition field.

  Returns `nil` when the value is not available in this snapshot.
  """
  @spec field_value(atom(), Context.t()) :: term()
  def field_value(:always_true, _context), do: true
  def field_value(:player_name, context), do: context.player_name
  def field_value(:player_id, context), do: context.player_id
  def field_value(:player_level, context), do: player(context, "level")
  def field_value(:is_vip, context), do: player(context, "is_vip") || false
  def field_value(:player_role, context), do: downcase(player(context, "role"))
  def field_value(:player_team, context), do: Context.team(context)
  def field_value(:player_unit_name, context), do: player(context, "unit_name")
  def field_value(:clan_tag, context), do: player(context, "clan_tag")

  def field_value(:is_squad_leader, context), do: Context.squad_leader?(context)
  def field_value(:is_commander, context), do: Context.commander?(context)
  def field_value(:squad_has_leader, context), do: Context.squad_has_leader?(context)
  def field_value(:squad_is_armor, context), do: Context.armor_squad?(context)
  def field_value(:squad_is_solo_armor, context), do: Context.solo_armor?(context)

  def field_value(:squad_size, context) do
    case Context.squad(context) do
      [] -> nil
      players -> length(players)
    end
  end

  def field_value(:platform, context), do: player(context, "platform")

  def field_value(:kills, context), do: player(context, "kills")
  def field_value(:deaths, context), do: player(context, "deaths")
  def field_value(:teamkills, context), do: player(context, "team_kills")
  def field_value(:combat_score, context), do: player(context, "combat")
  def field_value(:offense_score, context), do: player(context, "offense")
  def field_value(:defense_score, context), do: player(context, "defense")
  def field_value(:support_score, context), do: player(context, "support")
  def field_value(:playtime_seconds, context), do: player(context, "map_playtime_seconds")

  # A player with kills and no deaths has an undefined ratio; CRCON reports the
  # kill count itself there, and rules written against CRCON expect that.
  def field_value(:kill_death_ratio, context) do
    with kills when is_number(kills) <- player(context, "kills"),
         deaths when is_number(deaths) <- player(context, "deaths") do
      if deaths > 0, do: kills / deaths, else: kills * 1.0
    else
      _missing -> nil
    end
  end

  def field_value(:kills_per_minute, context), do: per_minute(context, "kills")
  def field_value(:deaths_per_minute, context), do: per_minute(context, "deaths")

  def field_value(:total_playtime_seconds, context),
    do: player_profile(context, "total_playtime_seconds")

  def field_value(:sessions_count, context), do: player_profile(context, "sessions_count")

  # CRCON stores penalties as a map of counters per action type; a rule asking
  # for "penalty_count" means "how many penalties in total".
  def field_value(:penalty_count, context) do
    case player_profile(context, "penalty_count") do
      counts when is_map(counts) -> counts |> Map.values() |> Enum.sum()
      count when is_integer(count) -> count
      _missing -> nil
    end
  end

  def field_value(:flags, context) do
    case player_profile(context, "flags") do
      flags when is_list(flags) -> Enum.map(flags, &flag_value/1)
      _missing -> nil
    end
  end

  def field_value(:server_player_count, context), do: Context.server_player_count(context)
  def field_value(:team_player_count, context), do: Context.team_player_count(context)

  def field_value(:queue_count, context),
    do: Context.gamestate_field(context.gamestate, "queue_count")

  def field_value(:allied_player_count, context),
    do: Context.gamestate_field(context.gamestate, "num_allied_players")

  def field_value(:axis_player_count, context),
    do: Context.gamestate_field(context.gamestate, "num_axis_players")

  def field_value(:allied_score, context),
    do: Context.gamestate_field(context.gamestate, "allied_score")

  def field_value(:axis_score, context),
    do: Context.gamestate_field(context.gamestate, "axis_score")

  # How lopsided the teams are, as a count, whichever side is bigger. A
  # seeding or balance rule wants "off by more than 3", not "who is ahead".
  def field_value(:team_balance, context) do
    with allied when is_number(allied) <-
           Context.gamestate_field(context.gamestate, "num_allied_players"),
         axis when is_number(axis) <-
           Context.gamestate_field(context.gamestate, "num_axis_players") do
      abs(allied - axis)
    else
      _missing -> nil
    end
  end

  def field_value(:map_name, context), do: Context.map_name(context)

  def field_value(:game_mode, context),
    do: downcase(Context.gamestate_field(context.gamestate, "game_mode"))

  def field_value(:match_time_remaining, context) do
    context.gamestate
    |> Context.gamestate_field("raw_time_remaining")
    |> Context.parse_time_remaining()
  end

  def field_value(:hour_of_day, context), do: Context.local_now(context).hour
  def field_value(:day_of_week, context), do: context |> Context.local_now() |> Context.day_name()

  def field_value(:message_content, context), do: event(context, :chat_message)
  def field_value(:message_scope, context), do: event(context, :chat_scope)
  def field_value(:message_team, context), do: event(context, :chat_team)
  def field_value(:weapon, context), do: event(context, :weapon)
  def field_value(:target_player_name, context), do: event(context, :target_player_name)
  def field_value(:event_action, context), do: event(context, :action)

  # The chat command trigger splits "!vip please" into the command and the
  # rest, so a rule reads `command is vip` rather than a regex on the message.
  def field_value(:command, context), do: context |> chat_command() |> elem(0)
  def field_value(:command_args, context), do: context |> chat_command() |> elem(1)

  # Set by the engine before evaluating, because it costs a query.
  def field_value(:strikes, context), do: Map.get(context.extra, :strikes, 0)

  defp chat_command(context) do
    case event(context, :chat_message) do
      message when is_binary(message) -> Context.parse_command(message)
      _no_message -> {nil, nil}
    end
  end

  # ── Comparison ─────────────────────────────────────────────────────────────

  @doc """
  Compares an actual value against the expected one from a condition.

      iex> alias HllConditionalActions.Engine.Evaluator
      iex> Evaluator.compare(15, :greater_than, "10", :kills)
      true
      iex> Evaluator.compare("Chris", :starts_with, "chr", :player_name)
      true
      iex> Evaluator.compare(nil, :equal, "anything", :player_name)
      false
  """
  @spec compare(term(), atom(), String.t() | nil, atom()) :: boolean()
  def compare(nil, _operator, _expected, _field), do: false

  def compare(actual, operator, expected, field) do
    type = Catalog.field_type(field)

    cond do
      Catalog.list_operator?(operator) -> compare_list(actual, operator, expected, type)
      type == :list -> compare_collection(actual, operator, expected)
      true -> compare_scalar(actual, operator, expected, type)
    end
  end

  defp compare_scalar(actual, operator, expected, _type)
       when operator in [:greater_than, :greater_than_or_equal, :less_than, :less_than_or_equal] do
    with {:ok, left} <- to_number(actual),
         {:ok, right} <- to_number(expected) do
      case operator do
        :greater_than -> left > right
        :greater_than_or_equal -> left >= right
        :less_than -> left < right
        :less_than_or_equal -> left <= right
      end
    else
      :error -> false
    end
  end

  defp compare_scalar(actual, :equal, expected, type), do: equal?(actual, expected, type)
  defp compare_scalar(actual, :not_equal, expected, type), do: not equal?(actual, expected, type)

  defp compare_scalar(actual, :contains, expected, _type),
    do: String.contains?(normalize(actual), normalize(expected))

  defp compare_scalar(actual, :not_contains, expected, _type),
    do: not String.contains?(normalize(actual), normalize(expected))

  defp compare_scalar(actual, :starts_with, expected, _type),
    do: String.starts_with?(normalize(actual), normalize(expected))

  defp compare_scalar(actual, :ends_with, expected, _type),
    do: String.ends_with?(normalize(actual), normalize(expected))

  defp compare_scalar(actual, :regex_match, expected, _type) do
    case Regex.compile(to_string(expected)) do
      {:ok, regex} -> Regex.match?(regex, to_string(actual))
      {:error, _reason} -> false
    end
  end

  defp compare_scalar(_actual, _operator, _expected, _type), do: false

  # `flags` and friends are lists; "contains" asks about membership.
  defp compare_collection(actual, :contains, expected) when is_list(actual) do
    Enum.any?(actual, &(normalize(&1) == normalize(expected)))
  end

  defp compare_collection(actual, :not_contains, expected) when is_list(actual) do
    not compare_collection(actual, :contains, expected)
  end

  defp compare_collection(_actual, _operator, _expected), do: false

  defp compare_list(actual, operator, expected, type) do
    values = expected |> to_string() |> String.split(",") |> Enum.map(&String.trim/1)
    member? = Enum.any?(values, &equal?(actual, &1, type))

    case operator do
      :in_list -> member?
      :not_in_list -> not member?
    end
  end

  defp equal?(actual, expected, :boolean), do: to_boolean(actual) == to_boolean(expected)

  defp equal?(actual, expected, type) when type in [:integer, :float] do
    case {to_number(actual), to_number(expected)} do
      {{:ok, left}, {:ok, right}} -> left == right
      _other -> false
    end
  end

  defp equal?(actual, expected, _type), do: normalize(actual) == normalize(expected)

  # ── Casting ────────────────────────────────────────────────────────────────

  defp to_number(value) when is_number(value), do: {:ok, value}

  defp to_number(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {int, ""} ->
        {:ok, int}

      _other ->
        case Float.parse(trimmed) do
          {float, ""} -> {:ok, float}
          _other -> :error
        end
    end
  end

  defp to_number(_value), do: :error

  defp to_boolean(true), do: true
  defp to_boolean(false), do: false
  defp to_boolean(value) when is_binary(value), do: String.downcase(value) in ~w(true 1 yes on)
  defp to_boolean(nil), do: false
  defp to_boolean(_value), do: true

  # Comparisons on text are case insensitive, matching CRCON's behaviour: an
  # admin writing a rule against "Sniper" means the role regardless of casing.
  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(nil), do: ""
  defp normalize(true), do: "true"
  defp normalize(false), do: "false"
  defp normalize(value), do: value |> to_string() |> String.downcase()

  # ── Small helpers ──────────────────────────────────────────────────────────

  defp player(context, key), do: Context.player_field(context.player, key)

  defp player_profile(%Context{player_profile: nil}, _key), do: nil
  defp player_profile(%Context{player_profile: profile}, key), do: Map.get(profile, key)

  defp per_minute(context, key) do
    with value when is_number(value) <- player(context, key),
         seconds when is_number(seconds) and seconds > 0 <-
           player(context, "map_playtime_seconds") do
      Float.round(value / (seconds / 60), 2)
    else
      _missing -> nil
    end
  end

  defp event(%Context{event: nil}, _key), do: nil
  defp event(%Context{event: event}, key), do: Map.get(event, key)

  defp flag_value(%{"flag" => flag}), do: flag
  defp flag_value(flag) when is_binary(flag), do: flag
  defp flag_value(_other), do: nil

  defp downcase(nil), do: nil
  defp downcase(value), do: value |> to_string() |> String.downcase()
end
