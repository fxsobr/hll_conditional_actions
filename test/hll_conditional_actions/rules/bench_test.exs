defmodule HllConditionalActions.Rules.BenchTest do
  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Evaluator
  alias HllConditionalActions.Engine.Samples
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Bench
  alias HllConditionalActions.Rules.Condition
  alias HllConditionalActions.Rules.ConditionGroups
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Rules.Snapshot
  alias HllConditionalActions.Rules.Transfer

  doctest HllConditionalActions.Rules.ConditionGroups

  defp event(server, player_id, at, player \\ %{}) do
    sample = %{
      server_id: server.id,
      trigger: :player_team_kill,
      player_id: player_id,
      player_name: "P#{player_id}",
      player: Map.merge(%{"player_id" => player_id, "name" => "P#{player_id}"}, player),
      player_profile: nil,
      gamestate: nil,
      squad: %{},
      ranks: %{},
      event: nil,
      at: at,
      at_us: DateTime.to_unix(at, :microsecond)
    }

    %{sample: sample, server: server, key: {server.id, sample.at_us, player_id}}
  end

  defp ladder(attrs \\ %{}) do
    struct(
      %Rule{
        trigger_event: :player_team_kill,
        logical_operator: :and,
        escalation_window_seconds: 3600,
        cooldown_seconds: 0,
        max_executions_per_player: 0,
        conditions: [%Condition{field: :always_true, operator: :equal, value: ""}],
        actions: [
          %Rules.Action{type: :message_player, parameters: %{"message" => "Careful"}},
          %Rules.Action{type: :punish_player, parameters: %{"reason" => "TK"}},
          %Rules.Action{
            type: :temp_ban_player,
            parameters: %{"reason" => "TK", "duration_hours" => 2}
          }
        ]
      },
      attrs
    )
  end

  describe "replay/2" do
    test "climbs the ladder with its own history and repeats the last rung" do
      server = server_fixture()
      now = DateTime.utc_now()

      events =
        for minutes <- [40, 30, 20, 10],
            do: event(server, "a", DateTime.add(now, -minutes, :minute))

      replay = Bench.replay(ladder(), events)

      assert replay.fires == 4
      assert replay.players == 1
      assert Enum.map(replay.judged, & &1.step) == [0, 1, 2, 2]
      assert Enum.map(replay.steps, & &1.count) == [1, 1, 2]
    end

    test "applies the cooldown, the cap and the exemptions" do
      server = server_fixture()
      now = DateTime.utc_now()

      events = [
        event(server, "a", DateTime.add(now, -300, :second)),
        event(server, "a", DateTime.add(now, -290, :second)),
        event(server, "vip", DateTime.add(now, -200, :second), %{"is_vip" => true}),
        event(server, "a", DateTime.add(now, -100, :second))
      ]

      rule =
        ladder(%{
          escalation_window_seconds: 0,
          cooldown_seconds: 60,
          max_executions_per_player: 1,
          exemptions: %Rules.Exemptions{exempt_vip: true}
        })

      assert Enum.map(Bench.replay(rule, events).judged, & &1.outcome) ==
               [:fires, :cooldown, :exempt, :max_executions]
    end

    test "compare names the players whose fate changed" do
      server = server_fixture()
      now = DateTime.utc_now()

      events = [
        event(server, "vip", DateTime.add(now, -60, :second), %{"is_vip" => true}),
        event(server, "b", DateTime.add(now, -30, :second))
      ]

      saved = ladder(%{exemptions: %Rules.Exemptions{exempt_vip: true}})

      draft =
        ladder(%{
          actions: [
            %Rules.Action{type: :message_player, parameters: %{"message" => "Different"}}
          ]
        })

      comparison = Bench.compare(Bench.replay(draft, events), Bench.replay(saved, events))

      assert comparison.delta == 1

      assert [
               %{player_id: "vip", kind: :now_fires, from: :exempt, vip?: true},
               %{player_id: "b", kind: :action}
             ] = comparison.changes
    end
  end

  describe "the replay window" do
    test "says when it read only the newest replay_limit/0 events" do
      server = server_fixture()
      now = DateTime.utc_now()
      limit = Bench.replay_limit()

      events =
        for n <- 1..limit,
            do: event(server, "p#{rem(n, 50)}", DateTime.add(now, -(limit - n), :second))

      {micros, replay} = :timer.tc(fn -> Bench.replay(ladder(), events) end)

      assert replay.events == limit
      assert replay.capped?
      assert replay.short?
      # Replayed on every edit in the builder: a full window stays well under
      # a second.
      assert micros < 1_000_000

      refute Bench.replay(ladder(), Enum.take(events, -10)).capped?
    end
  end

  describe "events/3 and recent_runs/3" do
    test "reads the recorded events of a trigger, oldest first" do
      server = server_fixture()

      for name <- ["first", "second"] do
        server
        |> Context.build(:player_team_kill, player_id: name, player: player(%{"name" => name}))
        |> Samples.record()
      end

      assert [%{sample: %{player_id: "first"}}, %{sample: %{player_id: "second"}}] =
               Bench.events([server], :player_team_kill)

      assert Bench.events([server], :player_connected) == []
    end

    test "says what the saved rule did with each event" do
      server = server_fixture()

      rule =
        rule_fixture(%{
          trigger_event: :player_team_kill,
          simulation: true,
          conditions: [%{field: :player_level, operator: :greater_than, value: "10"}]
        })

      for {id, level} <- [{"low", 5}, {"high", 50}] do
        server
        |> Context.build(:player_team_kill,
          player_id: id,
          player: player(%{"player_id" => id, "level" => level})
        )
        |> Samples.record()
      end

      {:ok, _execution} =
        Rules.record_execution(%{
          rule_id: rule.id,
          server_id: server.id,
          player_id: "high",
          trigger_event: "player_team_kill",
          status: :simulated
        })

      assert [%{outcome: :miss}, %{outcome: :simulated, execution: %{player_id: "high"}}] =
               Bench.recent_runs(rule, [server])
    end
  end

  describe "live_in_days/2" do
    test "counts down from the first simulated run" do
      server = server_fixture()
      rule = rule_fixture(%{simulation: true})

      assert Bench.live_in_days(%Rule{}) == Bench.unlock_days()
      assert Bench.live_in_days(rule) == Bench.unlock_days()

      {:ok, _execution} =
        Rules.record_execution(%{
          rule_id: rule.id,
          server_id: server.id,
          trigger_event: "player_connected",
          status: :simulated,
          executed_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      assert Bench.live_in_days(rule) == Bench.unlock_days() - 1
      assert Bench.live_in_days(%{rule | simulation: false}) == 0
    end
  end

  describe "condition groups" do
    test "the evaluator combines groups with the rule's operator" do
      server = server_fixture()

      context =
        Context.build(server, :player_connected, player: player(%{"level" => 5, "kills" => 30}))

      rule = %Rule{
        logical_operator: :or,
        conditions: [
          %Condition{
            field: :player_level,
            operator: :greater_than,
            value: "10",
            group: 0,
            group_operator: :and
          },
          %Condition{
            field: :kills,
            operator: :greater_than,
            value: "20",
            group: 1,
            group_operator: :and
          }
        ]
      }

      assert Evaluator.evaluate(rule, context)
      refute Evaluator.evaluate(%{rule | logical_operator: :and}, context)

      assert %{result: true, conditions: [%{result: false}, %{result: true}]} =
               Evaluator.explain(rule, context)
    end

    test "groups survive a save, a snapshot and an export" do
      rule =
        rule_fixture(%{
          logical_operator: :or,
          conditions: [
            %{
              field: :player_level,
              operator: :greater_than,
              value: "10",
              group: 0,
              group_operator: :and
            },
            %{field: :kills, operator: :greater_than, value: "20", group: 1, group_operator: :nor}
          ]
        })

      assert [%{group: 0, group_operator: :and}, %{group: 1, group_operator: :nor}] =
               rule.conditions

      assert ConditionGroups.grouped?(rule.conditions)

      restored = Snapshot.to_rule(%Rule{}, Snapshot.take(rule))

      assert Enum.map(restored.conditions, &{&1.group, &1.group_operator}) == [
               {0, :and},
               {1, :nor}
             ]

      {:ok, [attrs]} = rule |> List.wrap() |> Transfer.encode() |> Transfer.decode()
      assert [%{"group" => 0}, %{"group" => 1, "group_operator" => "nor"}] = attrs["conditions"]
    end

    test "a flat rule's snapshot carries no group keys" do
      rule = rule_fixture()
      assert [condition] = Snapshot.take(rule)["conditions"]
      refute Map.has_key?(condition, "group")
    end
  end
end
