defmodule HllConditionalActions.Engine.VehicleWatchTest do
  @moduledoc """
  HLL writes no log line when a vehicle is destroyed; the runner notices a
  player's `vehicles_destroyed` counter rising between two snapshots instead.
  """

  use HllConditionalActions.DataCase, async: false

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Engine.Runner
  alias HllConditionalActions.Rules

  @moduletag :capture_log

  setup do
    # The counter CRCON reports, and the objectives the player's team holds.
    {:ok, state} = Agent.start_link(fn -> %{destroyed: 0, allied_score: 2} end)

    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      %{destroyed: destroyed, allied_score: allied_score} = Agent.get(state, & &1)

      result =
        case conn.request_path do
          "/api/get_detailed_players" ->
            %{
              "players" => %{
                "76561190000000001" => player(%{"vehicles_destroyed" => destroyed})
              },
              "fail_count" => 0
            }

          "/api/get_gamestate" ->
            gamestate(%{"allied_score" => allied_score, "axis_score" => 5 - allied_score})

          _action ->
            true
        end

      Req.Test.json(conn, %{"result" => result, "failed" => false, "error" => nil})
    end)

    server = server_fixture()

    rule_fixture(%{
      server_id: server.id,
      trigger_event: :vehicle_destroyed,
      conditions: [%{field: :attacking_last_sector, operator: :equal, value: "false"}],
      actions: [
        %{type: :message_player, parameters: %{"message" => "HQ vehicles are off limits"}}
      ]
    })

    pid = start_supervised!({Runner, server: server})
    Ecto.Adapters.SQL.Sandbox.allow(HllConditionalActions.Repo, self(), pid)

    %{runner: pid, state: state}
  end

  defp tick(pid) do
    send(pid, :tick)
    _ = :sys.get_state(pid)
  end

  test "a rising counter fires the rule for that player", %{runner: pid, state: state} do
    tick(pid)
    assert Rules.list_executions() == []

    Agent.update(state, &%{&1 | destroyed: 1})
    tick(pid)

    assert [%{player_id: "76561190000000001", trigger_event: "vehicle_destroyed"}] =
             Rules.list_executions()
  end

  test "nothing fires while the team attacks the enemy's last sector", %{
    runner: pid,
    state: state
  } do
    Agent.update(state, &%{&1 | allied_score: 4})
    tick(pid)

    Agent.update(state, &%{&1 | destroyed: 1})
    tick(pid)

    assert Rules.list_executions() == []
  end
end
