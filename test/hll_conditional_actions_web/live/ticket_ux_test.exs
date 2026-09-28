defmodule HllConditionalActionsWeb.TicketUxTest do
  @moduledoc """
  The help-desk style round: the setup wizard, the settings tabs, the inbox
  views and claiming, and the collision guard on the ticket page.
  """

  use HllConditionalActionsWeb.ConnCase, async: false

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest
  import Req.Test, only: [set_req_test_to_shared: 1]

  alias HllConditionalActions.Crcon.Events.Event
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Tickets

  doctest HllConditionalActionsWeb.TicketLive.Index
  doctest HllConditionalActionsWeb.TicketSettingsForm

  setup :set_req_test_to_shared

  setup %{conn: conn} do
    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      Req.Test.json(conn, %{"result" => true, "failed" => false, "error" => nil})
    end)

    user = user_fixture(%{name: "Ana"})
    server = server_fixture(%{name: "EU #1"})

    conn = conn |> init_test_session(%{}) |> Plug.Conn.put_session(:user_id, user.id)
    %{conn: conn, user: user, server: server}
  end

  defp open_ticket(server, player_id \\ "76561198000000001") do
    {:ok, settings} =
      Tickets.save_settings(Tickets.get_settings(server.id), %{
        enabled: true,
        commands: ["!admin"]
      })

    event = %Event{
      type: :player_chat,
      action: "CHAT[Allies]",
      occurred_at: DateTime.utc_now(),
      player_id: player_id,
      player_name: "Sarge",
      chat_message: "!admin help me"
    }

    {:opened, ticket} = Tickets.handle_chat(server, settings, event)
    ticket
  end

  describe "setup wizard" do
    test "the inbox offers the wizard while nothing is set up", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tickets")
      assert has_element?(view, "#tickets-setup a[href='/tickets/setup']")
    end

    test "walks through the steps and switches tickets on", %{conn: conn, server: server} do
      {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/tickets/setup")
      assert has_element?(view, "#wizard-title", "Commands")

      view
      |> form("#wizard-form", settings: %{commands_text: "!ticket !adm"})
      |> render_change()

      view |> element("button", "Next") |> render_click()
      assert has_element?(view, "#wizard-title", "Categories")

      view |> element("button", "Add a category") |> render_click()

      view
      |> form("#wizard-form",
        settings: %{category_rows: %{"0" => %{name: "cheat", priority: "urgent"}}}
      )
      |> render_change()

      view |> element("button", "Next") |> render_click()
      assert has_element?(view, "#wizard-title", "Messages")
      assert has_element?(view, "#preview-received_message")

      view |> element("button", "Next") |> render_click()
      view |> element("button", "Next") |> render_click()
      assert has_element?(view, "#wizard-review", "!ticket")
      assert has_element?(view, "#wizard-review", "cheat")

      view |> form("#wizard-form") |> render_submit()
      assert_redirect(view, ~p"/servers/#{server.id}/tickets")

      settings = Tickets.get_settings(server.id)
      assert settings.enabled
      assert settings.commands == ["!ticket", "!adm"]
      assert settings.category_priorities == %{"cheat" => "urgent"}
    end

    test "a step with an error does not move on", %{conn: conn, server: server} do
      {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/tickets/setup")

      view |> form("#wizard-form", settings: %{commands_text: " "}) |> render_change()
      html = view |> element("button", "Next") |> render_click()

      assert html =~ "add at least one command"
      assert has_element?(view, "#wizard-title", "Commands")
    end

    test "from the global inbox it starts by picking servers", %{conn: conn, server: server} do
      other = server_fixture(%{name: "EU #2"})
      {:ok, view, _html} = live(conn, ~p"/tickets/setup")
      assert has_element?(view, "#wizard-title", "Servers")

      view
      |> form("#server-picker")
      |> render_change(%{"server_ids" => ["", to_string(server.id), to_string(other.id)]})

      for _step <- 1..5, do: view |> element("button", "Next") |> render_click()
      view |> form("#wizard-form") |> render_submit()

      assert Tickets.get_settings(server.id).enabled
      assert Tickets.get_settings(other.id).enabled
    end
  end

  describe "settings tabs" do
    test "sections switch without losing what was typed", %{conn: conn, server: server} do
      {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/tickets/settings")

      view
      |> form("#ticket-settings-form", settings: %{commands_text: "!help"})
      |> render_change()

      view |> element("#settings-sections button[data-section=limits]") |> render_click()

      assert has_element?(view, "#settings-section-limits:not(.hidden)")
      assert has_element?(view, "#settings-section-general.hidden")
      assert has_element?(view, "#unsaved")

      view |> form("#ticket-settings-form") |> render_submit()
      assert Tickets.get_settings(server.id).commands == ["!help"]
    end

    test "a failed save opens the section with the error", %{conn: conn, server: server} do
      {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/tickets/settings")
      view |> element("#settings-sections button[data-section=limits]") |> render_click()

      view
      |> form("#ticket-settings-form", settings: %{enabled: "true", commands_text: ""})
      |> render_submit()

      assert has_element?(view, "#settings-section-general:not(.hidden)")
      assert has_element?(view, "#settings-sections button[data-section=general] span", "1")
    end
  end

  describe "inbox views" do
    test "views count tickets and claiming moves one to mine", %{
      conn: conn,
      server: server,
      user: user
    } do
      ticket = open_ticket(server)
      {:ok, view, _html} = live(conn, ~p"/tickets")

      assert has_element?(view, "#ticket-views button[data-view=unassigned]", "1")
      assert has_element?(view, "#ticket-#{ticket.id}[data-age=fresh]")

      view |> element("#ticket-#{ticket.id} button", "Claim") |> render_click()
      assert Repo.reload!(ticket).assigned_to_id == user.id

      view |> element("#ticket-views button[data-view=mine]") |> render_click()
      assert has_element?(view, "#ticket-#{ticket.id}")

      view |> element("#ticket-views button[data-view=unassigned]") |> render_click()
      refute has_element?(view, "#ticket-#{ticket.id}")
    end
  end

  describe "collision guard" do
    test "other admins on the ticket show up, typing included", %{conn: conn, server: server} do
      ticket = open_ticket(server)
      other = user_fixture(%{name: "Bia"})

      other_conn =
        build_conn() |> init_test_session(%{}) |> Plug.Conn.put_session(:user_id, other.id)

      {:ok, view, _html} = live(conn, ~p"/tickets/#{ticket.id}")
      {:ok, other_view, _html} = live(other_conn, ~p"/tickets/#{ticket.id}")

      assert render(view) =~ "Bia is viewing"

      other_view |> form("#reply-form", reply: %{body: "on it"}) |> render_change()
      assert render(view) =~ "Bia is typing an answer"
    end

    test "an answer written before a new message is held once", %{conn: conn, server: server} do
      ticket = open_ticket(server)
      other = user_fixture(%{name: "Bia"})

      {:ok, view, _html} = live(conn, ~p"/tickets/#{ticket.id}")
      view |> form("#reply-form", reply: %{body: "Where?"}) |> render_change()

      {:ok, _} = Tickets.reply(ticket, other, "I got it")
      _ = render(view)

      html = view |> form("#reply-form", reply: %{body: "Where?"}) |> render_submit()
      assert html =~ "New messages arrived while you were typing"
      refute has_element?(view, "[data-author=admin]", "Where?")

      view |> form("#reply-form", reply: %{body: "Where?"}) |> render_submit()
      assert has_element?(view, "[data-author=admin]", "Where?")
    end
  end
end
