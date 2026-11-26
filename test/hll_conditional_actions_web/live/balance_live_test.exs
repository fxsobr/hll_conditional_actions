defmodule HllConditionalActionsWeb.BalanceLiveTest do
  use HllConditionalActionsWeb.ConnCase, async: false

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest
  import Req.Test, only: [set_req_test_to_shared: 1]

  alias HllConditionalActions.Balance
  alias HllConditionalActions.Balance.PlayerRating
  alias HllConditionalActions.Repo

  # "Right now" reads CRCON in a background task.
  setup :set_req_test_to_shared

  setup %{conn: conn} do
    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      Req.Test.json(conn, %{
        "result" => %{
          "players" => %{
            "a1" => %{"player_id" => "a1", "team" => "allies", "unit_name" => "able"},
            "x1" => %{"player_id" => "x1", "team" => "axis", "unit_name" => "able"}
          }
        },
        "failed" => false,
        "error" => nil
      })
    end)

    user = user_fixture()
    conn = conn |> init_test_session(%{}) |> Plug.Conn.put_session(:user_id, user.id)
    %{conn: conn, user: user}
  end

  test "shows the teams now, every match's plan, and saves the settings", %{conn: conn} do
    server = server_fixture(%{name: "EU #1"})
    Repo.insert!(%PlayerRating{game: "hll", player_id: "a1", rating: 1300, matches: 20})

    players = %{
      "a1" => %{"player_id" => "a1", "name" => "Ana", "team" => "allies", "unit_name" => "able"},
      "x1" => %{"player_id" => "x1", "name" => "Xu", "team" => "axis", "unit_name" => "able"}
    }

    plan = Balance.close_match(server, players, %{"allied_score" => 5, "axis_score" => 0})

    {:ok, view, _html} = live(conn, ~p"/balance")

    assert has_element?(view, "#balance-summary")
    assert has_element?(view, "#plan-#{plan.id}")
    assert render_async(view) =~ "1300"

    view
    |> form("#balance-settings-form", settings: %{trigger_gap: "25", max_moves: "8"})
    |> render_submit()

    assert Balance.get_settings(server.id).trigger_gap == 25
  end

  test "without a server running it, the page sends to the marketplace", %{conn: conn} do
    server_fixture(%{features: [:rules]})
    assert {:error, {:redirect, %{flash: %{"error" => error}}}} = live(conn, ~p"/balance")
    assert error =~ "Team balance"
  end

  test "the simulator compares the rules over the history", %{conn: conn} do
    server_fixture(%{name: "EU #1"})

    {:ok, view, _html} = live(conn, ~p"/balance?tab=simulator")
    render_async(view)

    assert has_element?(view, "#simulator-form")

    view
    |> form("#simulator-form", sim: %{trigger_gap: "50", source: "live"})
    |> render_change()

    render_async(view)
    assert has_element?(view, "#balance-simulator")
  end

  test "the report shows what stomps and maps cost", %{conn: conn} do
    server_fixture(%{name: "EU #1"})

    {:ok, view, _html} = live(conn, ~p"/balance?tab=report")
    render_async(view)

    assert has_element?(view, "#report-kinds")
    assert has_element?(view, "#report-rare")
    assert has_element?(view, "#report-maps")

    view |> form("#report-form", days: "45") |> render_change()
    render_async(view)
    assert has_element?(view, "#report-maps")
  end

  test "the settings choose the rule and the rest of a moved player", %{conn: conn} do
    server = server_fixture(%{name: "EU #1"})
    {:ok, view, _html} = live(conn, ~p"/balance")

    view
    |> form("#balance-settings-form", settings: %{rule: "either", cooldown_hours: "6"})
    |> render_submit()

    assert %{rule: "either", cooldown_hours: 6} = Balance.get_settings(server.id)
  end

  test "the marketplace offers the module", %{conn: conn} do
    server = server_fixture(%{features: []})
    {:ok, _view, html} = live(conn, ~p"/servers/#{server.id}/marketplace")
    assert html =~ "Team balance"
  end
end
