defmodule HllConditionalActions.TicketsRound3Test do
  @moduledoc """
  Categories, the player's own commands, office hours, the context captured
  before a call, internal notes, handing tickets over, ban durations and the
  text export.
  """

  use HllConditionalActions.DataCase, async: false

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Crcon.Events.Event
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Tickets
  alias HllConditionalActions.Tickets.Listener
  alias HllConditionalActions.Tickets.Ticket

  doctest HllConditionalActions.Tickets.Context

  @player_id "76561198000000001"

  setup do
    test_pid = self()

    Req.Test.set_req_test_to_shared()

    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:crcon, conn.request_path, body})
      Req.Test.json(conn, %{"result" => true, "failed" => false, "error" => nil})
    end)

    server = server_fixture(%{name: "EU #1", timezone: "Etc/UTC"})

    {:ok, settings} =
      Tickets.save_settings(Tickets.get_settings(server.id), %{
        enabled: true,
        commands: ["!admin"],
        cooldown_seconds: 0,
        category_priorities: %{"tk" => "high", "cheat" => "urgent"},
        status_word: "status",
        close_word: "fechar",
        received_message: "Received",
        offline_message: "Nobody is online"
      })

    %{server: server, settings: settings, admin: user_fixture(%{name: "Ana"})}
  end

  defp chat(text, attrs \\ %{}) do
    struct!(
      %Event{type: :player_chat, action: "CHAT[Allies]", occurred_at: DateTime.utc_now()},
      Map.merge(%{player_id: @player_id, player_name: "Sarge", chat_message: text}, attrs)
    )
  end

  defp sent_messages do
    receive do
      {:crcon, "/api/message_player", body} -> [Jason.decode!(body)["message"] | sent_messages()]
      {:crcon, _path, _body} -> sent_messages()
    after
      0 -> []
    end
  end

  describe "categories" do
    test "the first word is the category, and cheat opens urgent", %{
      server: server,
      settings: settings
    } do
      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin cheat aimbot at B"))

      assert ticket.category == "cheat"
      assert ticket.priority == :urgent

      assert [%{body: "aimbot at B"}] =
               Repo.preload(ticket, :messages).messages |> Enum.filter(&(&1.author == :player))
    end

    test "an unknown first word stays in the text", %{server: server, settings: settings} do
      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin help me"))

      assert ticket.category == nil
      assert ticket.priority == :normal
    end

    test "a bare command opens a ticket at the default priority", %{
      server: server,
      settings: settings
    } do
      {:ok, settings} = Tickets.save_settings(settings, %{default_priority: "low"})

      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin"))

      assert ticket.priority == :low
      assert ticket.category == nil

      assert [%{author: :player, body: "!admin"}] =
               ticket
               |> Repo.preload(:messages)
               |> Map.get(:messages)
               |> Enum.filter(&(&1.author == :player))

      assert sent_messages() == ["Received"]
      assert {:added, _} = Tickets.handle_chat(server, settings, chat("!admin"))
      assert Repo.aggregate(Ticket, :count) == 1
    end

    test "each category opens at its own priority", %{server: server, settings: settings} do
      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin tk at spawn"))
      assert ticket.priority == :high
    end

    test "urgent comes first, then high, normal, low", %{server: server, admin: admin} do
      ids =
        for {priority, index} <- Enum.with_index([:low, :urgent, :normal, :high]) do
          {:opened, ticket} =
            Tickets.open_from_rule(server, %{player_id: "p#{index}"},
              note: "x",
              priority: priority
            )

          {priority, ticket.id}
        end

      order = admin |> Tickets.list_tickets() |> Enum.map(& &1.priority)
      assert order == [:urgent, :high, :normal, :low]
      assert length(ids) == 4
    end

    test "a rule never lowers a ticket's priority", %{server: server} do
      player = %{player_id: @player_id}
      {:opened, ticket} = Tickets.open_from_rule(server, player, note: "a", priority: :high)
      {:added, same} = Tickets.open_from_rule(server, player, note: "b", priority: :low)

      assert same.id == ticket.id
      assert same.priority == :high
    end

    test "the inbox filters by category", %{server: server, settings: settings, admin: admin} do
      {:opened, _} = Tickets.handle_chat(server, settings, chat("!admin tk spawn"))

      assert [_] = Tickets.list_tickets(admin, category: "tk")
      assert [] = Tickets.list_tickets(admin, category: "cheat")
      assert Tickets.categories(admin) == ["tk"]
    end
  end

  describe "player commands" do
    test "status tells the player, without opening a ticket", %{
      server: server,
      settings: settings
    } do
      assert {:status, nil} = Tickets.handle_chat(server, settings, chat("!admin status"))
      assert Repo.aggregate(Ticket, :count) == 0
      assert [text] = sent_messages()
      assert text =~ "no open ticket"
    end

    test "status on an answered ticket says so", %{
      server: server,
      settings: settings,
      admin: admin
    } do
      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin help"))
      {:ok, _} = Tickets.reply(ticket, admin, "Hi")
      _ = sent_messages()

      assert {:status, %Ticket{}} = Tickets.handle_chat(server, settings, chat("!admin STATUS"))
      assert [text] = sent_messages()
      assert text =~ "answered"
    end

    test "the close word closes the player's ticket", %{server: server, settings: settings} do
      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin help"))

      assert {:closed, _} = Tickets.handle_chat(server, settings, chat("!admin fechar"))
      assert %{status: :closed, close_reason: "player"} = Repo.reload!(ticket)
    end
  end

  describe "office hours" do
    test "outside the hours the player gets the offline message", %{
      server: server,
      settings: settings
    } do
      now = DateTime.utc_now()
      closed_from = now |> DateTime.add(2, :hour) |> DateTime.to_time() |> Time.truncate(:second)
      closed_until = now |> DateTime.add(3, :hour) |> DateTime.to_time() |> Time.truncate(:second)

      {:ok, settings} =
        Tickets.save_settings(settings, %{
          hours_enabled: true,
          hours_start: closed_from,
          hours_end: closed_until
        })

      {:opened, _ticket} = Tickets.handle_chat(server, settings, chat("!admin help"))
      assert sent_messages() == ["Nobody is online"]
    end

    test "inside the hours the usual message goes out", %{server: server, settings: settings} do
      {:ok, settings} =
        Tickets.save_settings(settings, %{
          hours_enabled: true,
          hours_start: ~T[00:00:00],
          hours_end: ~T[23:59:59]
        })

      {:opened, _ticket} = Tickets.handle_chat(server, settings, chat("!admin help"))
      assert sent_messages() == ["Received"]
    end
  end

  describe "context before the call" do
    test "the listener attaches recent chat and team kills", %{server: server} do
      pid = start_supervised!({Listener, server: server})
      now = DateTime.utc_now()

      tk = %Event{
        type: :player_team_kill,
        action: "TEAM KILL",
        occurred_at: DateTime.add(now, -30, :second),
        player_id: "76561190000000099",
        player_name: "Rambo",
        target_player_id: @player_id,
        target_player_name: "Sarge",
        weapon: "M1 GARAND"
      }

      send(pid, {:crcon_event, tk})
      send(pid, {:crcon_event, chat("why", %{occurred_at: DateTime.add(now, -20, :second)})})
      send(pid, {:crcon_event, chat("!admin tk by Rambo", %{occurred_at: now})})
      _ = :sys.get_state(pid)

      ticket = Repo.one!(Ticket)
      texts = Enum.map(ticket.context, & &1["text"])

      assert "Rambo team killed Sarge (M1 GARAND)" in texts
      assert Enum.any?(texts, &(&1 =~ "Sarge: why"))
    end
  end

  describe "admin tools" do
    setup %{server: server, settings: settings} do
      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin help"))
      _ = sent_messages()
      %{ticket: ticket}
    end

    test "an internal note is kept but never sent", %{ticket: ticket, admin: admin} do
      assert {:ok, note} = Tickets.add_note(ticket, admin, "punished him yesterday")
      assert note.author == :note
      assert sent_messages() == []
    end

    test "the transcript leaves notes out unless asked", %{ticket: ticket, admin: admin} do
      {:ok, _} = Tickets.add_note(ticket, admin, "secret")
      {:ok, _} = Tickets.reply(ticket, admin, "On my way")
      {:ok, ticket} = Tickets.fetch_ticket(admin, ticket.id)

      text = Tickets.transcript(ticket)
      assert text =~ "ADMIN Ana: On my way"
      refute text =~ "secret"
      assert Tickets.transcript(ticket, notes: true) =~ "NOTE Ana: secret"
    end

    test "handing a ticket over tells the new owner", %{ticket: ticket, admin: admin} do
      Tickets.subscribe()
      other = user_fixture(%{name: "Bia"})

      assert other.id in Enum.map(Tickets.assignable_users(ticket), & &1.id)
      {:ok, _} = Tickets.assign(ticket, other, admin)

      other_id = other.id
      assert_receive {:ticket_assigned, _ticket, ^other_id, "Ana"}
    end

    test "a temporary ban takes the chosen hours", %{ticket: ticket, admin: admin} do
      assert {:ok, message} =
               Tickets.act(ticket, admin, :temp_ban, "cheating", nil, duration_hours: 168)

      assert message.body =~ "TEMPBAN 168h"

      assert_received {:crcon, "/api/temp_ban", body}
      assert Jason.decode!(body)["duration_hours"] == 168

      assert {:error, :bad_duration} =
               Tickets.act(ticket, admin, :temp_ban, "x", nil, duration_hours: 0)
    end
  end
end
