defmodule HllConditionalActionsWeb.LeaderboardLiveTest do
  # The snapshot is fetched from a task the LiveView starts, so the CRCON
  # stub has to be visible outside the test process.
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
                "1" =>
                  player(%{
                    "player_id" => "1",
                    "name" => "Sharpshooter",
                    "kills" => 42,
                    "unit_name" => "able",
                    "role" => "officer"
                  })
              },
              "fail_count" => 0
            }

          "/api/get_gamestate" ->
            gamestate()

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

    %{conn: conn}
  end

  test "ranks the players and squads of the server", %{conn: conn} do
    server = server_fixture(%{name: "EU #1"})

    {:ok, view, _html} = live(conn, ~p"/servers/#{server}/leaderboard")
    html = render_async(view)

    assert has_element?(view, "#leaderboard-kpis")
    assert has_element?(view, "#board-kills", "Sharpshooter")
    assert has_element?(view, "#board-squads-infantry", "Able")
    assert html =~ "{top_kills}"
  end

  test "a CRCON that does not answer is not an empty server", %{conn: conn} do
    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      conn |> Plug.Conn.put_status(502) |> Req.Test.text("Bad Gateway")
    end)

    server = server_fixture()

    {:ok, view, _html} = live(conn, ~p"/servers/#{server}/leaderboard")
    html = render_async(view)

    assert html =~ "CRCON did not answer"
    refute html =~ "Nobody is playing right now"
  end

  test "the old address opens the first server's leaderboard", %{conn: conn} do
    server = server_fixture()
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/leaderboard")
    assert to == "/servers/#{server.id}/leaderboard"
  end

  test "says so when there is no server", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/leaderboard")
    assert html =~ "No server to rank"
  end
end
