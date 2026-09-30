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

    assert has_element?(view, "#leaderboard-live", "Carentan")
    assert has_element?(view, "#board-kills", "Sharpshooter")
    assert has_element?(view, "#board-kill_death_ratio", "min. 5 kills")
    assert has_element?(view, "#board-squads-infantry", "Able")
    # The squad's head count against its size, and who leads it.
    assert has_element?(view, "#board-squads-infantry", "1/6")
    assert has_element?(view, "#board-squads-infantry", "leader Sharpshooter")
    assert html =~ "refreshes every 10 s"
    refute has_element?(view, "#board-offdef")
  end

  test "shows the squads alone on the squads view", %{conn: conn} do
    server = server_fixture(%{name: "EU #1"})

    {:ok, view, _html} = live(conn, ~p"/servers/#{server}/leaderboard?view=squads")
    render_async(view)

    assert has_element?(view, "#board-squads-infantry", "Able")
    refute has_element?(view, "#board-kills")
  end

  test "posts the scoreboard to the game's chat", %{conn: conn} do
    test = self()

    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      result =
        case conn.request_path do
          "/api/get_detailed_players" ->
            %{"players" => %{"1" => player(%{"player_id" => "1", "name" => "Sharpshooter"})}}

          "/api/get_gamestate" ->
            gamestate()

          "/api/message_all_players" ->
            {:ok, body, _conn} = Plug.Conn.read_body(conn)
            send(test, {:message_all_players, Jason.decode!(body)})
            true

          _other ->
            true
        end

      Req.Test.json(conn, %{"result" => result, "failed" => false, "error" => nil})
    end)

    server = server_fixture()

    {:ok, view, _html} = live(conn, ~p"/servers/#{server}/leaderboard")
    render_async(view)

    view |> element("#leaderboard-post") |> render_click()
    render_async(view)

    assert_received {:message_all_players, %{"message" => message}}
    assert message =~ "Sharpshooter"
  end

  test "narrows the rankings to one team", %{conn: conn} do
    server = server_fixture(%{name: "EU #1"})

    {:ok, view, _html} = live(conn, ~p"/servers/#{server}/leaderboard")
    render_async(view)
    assert has_element?(view, "#board-kills", "Sharpshooter")

    # The only player is on the Allies: the Axis' boards are empty.
    view |> element(~s{#leaderboard-teams a[href$="team=axis"]}) |> render_click()
    assert_patch(view, ~p"/servers/#{server}/leaderboard?team=axis")
    refute has_element?(view, "#board-kills", "Sharpshooter")

    view |> element(~s{#leaderboard-teams a[href$="team=allies"]}) |> render_click()
    assert has_element?(view, "#board-kills", "Sharpshooter")
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
