defmodule HllConditionalActionsWeb.ServerScopeNavTest do
  @moduledoc """
  The sidebar follows the URL: under /servers/:id it is that server's, with
  the switcher on it; elsewhere it is the organisation's.
  """

  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  doctest HllConditionalActionsWeb.Nav
  doctest HllConditionalActionsWeb.MapArt

  setup %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, one: server_fixture(%{name: "EU #1"}), two: server_fixture(%{name: "US #2"})}
  end

  test "a server's pages list that server's sections", %{conn: conn, one: one, two: two} do
    {:ok, view, _html} = live(conn, ~p"/servers/#{one}/rules")

    assert has_element?(view, "#sidebar-scope-button", "EU #1")
    assert has_element?(view, ~s{#sidebar-nav a[href="/servers/#{one.id}/leaderboard"]})
    assert has_element?(view, ~s{#sidebar-nav a[href="/servers/#{one.id}/history"]})
    assert has_element?(view, ~s{#sidebar-nav a[href="/servers/#{one.id}/achievements"]})

    # Switching keeps the page.
    assert has_element?(view, ~s{#sidebar-scope-menu a[href="/servers/#{two.id}/rules"]})
  end

  test "outside a server the sidebar is the organisation's", %{conn: conn, one: one} do
    {:ok, view, _html} = live(conn, ~p"/rules")

    assert has_element?(view, "#sidebar-scope-button", "All servers")
    assert has_element?(view, ~s{#sidebar-nav a[href="/seasons"]})
    refute has_element?(view, ~s{#sidebar-nav a[href="/servers/#{one.id}/leaderboard"]})
  end

  test "a server's rules are its own and the fleet wide ones of its game", %{
    conn: conn,
    one: one,
    two: two
  } do
    rule_fixture(%{name: "Only EU", server_id: one.id})
    rule_fixture(%{name: "Only US", server_id: two.id})
    rule_fixture(%{name: "Everywhere", server_id: nil})

    {:ok, view, html} = live(conn, ~p"/servers/#{one}/rules")

    assert html =~ "Only EU"
    assert html =~ "Everywhere"
    refute html =~ "Only US"
    refute has_element?(view, "#rule-filters select[name=server_id]")
  end
end
