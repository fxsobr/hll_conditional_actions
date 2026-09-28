defmodule HllConditionalActionsWeb.ServerCockpitTest do
  # The live snapshot and the match history are fetched from tasks, so the
  # CRCON stub must be visible outside the test process.
  use HllConditionalActionsWeb.ConnCase, async: false

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  setup %{conn: conn} = context do
    Req.Test.set_req_test_to_shared(context)

    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      result =
        case conn.request_path do
          "/api/get_detailed_players" ->
            %{
              "players" => %{
                "1" => player(%{"player_id" => "1", "name" => "Sharpshooter", "kills" => 42})
              },
              "fail_count" => 0
            }

          "/api/get_gamestate" ->
            gamestate(%{"allied_score" => 3, "axis_score" => 2})

          "/api/get_scoreboard_maps" ->
            %{
              "total" => 1,
              "maps" => [
                %{
                  "id" => 5,
                  "start" => "2026-09-20T20:00:00Z",
                  "end" => "2026-09-20T21:00:00Z",
                  "result" => %{"allied" => 5, "axis" => 0},
                  "map" => %{"map" => %{"pretty_name" => "Foy"}}
                }
              ]
            }

          _other ->
            true
        end

      Req.Test.json(conn, %{"result" => result, "failed" => false, "error" => nil})
    end)

    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, server: server_fixture(%{name: "EU #1"})}
  end

  test "opens on the live match, then who plays well, then what happened", %{
    conn: conn,
    server: server
  } do
    rule_fixture(%{name: "Welcome", server_id: server.id})

    {:ok, view, _html} = live(conn, ~p"/servers/#{server}")
    render_async(view)

    assert has_element?(view, "#cockpit-live", "Carentan")
    assert has_element?(view, "#cockpit-live", "3")
    assert has_element?(view, "#cockpit-board-kills", "Sharpshooter")
    assert has_element?(view, "#cockpit-matches", "Foy")
    assert has_element?(view, ~s{a[href="/servers/#{server.id}/leaderboard"]})
    assert render(view) =~ "Welcome"
  end
end
