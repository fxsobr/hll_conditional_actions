defmodule HllConditionalActions.Engine.SimulationTest do
  @moduledoc """
  A rule in simulation must be indistinguishable from a real one in the history
  and completely invisible to the game server.
  """

  use HllConditionalActions.DataCase, async: false

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Engine
  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Rules

  setup do
    test_pid = self()

    # Any CRCON call at all is a failure for these tests, so the stub reports
    # rather than answers.
    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      send(test_pid, {:crcon_called, conn.request_path})
      Req.Test.json(conn, %{"result" => true, "failed" => false, "error" => nil})
    end)

    %{server: server_fixture()}
  end

  defp context(server) do
    Context.build(server, :player_connected, player: player(), gamestate: gamestate())
  end

  test "records the execution without calling CRCON", %{server: server} do
    rule =
      rule_fixture(%{
        simulation: true,
        actions: [%{type: :kick_player, parameters: %{"reason" => "Bye {player_name}"}}]
      })

    assert {:ok, execution} = Engine.run_rule(rule, context(server))

    refute_received {:crcon_called, _path}
    assert execution.status == :simulated

    assert [%{"type" => "kick_player", "status" => "simulated", "detail" => "Bye Chris"}] =
             execution.results
  end

  test "renders templates exactly as a real run would", %{server: server} do
    rule =
      rule_fixture(%{
        simulation: true,
        actions: [
          %{
            type: :message_player,
            parameters: %{"message" => "{player_name} is level {player_level} on {map_name}"}
          }
        ]
      })

    assert {:ok, execution} = Engine.run_rule(rule, context(server))
    assert [%{"detail" => "Chris is level 42 on Carentan"}] = execution.results
  end

  test "still respects the conditions", %{server: server} do
    rule =
      rule_fixture(%{
        simulation: true,
        conditions: [%{field: :kills, operator: :greater_than, value: "500"}]
      })

    assert {:skip, :conditions_not_met} = Engine.run_rule(rule, context(server))
    assert Rules.list_executions() == []
  end

  test "still consumes the cooldown, so the trial matches the real thing", %{server: server} do
    rule = rule_fixture(%{simulation: true, cooldown_seconds: 300})

    assert {:ok, _execution} = Engine.run_rule(rule, context(server))
    assert {:skip, :cooldown} = Engine.run_rule(rule, context(server))
  end

  test "turning simulation off makes the same rule act", %{server: server} do
    rule = rule_fixture(%{simulation: true})
    {:ok, rule} = Rules.update_rule(rule, %{simulation: false})

    assert {:ok, execution} = Engine.run_rule(rule, context(server))

    assert_received {:crcon_called, _path}
    assert execution.status == :executed
  end
end
