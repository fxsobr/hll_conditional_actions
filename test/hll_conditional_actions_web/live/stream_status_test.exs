defmodule HllConditionalActionsWeb.StreamStatusTest do
  @moduledoc """
  Whether a server is live is the one thing on these pages that changes without
  anybody clicking. If the badge only tells the truth on a page load, adding a
  server leaves it saying "Connecting" until somebody presses F5 — which is
  what it did.
  """

  use HllConditionalActionsWeb.ConnCase, async: false

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Crcon.LogStream

  setup %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn}
  end

  # What the log stream announces when a connection comes up.
  defp announce(server_id, status) do
    Phoenix.PubSub.broadcast(
      HllConditionalActions.PubSub,
      LogStream.status_topic(),
      {:crcon_stream_status, server_id, status}
    )
  end

  describe "the servers page" do
    test "follows a server going live without a reload", %{conn: conn} do
      server = server_fixture(%{name: "Caveiras Brasil #1"})

      {:ok, view, html} = live(conn, ~p"/servers")
      assert html =~ "Caveiras Brasil #1"

      announce(server.id, :connected)

      assert render(view) =~ "Live"
    end

    test "follows a server added after the page was opened", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/servers")

      # Created elsewhere — another admin, another tab — which is what the
      # page hears about over PubSub.
      server = server_fixture(%{name: "Added later"})
      HllConditionalActions.Servers.subscribe()
      send(view.pid, {:server_created, server})

      assert render(view) =~ "Added later"

      announce(server.id, :connected)

      assert render(view) =~ "Live"
    end

    test "shows a server dropping out too", %{conn: conn} do
      server = server_fixture()

      {:ok, view, _html} = live(conn, ~p"/servers")

      announce(server.id, :connected)
      assert render(view) =~ "Live"

      announce(server.id, :disconnected)
      assert render(view) =~ "Offline"
    end
  end

  describe "the dashboard" do
    test "follows a server going live without a reload", %{conn: conn} do
      server = server_fixture(%{name: "Caveiras Brasil #1"})

      {:ok, view, _html} = live(conn, ~p"/")

      announce(server.id, :connected)

      assert render(view) =~ "Live"
    end

    test "follows a server added after the page was opened", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      server = server_fixture(%{name: "Added later"})
      send(view.pid, {:server_created, server})

      assert render(view) =~ "Added later"

      announce(server.id, :connected)

      assert render(view) =~ "Live"
    end
  end
end
