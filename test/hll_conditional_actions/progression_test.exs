defmodule HllConditionalActions.ProgressionTest do
  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Template
  alias HllConditionalActions.Progression
  alias HllConditionalActions.Progression.PlayerTotal
  alias HllConditionalActions.Repo

  doctest HllConditionalActions.Progression.Metrics

  setup do
    test_pid = self()

    # Every CRCON call is reported back, so a test can say what was sent.
    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:crcon, conn.request_path, body})
      Req.Test.json(conn, %{"result" => true, "failed" => false, "error" => nil})
    end)

    %{server: server_fixture()}
  end

  defp p(id, attrs) do
    player(
      Map.merge(
        %{"player_id" => id, "name" => id, "kills" => 0, "map_playtime_seconds" => 1800},
        attrs
      )
    )
  end

  defp players(list), do: Map.new(list, &{&1["player_id"], &1})

  defp achievement(server, attrs) do
    {:ok, achievement} =
      Progression.create_achievement(
        Map.merge(
          %{
            server_id: server.id,
            name: "Sharpshooter",
            scope: :match,
            metric: :kills,
            threshold: 20
          },
          attrs
        )
      )

    achievement
  end

  describe "a match end" do
    test "adds every player who played to their totals", %{server: server} do
      Progression.record_match(
        server,
        players([
          p("ana", %{"kills" => 12, "support" => 300}),
          p("late", %{"kills" => 1, "map_playtime_seconds" => 60})
        ])
      )

      Progression.record_match(server, players([p("ana", %{"kills" => 8})]))

      # The fixture player carries 40 support of their own in each match.
      assert %PlayerTotal{matches: 2, kills: 20, support: 340} =
               Repo.get_by(PlayerTotal, server_id: server.id, player_id: "ana")

      # A minute at the end of a match does not count as playing it.
      refute Repo.get_by(PlayerTotal, server_id: server.id, player_id: "late")
    end

    test "counts commanding and leading a squad", %{server: server} do
      Progression.record_match(
        server,
        players([
          p("cmd", %{"role" => "armycommander"}),
          p("sl", %{"role" => "officer"}),
          p("short", %{"role" => "officer", "map_playtime_seconds" => 600})
        ])
      )

      assert %{commander_matches: 1} = Repo.get_by(PlayerTotal, player_id: "cmd")
      assert %{leader_matches: 1} = Repo.get_by(PlayerTotal, player_id: "sl")
      assert %{leader_matches: 0} = Repo.get_by(PlayerTotal, player_id: "short")
    end
  end

  describe "achievements" do
    test "a match achievement unlocks once, with its reward", %{server: server} do
      achievement(server, %{reward_vip_hours: 24, reward_flag: "🎯", description: "20 kills"})

      %{unlocked: [%{player_id: "ana"}]} =
        Progression.record_match(
          server,
          players([p("ana", %{"kills" => 25}), p("bo", %{"kills" => 3})])
        )

      assert_received {:crcon, "/api/message_player", message}
      assert message =~ "Sharpshooter"
      assert_received {:crcon, "/api/add_vip", _vip}
      assert_received {:crcon, "/api/flag_player", _flag}
      # One announcement for the match, to everybody.
      assert_received {:crcon, "/api/message_all_players", announcement}
      assert announcement =~ "ana"

      assert %{unlocked: []} =
               Progression.record_match(server, players([p("ana", %{"kills" => 30})]))
    end

    test "a career achievement adds matches up", %{server: server} do
      achievement(server, %{name: "Veteran", scope: :career, metric: :matches, threshold: 2})

      assert %{unlocked: []} = Progression.record_match(server, players([p("ana", %{})]))
      assert %{unlocked: [_one]} = Progression.record_match(server, players([p("ana", %{})]))
    end

    test "in simulation it is recorded but nothing reaches the game", %{server: server} do
      achievement(server, %{simulation: true, reward_vip_hours: 24})

      assert %{unlocked: [_one]} =
               Progression.record_match(server, players([p("ana", %{"kills" => 25})]))

      refute_received {:crcon, _path, _body}
      assert [%{simulated: true}] = Progression.player_achievements("ana")
    end

    test "a match metric cannot be counted as a career one", %{server: server} do
      assert {:error, changeset} =
               Progression.create_achievement(%{
                 server_id: server.id,
                 name: "Nope",
                 scope: :match,
                 metric: :matches,
                 threshold: 5
               })

      assert %{metric: [_error]} = errors_on(changeset)
    end

    test "players can read theirs in chat", %{server: server} do
      achievement(server, %{})
      Progression.record_match(server, players([p("ana", %{"kills" => 25})]))

      context = Context.build(server, :chat_command, player: p("ana", %{}))

      assert Template.render("{achievements_count}: {achievements}", context) ==
               "1: [*] Sharpshooter"
    end

    test "an achievement of another server is not counted here", %{server: server} do
      achievement(server_fixture(%{name: "Other"}), %{})

      assert %{unlocked: []} =
               Progression.record_match(server, players([p("ana", %{"kills" => 25})]))
    end

    test "the starter set is created in simulation", %{server: server} do
      assert [_ | _] = achievements = Progression.create_starter_set(server.id)
      assert Enum.all?(achievements, & &1.simulation)
    end
  end

  describe "seasons" do
    defp season(server, attrs \\ %{}) do
      {:ok, season} =
        Progression.create_season(
          Map.merge(
            %{
              name: "Season 1",
              server_id: server.id,
              metric: :kills,
              duration_days: 30,
              winners_count: 2,
              min_matches: 2,
              reward_vip_hours: 168,
              starts_at: DateTime.add(DateTime.utc_now(), -1, :day)
            },
            attrs
          )
        )

      season
    end

    test "every match adds to the active season", %{server: server} do
      season = season(server)

      Progression.record_match(
        server,
        players([p("ana", %{"kills" => 10}), p("bo", %{"kills" => 4})])
      )

      Progression.record_match(server, players([p("ana", %{"kills" => 5})]))

      assert [
               %{player_id: "ana", score: 15, matches: 2, qualified: true},
               %{player_id: "bo", qualified: false}
             ] =
               Progression.standings(season)

      context = Context.build(server, :chat_command, player: p("bo", %{}))
      assert Template.render("{season_rank}", context) == "#2 (4)"
    end

    test "closing rewards the top qualified players and starts the next", %{server: server} do
      season = season(server)

      for kills <- [10, 10] do
        Progression.record_match(
          server,
          players([
            p("ana", %{"kills" => kills}),
            p("bo", %{"kills" => 5}),
            p("cy", %{"kills" => 1})
          ])
        )
      end

      # Plays once but scores more: not qualified, so not rewarded.
      Progression.record_match(server, players([p("one_shot", %{"kills" => 99})]))

      finished = Progression.finalize_season(season)
      assert finished.status == :finished

      ranked = season |> Progression.standings() |> Enum.filter(& &1.rank)
      assert Enum.map(ranked, &{&1.player_id, &1.rank}) == [{"ana", 1}, {"bo", 2}]
      assert Enum.all?(ranked, & &1.rewarded_at)

      assert_received {:crcon, "/api/add_vip", _ana}
      assert_received {:crcon, "/api/add_vip", _bo}
      refute_received {:crcon, "/api/add_vip", _third}

      assert [%{name: "Season 2", status: :active, duration_days: 30}] =
               Enum.filter(Progression.list_seasons(), &(&1.status == :active))
    end

    test "a season across servers ranks everybody together", %{server: server} do
      other = server_fixture(%{name: "EU #2"})
      season = season(server, %{server_id: nil, server_ids: [server.id, other.id]})

      Progression.record_match(server, players([p("ana", %{"kills" => 10})]))
      Progression.record_match(other, players([p("ana", %{"kills" => 7})]))
      Progression.record_match(other, players([p("bo", %{"kills" => 30})]))

      assert [%{player_id: "bo", score: 30}, %{player_id: "ana", score: 17, matches: 2}] =
               Progression.standings(season)

      # The winners get VIP on every server of the season.
      Progression.finalize_season(season)
      assert_received {:crcon, "/api/add_vip", _first}
      assert_received {:crcon, "/api/add_vip", _second}
      assert_received {:crcon, "/api/message_all_players", _one}
      assert_received {:crcon, "/api/message_all_players", _two}

      assert [%{server_ids: ids}] =
               Progression.list_seasons()
               |> Enum.filter(&(&1.status == :active))
               |> Enum.map(&%{server_ids: Enum.map(&1.servers, fn s -> s.id end)})

      assert Enum.sort(ids) == Enum.sort([server.id, other.id])
    end

    test "a season does not mix games", %{server: server} do
      vietnam = server_fixture(%{game: :hllv})

      assert {:error, changeset} =
               Progression.create_season(%{
                 name: "Mixed",
                 server_ids: [server.id, vietnam.id],
                 metric: :kills,
                 duration_days: 7,
                 winners_count: 1
               })

      assert %{servers: [_error]} = errors_on(changeset)
    end

    test "a season on another server ignores this one's matches", %{server: server} do
      season = season(server_fixture(%{name: "Elsewhere"}))
      Progression.record_match(server, players([p("ana", %{"kills" => 10})]))
      assert Progression.standings(season) == []
    end

    test "an idle rating decays back towards the start", %{server: server} do
      season = season(server, %{scoring: :elo, metric: nil, rating: %{"decay" => 10}})
      long_ago = DateTime.add(DateTime.utc_now(), -20, :day) |> DateTime.truncate(:second)

      Repo.insert!(%HllConditionalActions.Progression.SeasonScore{
        season_id: season.id,
        player_id: "ana",
        score: 1200,
        matches: 20,
        last_match_at: long_ago
      })

      assert Progression.decay_ratings() == 1
      assert [%{score: 1180}] = Progression.standings(season)

      # Once a week, not every run.
      assert Progression.decay_ratings() == 0
    end

    test "an Elo season moves ratings by the match's result", %{server: server} do
      season = season(server, %{scoring: :elo, metric: nil})

      Progression.record_match(
        server,
        players([p("ana", %{"team" => "allies"}), p("bo", %{"team" => "axis"})]),
        gamestate: %{"allied_score" => 4, "axis_score" => 1}
      )

      assert [%{player_id: "ana", score: ana, wins: 1}, %{player_id: "bo", score: bo, losses: 1}] =
               Progression.standings(season)

      assert ana > 1000 and bo < 1000
    end

    test "seasons whose time is up are closed by the scheduled job", %{server: server} do
      season(server, %{starts_at: DateTime.add(DateTime.utc_now(), -31, :day), auto_renew: false})

      assert [%{status: :finished}] = Progression.finalize_due_seasons()
      assert Progression.finalize_due_seasons() == []
    end
  end
end
