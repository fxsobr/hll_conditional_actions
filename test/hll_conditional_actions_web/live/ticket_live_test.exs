defmodule HllConditionalActionsWeb.TicketLiveTest do
  use HllConditionalActionsWeb.ConnCase, async: false

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest
  import Req.Test, only: [set_req_test_to_shared: 1]

  alias HllConditionalActions.Crcon.Events.Event
  alias HllConditionalActions.Tickets

  doctest HllConditionalActionsWeb.TicketLive.Settings
  doctest HllConditionalActionsWeb.TicketLive.Metrics

  # The ticket page reads the player card from CRCON in a background task,
  # which may outlive a test's own process; shared stubs reach it.
  setup :set_req_test_to_shared

  setup %{conn: conn} do
    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      Req.Test.json(conn, %{"result" => true, "failed" => false, "error" => nil})
    end)

    user = user_fixture(%{name: "Ana"})
    server = server_fixture(%{name: "EU #1"})

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, user: user, server: server}
  end

  defp enable(server) do
    {:ok, settings} =
      Tickets.save_settings(Tickets.get_settings(server.id), %{
        enabled: true,
        commands: ["!admin"],
        reply_prefix: "[ADMIN {admin}]"
      })

    settings
  end

  defp open_ticket(server, text \\ "!admin help me") do
    event = %Event{
      type: :player_chat,
      action: "CHAT[Allies]",
      occurred_at: DateTime.utc_now(),
      player_id: "76561198000000001",
      player_name: "Sarge",
      chat_message: text
    }

    {:opened, ticket} = Tickets.handle_chat(server, enable(server), event)
    ticket
  end

  test "the inbox lists open tickets and updates live", %{conn: conn, server: server} do
    {:ok, view, html} = live(conn, ~p"/tickets")
    assert html =~ "No tickets"

    ticket = open_ticket(server)

    assert render(view) =~ "Sarge"
    assert has_element?(view, "#ticket-#{ticket.id}")
  end

  test "an admin answers and closes a ticket", %{conn: conn, server: server} do
    ticket = open_ticket(server)

    {:ok, view, html} = live(conn, ~p"/servers/#{server.id}/tickets/#{ticket.id}")
    assert html =~ "help me"

    view |> form("#reply-form", reply: %{body: "On my way"}) |> render_submit()
    assert has_element?(view, "[data-author=admin]", "On my way")

    view |> form("#close-form", %{"reason" => "duplicate"}) |> render_submit()
    assert has_element?(view, "#ticket-closed-note", "Duplicate")
    assert HllConditionalActions.Repo.reload!(ticket).close_reason == "duplicate"
  end

  test "settings take several commands", %{conn: conn, server: server} do
    {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/tickets/settings")

    view
    |> form("#ticket-settings-form",
      settings: %{enabled: "true", commands_text: "!admin, !ADM  @help"}
    )
    |> render_submit()

    settings = Tickets.get_settings(server.id)
    assert settings.enabled
    assert settings.commands == ["!admin", "!adm", "@help"]
  end

  test "turning tickets on without a command is refused", %{conn: conn, server: server} do
    {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/tickets/settings")

    html =
      view
      |> form("#ticket-settings-form", settings: %{enabled: "true", commands_text: " "})
      |> render_submit()

    assert html =~ "add at least one command"
    refute Tickets.get_settings(server.id).enabled
  end

  test "a role without the ticket permission cannot open the inbox", %{conn: conn} do
    role = role_fixture(%{permissions: ["view_servers"]})
    user = user_fixture(%{role: role})
    conn = Plug.Conn.put_session(conn, :user_id, user.id)

    assert {:error, {_kind, _redirect}} = live(conn, ~p"/tickets")
  end

  describe "third round" do
    test "a new ticket rings every open page", %{conn: conn, server: server} do
      {:ok, view, _html} = live(conn, ~p"/")
      ticket = open_ticket(server)

      url = "/tickets/#{ticket.id}"
      assert_push_event(view, "ticket-alert", %{url: ^url})
    end

    test "the inbox has the alert switch and a category filter", %{conn: conn, server: server} do
      settings = enable(server)
      {:ok, settings} = Tickets.save_settings(settings, %{category_priorities: %{"tk" => "high"}})

      event = %Event{
        type: :player_chat,
        action: "CHAT[Allies]",
        occurred_at: DateTime.utc_now(),
        player_id: "76561198000000001",
        player_name: "Sarge",
        chat_message: "!admin tk spawn"
      }

      {:opened, ticket} = Tickets.handle_chat(server, settings, event)

      {:ok, view, _html} = live(conn, ~p"/tickets")
      assert has_element?(view, "#ticket-alert-toggle")

      view |> element("#ticket-filters") |> render_change(%{"category" => "tk"})
      assert has_element?(view, "#ticket-#{ticket.id}", "tk")
    end

    test "an internal note stays on the page and is not sent", %{conn: conn, server: server} do
      ticket = open_ticket(server)
      {:ok, view, _html} = live(conn, ~p"/tickets/#{ticket.id}")

      view
      |> form("#reply-form", reply: %{body: "banned him last week"})
      |> render_submit(%{"mode" => "note"})

      assert has_element?(view, "[data-author=note]", "banned him last week")
      assert has_element?(view, "#ticket-export")
    end

    test "the priority is picked from a list", %{conn: conn, server: server} do
      ticket = open_ticket(server)
      {:ok, view, _html} = live(conn, ~p"/tickets/#{ticket.id}")

      view |> form("#priority-form") |> render_change(%{"priority" => "high"})

      assert HllConditionalActions.Repo.reload!(ticket).priority == :high
    end

    test "a ticket is handed to another admin from the list", %{conn: conn, server: server} do
      other = user_fixture(%{name: "Bia"})
      ticket = open_ticket(server)
      {:ok, view, _html} = live(conn, ~p"/tickets/#{ticket.id}")

      view |> form("#transfer-form") |> render_change(%{"user_id" => to_string(other.id)})

      assert HllConditionalActions.Repo.reload!(ticket).assigned_to_id == other.id
    end

    test "settings save categories, the player words and the office hours", %{
      conn: conn,
      server: server
    } do
      {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/tickets/settings")
      assert has_element?(view, "#no-categories")

      view |> element("button", "Add a category") |> render_click()
      view |> element("button", "Add a category") |> render_click()

      view
      |> form("#ticket-settings-form",
        settings: %{
          enabled: "true",
          commands_text: "!admin",
          default_priority: "low",
          category_rows: %{
            "0" => %{name: "TK", priority: "high"},
            "1" => %{name: "cheat", priority: "urgent"}
          },
          status_word: "Status",
          close_word: "fechar",
          hours_enabled: "true",
          hours_start: "20:00",
          hours_end: "02:00",
          hours_days: ["", "6", "7"]
        }
      )
      |> render_submit()

      settings = Tickets.get_settings(server.id)
      assert settings.category_priorities == %{"tk" => "high", "cheat" => "urgent"}
      assert settings.default_priority == "low"
      assert settings.status_word == "status"
      assert settings.hours_enabled
      assert settings.hours_start == ~T[20:00:00]
      assert settings.hours_days == [6, 7]
    end
  end

  describe "settings without a server" do
    test "the inbox links to the global settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tickets")
      assert has_element?(view, ~s(a[href="/tickets/settings"]))
    end

    test "the same settings are saved on every ticked server", %{conn: conn, server: server} do
      other = server_fixture(%{name: "EU #2"})
      untouched = server_fixture(%{name: "EU #3"})

      {:ok, view, _html} = live(conn, ~p"/tickets/settings")

      view
      |> form("#server-picker")
      |> render_change(%{"server_ids" => ["", to_string(server.id), to_string(other.id)]})

      assert has_element?(view, "#multi-save-note")

      view
      |> form("#ticket-settings-form",
        settings: %{enabled: "true", commands_text: "!ticket", max_per_hour: "4"}
      )
      |> render_submit()

      for id <- [server.id, other.id] do
        settings = Tickets.get_settings(id)
        assert settings.enabled
        assert settings.commands == ["!ticket"]
        assert settings.max_per_hour == 4
      end

      refute Tickets.get_settings(untouched.id).enabled
      assert has_element?(view, "#server-picker", "!ticket")
    end

    test "ticking one server loads its settings", %{conn: conn, server: server} do
      enable(server)
      other = server_fixture(%{name: "EU #2"})

      {:ok, view, _html} = live(conn, ~p"/tickets/settings")

      view
      |> form("#server-picker")
      |> render_change(%{"server_ids" => ["", to_string(server.id)]})

      assert has_element?(view, "#settings_commands_text[value='!admin']")

      view
      |> form("#server-picker")
      |> render_change(%{"server_ids" => ["", to_string(other.id)]})

      refute Tickets.get_settings(other.id).enabled
    end

    test "saving with no server ticked is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tickets/settings")

      view |> form("#server-picker") |> render_change(%{"server_ids" => [""]})

      html =
        view
        |> form("#ticket-settings-form", settings: %{enabled: "true", commands_text: "!admin"})
        |> render_submit()

      assert html =~ "Pick at least one server."
    end
  end

  describe "second round" do
    defp stub_players(players) do
      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        result =
          case conn.request_path do
            "/api/get_detailed_players" -> %{"players" => players}
            "/api/get_player_profile" -> %{"penalty_count" => %{"KICK" => 2}}
            _other -> true
          end

        Req.Test.json(conn, %{"result" => result, "failed" => false, "error" => nil})
      end)
    end

    test "the menu shows how many tickets wait", %{conn: conn, server: server} do
      open_ticket(server)

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "[data-nav-badge]", "1")
    end

    test "a quick reply fills the answer box", %{conn: conn, server: server} do
      ticket = open_ticket(server)

      {:ok, _} =
        Tickets.save_settings(Tickets.get_settings(server.id), %{quick_replies: ["On my way"]})

      {:ok, view, _html} = live(conn, ~p"/tickets/#{ticket.id}")
      view |> element("#quick-replies button", "On my way") |> render_click()

      assert has_element?(view, "#reply-form textarea", "On my way")
    end

    test "the player card warns when the player left", %{conn: conn, server: server} do
      stub_players(%{})
      ticket = open_ticket(server)

      {:ok, view, _html} = live(conn, ~p"/tickets/#{ticket.id}")
      render_async(view)

      assert has_element?(view, "#player-offline-warning")
      assert has_element?(view, "#player-card", "KICK")
    end

    test "an online player shows as online", %{conn: conn, server: server} do
      stub_players(%{"76561198000000001" => player(%{"player_id" => "76561198000000001"})})
      ticket = open_ticket(server)

      {:ok, view, _html} = live(conn, ~p"/tickets/#{ticket.id}")
      render_async(view)

      assert has_element?(view, "#player-online", "Online")
      refute has_element?(view, "#player-offline-warning")
    end

    test "an admin punishes from the ticket", %{conn: conn, server: server} do
      ticket = open_ticket(server)
      {:ok, view, _html} = live(conn, ~p"/tickets/#{ticket.id}")

      view
      |> form("#act-form", act: %{action: "punish", reason: "Team killing", target: ""})
      |> render_submit()

      assert has_element?(view, "[data-author=system]", "PUNISH Sarge: Team killing")
    end

    test "the inbox searches by player", %{conn: conn, server: server} do
      ticket = open_ticket(server)
      {:ok, view, _html} = live(conn, ~p"/tickets")

      view |> element("#ticket-filters") |> render_change(%{"q" => "nobody"})
      refute has_element?(view, "#ticket-#{ticket.id}")

      view |> element("#ticket-filters") |> render_change(%{"q" => "sarg"})
      assert has_element?(view, "#ticket-#{ticket.id}")
    end

    test "metrics count the tickets", %{conn: conn, server: server} do
      open_ticket(server)
      {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/tickets/metrics")

      assert has_element?(view, "#metrics-kpis", "1")
      assert has_element?(view, "#metrics-top-players", "Sarge")
    end

    test "settings save the limit, the alert time and quick replies", %{
      conn: conn,
      server: server
    } do
      {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/tickets/settings")

      view
      |> form("#ticket-settings-form",
        settings: %{
          enabled: "true",
          commands_text: "!admin",
          max_per_hour: "3",
          attention_minutes: "10",
          quick_replies_text: "On my way\nSend a clip"
        }
      )
      |> render_submit()

      settings = Tickets.get_settings(server.id)
      assert settings.max_per_hour == 3
      assert settings.attention_minutes == 10
      assert settings.quick_replies == ["On my way", "Send a clip"]
    end
  end
end
