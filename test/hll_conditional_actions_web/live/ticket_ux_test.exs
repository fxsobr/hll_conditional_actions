defmodule HllConditionalActionsWeb.TicketUxTest do
  @moduledoc """
  The help-desk style round: the setup wizard, the settings panels, the inbox
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
      assert has_element?(view, "#wizard-title", "How the player calls an admin")

      view |> element("#command-add") |> render_submit(%{"command" => "!Ticket"})
      view |> element("#command-chips button[phx-value-command='!admin']") |> render_click()
      assert has_element?(view, "#command-chips", "!ticket")

      view |> element("#wizard-next") |> render_click()
      assert has_element?(view, "#wizard-title", "What the calls are about")
      # Tickets are still off, so the step was kept as a draft.
      assert has_element?(view, "#draft-saved")
      refute Tickets.get_settings(server.id).enabled
      assert Tickets.get_settings(server.id).commands == ["!ticket"]

      view |> element("#wizard-next") |> render_click()
      assert has_element?(view, "#wizard-title", "What the player reads")
      assert has_element?(view, "#message-received")

      view |> element("#wizard-next") |> render_click()
      view |> element("#wizard-next") |> render_click()
      assert has_element?(view, "#wizard-review", "!ticket")
      assert has_element?(view, "#wizard-review", "Friendly fire")

      view |> element("#wizard-finish") |> render_click()
      assert_redirect(view, ~p"/servers/#{server.id}/tickets")

      settings = Tickets.get_settings(server.id)
      assert settings.enabled
      assert settings.commands == ["!ticket"]
      assert settings.category_priorities["Friendly fire"] == "high"
    end

    test "the commands step sets the wait, the audience and the blocks", %{
      conn: conn,
      server: server
    } do
      {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/tickets/setup")

      view
      |> form("#wizard-form",
        settings: %{
          cooldown_choice: "5",
          audience: "vip",
          ask_reason: "true",
          ignore_case: "false"
        }
      )
      |> render_change()

      view |> element("button[phx-click=max_open][phx-value-delta='1']") |> render_click()
      view |> element("button[phx-click=toggle_adding_block]") |> render_click()
      view |> element("#flag-add") |> render_submit(%{"flag" => "sem_ticket"})
      assert has_element?(view, "#wizard-form", "sem_ticket")

      view |> element("#wizard-save-exit") |> render_click()
      assert_redirect(view, ~p"/inbox")

      settings = Tickets.get_settings(server.id)
      assert settings.cooldown_seconds == 300
      assert settings.audience == "vip"
      assert settings.ask_reason
      refute settings.ignore_case
      assert settings.max_open_per_player == 2
      assert settings.blocked_flags == ["sem_ticket"]
    end

    test "a step with an error does not move on", %{conn: conn, server: server} do
      {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/tickets/setup")

      view |> element("#command-chips button[phx-value-command='!admin']") |> render_click()
      html = view |> element("#wizard-next") |> render_click()

      assert html =~ "add at least one command"
      assert has_element?(view, "#wizard-title", "How the player calls an admin")
    end

    test "from the global inbox it starts by picking servers", %{conn: conn, server: server} do
      other = server_fixture(%{name: "EU #2"})
      {:ok, view, _html} = live(conn, ~p"/tickets/setup")
      assert has_element?(view, "#wizard-title", "Which servers take tickets")

      view
      |> element("#server-picker")
      |> render_change(%{"server_ids" => ["", to_string(server.id), to_string(other.id)]})

      for _step <- 1..5, do: view |> element("#wizard-next") |> render_click()
      view |> element("#wizard-finish") |> render_click()

      assert Tickets.get_settings(server.id).enabled
      assert Tickets.get_settings(other.id).enabled
    end
  end

  describe "settings panels" do
    test "every panel is on the page and saved together", %{conn: conn, server: server} do
      {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/tickets/settings")

      for panel <- ~w(categories autoclose discord replies messages hours) do
        assert has_element?(view, "#settings-#{panel}")
      end

      view
      |> form("#ticket-settings-form", settings: %{commands_text: "!help"})
      |> render_change()

      assert has_element?(view, "#unsaved", "1")

      view |> form("#ticket-settings-form") |> render_submit()
      assert Tickets.get_settings(server.id).commands == ["!help"]
      refute has_element?(view, "#unsaved")
    end

    test "a failed save opens the settings with the error", %{conn: conn, server: server} do
      {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/tickets/settings")

      html =
        view
        |> form("#ticket-settings-form", settings: %{commands_text: ""})
        |> render_submit(%{"settings" => %{"enabled" => "true"}})

      assert html =~ "add at least one command"
      assert has_element?(view, "#settings-more[open]")
      refute Tickets.get_settings(server.id).enabled
    end

    test "discard goes back to what is saved", %{conn: conn, server: server} do
      {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/tickets/settings")

      view
      |> form("#ticket-settings-form", settings: %{commands_text: "!other"})
      |> render_change()

      view |> element("#settings-discard") |> render_click()

      refute has_element?(view, "#unsaved")
      assert has_element?(view, "#settings_commands_text[value='!admin']")
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
