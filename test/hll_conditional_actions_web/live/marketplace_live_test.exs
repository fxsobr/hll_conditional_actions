defmodule HllConditionalActionsWeb.MarketplaceLiveTest do
  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Features

  doctest HllConditionalActionsWeb.FeatureGuard

  setup %{conn: conn} do
    %{conn: conn |> init_test_session(%{}) |> Plug.Conn.put_session(:user_id, user_fixture().id)}
  end

  test "installing a module opens its pages and lists it in the sidebar", %{conn: conn} do
    server = server_fixture(%{features: []})

    {:ok, view, html} = live(conn, ~p"/servers/#{server.id}/marketplace")
    refute html =~ ~s|href="/servers/#{server.id}/tickets"|

    view |> element("#install-tickets") |> render_click()

    assert Features.installed?(server.id, :tickets)
    assert has_element?(view, "#uninstall-tickets")
    assert has_element?(view, ~s|a[href="/servers/#{server.id}/tickets"]|)
    assert {:ok, _view, _html} = live(conn, ~p"/servers/#{server.id}/tickets")
  end

  test "a page of a module that is not installed sends you to the marketplace", %{conn: conn} do
    server = server_fixture(%{features: [:rules]})
    marketplace = "/servers/#{server.id}/marketplace"

    assert {:error, {:redirect, %{to: ^marketplace}}} =
             live(conn, ~p"/servers/#{server.id}/leaderboard")

    assert {:ok, _view, _html} = live(conn, ~p"/servers/#{server.id}/rules")
  end

  test "removing a module keeps the server and closes its pages", %{conn: conn} do
    server = server_fixture(%{features: [:live_feed]})

    {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/marketplace")
    view |> element("#uninstall-live_feed") |> render_click()

    refute Features.installed?(server.id, :live_feed)
    assert {:error, {:redirect, _to}} = live(conn, ~p"/servers/#{server.id}/feed")
  end

  test "organisation pages need the module on at least one server", %{conn: conn} do
    _without = server_fixture(%{features: []})

    assert {:error, {:redirect, %{to: "/servers"}}} = live(conn, ~p"/seasons")

    _with = server_fixture(%{features: [:progression]})
    assert {:ok, _view, _html} = live(conn, ~p"/seasons")
  end
end
