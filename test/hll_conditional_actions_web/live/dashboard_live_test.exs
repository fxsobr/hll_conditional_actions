defmodule HllConditionalActionsWeb.DashboardLiveTest do
  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Rules

  setup %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, user: user}
  end

  test "a fresh install is walked through the first steps", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#onboarding")
    assert has_element?(view, "#onboarding-step-server[data-state=current]")
    refute has_element?(view, "#overview-kpis")
  end

  test "shows the period's numbers once rules have fired", %{conn: conn} do
    server = server_fixture()
    rule = rule_fixture(%{name: "Greeter", server_id: server.id})

    {:ok, _execution} =
      Rules.record_execution(%{
        rule_id: rule.id,
        server_id: server.id,
        player_id: "76561190000000001",
        trigger_event: "player_connected",
        status: :executed,
        trace: %{"duration_ms" => 120}
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#overview-kpis")
    assert has_element?(view, "#overview-chart")
    assert has_element?(view, "#overview-rules", "Greeter")

    view |> element("#overview-period a", "7") |> render_click()
    assert_patch(view, ~p"/?period=7")
  end
end
