defmodule HllConditionalActions.TicketsFidelityTest do
  @moduledoc """
  What the Caixa and the ticket settings boards ask of tickets: case in
  commands, asking for the reason, several tickets at once, picking a
  category by its number, who may call, what happens outside office hours,
  the warning before a silent ticket closes, the reported player, and the
  numbers of the metrics page.
  """

  use HllConditionalActions.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Crcon.Events.Event
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Tickets
  alias HllConditionalActions.Tickets.Message
  alias HllConditionalActions.Tickets.Stats
  alias HllConditionalActions.Tickets.Ticket

  doctest HllConditionalActions.Tickets.Reported
  doctest HllConditionalActions.Tickets.Eligibility
  doctest HllConditionalActions.Tickets.Stats

  @player_id "76561198000000001"

  setup do
    test_pid = self()
    Req.Test.set_req_test_to_shared()
    stub_crcon(test_pid, %{})

    server = server_fixture(%{name: "EU #1", timezone: "Etc/UTC"})

    {:ok, settings} =
      Tickets.save_settings(Tickets.get_settings(server.id), %{
        enabled: true,
        commands: ["!admin"],
        cooldown_seconds: 0,
        received_message: "Ticket \#{ticket_id} opened, {player_name}"
      })

    %{server: server, settings: settings, test_pid: test_pid}
  end

  # CRCON answers `results` per path (true otherwise) and tells the test
  # what it was asked.
  defp stub_crcon(test_pid, results) do
    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:crcon, conn.request_path, body})
      result = Map.get(results, conn.request_path, true)
      Req.Test.json(conn, %{"result" => result, "failed" => false, "error" => nil})
    end)
  end

  defp chat(text, attrs \\ %{}) do
    struct!(
      %Event{type: :player_chat, action: "CHAT[Allies]", occurred_at: DateTime.utc_now()},
      Map.merge(%{player_id: @player_id, player_name: "Sarge", chat_message: text}, attrs)
    )
  end

  defp save(settings, attrs) do
    {:ok, settings} = Tickets.save_settings(settings, attrs)
    settings
  end

  defp sent_messages do
    receive do
      {:crcon, "/api/message_player", body} -> [Jason.decode!(body)["message"] | sent_messages()]
      {:crcon, _path, _body} -> sent_messages()
    after
      0 -> []
    end
  end

  describe "commands" do
    test "case matters only when the server says so", %{server: server, settings: settings} do
      assert {:opened, _ticket} = Tickets.handle_chat(server, settings, chat("!ADMIN help"))

      strict = save(settings, %{ignore_case: false})
      other = chat("!ADMIN help", %{player_id: "p2"})
      assert Tickets.handle_chat(server, strict, other) == :ignored
    end

    test "a bare command asks for the reason", %{server: server, settings: settings} do
      settings = save(settings, %{ask_reason: true})
      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin"))

      assert ticket.opened_with == "!admin"
      assert Enum.any?(sent_messages(), &(&1 =~ "Tell us what happened"))
    end

    test "a player keeps several tickets when allowed, and is reminded after that", %{
      server: server,
      settings: settings
    } do
      settings = save(settings, %{max_open_per_player: 2})

      {:opened, first} = Tickets.handle_chat(server, settings, chat("!admin tk on the bridge"))
      {:opened, second} = Tickets.handle_chat(server, settings, chat("!admin cheater in B"))
      assert first.id != second.id

      _ = sent_messages()
      assert {:added, %{id: id}} = Tickets.handle_chat(server, settings, chat("!admin again"))
      assert id == second.id
      assert Enum.any?(sent_messages(), &(&1 =~ "You already have ticket ##{second.id} open"))

      # A line without a command joins the newest.
      assert {:added, %{id: ^id}} = Tickets.handle_chat(server, settings, chat("still here"))
    end

    test "the player picks the category by its number", %{server: server, settings: settings} do
      settings =
        save(settings, %{
          category_priorities: %{"Tiro amigo" => "high", "Dúvida" => "low"},
          category_order: ["Tiro amigo", "Dúvida"],
          received_message: "Pick one: {categories}"
        })

      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin help"))
      assert ticket.category == nil
      assert Enum.any?(sent_messages(), &(&1 == "Pick one: 1 Tiro amigo, 2 Dúvida"))

      {:added, ticket} = Tickets.handle_chat(server, settings, chat("1"))
      assert ticket.category == "Tiro amigo"
      assert ticket.priority == :high
    end
  end

  describe "who may call" do
    test "VIPs only refuses a player without VIP and tells them", %{
      server: server,
      settings: settings,
      test_pid: test_pid
    } do
      stub_crcon(test_pid, %{
        "/api/get_player_profile" => %{"vips" => []},
        "/api/get_detailed_players" => %{"players" => %{@player_id => %{"is_vip" => false}}}
      })

      settings = save(settings, %{audience: "vip"})
      assert Tickets.handle_chat(server, settings, chat("!admin help")) == :not_allowed
      assert Enum.any?(sent_messages(), &(&1 =~ "Only VIPs"))
      assert Repo.aggregate(Ticket, :count) == 0
    end

    test "a blocking flag keeps a player out", %{
      server: server,
      settings: settings,
      test_pid: test_pid
    } do
      stub_crcon(test_pid, %{
        "/api/get_player_profile" => %{"flags" => [%{"flag" => "sem_ticket"}]}
      })

      settings = save(settings, %{blocked_flags: ["sem_ticket"]})
      assert Tickets.handle_chat(server, settings, chat("!admin help")) == :not_allowed
    end

    test "outside office hours a server can refuse tickets", %{
      server: server,
      settings: settings
    } do
      # Open on no day at all this week but one hour a year from now: closed.
      day = Date.day_of_week(Date.utc_today())
      other_day = to_string(rem(day, 7) + 1)

      settings =
        save(settings, %{
          hours_enabled: true,
          hours_ranges: %{other_day => [["00:00", "00:01"]]},
          accept_offline: false,
          offline_message: "We are closed"
        })

      assert Tickets.handle_chat(server, settings, chat("!admin help")) == :offline
      assert Enum.any?(sent_messages(), &(&1 == "We are closed"))
    end
  end

  describe "silent tickets" do
    test "the player is warned an hour before, once", %{server: server, settings: settings} do
      settings = save(settings, %{auto_close_hours: 12, warn_before_close: true})
      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin help"))

      earlier = DateTime.add(DateTime.utc_now(:second), -11 * 3600 - 60, :second)
      ticket |> Ecto.Changeset.change(last_activity_at: earlier) |> Repo.update!()
      _ = sent_messages()

      assert Tickets.close_stale() == 0
      assert Enum.any?(sent_messages(), &(&1 =~ "closes in 1 hour"))

      assert Tickets.close_stale() == 0
      assert sent_messages() == []
      assert Repo.reload!(ticket).status == :open
    end
  end

  describe "the reported player" do
    test "is the one who team killed the caller before the call", %{
      server: server,
      settings: settings
    } do
      now = DateTime.utc_now()

      tk = %Event{
        type: :player_team_kill,
        action: "TEAM KILL",
        occurred_at: DateTime.add(now, -30, :second),
        player_id: "p9",
        player_name: "Rudi_88",
        target_player_id: @player_id,
        target_player_name: "Sarge",
        weapon: "75MM CANNON"
      }

      call = chat("!admin he keeps killing us", %{occurred_at: now})
      {:opened, ticket} = Tickets.handle_chat(server, settings, call, recent: [tk, call])

      assert ticket.reported_player_id == "p9"
      assert ticket.reported_player_name == "Rudi_88"
    end

    test "older tickets work it out from the names in their context", %{
      server: server,
      settings: settings
    } do
      # Rudi called once himself, so his id is known.
      {:opened, _rudi} =
        Tickets.handle_chat(
          server,
          settings,
          chat("!admin hi", %{player_id: "p9", player_name: "Rudi_88"})
        )

      {:opened, ticket} = Tickets.handle_chat(server, settings, chat("!admin é o Rudi"))

      ticket =
        ticket
        |> Ecto.Changeset.change(
          context: [%{"kind" => "team_kill", "text" => "Rudi_88 team killed Sarge (M1)"}]
        )
        |> Repo.update!()
        |> Repo.preload(:messages)

      assert %{reported_player_id: "p9"} = Tickets.infer_reported(ticket)
    end
  end

  describe "numbers" do
    test "the metrics page counts days, answers, categories and callers", %{
      server: server,
      settings: settings
    } do
      admin = user_fixture(%{name: "Ana"})
      settings = save(settings, %{category_priorities: %{"tk" => "high"}})

      {:opened, one} = Tickets.handle_chat(server, settings, chat("!admin tk bridge"))

      {:opened, two} =
        Tickets.handle_chat(
          server,
          settings,
          chat("!admin help", %{player_id: "p2", player_name: "Bia"})
        )

      {:ok, _} = Tickets.set_reported(one, "p9", "Rudi_88")
      {:ok, _} = Tickets.set_reported(two, "p9", "Rudi_88")

      opened = DateTime.add(DateTime.utc_now(:second), -200, :second)
      one |> Ecto.Changeset.change(inserted_at: opened) |> Repo.update!()

      {:ok, _message} =
        Tickets.reply(Repo.reload!(one), admin, "On my way", quick_reply: "Looking")

      metrics = Stats.metrics(admin, days: 7, server_ids: [server.id], timezone: "Etc/UTC")

      assert metrics.total == 2
      assert length(metrics.per_day) == 7
      assert metrics.per_day |> List.last() |> elem(1) == 2
      assert metrics.first_response.count == 1
      assert {:from_3_to_5, 1} in metrics.first_response.buckets
      assert [%{name: "Ana", count: 1}] = metrics.responders
      assert {"tk", 1} in metrics.categories
      assert %{name: "Rudi_88", tickets: 2, callers: 2} = metrics.most_cited
      assert Enum.map(metrics.top_players, & &1.name) |> Enum.sort() == ["Bia", "Sarge"]

      assert Stats.reply_uses(server.id) == %{"Looking" => 1}
      assert Stats.category_counts_this_month(server.id, "Etc/UTC") == %{"tk" => 1}
      assert %{resolved: 0, median_response: seconds} = Stats.today(admin, [server.id], "Etc/UTC")
      assert seconds >= 200

      assert [%Message{quick_reply: "Looking"}] =
               Repo.all(from m in Message, where: m.author == :admin)
    end
  end
end
