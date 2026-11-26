defmodule HllConditionalActions.BalanceTest do
  use HllConditionalActions.DataCase, async: true
  use Oban.Testing, repo: HllConditionalActions.Repo

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Balance
  alias HllConditionalActions.Balance.Partner
  alias HllConditionalActions.Balance.Plan
  alias HllConditionalActions.Balance.PlayerRating
  alias HllConditionalActions.Discord
  alias HllConditionalActions.Players.MatchImport
  alias HllConditionalActions.Players.MatchStat
  alias HllConditionalActions.Workers.DeliverWebhook

  doctest Balance

  setup do
    %{server: server_fixture(%{name: "EU #1"})}
  end

  defp match(server, match_id, allied, axis, ended_at, lines) do
    now = DateTime.utc_now(:second)

    Repo.insert!(%MatchImport{
      server_id: server.id,
      match_id: match_id,
      players: length(lines),
      ended_at: ended_at,
      allied_score: allied,
      axis_score: axis
    })

    for {id, team, squad, combat} <- lines do
      Repo.insert!(%MatchStat{
        server_id: server.id,
        match_id: match_id,
        player_id: id,
        player_name: "P#{id}",
        team: team,
        unit_name: squad,
        combat: combat,
        kills: 10,
        deaths: 5,
        playtime_seconds: 3600,
        inserted_at: now
      })
    end
  end

  defp lines do
    [
      {"a1", "allies", "able", 300},
      {"a2", "allies", "able", 200},
      {"a3", "allies", "baker", 100},
      {"x1", "axis", "able", 300},
      {"x2", "axis", "able", 200},
      {"x3", "axis", "baker", 100},
      # CRCON had no squad for this one.
      {"x4", "axis", nil, 50}
    ]
  end

  describe "learning" do
    test "winners gain, losers lose, and squadmates become partners", %{server: server} do
      ended = DateTime.add(DateTime.utc_now(:second), -3600)
      match(server, "1", 5, 0, ended, lines())

      assert Balance.learn_pending(server) == 1
      assert Balance.learn_pending(server) == 0

      ratings = Balance.ratings(server.game, ~w(a1 x1))
      assert ratings["a1"].rating > 1000
      assert ratings["x1"].rating < 1000
      assert ratings["a1"].matches == 1

      assert Repo.get_by(Partner, player_a: "a1", player_b: "a2").matches == 1
      refute Repo.get_by(Partner, player_a: "a1", player_b: "a3")
    end

    test "a match without its result is skipped, once", %{server: server} do
      ended = DateTime.add(DateTime.utc_now(:second), -3600)
      match(server, "2", nil, nil, ended, lines())

      assert Balance.learn_pending(server) == 0
      assert Repo.aggregate(PlayerRating, :count) == 0
      assert Repo.get_by!(MatchImport, match_id: "2").balance_learned_at
    end

    test "old one-off partnerships are forgotten" do
      old = DateTime.add(DateTime.utc_now(:second), -40, :day)
      Repo.insert!(%Partner{player_a: "a", player_b: "b", matches: 1, last_at: old})
      Repo.insert!(%Partner{player_a: "a", player_b: "c", matches: 4, last_at: old})

      assert Balance.prune_partners() == 1
      assert Repo.get_by(Partner, player_a: "a", player_b: "c")
    end
  end

  defp live_players(ratings) do
    for {id, team, squad, rating} <- ratings, into: %{} do
      Repo.insert!(%PlayerRating{game: "hll", player_id: id, rating: rating, matches: 20})

      {id,
       %{
         "player_id" => id,
         "name" => "P#{id}",
         "team" => team,
         "unit_name" => squad,
         "role" => "rifleman"
       }}
    end
  end

  # Two sides of `size` players in squads of four, ids "a1".. and "x1"..;
  # `teams` says which side each prefix plays on, `kills` their kills.
  defp sides(size, opts \\ []) do
    teams = Keyword.get(opts, :teams, %{"a" => "allies", "x" => "axis"})
    kills = Keyword.get(opts, :kills, %{"a" => 10, "x" => 10})
    ratings = Keyword.get(opts, :ratings, %{"a" => 1000, "x" => 1000})

    for prefix <- ["a", "x"], i <- 1..size, into: %{} do
      id = "#{prefix}#{i}"

      Repo.insert!(
        %PlayerRating{game: "hll", player_id: id, rating: ratings[prefix], matches: 20},
        on_conflict: :nothing
      )

      {id,
       %{
         "player_id" => id,
         "name" => "P#{id}",
         "team" => teams[prefix],
         "unit_name" => "s#{div(i - 1, 4)}",
         "role" => "rifleman",
         "kills" => kills[prefix],
         "combat" => 100
       }}
    end
  end

  defp at(minutes), do: DateTime.add(~U[2026-11-26 20:00:00Z], minutes, :minute)

  describe "the decision in the preparation" do
    test "the gap rule fires on uneven teams and is posted to Discord", %{server: server} do
      Req.Test.stub(HllConditionalActions.Discord, fn conn ->
        Req.Test.json(conn, %{"name" => "Balance", "channel_id" => "1", "guild_id" => "2"})
      end)

      {:ok, webhook} =
        Discord.create_webhook(%{name: "Balance", url: "https://discord.com/api/webhooks/1/abc"})

      {:ok, _settings} =
        Balance.save_settings(Balance.get_settings(server.id), %{
          webhook_id: webhook.id,
          rule: "gap",
          trigger_gap: 15
        })

      players =
        live_players([
          {"a1", "allies", "able", 1400},
          {"a2", "allies", "able", 1380},
          {"a3", "allies", "baker", 1000},
          {"a4", "allies", "charlie", 1000},
          {"x1", "axis", "able", 900},
          {"x2", "axis", "able", 920},
          {"x3", "axis", "baker", 1000},
          {"x4", "axis", "charlie", 1000}
        ])

      plan = Balance.decide_warmup(server, players, %{}, now: at(0))

      assert %Plan{status: "simulated", rule_fired: "gap", strong_team: "allies"} = plan
      assert plan.started_at == at(0)
      assert is_nil(plan.ended_at)
      assert plan.gap_after < plan.gap
      assert Plan.moved(plan) > 0

      assert [job] = all_enqueued(worker: DeliverWebhook)
      assert job.args["payload"]["content"] =~ "EU #1"

      # MATCH START written twice: one decision.
      assert Balance.decide_warmup(server, players, %{}, now: at(2)) == nil
    end

    test "nothing fires on even teams, and nothing is posted", %{server: server} do
      {:ok, _} = Balance.save_settings(Balance.get_settings(server.id), %{rule: "gap"})

      assert %Plan{status: "balanced", moves: [], rule_fired: nil} =
               Balance.decide_warmup(server, sides(8), %{}, now: at(0))

      assert all_enqueued(worker: DeliverWebhook) == []
    end

    test "a dominant group from the previous match, together again, gets a plan", %{
      server: server
    } do
      # Match A ends: allies win with twice the kills. Its warmup was missed.
      a = sides(12, kills: %{"a" => 20, "x" => 10})

      assert %Plan{status: "measured", kills_ratio: 200, winner_ids: winners} =
               Balance.close_match(server, a, %{"allied_score" => 5, "axis_score" => 0},
                 now: at(0)
               )

      assert length(winners) == 12

      # Match B's warmup: the game swapped the factions, the group is axis now.
      b = sides(12, teams: %{"a" => "axis", "x" => "allies"})
      decision = Balance.decide_warmup(server, b, %{}, now: at(3))

      assert %Plan{status: "simulated", rule_fired: "previous", stack_side: "axis"} = decision
      assert length(decision.stack_ids) == 12
      assert decision.stack_together == 100
      assert Plan.moved(decision) > 0
      # Some of the group leaves the axis (possibly swapped for others).
      assert Enum.any?(decision.moves, fn move ->
               move["from"] == "axis" and
                 Enum.all?(move["players"], &String.starts_with?(&1["id"], "a"))
             end)

      # B ends and the group wins again.
      Balance.close_match(server, b, %{"allied_score" => 0, "axis_score" => 5}, now: at(40))

      assert %Plan{strong_won_again: true, axis_score: 5, ended_at: ended} =
               Repo.reload!(decision)

      assert ended == at(40)
    end

    test "a player a plan moved rests before being moved again", %{server: server} do
      {:ok, _} =
        Balance.save_settings(Balance.get_settings(server.id), %{
          rule: "gap",
          trigger_gap: 15,
          max_count_gap: 6
        })

      players = sides(8, ratings: %{"a" => 1300, "x" => 1000})
      first = Balance.decide_warmup(server, players, %{}, now: at(0))
      moved = first.moves |> Enum.flat_map(& &1["players"]) |> MapSet.new(& &1["id"])
      assert MapSet.size(moved) > 0

      Balance.close_match(server, players, %{"allied_score" => 5, "axis_score" => 0}, now: at(30))
      second = Balance.decide_warmup(server, players, %{}, now: at(33))

      again = second.moves |> Enum.flat_map(& &1["players"]) |> MapSet.new(& &1["id"])
      assert MapSet.disjoint?(moved, again)
    end

    test "without teams in the warmup, the previous match's sides stand in, swapped", %{
      server: server
    } do
      a = sides(8)
      Balance.close_match(server, a, %{"allied_score" => 5, "axis_score" => 0}, now: at(0))

      no_teams = Map.new(a, fn {id, p} -> {id, Map.delete(p, "team")} end)
      decision = Balance.decide_warmup(server, no_teams, %{}, now: at(3))

      assert decision.source == "previous"
      assert Enum.find(decision.roster, &(&1["id"] == "a1"))["team"] == "axis"
    end
  end

  test "a summary of the week", %{server: server} do
    {:ok, _} =
      Balance.save_settings(Balance.get_settings(server.id), %{rule: "gap", trigger_gap: 15})

    players = sides(4, ratings: %{"a" => 1400, "x" => 900})
    now = DateTime.utc_now(:second)
    Balance.decide_warmup(server, players, %{}, now: now)

    assert %{matches: 1, unbalanced: 1} = Balance.summary([server.id])
  end
end
