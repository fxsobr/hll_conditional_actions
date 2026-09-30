defmodule HllConditionalActionsWeb.PlayerListTest do
  @moduledoc """
  Jogadores: the list of every player the install knows - what the app
  recorded joined with CRCON's player history - with the live filters
  (online, VIP, watchlist) read once per server.
  """

  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Progression.PlayerTotal
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules

  @moduletag :capture_log

  doctest HllConditionalActions.Players
  doctest HllConditionalActions.Players.Directory
  doctest HllConditionalActions.Players.Actions

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: conn |> init_test_session(%{}) |> Plug.Conn.put_session(:user_id, user.id)}
  end

  defp total(server, player_id, name, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        PlayerTotal,
        Map.merge(
          %{
            server_id: server.id,
            player_id: player_id,
            player_name: name,
            matches: 4,
            kills: 40,
            deaths: 20,
            playtime_seconds: 4 * 3600
          },
          attrs
        )
      )
    )
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

  # A CRCON that knows one online player (Sarge, on the Axis), one VIP
  # (Rookie) and one watched player (Ghost, known only to CRCON).
  defp stub_crcon(test_pid \\ nil) do
    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      if test_pid, do: send(test_pid, {:crcon, conn.request_path})

      result =
        case conn.request_path do
          "/api/get_detailed_players" ->
            %{
              "players" => %{
                "76561190000000011" => %{
                  "player_id" => "76561190000000011",
                  "name" => "Sarge",
                  "team" => "axis",
                  "level" => 112,
                  "kills" => 12,
                  "profile" => %{
                    "sessions_count" => 188,
                    "total_playtime_seconds" => 312 * 3600,
                    "penalty_count" => %{"KICK" => 2, "PUNISH" => 5},
                    "flags" => [%{"flag" => "🌱", "comment" => "Seeder"}]
                  }
                }
              }
            }

          "/api/get_vip_ids" ->
            [%{"player_id" => "76561190000000022", "name" => "Rookie", "vip_expiration" => nil}]

          "/api/get_players_history" ->
            %{
              "players" => [
                %{
                  "player_id" => "76561190000000033",
                  "names" => [%{"name" => "Ghost"}],
                  "sessions_count" => 3,
                  "watchlist" => %{"is_watched" => true, "reason" => "TK", "by" => "Ana"}
                }
              ]
            }

          _other ->
            []
        end

      Req.Test.json(conn, %{"result" => result, "failed" => false, "error" => nil})
    end)
  end

  describe "the list" do
    test "joins match totals and rule hits into one row per player", %{conn: conn} do
      server = server_fixture()
      total(server, "76561190000000011", "Sarge")
      hit(server, "76561190000000011", "Sarge")
      hit(server, "76561190000000022", "Rookie")

      {:ok, view, _html} = live(conn, ~p"/players")

      assert has_element?(view, "#players-76561190000000011", "Sarge")
      assert has_element?(view, "#players-76561190000000022", "Rookie")
      assert has_element?(view, ~s|#players-76561190000000011[href="/players/76561190000000011"]|)
      assert has_element?(view, "#player-filter-all", "2")
      assert has_element?(view, "#player-filter-menu-matches", "1")
      assert has_element?(view, "#player-filter-menu-rules", "2")
    end

    test "searches by name and by player ID", %{conn: conn} do
      server = server_fixture()
      total(server, "76561190000000011", "Sarge")
      total(server, "76561190000000022", "Rookie")

      {:ok, view, _html} = live(conn, ~p"/players")

      view |> element("#player-search") |> render_change(%{"q" => "sar"})

      assert has_element?(view, "#players-76561190000000011")
      refute has_element?(view, "#players-76561190000000022")

      {:ok, view, _html} = live(conn, ~p"/players?q=76561190000000022")

      assert has_element?(view, "#players-76561190000000022")
      refute has_element?(view, "#players-76561190000000011")
    end

    test "a filter from the + Filter menu narrows the list", %{conn: conn} do
      server = server_fixture()
      total(server, "76561190000000011", "Sarge")
      hit(server, "76561190000000022", "Rookie")

      {:ok, view, _html} = live(conn, ~p"/players")

      view |> element("#player-filter-menu-rules") |> render_click()

      assert_patch(view, ~p"/players?filter=rules")
      assert has_element?(view, "#player-filter-rules[aria-current=true]")
      assert has_element?(view, "#players-76561190000000022")
      refute has_element?(view, "#players-76561190000000011")
    end

    test "sorts by another column", %{conn: conn} do
      server = server_fixture()
      total(server, "76561190000000011", "Sarge", %{playtime_seconds: 3600})
      total(server, "76561190000000022", "Rookie", %{playtime_seconds: 90 * 3600})

      {:ok, view, _html} = live(conn, ~p"/players")
      view |> element("#player-sort-playtime") |> render_click()

      assert_patch(view, ~p"/players?sort=playtime")
      html = view |> element("#players") |> render()
      assert :binary.match(html, "Rookie") < :binary.match(html, "Sarge")
    end

    test "a search with no match says so", %{conn: conn} do
      server = server_fixture()
      total(server, "76561190000000011", "Sarge")

      {:ok, view, _html} = live(conn, ~p"/players?q=nobody")

      assert has_element?(view, "#players-empty")
      refute has_element?(view, "#players-76561190000000011")
    end

    test "only shows players of the servers the user may see", %{conn: conn} do
      mine = server_fixture()
      other = server_fixture()
      total(mine, "76561190000000011", "Sarge")
      total(other, "76561190000000022", "Stranger")

      user = user_fixture()
      {:ok, _user} = HllConditionalActions.Accounts.set_user_servers(user, [mine.id])

      conn = Plug.Conn.put_session(conn, :user_id, user.id)
      {:ok, view, _html} = live(conn, ~p"/players")

      assert has_element?(view, "#players-76561190000000011")
      refute has_element?(view, "#players-76561190000000022")
    end

    test "with nobody recorded it explains where players come from", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/players")

      refute has_element?(view, "#player-list")
    end
  end

  describe "what CRCON knows" do
    test "online, VIP and watchlist come from one read per server", %{conn: conn} do
      stub_crcon(self())
      server = server_fixture()
      total(server, "76561190000000011", "Sarge")
      total(server, "76561190000000022", "Rookie")

      {:ok, view, _html} = live(conn, ~p"/players")
      render_async(view)

      # The watched player CRCON told about is in the directory now.
      assert has_element?(view, "#players-76561190000000033", "Ghost")

      # The online player: team, level, CRCON's sessions and penalties, marks.
      row = "#players-76561190000000011"
      # No log stream in a test: the row says where they are, not the team.
      assert has_element?(view, row, "no stream")
      assert has_element?(view, row, "112")
      assert has_element?(view, row, "188")
      assert has_element?(view, row, "312 h")
      assert has_element?(view, "#{row} .players-col-penalties", "7")
      assert has_element?(view, row, "Seeder")

      assert has_element?(view, "#player-filter-online", "1")
      assert has_element?(view, "#player-filter-vip", "1")
      assert has_element?(view, "#player-filter-watchlist", "1")
      assert has_element?(view, "#player-filter-penalties", "1")

      view |> element("#player-filter-vip") |> render_click()
      assert has_element?(view, "#players-76561190000000022")
      refute has_element?(view, "#players-76561190000000011")

      view |> element("#player-filter-watchlist") |> render_click()
      assert has_element?(view, "#players-76561190000000033")
      refute has_element?(view, "#players-76561190000000022")

      # One call per list and server, not one per player.
      calls = collect_calls()
      assert Enum.count(calls, &(&1 == "/api/get_detailed_players")) == 1
      assert Enum.count(calls, &(&1 == "/api/get_vip_ids")) == 1
      refute "/api/get_player_profile" in calls
    end

    test "exports the list as CSV", %{conn: conn} do
      stub_crcon()
      server = server_fixture()
      total(server, "76561190000000011", "Sarge")
      total(server, "76561190000000044", "=Evil")

      {:ok, view, _html} = live(conn, ~p"/players")
      render_async(view)

      view |> element("#players-export") |> render_click()

      assert_push_event(view, "players:csv", %{filename: "players-" <> _, content: csv})
      assert csv =~ "player_id,name,online_on"
      assert csv =~ "76561190000000011,Sarge,"
      # A name that starts like a formula is defused.
      assert csv =~ "'=Evil"
    end
  end

  defp collect_calls(acc \\ []) do
    receive do
      {:crcon, path} -> collect_calls([path | acc])
    after
      0 -> acc
    end
  end
end
