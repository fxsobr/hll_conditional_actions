defmodule HllConditionalActions.TicketsExtrasTest do
  @moduledoc """
  The second round of ticket features: duplicate lines, the hourly limit,
  tickets opened by rules, CRCON actions from a ticket, the attention inbox,
  metrics, search and the Discord announcement.
  """

  use HllConditionalActions.DataCase, async: false
  use Oban.Testing, repo: HllConditionalActions.Repo

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Attention
  alias HllConditionalActions.Crcon.Events.Event
  alias HllConditionalActions.Discord
  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Executor
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules.Action
  alias HllConditionalActions.Tickets
  alias HllConditionalActions.Tickets.Message
  alias HllConditionalActions.Tickets.Ticket
  alias HllConditionalActions.Workers.DeliverWebhook

  doctest HllConditionalActions.Tickets.PlayerInfo
  doctest HllConditionalActions.Tickets.Announcement

  @player_id "76561198000000001"

  setup do
    test_pid = self()

    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:crcon, conn.request_path, body})
      Req.Test.json(conn, %{"result" => true, "failed" => false, "error" => nil})
    end)

    server = server_fixture(%{name: "EU #1"})

    {:ok, settings} =
      Tickets.save_settings(Tickets.get_settings(server.id), %{
        enabled: true,
        commands: ["!admin"],
        cooldown_seconds: 0
      })

    %{server: server, settings: settings, admin: user_fixture(%{name: "Ana"})}
  end

  defp chat(text, raw \\ %{}) do
    %Event{
      type: :player_chat,
      action: "CHAT[Allies]",
      occurred_at: DateTime.utc_now(),
      player_id: @player_id,
      player_name: "Sarge",
      chat_message: text,
      raw: raw
    }
  end

  describe "duplicate lines" do
    test "a line the stream sends twice is recorded once", %{server: server, settings: settings} do
      line = chat("!admin help", %{"stream_id" => "1790000000-0"})

      assert {:opened, ticket} = Tickets.handle_chat(server, settings, line)
      assert :duplicate = Tickets.handle_chat(server, settings, line)

      follow_up = chat("still here", %{"stream_id" => "1790000001-0"})
      assert {:added, _} = Tickets.handle_chat(server, settings, follow_up)
      assert :duplicate = Tickets.handle_chat(server, settings, follow_up)

      assert Repo.aggregate(
               from(m in Message, where: m.ticket_id == ^ticket.id and m.author == :player),
               :count
             ) == 2
    end
  end

  describe "hourly limit" do
    test "a player past the limit cannot open another ticket", %{
      server: server,
      settings: settings,
      admin: admin
    } do
      {:ok, settings} = Tickets.save_settings(settings, %{max_per_hour: 2})

      for _round <- 1..2 do
        {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin"))
        {:ok, _closed} = Tickets.close(ticket, admin)
      end

      assert :rate_limited = Tickets.handle_chat(server, settings, chat("!admin again"))
    end
  end

  describe "tickets opened by rules" do
    test "the open_ticket action opens an urgent ticket without telling the player", %{
      server: server
    } do
      rule = rule_fixture(%{name: "Team kill watch"})

      context =
        server
        |> Context.build(:player_team_kill, player_id: @player_id, player_name: "Sarge")
        |> then(&%{&1 | extra: Map.put(&1.extra, :rule_id, rule.id)})

      action = %Action{
        type: :open_ticket,
        parameters: %{"note" => "3 team kills in 5 minutes", "priority" => "urgent"}
      }

      assert [%{status: :ok}] = Executor.run([action], context)

      ticket = Repo.one!(Ticket) |> Repo.preload(:messages)
      assert ticket.source == :rule
      assert ticket.priority == :urgent
      assert ticket.rule_id == rule.id
      assert [%{author: :system, body: "3 team kills in 5 minutes"}] = ticket.messages
      refute_received {:crcon, "/api/message_player", _}
    end

    test "a second note joins the open ticket", %{server: server} do
      player = %{player_id: @player_id, player_name: "Sarge"}

      {:opened, ticket} = Tickets.open_from_rule(server, player, note: "first")
      {:added, same} = Tickets.open_from_rule(server, player, note: "second", priority: :urgent)

      assert same.id == ticket.id
      assert same.priority == :urgent
    end

    test "rule tickets do not count against the player's limit", %{
      server: server,
      settings: settings
    } do
      {:ok, settings} = Tickets.save_settings(settings, %{max_per_hour: 1})
      {:opened, rule_ticket} = Tickets.open_from_rule(server, %{player_id: @player_id}, note: "x")
      {:ok, _} = Tickets.close(rule_ticket, nil)

      assert {:opened, _} = Tickets.handle_chat(server, settings, chat("!admin"))
    end
  end

  describe "CRCON actions from a ticket" do
    setup %{server: server, settings: settings} do
      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin he tks"))
      %{ticket: ticket}
    end

    test "punishing the reported player is recorded in the conversation", %{
      ticket: ticket,
      admin: admin
    } do
      assert {:ok, message} =
               Tickets.act(ticket, admin, :punish, "Team killing", "76561190000000099")

      assert_received {:crcon, "/api/punish", body}
      assert body =~ "76561190000000099"
      assert message.body =~ "PUNISH 76561190000000099: Team killing"
    end

    test "an action needs a reason", %{ticket: ticket, admin: admin} do
      assert {:error, :empty_reason} = Tickets.act(ticket, admin, :kick, " ")
    end
  end

  describe "attention inbox" do
    test "a ticket waiting too long is urgent", %{
      server: server,
      settings: settings,
      admin: admin
    } do
      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin"))
      old = DateTime.add(DateTime.utc_now(:second), -10, :minute)
      ticket |> Ecto.Changeset.change(last_activity_at: old) |> Repo.update!()

      %{open: items} = Attention.items(admin, [server], %{})

      assert Enum.any?(items, &(&1.kind == :ticket_waiting and &1.severity == :error))
    end

    test "an answered ticket is not waiting", %{server: server, settings: settings, admin: admin} do
      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin"))
      {:ok, _} = Tickets.reply(ticket, admin, "Hi")

      assert Tickets.overdue([server.id]) == []
    end
  end

  describe "search and metrics" do
    test "tickets are found by name or id and counted", %{
      server: server,
      settings: settings,
      admin: admin
    } do
      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin"))
      {:ok, _} = Tickets.reply(ticket, admin, "Hi")

      assert [%{id: id}] = Tickets.list_tickets(admin, query: "sar")
      assert id == ticket.id
      assert [_] = Tickets.list_tickets(admin, query: @player_id)
      assert [] = Tickets.list_tickets(admin, query: "nobody")

      metrics = Tickets.metrics(admin, days: 7)
      assert metrics.opened == 1
      assert metrics.answered == 1
      assert [{"Ana", 1, 1}] = metrics.by_admin
      assert [{@player_id, "Sarge", 1}] = metrics.top_players
      assert Enum.sum(metrics.by_hour) == 1
    end
  end

  describe "Discord announcement" do
    test "a new ticket is queued for the server's webhook", %{server: server, settings: settings} do
      Req.Test.stub(HllConditionalActions.Discord, fn conn ->
        Req.Test.json(conn, %{"name" => "Admins", "channel_id" => "1", "guild_id" => "2"})
      end)

      {:ok, webhook} =
        Discord.create_webhook(%{
          name: "Tickets",
          url: "https://discord.com/api/webhooks/1/abc"
        })

      {:ok, settings} =
        Tickets.save_settings(settings, %{
          discord_webhook_id: webhook.id,
          discord_mention_role_ids: "123"
        })

      {:opened, _ticket} = Tickets.handle_chat(server, settings, chat("!admin tk"))

      assert [job] = all_enqueued(worker: DeliverWebhook)
      assert job.args["webhook_id"] == webhook.id
      assert job.args["payload"]["content"] == "<@&123>"
      assert [%{"description" => "tk"}] = job.args["payload"]["embeds"]
    end
  end
end
