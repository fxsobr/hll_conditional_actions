defmodule HllConditionalActions.Engine.EvaluatorTest do
  use ExUnit.Case, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Crcon.Events
  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Evaluator
  alias HllConditionalActions.Rules.Condition
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Servers.Server

  doctest HllConditionalActions.Engine.Evaluator
  doctest HllConditionalActions.Engine.Context

  @server %Server{id: 1, name: "EU #1", game: :hll}
  @hllv_server %Server{id: 2, name: "Nam #1", game: :hllv}

  describe "numeric fields" do
    setup do
      %{context: context(player: player())}
    end

    test "compares against the value stored as text", %{context: context} do
      assert holds?(:kills, :greater_than, "5", context)
      refute holds?(:kills, :greater_than, "50", context)
      assert holds?(:kills, :greater_than_or_equal, "10", context)
      assert holds?(:deaths, :less_than, "10", context)
      assert holds?(:kills, :equal, "10", context)
    end

    test "a non numeric expected value fails instead of raising", %{context: context} do
      refute holds?(:kills, :greater_than, "many", context)
    end

    test "derives the kill/death ratio", %{context: context} do
      # 10 kills, 5 deaths
      assert Evaluator.field_value(:kill_death_ratio, context) == 2.0
      assert holds?(:kill_death_ratio, :greater_than_or_equal, "2", context)
    end

    test "a player with no deaths reports their kill count as the ratio" do
      context = context(player: player(%{"kills" => 7, "deaths" => 0}))
      assert Evaluator.field_value(:kill_death_ratio, context) == 7.0
    end

    test "derives per minute rates from the map playtime" do
      context = context(player: player(%{"kills" => 30, "map_playtime_seconds" => 600}))
      assert Evaluator.field_value(:kills_per_minute, context) == 3.0
    end

    test "a rate is unavailable rather than infinite when playtime is zero" do
      context = context(player: player(%{"map_playtime_seconds" => 0}))
      assert Evaluator.field_value(:kills_per_minute, context) == nil
    end
  end

  describe "text fields" do
    setup do
      %{context: context(player: player(%{"name" => "Chris"}))}
    end

    test "comparisons ignore casing", %{context: context} do
      assert holds?(:player_name, :equal, "chris", context)
      assert holds?(:player_name, :contains, "HRI", context)
      assert holds?(:player_name, :starts_with, "CH", context)
      assert holds?(:player_name, :ends_with, "is", context)
    end

    test "regex matching", %{context: context} do
      assert holds?(:player_name, :regex_match, "^Chr", context)
      refute holds?(:player_name, :regex_match, "^Mu", context)
    end

    test "an invalid regex fails closed instead of raising", %{context: context} do
      refute holds?(:player_name, :regex_match, "[unclosed", context)
    end

    test "list membership", %{context: context} do
      assert holds?(:player_name, :in_list, "muctar, chris, ana", context)
      refute holds?(:player_name, :in_list, "muctar, ana", context)
      assert holds?(:player_name, :not_in_list, "muctar, ana", context)
    end
  end

  describe "booleans" do
    test "accept the JSON and form spellings of true" do
      context = context(player: player(%{"is_vip" => true}))

      assert holds?(:is_vip, :equal, "true", context)
      assert holds?(:is_vip, :equal, "yes", context)
      assert holds?(:is_vip, :equal, "1", context)
      refute holds?(:is_vip, :equal, "false", context)
    end

    test "a missing VIP flag reads as false, not as unknown" do
      context = context(player: player() |> Map.delete("is_vip"))

      assert holds?(:is_vip, :equal, "false", context)
    end
  end

  describe "game specific fields" do
    test "the role value is the one CRCON reports for that game" do
      hll = context(player: player(%{"role" => "Officer"}))
      hllv = context(server: @hllv_server, player: player(%{"role" => "SquadLeader"}))

      assert holds?(:player_role, :equal, "officer", hll)
      assert holds?(:player_role, :equal, "squadleader", hllv)
    end

    test "teams keep CRCON's keys in both games" do
      context = context(server: @hllv_server, player: player(%{"team" => "allies"}))

      assert holds?(:player_team, :equal, "allies", context)
    end
  end

  describe "server and match fields" do
    setup do
      %{context: context(player: player(), gamestate: gamestate())}
    end

    test "sums both teams for the server player count", %{context: context} do
      assert Evaluator.field_value(:server_player_count, context) == 49
      assert holds?(:server_player_count, :greater_than, "40", context)
    end

    test "reads the count of the player's own team", %{context: context} do
      assert Evaluator.field_value(:team_player_count, context) == 25
    end

    test "parses the remaining match time into seconds", %{context: context} do
      assert Evaluator.field_value(:match_time_remaining, context) == 3723
    end

    test "reads the map's pretty name", %{context: context} do
      assert holds?(:map_name, :contains, "carentan", context)
    end

    test "everything is unavailable without a game state" do
      context = context(player: player())

      assert Evaluator.field_value(:server_player_count, context) == nil
      refute holds?(:server_player_count, :greater_than, "0", context)
    end
  end

  describe "profile fields" do
    test "sums CRCON's per action penalty counters" do
      context =
        context(
          player: player(),
          player_profile: %{"penalty_count" => %{"KICK" => 2, "PUNISH" => 3, "TEMPBAN" => 1}}
        )

      assert Evaluator.field_value(:penalty_count, context) == 6
      assert holds?(:penalty_count, :greater_than, "5", context)
    end

    test "flags are a list and support membership" do
      context =
        context(player: player(), player_profile: %{"flags" => [%{"flag" => "🇧🇷"}]})

      assert holds?(:flags, :contains, "🇧🇷", context)
      assert holds?(:flags, :not_contains, "⭐", context)
    end

    test "a profile that was not fetched leaves the fields unavailable" do
      context = context(player: player())

      assert Evaluator.field_value(:sessions_count, context) == nil
    end
  end

  describe "event fields" do
    test "read from the event that triggered the evaluation" do
      event =
        Events.from_log(
          log_line(%{"action" => "CHAT[Allies][Team]", "sub_content" => "Enemy tank north!"})
        )

      context = context(player: player(), event: event, trigger: :player_chat)

      assert holds?(:message_content, :contains, "tank", context)
      assert holds?(:message_scope, :equal, "team", context)
      assert holds?(:message_team, :equal, "allies", context)
    end

    test "the weapon comes from a kill event" do
      context =
        context(player: player(), event: Events.from_log(log_line()), trigger: :player_kill)

      assert holds?(:weapon, :contains, "garand", context)
    end
  end

  describe "combining conditions" do
    setup do
      %{context: context(player: player(), gamestate: gamestate())}
    end

    test "and requires every condition", %{context: context} do
      rule = rule(:and, [{:kills, :greater_than, "5"}, {:deaths, :less_than, "10"}])
      assert Evaluator.evaluate(rule, context)

      rule = rule(:and, [{:kills, :greater_than, "5"}, {:deaths, :less_than, "1"}])
      refute Evaluator.evaluate(rule, context)
    end

    test "or accepts any condition", %{context: context} do
      rule = rule(:or, [{:kills, :greater_than, "500"}, {:deaths, :less_than, "10"}])
      assert Evaluator.evaluate(rule, context)
    end

    test "nand and nor invert their counterparts", %{context: context} do
      conditions = [{:kills, :greater_than, "5"}, {:deaths, :less_than, "1"}]

      assert Evaluator.evaluate(rule(:nand, conditions), context)
      refute Evaluator.evaluate(rule(:nor, conditions), context)
    end
  end

  describe "explain/2" do
    test "reports each condition's actual value alongside the verdict" do
      context = context(player: player())
      rule = rule(:and, [{:kills, :greater_than, "5"}, {:deaths, :greater_than, "50"}])

      assert %{result: false, conditions: [first, second]} = Evaluator.explain(rule, context)
      assert first.actual == 10
      assert first.result
      assert second.actual == 5
      refute second.result
    end
  end

  test "a condition on a missing value is false, never an error" do
    context = context(player: nil)

    refute holds?(:kills, :greater_than, "0", context)
    refute holds?(:player_name, :equal, "chris", context)
  end

  test "always_true holds even with no data at all" do
    assert holds?(:always_true, :equal, "", context(player: nil))
  end

  defp context(opts) do
    server = Keyword.get(opts, :server, @server)
    trigger = Keyword.get(opts, :trigger, :periodic)

    Context.build(server, trigger,
      player: Keyword.get(opts, :player),
      player_profile: Keyword.get(opts, :player_profile),
      gamestate: Keyword.get(opts, :gamestate),
      event: Keyword.get(opts, :event)
    )
  end

  defp holds?(field, operator, value, context) do
    Evaluator.evaluate_condition(
      %Condition{field: field, operator: operator, value: value},
      context
    )
  end

  defp rule(logical_operator, conditions) do
    %Rule{
      logical_operator: logical_operator,
      conditions:
        Enum.map(conditions, fn {field, operator, value} ->
          %Condition{field: field, operator: operator, value: value}
        end)
    }
  end
end
