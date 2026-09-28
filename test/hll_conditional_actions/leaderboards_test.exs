defmodule HllConditionalActions.LeaderboardsTest do
  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Engine
  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Evaluator
  alias HllConditionalActions.Engine.Snapshot
  alias HllConditionalActions.Engine.Template
  alias HllConditionalActions.Leaderboards
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Servers.Server

  doctest HllConditionalActions.Leaderboards

  defp p(id, attrs) do
    player(
      Map.merge(
        %{
          "player_id" => id,
          "name" => id,
          "kills" => 0,
          "deaths" => 0,
          "combat" => 0,
          "offense" => 0,
          "defense" => 0,
          "support" => 0,
          "team" => "allies",
          "unit_name" => nil,
          "role" => "rifleman",
          "map_playtime_seconds" => 1200
        },
        attrs
      )
    )
  end

  defp roster(players), do: Map.new(players, &{&1["player_id"], &1})

  describe "players" do
    test "ranks by category, best first, leaving out who has nothing" do
      roster = roster([p("ana", %{"kills" => 10}), p("bo", %{"kills" => 25}), p("cy", %{})])

      assert [%{name: "bo", value: 25}, %{name: "ana", value: 10}] =
               Leaderboards.top_players(roster, :kills, 5)

      assert Leaderboards.rank(roster, "ana", :kills) == 2
      assert Leaderboards.rank(roster, "cy", :kills) == nil
    end

    test "a K/D ratio needs a few kills before it counts" do
      roster =
        roster([
          p("lucky", %{"kills" => 2, "deaths" => 0}),
          p("steady", %{"kills" => 20, "deaths" => 5})
        ])

      assert [%{name: "steady", value: 4.0}] =
               Leaderboards.top_players(roster, :kill_death_ratio, 5)
    end

    test "teamplay and offense + defense are combined scores" do
      roster =
        roster([
          p("medic", %{"combat" => 100, "support" => 900}),
          p("rambo", %{"combat" => 700, "support" => 0})
        ])

      assert [%{name: "medic", value: 1000} | _rest] =
               Leaderboards.top_players(roster, :teamplay, 5)
    end
  end

  describe "squads" do
    test "are grouped per team and typed from their roles" do
      roster =
        roster([
          p("a1", %{"unit_name" => "able", "role" => "officer", "combat" => 300}),
          p("a2", %{"unit_name" => "able", "role" => "rifleman", "support" => 200}),
          p("t1", %{"unit_name" => "tiger", "role" => "tankcommander", "combat" => 900}),
          p("b1", %{"unit_name" => "baker", "role" => "rifleman", "combat" => 100}),
          p("x1", %{"unit_name" => "able", "team" => "axis", "combat" => 50}),
          p("cmd", %{"role" => "armycommander", "unit_name" => "command", "combat" => 999})
        ])

      squads = Leaderboards.squads(roster)

      assert [%{name: "able", team: "allies", score: 500, has_leader: true, size: 2} | _rest] =
               squads.infantry

      assert length(squads.infantry) == 3
      assert [%{name: "tiger"}] = squads.armor
      refute Enum.any?(List.flatten(Map.values(squads)), &(&1.name == "command"))

      assert Leaderboards.squad_rank(roster, "b1") == 2
      assert Leaderboards.squad_type_of(roster, "t1") == :armor
    end
  end

  describe "in rules" do
    @server %Server{id: 1, name: "EU #1", game: :hll}

    test "a rank condition reads the player's position" do
      roster = roster([p("ana", %{"kills" => 10}), p("bo", %{"kills" => 25})])
      context = Context.build(@server, :match_end, player: roster["ana"], roster: roster)

      assert Evaluator.field_value(:rank_kills, context) == 2
      assert Evaluator.field_value(:rank_support, context) == nil
    end

    test "a message can carry the live top three" do
      roster = roster([p("ana", %{"kills" => 10}), p("bo", %{"kills" => 25})])
      context = Context.build(@server, :chat_command, player: roster["ana"], roster: roster)

      assert Template.render("Kills: {top_kills} | Armor: {top_armor_squads}", context) ==
               "Kills: \n1. bo (25)\n2. ana (10) | Armor: -"
    end
  end

  describe "a match end announcement" do
    setup do
      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        Req.Test.json(conn, %{"result" => true, "failed" => false, "error" => nil})
      end)

      %{server: server_fixture()}
    end

    test "goes out once, not once per player", %{server: server} do
      rule =
        rule_fixture(%{
          server_id: server.id,
          trigger_event: :match_end,
          actions: [
            %{type: :message_all_players, parameters: %{"message" => "Top: {top_kills}"}},
            %{type: :message_player, parameters: %{"message" => "GG"}}
          ]
        })

      snapshot = %Snapshot{
        players: roster([p("one", %{"kills" => 3}), p("two", %{"kills" => 9})]),
        gamestate: gamestate(),
        stale?: false
      }

      executions = Engine.process_batch_trigger(server, [rule], :match_end, snapshot: snapshot)
      assert length(executions) == 2

      statuses =
        for execution <- Rules.list_executions(),
            %{"type" => "message_all_players", "status" => status} <- execution.results,
            do: status

      assert Enum.sort(statuses) == ["ok", "skipped"]
    end
  end
end
