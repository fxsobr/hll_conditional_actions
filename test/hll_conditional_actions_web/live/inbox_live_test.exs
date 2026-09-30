defmodule HllConditionalActionsWeb.InboxLiveTest do
  @moduledoc """
  The Caixa: Attention items and tickets in one list, the filters, and the
  detail on the right (an item to mark as handled, a ticket's conversation).
  """

  use HllConditionalActionsWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest
  import Req.Test, only: [set_req_test_to_shared: 1]

  alias HllConditionalActions.Crcon.Events.Event
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Tickets
  alias HllConditionalActions.Tickets.Ticket

  doctest HllConditionalActionsWeb.TicketComponents
  doctest HllConditionalActionsWeb.AttentionLive

  # The conversation reads the player card from CRCON in a background task.
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

  defp open_ticket(server, attrs \\ %{}) do
    {:ok, settings} =
      Tickets.save_settings(
        Tickets.get_settings(server.id),
        Map.merge(%{enabled: true, commands: ["!admin"]}, attrs)
      )

    event = %Event{
      type: :player_chat,
      action: "CHAT[Allies]",
      occurred_at: DateTime.utc_now(),
      player_id: "76561198000000001",
      player_name: "Sarge",
      chat_message: "!admin someone is team killing"
    }

    {:opened, ticket} = Tickets.handle_chat(server, settings, event)
    ticket
  end

  defp review_item(server) do
    rule = rule_fixture(%{name: "HQ guard", server_id: server.id})

    {:ok, execution} =
      Rules.record_execution(%{
        rule_id: rule.id,
        server_id: server.id,
        player_id: "76561190000000009",
        player_name: "Chris",
        trigger_event: "vehicle_destroyed",
        status: :executed,
        results: [
          %{"type" => "add_to_watchlist", "status" => "ok", "detail" => "Check the HQ vehicle"}
        ]
      })

    execution
  end

  test "an empty inbox says all clear", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/inbox")

    assert html =~ "All clear"
    assert has_element?(view, "#inbox-empty")
    assert has_element?(view, "#inbox-pick")
  end

  test "Attention items and tickets share one list", %{conn: conn, server: server} do
    execution = review_item(server)
    ticket = open_ticket(server)

    {:ok, view, _html} = live(conn, ~p"/inbox")

    assert has_element?(view, "#inbox-item-review-#{execution.id}", "Review Chris")
    assert has_element?(view, "#inbox-ticket-#{ticket.id}", "Sarge")
    # The owner tabs sit beside the page title.
    assert has_element?(view, "#section-tabs a[aria-current=page]", "2")
  end

  test "a ticket that changes elsewhere updates the list", %{conn: conn, server: server} do
    {:ok, view, _html} = live(conn, ~p"/inbox")
    ticket = open_ticket(server)

    # The change comes through the navigation hook, which lets it reach
    # the page; the page does not subscribe a second time.
    send(view.pid, {:ticket_changed, ticket})
    assert has_element?(view, "#inbox-ticket-#{ticket.id}")
  end

  test "an Attention item opens on the right and is marked as handled", %{
    conn: conn,
    server: server
  } do
    execution = review_item(server)
    {:ok, view, _html} = live(conn, ~p"/inbox")

    view |> element("#inbox-item-review-#{execution.id}") |> render_click()
    assert_patch(view, ~p"/inbox?#{[item: "review:#{execution.id}"]}")

    assert has_element?(view, "#inbox-item", "Check the HQ vehicle")
    assert has_element?(view, "#inbox-item a[href='/players/#{execution.player_id}']")

    view |> element("#inbox-resolve") |> render_click()
    assert_patch(view, ~p"/inbox")

    refute has_element?(view, "#inbox-item-review-#{execution.id}")
    refute has_element?(view, "#inbox-item")
  end

  test "an item that is gone says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/inbox?#{[item: "review:999999"]}")
    assert has_element?(view, "#inbox-gone")
  end

  test "a ticket opens its conversation, and the answer goes out from the inbox", %{
    conn: conn,
    server: server,
    user: user
  } do
    ticket = open_ticket(server)
    {:ok, view, _html} = live(conn, ~p"/inbox")

    view |> element("#inbox-ticket-#{ticket.id}") |> render_click()
    assert_patch(view, ~p"/inbox?#{[ticket: ticket.id]}")

    assert has_element?(view, "#ticket-conversation", "someone is team killing")
    assert has_element?(view, "#inbox-ticket-#{ticket.id}[aria-current=true]")

    view |> element("#ticket-assign-me") |> render_click()
    assert Repo.reload!(ticket).assigned_to_id == user.id

    view |> form("#reply-form", reply: %{body: "On my way"}) |> render_submit()
    assert has_element?(view, "#ticket-messages [data-author=admin]", "On my way")

    render_patch(view, ~p"/inbox?#{[owner: "mine"]}")
    assert has_element?(view, "#inbox-ticket-#{ticket.id}")

    render_patch(view, ~p"/inbox?#{[owner: "unowned"]}")
    refute has_element?(view, "#inbox-ticket-#{ticket.id}")
  end

  test "an internal note from the inbox stays with the admins", %{conn: conn, server: server} do
    ticket = open_ticket(server)
    {:ok, view, _html} = live(conn, ~p"/inbox?#{[ticket: ticket.id]}")

    view
    |> form("#reply-form", reply: %{body: "banned him last week"})
    |> render_submit(%{"mode" => "note"})

    assert has_element?(view, "[data-author=note]", "banned him last week")
  end

  test "closing from the inbox moves the ticket to the resolved chip", %{
    conn: conn,
    server: server
  } do
    ticket = open_ticket(server)
    {:ok, view, _html} = live(conn, ~p"/inbox?#{[ticket: ticket.id]}")

    view |> element("#close-resolved") |> render_click()
    assert has_element?(view, "#ticket-closed-note")
    refute has_element?(view, "#inbox-ticket-#{ticket.id}")

    view |> element("#inbox-chips button[data-chip=resolved]") |> render_click()
    assert has_element?(view, "#inbox-ticket-#{ticket.id}")
  end

  test "chips and the search narrow the list", %{conn: conn, server: server} do
    execution = review_item(server)
    ticket = open_ticket(server)
    {:ok, view, _html} = live(conn, ~p"/inbox")

    view |> element("#inbox-chips button[data-chip=tickets]") |> render_click()
    assert has_element?(view, "#inbox-ticket-#{ticket.id}")
    refute has_element?(view, "#inbox-item-review-#{execution.id}")

    view |> element("#inbox-chips button[data-chip=players]") |> render_click()
    refute has_element?(view, "#inbox-ticket-#{ticket.id}")
    assert has_element?(view, "#inbox-item-review-#{execution.id}")

    # The same chip again shows everything.
    view |> element("#inbox-chips button[data-chip=players]") |> render_click()
    assert has_element?(view, "#inbox-ticket-#{ticket.id}")

    view |> form("#inbox-search", %{"q" => "chris"}) |> render_change()
    assert has_element?(view, "#inbox-item-review-#{execution.id}")
    refute has_element?(view, "#inbox-ticket-#{ticket.id}")
  end

  test "a ticket waiting too long is one urgent row", %{conn: conn, server: server} do
    ticket = open_ticket(server, %{attention_minutes: 5})
    earlier = DateTime.add(DateTime.utc_now(:second), -30, :minute)

    Repo.update_all(
      from(t in Ticket, where: t.id == ^ticket.id),
      set: [last_activity_at: earlier]
    )

    {:ok, view, _html} = live(conn, ~p"/inbox")

    assert has_element?(view, "#inbox-ticket-#{ticket.id}")
    refute has_element?(view, "#inbox-item-ticket-#{ticket.id}")
    assert has_element?(view, "#inbox-chips button[data-chip=urgent]", "1")

    view |> element("#inbox-chips button[data-chip=urgent]") |> render_click()
    assert has_element?(view, "#inbox-ticket-#{ticket.id}")
  end

  test "without the ticket permission only Attention shows", %{conn: conn, server: server} do
    ticket = open_ticket(server)
    execution = review_item(server)
    role = role_fixture(%{permissions: ["view_executions", "view_rules"]})
    reader = user_fixture(%{role: role})
    conn = Plug.Conn.put_session(conn, :user_id, reader.id)

    {:ok, view, _html} = live(conn, ~p"/inbox?#{[ticket: ticket.id]}")

    refute has_element?(view, "#inbox-ticket-#{ticket.id}")
    refute has_element?(view, "#ticket-conversation")
    refute has_element?(view, "#inbox-chips button[data-chip=tickets]")
    assert has_element?(view, "#inbox-item-review-#{execution.id}")
  end

  test "tickets of a server without the module stay out", %{conn: conn} do
    server = server_fixture(%{name: "No tickets", features: [:rules]})
    ticket = open_ticket(server)

    {:ok, view, _html} = live(conn, ~p"/inbox")
    refute has_element?(view, "#inbox-ticket-#{ticket.id}")
  end

  test "the reported player has a card and the one-click actions", %{
    conn: conn,
    server: server
  } do
    ticket = open_ticket(server)
    {:ok, _ticket} = Tickets.set_reported(ticket, "76561190000000077", "Rudi_88")

    {:ok, view, _html} = live(conn, ~p"/inbox?#{[ticket: ticket.id]}")
    render_async(view)

    assert has_element?(view, "#ticket-cited", "Rudi_88")
    assert has_element?(view, "#ticket-player", "Sarge")

    view |> element("#cited-temp_ban") |> render_click()
    assert has_element?(view, "#act-sheet", "Ban Rudi_88")

    view |> form("#act-form", act: %{reason: "Team killing in the tank"}) |> render_submit()

    assert has_element?(
             view,
             "#ticket-messages [data-author=system]",
             "TEMPBAN 2h Rudi_88: Team killing in the tank"
           )
  end

  test "the more options sheet changes who the ticket is about", %{conn: conn, server: server} do
    ticket = open_ticket(server)
    {:ok, view, _html} = live(conn, ~p"/inbox?#{[ticket: ticket.id]}")

    refute has_element?(view, "#cited-actions")
    view |> element("#ticket-more") |> render_click()

    view
    |> form("#reported-form", reported: %{player_id: "76561190000000077"})
    |> render_submit()

    assert Repo.reload!(ticket).reported_player_id == "76561190000000077"
    assert has_element?(view, "#cited-actions")
  end

  test "the ticket page and Attention link to the inbox", %{conn: conn, server: server} do
    ticket = open_ticket(server)

    {:ok, view, _html} = live(conn, ~p"/tickets/#{ticket.id}")
    assert has_element?(view, ~s|a[href="/inbox?ticket=#{ticket.id}"]|)

    {:ok, view, _html} = live(conn, ~p"/attention")
    assert has_element?(view, ~s|a[href="/inbox"]|)
  end

  describe "configure tickets" do
    test "leads to the setup wizard until tickets run, then to the settings", %{
      conn: conn,
      server: server
    } do
      {:ok, view, _html} = live(conn, ~p"/inbox")
      assert has_element?(view, ~s|#inbox-configure[href="/tickets/setup"]|)

      {:ok, _settings} =
        Tickets.save_settings(Tickets.get_settings(server.id), %{
          enabled: true,
          commands: ["!admin"]
        })

      {:ok, view, _html} = live(conn, ~p"/inbox")
      assert has_element?(view, ~s|#inbox-configure[href="/tickets/settings"]|)
    end

    test "is not offered to who cannot change tickets" do
      viewer = user_fixture(%{role: HllConditionalActions.Accounts.ensure_system_roles!().viewer})

      conn =
        build_conn() |> init_test_session(%{}) |> Plug.Conn.put_session(:user_id, viewer.id)

      {:ok, view, _html} = live(conn, ~p"/inbox")
      refute has_element?(view, "#inbox-configure")
    end
  end
end
