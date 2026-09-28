defmodule HllConditionalActions.TicketsTest do
  @moduledoc """
  Tickets open from a chat command, gather the player's follow-up lines,
  carry admin answers back to the game, and close by hand or on their own.
  """

  use HllConditionalActions.DataCase, async: false

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Crcon.Events.Event
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Tickets
  alias HllConditionalActions.Tickets.Ticket

  doctest HllConditionalActions.Tickets
  doctest HllConditionalActions.Tickets.Settings

  @player_id "76561198000000001"

  setup do
    test_pid = self()

    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:crcon, conn.request_path, Jason.decode!(body)})
      Req.Test.json(conn, %{"result" => true, "failed" => false, "error" => nil})
    end)

    server = server_fixture()

    {:ok, settings} =
      Tickets.save_settings(Tickets.get_settings(server.id), %{
        enabled: true,
        commands: ["!admin", "!adm"],
        cooldown_seconds: 60,
        received_message: "Got it, {player}",
        reply_prefix: "[ADMIN {admin}]",
        closed_message: "Closed"
      })

    %{server: server, settings: settings, admin: user_fixture(%{name: "Ana"})}
  end

  defp chat(text, attrs \\ %{}) do
    struct!(
      %Event{type: :player_chat, action: "CHAT[Allies][Team]", occurred_at: DateTime.utc_now()},
      Map.merge(%{player_id: @player_id, player_name: "Sarge", chat_message: text}, attrs)
    )
  end

  defp bodies(ticket) do
    ticket = Repo.preload(ticket, :messages, force: true)
    Enum.map(ticket.messages, &{&1.author, &1.body})
  end

  describe "handle_chat/3" do
    test "a command opens a ticket and tells the player", %{server: server, settings: settings} do
      assert {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!Admin tk at spawn"))

      assert ticket.status == :open
      assert bodies(ticket) == [{:player, "tk at spawn"}, {:system, "Got it, Sarge"}]
      assert_received {:crcon, "/api/message_player", %{"message" => "Got it, Sarge"}}
    end

    test "chat that is not a command is ignored", %{server: server, settings: settings} do
      assert :ignored = Tickets.handle_chat(server, settings, chat("anyone seen !admin?"))
      assert Repo.aggregate(Ticket, :count) == 0
    end

    test "every configured command works", %{server: server, settings: settings} do
      assert {:opened, _ticket} = Tickets.handle_chat(server, settings, chat("!adm"))
    end

    test "while a ticket is open, the player's chat joins it", %{
      server: server,
      settings: settings
    } do
      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin help"))
      assert {:added, _} = Tickets.handle_chat(server, settings, chat("it's at the bridge"))
      assert {:added, _} = Tickets.handle_chat(server, settings, chat("!admin still there?"))

      assert Repo.aggregate(Ticket, :count) == 1

      assert {:player, "it's at the bridge"} in bodies(ticket)
      assert {:player, "still there?"} in bodies(ticket)
    end

    test "a new ticket right after one closed waits out the cooldown", %{
      server: server,
      settings: settings,
      admin: admin
    } do
      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin help"))
      {:ok, _closed} = Tickets.close(ticket, admin)

      assert :cooldown = Tickets.handle_chat(server, settings, chat("!admin again"))
    end

    test "nothing happens while tickets are off", %{server: server, settings: settings} do
      assert :ignored = Tickets.handle_chat(server, %{settings | enabled: false}, chat("!admin"))
    end
  end

  describe "admin actions" do
    setup %{server: server, settings: settings} do
      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin help"))
      %{ticket: ticket}
    end

    test "an answer reaches the player with the prefix", %{ticket: ticket, admin: admin} do
      assert {:ok, message} = Tickets.reply(ticket, admin, "On my way")
      assert message.delivery == :sent

      assert_received {:crcon, "/api/message_player",
                       %{"player_id" => @player_id, "message" => "[ADMIN Ana] On my way"}}

      ticket = Repo.reload!(ticket)
      assert ticket.status == :answered
      assert ticket.assigned_to_id == admin.id
    end

    test "an answer CRCON refuses is kept, marked as not delivered", %{
      ticket: ticket,
      admin: admin
    } do
      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        Req.Test.json(conn, %{"result" => nil, "failed" => true, "error" => "Player not found"})
      end)

      assert {:ok, message} = Tickets.reply(ticket, admin, "Hello?")
      assert message.delivery == :failed
      assert message.delivery_error =~ "Player not found"
    end

    test "the player writing again puts the ticket back in the queue", %{
      server: server,
      settings: settings,
      ticket: ticket,
      admin: admin
    } do
      {:ok, _message} = Tickets.reply(ticket, admin, "Where?")
      {:added, ticket} = Tickets.handle_chat(server, settings, chat("bridge"))

      assert ticket.status == :open
    end

    test "a closed ticket takes no answers and can be reopened", %{
      ticket: ticket,
      admin: admin
    } do
      {:ok, closed} = Tickets.close(ticket, admin, "done")
      assert closed.status == :closed
      assert_received {:crcon, "/api/message_player", %{"message" => "Closed"}}

      assert {:error, :closed} = Tickets.reply(closed, admin, "late")
      assert {:ok, %{status: :open}} = Tickets.reopen(closed)
    end

    test "silent tickets close on their own", %{ticket: ticket} do
      old = DateTime.add(DateTime.utc_now(:second), -13, :hour)
      ticket |> Ecto.Changeset.change(last_activity_at: old) |> Repo.update!()

      assert Tickets.close_stale() == 1
      assert %{status: :closed, close_reason: "inactivity"} = Repo.reload!(ticket)
    end
  end

  describe "visibility" do
    test "a user restricted to other servers sees none of this server's tickets", %{
      server: server,
      settings: settings
    } do
      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin"))
      other = server_fixture()

      user = user_fixture()
      {:ok, user} = Accounts.set_user_servers(user, [other.id])

      assert Tickets.list_tickets(user) == []
      assert :error = Tickets.fetch_ticket(user, ticket.id)
    end
  end
end
