defmodule HllConditionalActions.Engine.RunnerProgressionTest do
  use HllConditionalActions.DataCase, async: false

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Crcon.Events
  alias HllConditionalActions.Engine.Runner
  alias HllConditionalActions.Progression.PlayerTotal
  alias HllConditionalActions.Repo

  @moduletag :capture_log

  setup do
    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      result =
        case conn.request_path do
          "/api/get_detailed_players" ->
            %{"players" => %{"76561190000000001" => player()}, "fail_count" => 0}

          "/api/get_gamestate" ->
            gamestate()

          _action ->
            true
        end

      Req.Test.json(conn, %{"result" => result, "failed" => false, "error" => nil})
    end)

    server = server_fixture()
    pid = start_supervised!({Runner, server: server})
    Ecto.Adapters.SQL.Sandbox.allow(HllConditionalActions.Repo, self(), pid)

    %{server: server, runner: pid}
  end

  defp event(server, action, attrs \\ %{}) do
    Events.from_log(
      log_line(
        Map.merge(
          %{
            "action" => action,
            "player_name_1" => nil,
            "player_id_1" => nil,
            "player_name_2" => nil,
            "player_id_2" => nil,
            "weapon" => nil
          },
          attrs
        )
      ),
      server
    )
  end

  test "a match end counts the match, once even if CRCON repeats it", %{
    server: server,
    runner: pid
  } do
    send(pid, {:crcon_event, event(server, "MATCH ENDED")})
    send(pid, {:crcon_event, event(server, "MATCH ENDED")})
    _ = :sys.get_state(pid)

    assert %PlayerTotal{matches: 1} = Repo.get_by(PlayerTotal, player_id: "76561190000000001")
  end

  # A connect nobody listens for once replaced the runner's state with the
  # return value of the sampling call, and the next event crashed it.
  test "a connect with no rule listening keeps the runner alive", %{server: server, runner: pid} do
    connect =
      event(server, "CONNECTED", %{
        "player_name_1" => "Chris",
        "player_id_1" => "76561190000000001"
      })

    send(pid, {:crcon_event, connect})
    send(pid, {:crcon_event, connect})

    assert %Runner.State{} = :sys.get_state(pid)
  end
end
