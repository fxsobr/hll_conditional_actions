defmodule HllConditionalActionsWeb.ServerCockpitTest do
  # The live snapshot, the match's facts and the recent log are fetched from
  # tasks, so the CRCON stub must be visible outside the test process.
  use HllConditionalActionsWeb.ConnCase, async: false

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Crcon.Events
  alias HllConditionalActions.LiveFeed
  alias HllConditionalActions.Rules

  @kill_message "Chris(Allies/76561190000000001) -> Muctar(Axis/76561190000000002) with M1 GARAND"

  setup %{conn: conn} = context do
    Req.Test.set_req_test_to_shared(context)
    stub_crcon()

    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, server: server_fixture(%{name: "EU #1"})}
  end

  # A CRCON answering the cockpit's reads; `logs` is what get_recent_logs
  # returns, `started` the start of the current map.
  defp stub_crcon(opts \\ []) do
    logs = Keyword.get(opts, :logs, [])
    started = Keyword.get(opts, :started, DateTime.add(DateTime.utc_now(), -3600))
    test = self()

    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      result =
        case conn.request_path do
          "/api/get_detailed_players" ->
            %{
              "players" => %{
                "1" => player(%{"player_id" => "1", "name" => "Sharpshooter", "kills" => 42}),
                "2" =>
                  player(%{
                    "player_id" => "2",
                    "name" => "Medic",
                    "team" => "axis",
                    "support" => 900
                  })
              },
              "fail_count" => 0
            }

          "/api/get_gamestate" ->
            gamestate(%{"allied_score" => 3, "axis_score" => 2})

          "/api/get_public_info" ->
            %{
              "current_map" => %{"start" => DateTime.to_unix(started)},
              "max_player_count" => 100
            }

          "/api/get_recent_logs" ->
            %{"logs" => logs}

          "/api/message_all_players" ->
            {:ok, body, _conn} = Plug.Conn.read_body(conn)
            send(test, {:message_all_players, Jason.decode!(body)})
            true

          _other ->
            true
        end

      Req.Test.json(conn, %{"result" => result, "failed" => false, "error" => nil})
    end)
  end

  test "opens on the live match, then the feed, the match's best and the rules", %{
    conn: conn,
    server: server
  } do
    rule = rule_fixture(%{name: "Welcome", server_id: server.id})
    execute(rule, server)

    {:ok, view, _html} = live(conn, ~p"/servers/#{server}")
    render_async(view)

    assert has_element?(view, "#cockpit-live", "Carentan")
    assert has_element?(view, "#cockpit-live", "3")
    assert has_element?(view, "#cockpit-live", "/100")
    assert has_element?(view, "#cockpit-live", "Log stream")
    assert has_element?(view, "#cockpit-board-kills", "Sharpshooter")
    assert has_element?(view, "#cockpit-board-support", "Medic")
    assert has_element?(view, ~s{#cockpit-views a[href="/servers/#{server.id}/leaderboard"]})

    assert has_element?(
             view,
             ~s{#cockpit-views a[href="/servers/#{server.id}/leaderboard?view=squads"]}
           )

    # The rules in this match count what they did since CRCON's start.
    assert has_element?(view, "#cockpit-rule-counts", "Welcome")
    assert has_element?(view, "#cockpit-rules", "1")
  end

  test "says when the match started, in the server's time zone", %{conn: conn} do
    server = server_fixture(%{timezone: "America/Sao_Paulo"})
    stub_crcon(started: ~U[2026-09-20 00:02:00Z])

    {:ok, view, _html} = live(conn, ~p"/servers/#{server}")
    render_async(view)

    assert has_element?(view, "#cockpit-live", "started at 21:02")
  end

  describe "the feed" do
    test "shows the server's events with the players in their team's colour", %{
      conn: conn,
      server: server
    } do
      {:ok, view, _html} = live(conn, ~p"/servers/#{server}")
      render_async(view)

      send(view.pid, {:crcon_event, kill(server)})

      assert has_element?(view, "#cockpit-feed-rows .text-allies", "Chris")
      assert has_element?(view, "#cockpit-feed-rows .text-axis", "Muctar")
      assert has_element?(view, "#cockpit-feed-rows", "M1 GARAND")
    end

    test "opens on the last lines of the log, with the rule that acted on them", %{
      conn: conn,
      server: server
    } do
      line = log_line(%{"message" => @kill_message, "timestamp_ms" => now_ms()})
      stub_crcon(logs: [line])

      rule = rule_fixture(%{name: "Friendly fire", server_id: server.id, simulation: true})
      event = Events.from_log(line, server)
      execution = execute(rule, server, event: event, status: :simulated)

      {:ok, view, _html} = live(conn, ~p"/servers/#{server}")
      render_async(view)

      row = "#cockpit-feed-rows #ev-#{LiveFeed.event_key(event)}"
      assert has_element?(view, row, "Muctar")
      assert has_element?(view, ~s{#{row} a[href="/rules/#{rule.id}"]}, "Friendly fire")
      # The execution sits on its line, not on a line of its own.
      refute has_element?(view, "#execution-#{execution.id}")
    end

    test "puts a rule that fires on the line that made it fire", %{conn: conn, server: server} do
      rule = rule_fixture(%{name: "Kill feed", server_id: server.id, trigger_event: :player_kill})

      {:ok, view, _html} = live(conn, ~p"/servers/#{server}")
      render_async(view)

      event = kill(server)
      send(view.pid, {:crcon_event, event})
      send(view.pid, {:rule_fired, execute(rule, server, event: event)})

      assert has_element?(
               view,
               ~s{#ev-#{LiveFeed.event_key(event)} a[href="/rules/#{rule.id}"]},
               "Kill feed"
             )
    end

    test "names the rule that acted where no line started it, and opens it", %{
      conn: conn,
      server: server
    } do
      rule = rule_fixture(%{name: "Welcome", server_id: server.id})
      execution = execute(rule, server)

      {:ok, view, _html} = live(conn, ~p"/servers/#{server}")
      render_async(view)

      assert has_element?(view, "#cockpit-feed-rows #execution-#{execution.id}", "Tavares")

      assert has_element?(
               view,
               ~s{#execution-#{execution.id} a[href="/rules/#{rule.id}"]},
               "Welcome"
             )
    end

    test "narrows to kills, chat, or where rules acted", %{conn: conn, server: server} do
      rule = rule_fixture(%{name: "Kill feed", server_id: server.id, trigger_event: :player_kill})

      {:ok, view, _html} = live(conn, ~p"/servers/#{server}")
      render_async(view)

      acted = kill(server)
      plain = kill(server, 1_000)
      send(view.pid, {:crcon_event, chat(server)})
      send(view.pid, {:crcon_event, plain})
      send(view.pid, {:crcon_event, acted})
      send(view.pid, {:rule_fired, execute(rule, server, event: acted)})

      view |> element("#feed-chip-acted") |> render_click()
      assert has_element?(view, "#ev-#{LiveFeed.event_key(acted)}")
      refute has_element?(view, "#ev-#{LiveFeed.event_key(plain)}")
      refute has_element?(view, "#cockpit-feed-rows", "anyone on the hill?")

      view |> element("#feed-chip-chat") |> render_click()
      assert has_element?(view, "#cockpit-feed-rows", "anyone on the hill?")
      refute has_element?(view, "#cockpit-feed-rows", "Muctar")

      view |> element("#feed-chip-kills") |> render_click()
      assert has_element?(view, "#ev-#{LiveFeed.event_key(plain)}")
      refute has_element?(view, "#cockpit-feed-rows", "anyone on the hill?")

      view |> element("#feed-chip-all") |> render_click()
      assert has_element?(view, "#cockpit-feed-rows", "anyone on the hill?")
      assert has_element?(view, "#ev-#{LiveFeed.event_key(plain)}")
    end

    test "holds new lines while paused and shows them on resume", %{
      conn: conn,
      server: server
    } do
      {:ok, view, _html} = live(conn, ~p"/servers/#{server}")
      render_async(view)

      view |> element("#cockpit-feed-filters-pause") |> render_click()
      send(view.pid, {:crcon_event, kill(server)})
      refute has_element?(view, "#cockpit-feed-rows", "Muctar")

      view |> element("#cockpit-feed-filters-pause") |> render_click()
      assert has_element?(view, "#cockpit-feed-rows", "Muctar")
    end

    test "is the rules' activity alone without the live feed module", %{conn: conn} do
      server = server_fixture(%{features: [:rules, :stats]})

      {:ok, view, _html} = live(conn, ~p"/servers/#{server}")
      render_async(view)

      refute has_element?(view, "#cockpit-feed-filters-pause")
      send(view.pid, {:crcon_event, kill(server)})
      refute has_element?(view, "#cockpit-feed-rows", "Muctar")
    end
  end

  test "sends a message to every player", %{conn: conn, server: server} do
    {:ok, view, _html} = live(conn, ~p"/servers/#{server}")
    render_async(view)

    view |> element("#cockpit-message") |> render_click()
    assert has_element?(view, "#broadcast-form")

    view
    |> form("#broadcast-form", message: %{text: "Seeding night, be nice"})
    |> render_submit()

    render_async(view)
    assert_received {:message_all_players, %{"message" => "Seeding night, be nice"}}
    refute has_element?(view, "#broadcast-form")
  end

  describe "the live feed page" do
    test "draws each event as a line of the feed", %{conn: conn, server: server} do
      {:ok, view, _html} = live(conn, ~p"/servers/#{server}/feed")
      render_async(view)

      send(view.pid, {:crcon_event, kill(server)})

      assert has_element?(view, "#feed .text-allies", "Chris")
      assert has_element?(view, "#feed", "M1 GARAND")

      view |> element("#feed-clear") |> render_click()
      refute has_element?(view, "#feed", "Chris")
    end

    test "puts the rule on its line and narrows to where rules acted", %{
      conn: conn,
      server: server
    } do
      rule = rule_fixture(%{name: "Kill feed", server_id: server.id, trigger_event: :player_kill})

      {:ok, view, _html} = live(conn, ~p"/servers/#{server}/feed")
      render_async(view)

      acted = kill(server)
      send(view.pid, {:crcon_event, chat(server)})
      send(view.pid, {:crcon_event, acted})
      send(view.pid, {:rule_fired, execute(rule, server, event: acted)})

      assert has_element?(view, ~s{#ev-#{LiveFeed.event_key(acted)} a[href="/rules/#{rule.id}"]})

      view |> element("#feed-chip-acted") |> render_click()
      refute has_element?(view, "#feed", "anyone on the hill?")
      assert has_element?(view, "#ev-#{LiveFeed.event_key(acted)}")
    end
  end

  test "names the teams after the server's game", %{conn: conn} do
    server = server_fixture(%{name: "VN #1", game: :hllv})

    {:ok, view, _html} = live(conn, ~p"/servers/#{server}")
    render_async(view)

    assert has_element?(view, "#cockpit-live", "Allies (US)")
    assert has_element?(view, "#cockpit-live", "NVA")

    # Vietnam counts its crewed helicopters where WW2 shows the queue
    # (Vietnam board); nobody flies in this match.
    assert has_element?(view, "#cockpit-live", "Helicopters crewed")
    refute has_element?(view, "#cockpit-live", "In queue")
  end

  test "on a phone the header is the server in scope, without the page's buttons", %{
    conn: conn,
    server: server
  } do
    {:ok, view, _html} = live(conn, ~p"/servers/#{server}")

    assert has_element?(view, "#header-scope-phone", "EU #1")
    assert has_element?(view, ~s{[class*="max-md:hidden"] > #cockpit-message})
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp now_ms, do: System.system_time(:millisecond)

  # A kill line as CRCON writes it, with both players' teams.
  defp kill(server, offset_ms \\ 0) do
    %{"message" => @kill_message, "timestamp_ms" => now_ms() - offset_ms}
    |> log_line()
    |> Events.from_log(server)
  end

  defp chat(server) do
    %{
      "action" => "CHAT[Allies][Team]",
      "message" => "anyone on the hill?",
      "sub_content" => "anyone on the hill?",
      "player_name_2" => nil,
      "player_id_2" => nil,
      "timestamp_ms" => now_ms() - 2_000
    }
    |> log_line()
    |> Events.from_log(server)
  end

  # An execution as the engine records it, linked to its line when there is
  # one.
  defp execute(rule, server, opts \\ []) do
    event = Keyword.get(opts, :event)
    key = LiveFeed.event_key(event)

    {:ok, execution} =
      Rules.record_execution(%{
        rule_id: rule.id,
        server_id: server.id,
        player_id: "76561190000000001",
        player_name: "Tavares",
        trigger_event: to_string(rule.trigger_event),
        status: Keyword.get(opts, :status, :executed),
        results: [%{"type" => "message_player", "status" => "ok", "detail" => nil}],
        trace: if(key, do: %{"event_key" => key}, else: %{})
      })

    execution
  end
end
