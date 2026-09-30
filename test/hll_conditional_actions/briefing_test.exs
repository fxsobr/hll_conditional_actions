defmodule HllConditionalActions.BriefingTest do
  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Briefing
  alias HllConditionalActions.Briefing.LiveStatus
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Action
  alias HllConditionalActions.Rules.Condition
  alias HllConditionalActions.Rules.Rule

  defp record(rule, server, attrs) do
    {:ok, execution} =
      Rules.record_execution(
        Map.merge(
          %{
            rule_id: rule.id,
            server_id: server.id,
            player_id: "7656119000000000#{System.unique_integer([:positive])}",
            trigger_event: "player_connected",
            status: :executed,
            trace: %{"duration_ms" => 100}
          },
          attrs
        )
      )

    execution
  end

  describe "activity/4" do
    test "splits the fires by series, with a row per day" do
      server = server_fixture()
      rule = rule_fixture(%{server_id: server.id})
      record(rule, server, %{})
      record(rule, server, %{status: :failed, trace: %{"duration_ms" => 300}})
      record(rule, server, %{status: :simulated})

      all = Briefing.activity(nil, 7)
      assert %{fired: 3, live: 2, simulated: 1, failed: 1, players: 3} = all.totals
      assert all.totals.success_rate == 50.0
      assert all.totals.duration_ms == 167
      assert length(all.daily) == 8
      assert List.last(all.daily).fired == 3

      assert Briefing.activity(nil, 7, "live").totals.fired == 2
      assert Briefing.activity(nil, 7, "simulated").totals.fired == 1
    end
  end

  describe "simulation_digest/2" do
    test "counts each action the rule would have taken" do
      server = server_fixture()
      rule = rule_fixture(%{server_id: server.id, simulation: true})

      for _run <- 1..3 do
        record(rule, server, %{
          status: :simulated,
          results: [
            %{"type" => "message_player", "status" => "simulated"},
            %{"type" => "kick_player", "status" => "skipped"}
          ]
        })
      end

      record(rule, server, %{
        status: :simulated,
        results: [%{"type" => "kick_player", "status" => "simulated"}]
      })

      digest = Briefing.simulation_digest(nil, rule)

      assert digest.runs == 4
      assert digest.players == 4
      assert digest.actions == [{"message_player", 3}, {"kick_player", 1}]
    end
  end

  describe "seeding_threshold/2" do
    test "reads the player count under which a live VIP rule pays out" do
      server = server_fixture()

      rule = %Rule{
        enabled: true,
        simulation: false,
        server_id: server.id,
        conditions: [%Condition{field: :server_player_count, operator: :less_than, value: "41"}],
        actions: [%Action{type: :grant_vip, parameters: %{"duration_hours" => 24}}]
      }

      assert Briefing.seeding_threshold([rule], server.id) == 40
      assert Briefing.seeding_threshold([%{rule | simulation: true}], server.id) == nil
    end
  end

  describe "Onboarding.new_server/4" do
    alias HllConditionalActions.Onboarding

    test "is the newest server with nothing installed, or a fresh one no rule acts on" do
      now = DateTime.utc_now()
      old = DateTime.add(now, -30, :day)

      set_up = %{id: 1, inserted_at: old}
      empty = %{id: 2, inserted_at: old}
      fresh = %{id: 3, inserted_at: now}

      installed = %{1 => MapSet.new([:rules]), 3 => MapSet.new([:rules])}
      live = %Rule{enabled: true, simulation: false, server_id: 3}

      assert Onboarding.new_server([set_up, empty, fresh], installed, [], now) == fresh
      assert Onboarding.new_server([set_up, empty, fresh], installed, [live], now) == empty
      assert Onboarding.new_server([set_up], installed, [], now) == nil
    end
  end

  describe "LiveStatus" do
    test "reads the public info" do
      status =
        LiveStatus.from_public_info(%{
          "player_count" => 23,
          "max_player_count" => 100,
          "score" => %{"allied" => 2, "axis" => 3},
          "time_remaining" => 600.4,
          "current_map" => %{"map" => %{"game_mode" => "warfare", "pretty_name" => "Kursk"}}
        })

      assert %{players: 23, max_players: 100, allied_score: 2, axis_score: 3} = status
      assert %{time_remaining: 600, map: "Kursk", mode: "warfare"} = status
    end

    test "falls back on the game state" do
      status =
        LiveStatus.from_gamestate(%{
          "num_allied_players" => 40,
          "num_axis_players" => 38,
          "allied_score" => 3,
          "axis_score" => 2,
          "raw_time_remaining" => "0:47:10"
        })

      assert %{players: 78, max_players: nil, time_remaining: 2830} = status
    end

    test "sums the players of the servers that answered" do
      assert LiveStatus.players_online(%{1 => %{players: 98}, 2 => :error, 3 => %{players: 23}}) ==
               {121, 2}

      assert LiveStatus.players_online(%{1 => :error}) == nil
    end
  end
end
