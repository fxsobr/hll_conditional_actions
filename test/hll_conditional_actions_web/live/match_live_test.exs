defmodule HllConditionalActionsWeb.MatchLiveTest do
  # The history is fetched from a task the LiveView starts, so the CRCON stub
  # has to be visible outside the test process.
  use HllConditionalActionsWeb.ConnCase, async: false

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Matches
  alias HllConditionalActions.Rules

  @start "2026-09-20T20:00:00Z"
  @end_ "2026-09-20T21:30:00Z"

  defp match(extra \\ %{}) do
    Map.merge(
      %{
        "id" => 77,
        "start" => @start,
        "end" => @end_,
        "result" => %{"allied" => 3, "axis" => 2},
        "map" => %{
          "game_mode" => "warfare",
          "map" => %{"pretty_name" => "Carentan"}
        },
        "player_stats" => []
      },
      extra
    )
  end

  defp stat(id, name, attrs) do
    Map.merge(
      %{
        "player_id" => id,
        "player" => name,
        "kills" => 0,
        "deaths" => 0,
        "combat" => 0,
        "offense" => 0,
        "defense" => 0,
        "support" => 0,
        "time_seconds" => 3600,
        # As CRCON stores it: numbers, -111 for none.
        "units" => [%{"ts" => 0, "team" => 1, "squad" => 0, "role" => 0}]
      },
      attrs
    )
  end

  setup %{conn: conn} = context do
    Req.Test.set_req_test_to_shared(context)

    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      result =
        case conn.request_path do
          "/api/get_scoreboard_maps" ->
            %{"page" => 1, "page_size" => 20, "total" => 1, "maps" => [match()]}

          "/api/get_map_scoreboard" ->
            match(%{
              "player_stats" => [
                stat("1", "Sharpshooter", %{"kills" => 40, "combat" => 900}),
                stat("2", "Medic", %{
                  "kills" => 4,
                  "support" => 1500,
                  "units" => [%{"ts" => 10, "team" => 2, "squad" => 1, "role" => 3}]
                })
              ]
            })

          _other ->
            true
        end

      Req.Test.json(conn, %{"result" => result, "failed" => false, "error" => nil})
    end)

    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, server: server_fixture(%{name: "EU #1"})}
  end

  test "a match's stats become a roster the leaderboards read" do
    roster =
      Matches.roster([
        stat("2", "Medic", %{
          "units" => [
            %{"ts" => 0, "team" => 1, "squad" => 0, "role" => 0},
            %{"ts" => 60, "team" => 2, "squad" => 1, "role" => 3}
          ]
        }),
        stat("3", "Tanker", %{"units" => [%{"ts" => 0, "team" => 1, "squad" => 7, "role" => 12}]}),
        stat("4", "Idle", %{
          "units" => [%{"ts" => 0, "team" => -111, "squad" => -111, "role" => -111}]
        })
      ])

    # The last unit wins: that is where the player ended the match.
    assert %{"team" => "axis", "unit_name" => "baker", "role" => "medic"} = roster["2"]
    assert %{"unit_name" => "how", "role" => "tankcommander"} = roster["3"]
    assert %{"unit_name" => nil, "role" => nil} = roster["4"]
  end

  test "Vietnam numbers its roles its own way" do
    roster =
      Matches.roster(
        [
          stat("1", "Cmd", %{"units" => [%{"ts" => 0, "team" => 1, "squad" => -1, "role" => 20}]})
        ],
        :hllv
      )

    assert %{"unit_name" => "command", "role" => "armycommander"} = roster["1"]
  end

  test "lists the server's matches with their result", %{conn: conn, server: server} do
    {:ok, view, _html} = live(conn, ~p"/servers/#{server}/matches")
    render_async(view)

    assert has_element?(view, "#match-#{server.id}-77", "Carentan")
    assert has_element?(view, "#match-#{server.id}-77", "Allies won")
    assert has_element?(view, "#matches-summary", "1")
    assert has_element?(view, "#matches-by-map", "Carentan")

    # The players of the matches on screen come in afterwards.
    render_async(view)
    assert has_element?(view, "#match-#{server.id}-77", "2 players")
  end

  test "all servers at once, and exporting the list", %{conn: conn, server: server} do
    other = server_fixture(%{name: "EU #2"})
    {:ok, view, _html} = live(conn, ~p"/matches")
    render_async(view)

    assert has_element?(view, "#match-servers", "All servers")
    assert has_element?(view, "#match-servers", other.name)
    assert has_element?(view, "#match-servers", server.name)

    view |> element("#matches-export") |> render_click()
    assert_push_event(view, "download_csv", %{content: csv})
    assert csv =~ "Carentan"
  end

  test "the report ranks the match and shows what the rules did", %{conn: conn, server: server} do
    rule = rule_fixture(%{name: "Welcome", server_id: server.id})

    {:ok, _execution} =
      Rules.record_execution(%{
        rule_id: rule.id,
        server_id: server.id,
        player_id: "1",
        player_name: "Sharpshooter",
        trigger_event: "player_connected",
        status: :executed,
        executed_at: ~U[2026-09-20 20:12:00Z]
      })

    {:ok, view, _html} = live(conn, ~p"/servers/#{server}/matches/77")
    render_async(view)

    assert has_element?(view, "#match-mvp", "Medic")
    assert has_element?(view, "#match-hero", "Carentan")
    assert has_element?(view, "#match-board-kills", "Sharpshooter")
    assert has_element?(view, "#match-squads", "Baker")
    assert has_element?(view, "#match-rules", "Welcome")
    assert has_element?(view, "#match-scoreboard", "Sharpshooter")

    view |> element("#scoreboard-teams button", "Axis") |> render_click()
    assert has_element?(view, "#match-scoreboard", "Medic")
    refute has_element?(view, "#match-scoreboard a", "Sharpshooter")

    view |> element("#match-export") |> render_click()
    assert_push_event(view, "download_csv", %{filename: "match-77.csv"})
  end
end
