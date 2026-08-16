defmodule HllConditionalActions.Engine.SquadConditionsTest do
  @moduledoc """
  The squad conditions are read from the roster the evaluation cycle already
  fetched, so they must work off `get_detailed_players` alone — no extra CRCON
  call — and stay `nil` (rather than guessing) when the roster is missing.
  """

  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Evaluator

  defp roster(players) do
    Map.new(players, &{&1["player_id"], &1})
  end

  defp context(server, player, mates \\ []) do
    Context.build(server, :periodic,
      player: player,
      roster: roster([player | mates]),
      gamestate: gamestate()
    )
  end

  setup do
    %{server: server_fixture()}
  end

  describe "squad membership" do
    test "counts everyone in the same unit on the same team", %{server: server} do
      me = player(%{"player_id" => "1", "unit_name" => "able", "team" => "allies"})

      mates = [
        player(%{"player_id" => "2", "unit_name" => "able", "team" => "allies"}),
        # same unit letter, other team: a different squad
        player(%{"player_id" => "3", "unit_name" => "able", "team" => "axis"}),
        player(%{"player_id" => "4", "unit_name" => "baker", "team" => "allies"})
      ]

      assert Evaluator.field_value(:squad_size, context(server, me, mates)) == 2
    end

    test "has no squad without a unit", %{server: server} do
      me = player(%{"player_id" => "1", "unit_name" => nil})

      assert Evaluator.field_value(:squad_size, context(server, me)) == nil
    end
  end

  describe "leadership" do
    test "sees the officer in the squad", %{server: server} do
      me = player(%{"player_id" => "1", "role" => "rifleman"})
      officer = player(%{"player_id" => "2", "role" => "officer"})

      assert Evaluator.field_value(:squad_has_leader, context(server, me, [officer])) == true
      assert Evaluator.field_value(:is_squad_leader, context(server, me, [officer])) == false
    end

    test "reports a leaderless squad", %{server: server} do
      me = player(%{"player_id" => "1", "role" => "rifleman"})
      mate = player(%{"player_id" => "2", "role" => "medic"})

      assert Evaluator.field_value(:squad_has_leader, context(server, me, [mate])) == false
    end

    test "knows the player leads it themselves", %{server: server} do
      me = player(%{"player_id" => "1", "role" => "officer"})

      assert Evaluator.field_value(:is_squad_leader, context(server, me)) == true
    end

    test "knows the commander", %{server: server} do
      me = player(%{"player_id" => "1", "role" => "armycommander"})

      assert Evaluator.field_value(:is_commander, context(server, me)) == true
      assert Evaluator.field_value(:is_commander, context(server, player())) == false
    end
  end

  describe "armor" do
    test "spots a lone tanker", %{server: server} do
      me = player(%{"player_id" => "1", "role" => "crewman", "unit_name" => "able"})

      assert Evaluator.field_value(:squad_is_armor, context(server, me)) == true
      assert Evaluator.field_value(:squad_is_solo_armor, context(server, me)) == true
    end

    test "a crewed tank is not solo", %{server: server} do
      me = player(%{"player_id" => "1", "role" => "crewman", "unit_name" => "able"})
      mate = player(%{"player_id" => "2", "role" => "tankcommander", "unit_name" => "able"})

      assert Evaluator.field_value(:squad_is_solo_armor, context(server, me, [mate])) == false
    end

    test "infantry is never armor", %{server: server} do
      assert Evaluator.field_value(:squad_is_armor, context(server, player())) == false
    end
  end

  describe "team and match fields" do
    test "reads the per-team counts and how lopsided they are", %{server: server} do
      state = gamestate(%{"num_allied_players" => 40, "num_axis_players" => 46})
      context = Context.build(server, :periodic, player: player(), gamestate: state)

      assert Evaluator.field_value(:allied_player_count, context) == 40
      assert Evaluator.field_value(:axis_player_count, context) == 46
      assert Evaluator.field_value(:team_balance, context) == 6
    end

    test "has no balance without a game state", %{server: server} do
      context = Context.build(server, :periodic, player: player())

      assert Evaluator.field_value(:team_balance, context) == nil
    end
  end
end
