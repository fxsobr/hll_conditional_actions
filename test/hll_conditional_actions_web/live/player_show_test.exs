defmodule HllConditionalActionsWeb.PlayerShowTest do
  @moduledoc """
  The player 360: identity, numbers, timeline, the last 10 matches read from
  CRCON's match history, and the actions on the player - always against a
  `Req.Test` stub, never a real CRCON.
  """

  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Players.MatchStat
  alias HllConditionalActions.Progression.PlayerTotal
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules

  @moduletag :capture_log

  @sarge "76561190000000011"

  setup %{conn: conn} do
    user = user_fixture()
    test_pid = self()

    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:crcon, conn.request_path, body})

      result =
        case conn.request_path do
          "/api/get_detailed_players" ->
            %{
              "players" => %{
                @sarge => %{
                  "player_id" => @sarge,
                  "name" => "Sarge",
                  "team" => "axis",
                  "role" => "crewman",
                  "level" => 112,
                  "kills" => 9,
                  "team_kills" => 3,
                  "platform" => "steam"
                }
              }
            }

          "/api/get_player_profile" ->
            %{
              "player_id" => @sarge,
              "names" => [%{"name" => "Sarge"}],
              "sessions_count" => 188,
              "total_playtime_seconds" => 312 * 3600,
              "penalty_count" => %{"KICK" => 2, "TEMPBAN" => 1, "PUNISH" => 4},
              "received_actions" => [
                %{
                  "action_type" => "TEMPBAN",
                  "reason" => "TK on purpose",
                  "by" => "Ana",
                  "time" => "2026-09-21T20:00:00Z"
                }
              ],
              "watchlist" => %{"is_watched" => true, "reason" => "TK", "by" => "Ana"},
              "vips" => [%{"server_number" => 1, "expiration" => "2026-10-12T00:00:00Z"}]
            }

          "/api/get_vip_ids" ->
            [
              %{
                "player_id" => @sarge,
                "name" => "Sarge",
                "vip_expiration" => "2026-10-12T00:00:00Z"
              }
            ]

          "/api/get_scoreboard_maps" ->
            %{
              "maps" => [
                %{
                  "id" => 501,
                  "start" => "2026-09-29T20:00:00Z",
                  "end" => "2026-09-29T21:30:00Z",
                  "map" => %{"pretty_name" => "Carentan", "game_mode" => "warfare"}
                }
              ]
            }

          "/api/get_map_scoreboard" ->
            %{
              "id" => 501,
              "start" => "2026-09-29T20:00:00Z",
              "end" => "2026-09-29T21:30:00Z",
              "map" => %{"pretty_name" => "Carentan", "game_mode" => "warfare"},
              "player_stats" => [
                %{
                  "player_id" => @sarge,
                  "player" => "Sarge",
                  "kills" => 24,
                  "deaths" => 10,
                  "teamkills" => 2,
                  "time_seconds" => 5000,
                  "level" => 111
                }
              ]
            }

          "/api/get_players_history" ->
            %{"players" => []}

          _action ->
            "SUCCESS"
        end

      Req.Test.json(conn, %{"result" => result, "failed" => false, "error" => nil})
    end)

    %{
      conn: conn |> init_test_session(%{}) |> Plug.Conn.put_session(:user_id, user.id),
      user: user
    }
  end

  defp total(server, player_id, name) do
    Repo.insert!(%PlayerTotal{
      server_id: server.id,
      player_id: player_id,
      player_name: name,
      matches: 4,
      kills: 40,
      deaths: 20,
      playtime_seconds: 4 * 3600
    })
  end

  defp hit(server, player_id, name) do
    rule = rule_fixture(%{server_id: server.id})

    {:ok, execution} =
      Rules.record_execution(%{
        rule_id: rule.id,
        server_id: server.id,
        player_id: player_id,
        player_name: name,
        trigger_event: "player_connected",
        status: :executed,
        results: [%{"type" => "message_player", "status" => "ok", "detail" => "Welcome!"}]
      })

    {rule, execution}
  end

  defp calls(acc \\ []) do
    receive do
      {:crcon, path, body} -> calls([{path, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "the page" do
    test "shows who they are, their numbers and what happened to them", %{conn: conn} do
      server = server_fixture()
      total(server, @sarge, "Sarge")
      {rule, execution} = hit(server, @sarge, "Sarge")

      {:ok, view, _html} = live(conn, ~p"/players/#{@sarge}")
      render_async(view)

      assert has_element?(view, "#player-name", "Sarge")
      assert has_element?(view, "#player-hero", "Playing on")
      assert has_element?(view, "#player-hero", "Tank crewman")
      assert has_element?(view, "#player-hero", "Level 112")
      assert has_element?(view, "#player-hero", "VIP until")
      assert has_element?(view, "#player-hero", "Watchlist")

      assert has_element?(view, "#player-kpis", "312 h")
      assert has_element?(view, "#player-kpis", "188 sessions")
      assert has_element?(view, "#player-kpis", "1 ban, 2 kicks")

      assert has_element?(view, "#player-rules", rule.name)
      assert has_element?(view, "#timeline-execution-#{execution.id}")
      assert has_element?(view, "#timeline-penalty-0", "Banned for a while by Ana")

      view |> element("#timeline-execution-#{execution.id} button") |> render_click()
      assert has_element?(view, "#execution-#{execution.id}-results")

      view |> element("#timeline-filter-penalties") |> render_click()
      refute has_element?(view, "#timeline-execution-#{execution.id}")
      assert has_element?(view, "#timeline-penalty-0")
    end

    test "runs of the same rule in a row read as one timeline line", %{conn: conn} do
      server = server_fixture()
      rule = rule_fixture(%{server_id: server.id})
      other = rule_fixture(%{server_id: server.id})
      now = DateTime.utc_now()

      record = fn rule, minutes_ago ->
        {:ok, execution} =
          Rules.record_execution(%{
            rule_id: rule.id,
            server_id: server.id,
            player_id: @sarge,
            player_name: "Sarge",
            trigger_event: "player_connected",
            status: :executed,
            executed_at: DateTime.add(now, -minutes_ago * 60, :second)
          })

        execution
      end

      newest = record.(rule, 1)
      middle = record.(rule, 3)
      oldest = record.(rule, 5)
      lone = record.(other, 2)

      {:ok, view, _html} = live(conn, ~p"/players/#{@sarge}")
      render_async(view)

      assert has_element?(view, "#timeline-execution-#{newest.id}")
      assert has_element?(view, "#execution-#{newest.id}-runs", "×3")
      refute has_element?(view, "#timeline-execution-#{middle.id}")
      refute has_element?(view, "#timeline-execution-#{oldest.id}")

      assert has_element?(view, "#timeline-execution-#{lone.id}")
      refute has_element?(view, "#execution-#{lone.id}-runs")
    end

    test "reads the last matches from CRCON's match history once", %{conn: conn} do
      server = server_fixture()
      total(server, @sarge, "Sarge")

      {:ok, view, _html} = live(conn, ~p"/players/#{@sarge}")
      render_async(view)

      assert [%MatchStat{kills: 24, team_kills: 2, map: "Carentan"}] =
               Repo.all(MatchStat)

      # Online now: the finished match and the one being played.
      assert has_element?(view, "#player-match-live")
      assert has_element?(view, "#player-kpis", "2.40")
      assert has_element?(view, "#player-kpis", "24 kills per match")

      {:ok, view, _html} = live(conn, ~p"/players/#{@sarge}?tab=matches")
      render_async(view)
      assert has_element?(view, "#player-match-list", "Carentan")
      assert Repo.aggregate(MatchStat, :count) == 1
    end

    test "the history tab lists every run", %{conn: conn} do
      server = server_fixture()
      {_rule, execution} = hit(server, @sarge, "Sarge")

      {:ok, view, _html} = live(conn, ~p"/players/#{@sarge}?tab=executions")
      render_async(view)

      assert has_element?(view, "#player-executions")
      assert has_element?(view, "#player-row-#{execution.id}")
    end

    test "a player nobody knows gets an explanation", %{conn: conn} do
      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        Req.Test.json(conn, %{"result" => nil, "failed" => true, "error" => "not found"})
      end)

      {:ok, view, _html} = live(conn, ~p"/players/76561199999999999")
      render_async(view)

      assert render(view) =~ "Nothing recorded for this player"
    end
  end

  describe "actions" do
    test "a ban asks for the name, then bans on the server they play on", %{conn: conn} do
      server = server_fixture()
      total(server, @sarge, "Sarge")

      {:ok, view, _html} = live(conn, ~p"/players/#{@sarge}")
      render_async(view)
      calls()

      view |> element("#player-more-ban") |> render_click()
      assert has_element?(view, "#player-action-dialog")

      view |> element("#player-ban-6") |> render_click()

      view
      |> form("#player-action-form", action: %{reason: "TK in the tank", typed: "wrong"})
      |> render_submit()

      refute Enum.any?(calls(), fn {path, _body} -> path == "/api/temp_ban" end)

      view
      |> form("#player-action-form", action: %{reason: "TK in the tank", typed: "Sarge"})
      |> render_submit()

      assert [{"/api/temp_ban", body}] = Enum.filter(calls(), &(elem(&1, 0) == "/api/temp_ban"))

      assert %{"player_id" => @sarge, "duration_hours" => 6, "reason" => reason} =
               Jason.decode!(body)

      assert reason =~ "TK in the tank"
      refute has_element?(view, "#player-action-dialog")
    end

    test "a message goes as written", %{conn: conn} do
      server = server_fixture()
      total(server, @sarge, "Sarge")

      {:ok, view, _html} = live(conn, ~p"/players/#{@sarge}")
      render_async(view)

      view |> element("#player-act-message") |> render_click()
      view |> form("#player-action-form", action: %{reason: "Hi there"}) |> render_submit()

      assert [{"/api/message_player", body}] =
               Enum.filter(calls(), &(elem(&1, 0) == "/api/message_player"))

      assert %{"message" => "Hi there"} = Jason.decode!(body)
    end

    test "?act= from the command palette opens the dialog", %{conn: conn} do
      server = server_fixture()
      total(server, @sarge, "Sarge")

      {:ok, view, _html} = live(conn, ~p"/players/#{@sarge}?act=ban")
      assert has_element?(view, "#player-action-dialog")
      assert has_element?(view, "#player-ban-2[aria-checked=true]")
    end

    test "without the permission there are no actions", %{conn: conn} do
      server = server_fixture()
      total(server, @sarge, "Sarge")

      role = role_fixture(%{permissions: ["view_stats"]})
      viewer = user_fixture(%{role: role})
      conn = Plug.Conn.put_session(conn, :user_id, viewer.id)

      {:ok, view, _html} = live(conn, ~p"/players/#{@sarge}?act=ban")
      render_async(view)

      refute has_element?(view, "#player-actions")
      refute has_element?(view, "#player-action-dialog")
      refute Accounts.can?(Repo.preload(viewer, :role), :manage_players)
    end

    test "answering tickets is not enough to act on a player", %{conn: conn} do
      server = server_fixture()
      total(server, @sarge, "Sarge")

      role = role_fixture(%{permissions: ["view_stats", "manage_tickets"]})
      agent = user_fixture(%{role: role})
      conn = Plug.Conn.put_session(conn, :user_id, agent.id)

      {:ok, view, _html} = live(conn, ~p"/players/#{@sarge}")
      render_async(view)

      refute has_element?(view, "#player-actions")

      # Nor by pushing the event by hand.
      render_hook(view, "action_open", %{"action" => "kick"})
      refute has_element?(view, "#player-action-dialog")

      assert {:error, :forbidden} =
               HllConditionalActions.Players.Actions.run(
                 Repo.preload(agent, [:role, :servers]),
                 server,
                 @sarge,
                 :kick,
                 "TK"
               )
    end

    test "the player permission alone shows the actions", %{conn: conn} do
      server = server_fixture()
      total(server, @sarge, "Sarge")

      role = role_fixture(%{permissions: ["view_stats", "manage_players"]})
      moderator = user_fixture(%{role: role})
      conn = Plug.Conn.put_session(conn, :user_id, moderator.id)

      {:ok, view, _html} = live(conn, ~p"/players/#{@sarge}")
      render_async(view)

      assert has_element?(view, "#player-actions")
      refute Accounts.can?(Repo.preload(moderator, :role), :manage_tickets)
    end
  end
end
