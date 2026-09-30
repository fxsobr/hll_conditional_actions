defmodule HllConditionalActionsWeb.ServerScopeNavTest do
  @moduledoc """
  Navigation follows the URL: under /servers/:id it is that server's, with
  the switcher in the header showing it; elsewhere it is the organisation's.
  The rail groups the pages into areas, whose pages are the header's tabs.
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

  test "a server's pages open that server's areas", %{conn: conn, one: one, two: two} do
    {:ok, view, _html} = live(conn, ~p"/servers/#{one}/rules")

    assert has_element?(view, "#header-scope-button", "EU #1")

    # The rail's areas open this server's pages; Rules is the active one, and
    # its pages are the tabs beside the title.
    assert has_element?(view, ~s{#rail-live[href="/servers/#{one.id}"]})
    assert has_element?(view, ~s{#rail-rules[aria-current="page"]})
    assert has_element?(view, ~s{#section-tabs a[href="/servers/#{one.id}/history"]})
    assert has_element?(view, ~s{#rail-modules[href="/servers/#{one.id}/marketplace"]})

    # The phone's tab bar follows the same areas.
    assert has_element?(view, ~s{#tab-bar-rules[aria-current="page"]})

    # Switching keeps the page.
    assert has_element?(view, ~s{#header-scope-menu a[href="/servers/#{two.id}/rules"]})
  end

  test "outside a server the areas are the organisation's", %{conn: conn, one: one} do
    {:ok, view, _html} = live(conn, ~p"/rules")

    assert has_element?(view, "#header-scope-button", "All servers")
    assert has_element?(view, ~s{#section-tabs a[href="/executions"]})
    assert has_element?(view, ~s{#section-tabs a[href="/rules/simulate"]})

    # "Ao vivo" is always there: the first server's cockpit.
    assert has_element?(view, ~s{#rail-live[href="/servers/#{one.id}"]})
    refute has_element?(view, ~s{#section-tabs a[href="/servers/#{one.id}/history"]})
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
