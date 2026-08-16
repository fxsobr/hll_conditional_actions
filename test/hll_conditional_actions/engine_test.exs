defmodule HllConditionalActions.EngineTest do
  use HllConditionalActions.DataCase, async: false

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Engine
  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Limiter
  alias HllConditionalActions.Engine.Snapshot
  alias HllConditionalActions.Rules

  doctest HllConditionalActions.Engine.Limiter

  setup do
    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      Req.Test.json(conn, %{"result" => true, "failed" => false, "error" => nil})
    end)

    server = server_fixture()
    %{server: server}
  end

  describe "run_rule/2" do
    test "records an execution and its action results when the conditions hold", %{
      server: server
    } do
      rule =
        rule_fixture(%{
          conditions: [%{field: :kills, operator: :greater_than, value: "5"}],
          actions: [%{type: :message_player, parameters: %{"message" => "Nice, {player_name}!"}}]
        })

      assert {:ok, execution} = Engine.run_rule(rule, context(server))

      assert execution.status == :executed
      assert execution.player_id == "76561190000000001"

      assert [%{"type" => "message_player", "status" => "ok", "detail" => detail}] =
               execution.results

      assert detail == "Nice, Chris!"
    end

    test "skips silently when the conditions do not hold", %{server: server} do
      rule =
        rule_fixture(%{conditions: [%{field: :kills, operator: :greater_than, value: "500"}]})

      assert {:skip, :conditions_not_met} = Engine.run_rule(rule, context(server))
      assert Rules.list_executions() == []
    end

    test "an action that fails is recorded rather than swallowed", %{server: server} do
      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        Req.Test.json(conn, %{"failed" => true, "error" => "Player not found"})
      end)

      rule = rule_fixture(%{actions: [%{type: :kick_player, parameters: %{"reason" => "Bye"}}]})

      assert {:ok, execution} = Engine.run_rule(rule, context(server))
      assert execution.status == :failed
      assert execution.error == "kick: Player not found"
    end

    test "one failing action among several is recorded as partial", %{server: server} do
      # `switch_player_now` answers normally, `kick` fails.
      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        if conn.request_path == "/api/kick" do
          Req.Test.json(conn, %{"failed" => true, "error" => "nope"})
        else
          Req.Test.json(conn, %{"failed" => false, "result" => true})
        end
      end)

      rule =
        rule_fixture(%{
          actions: [
            %{type: :switch_player_team, parameters: %{}},
            %{type: :kick_player, parameters: %{"reason" => "Bye"}}
          ]
        })

      assert {:ok, execution} = Engine.run_rule(rule, context(server))
      assert execution.status == :partial
    end

    test "a player scoped action is skipped when the event has no player", %{server: server} do
      rule = rule_fixture(%{actions: [%{type: :kick_player, parameters: %{"reason" => "Bye"}}]})

      context = Context.build(server, :match_end, gamestate: gamestate())

      assert {:ok, execution} = Engine.run_rule(rule, context)
      assert [%{"status" => "skipped"}] = execution.results
    end
  end

  describe "rate limiting" do
    test "a cooldown blocks the second run for the same player", %{server: server} do
      rule = rule_fixture(%{cooldown_seconds: 300})

      assert {:ok, _execution} = Engine.run_rule(rule, context(server))
      assert {:skip, :cooldown} = Engine.run_rule(rule, context(server))
    end

    test "the cooldown is per player", %{server: server} do
      rule = rule_fixture(%{cooldown_seconds: 300})

      assert {:ok, _} = Engine.run_rule(rule, context(server))

      other = context(server, player: player(%{"player_id" => "76561190000000009"}))
      assert {:ok, _} = Engine.run_rule(rule, other)
    end

    test "the execution cap stops a rule after N runs", %{server: server} do
      rule = rule_fixture(%{max_executions_per_player: 2})

      assert {:ok, _} = Engine.run_rule(rule, context(server))
      assert {:ok, _} = Engine.run_rule(rule, context(server))
      assert {:skip, :max_executions} = Engine.run_rule(rule, context(server))
    end

    test "zero disables both limits", %{server: server} do
      rule = rule_fixture(%{cooldown_seconds: 0, max_executions_per_player: 0})

      assert :ok = Limiter.check(rule, "76561190000000001")
      assert {:ok, _} = Engine.run_rule(rule, context(server))
      assert :ok = Limiter.check(rule, "76561190000000001")
    end

    test "cooldown_remaining reports the seconds left", %{server: server} do
      rule = rule_fixture(%{cooldown_seconds: 300})
      assert {:ok, _} = Engine.run_rule(rule, context(server))

      remaining = Limiter.cooldown_remaining(rule, "76561190000000001")
      assert remaining > 290 and remaining <= 300
    end
  end

  describe "process_player_trigger/4" do
    test "runs only the rules that subscribe to the trigger", %{server: server} do
      connect_rule = rule_fixture(%{trigger_event: :player_connected, name: "on connect"})
      _kill_rule = rule_fixture(%{trigger_event: :player_kill, name: "on kill"})

      snapshot = snapshot()

      executions =
        Engine.process_player_trigger(server, [connect_rule], :player_connected,
          player_id: "76561190000000001",
          player_name: "Chris",
          snapshot: snapshot
        )

      assert length(executions) == 1
      assert [execution] = Rules.list_executions()
      assert execution.rule_id == connect_rule.id
    end

    test "higher priority rules run first", %{server: server} do
      low = rule_fixture(%{name: "low", priority: 0})
      high = rule_fixture(%{name: "high", priority: 10})

      Engine.process_player_trigger(server, [low, high], :player_connected,
        player_id: "76561190000000001",
        player_name: "Chris",
        snapshot: snapshot()
      )

      order = Rules.list_executions() |> Enum.map(& &1.rule_id) |> Enum.reverse()
      assert order == [high.id, low.id]
    end

    test "falls back to the event's player name when the snapshot has no entry yet", %{
      server: server
    } do
      rule =
        rule_fixture(%{
          trigger_event: :player_connected,
          conditions: [%{field: :player_name, operator: :equal, value: "Newcomer"}],
          actions: [%{type: :message_player, parameters: %{"message" => "Welcome {player_name}"}}]
        })

      executions =
        Engine.process_player_trigger(server, [rule], :player_connected,
          player_id: "76561190000000042",
          player_name: "Newcomer",
          snapshot: snapshot()
        )

      assert [execution] = executions
      assert execution.player_name == "Newcomer"
    end
  end

  describe "process_batch_trigger/4" do
    test "evaluates every player in the snapshot", %{server: server} do
      rule = rule_fixture(%{trigger_event: :match_end})

      snapshot = %Snapshot{
        players: %{
          "1" => player(%{"player_id" => "1", "name" => "One"}),
          "2" => player(%{"player_id" => "2", "name" => "Two"})
        },
        gamestate: gamestate(),
        stale?: false
      }

      executions =
        Engine.process_batch_trigger(server, [rule], :match_end, snapshot: snapshot)

      assert length(executions) == 2
      assert Rules.list_executions() |> Enum.map(& &1.player_name) |> Enum.sort() == ~w(One Two)
    end
  end

  describe "periodic_due?/3" do
    test "is due when it has never run" do
      rule = rule_fixture(%{trigger_event: :periodic, trigger_interval_seconds: 60})
      assert Engine.periodic_due?(rule, nil, 0)
    end

    test "waits for the interval to pass" do
      rule = rule_fixture(%{trigger_event: :periodic, trigger_interval_seconds: 60})

      refute Engine.periodic_due?(rule, 0, 59_000)
      assert Engine.periodic_due?(rule, 0, 60_000)
    end
  end

  defp context(server, opts \\ []) do
    Context.build(server, :player_connected,
      player: Keyword.get(opts, :player, player()),
      gamestate: gamestate()
    )
  end

  defp snapshot do
    %Snapshot{
      players: %{"76561190000000001" => player()},
      gamestate: gamestate(),
      stale?: false
    }
  end
end
