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
      {"x3", "axis", "baker", 100}
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

  describe "planning at the end of a match" do
    test "an uneven match gets a plan, posted to Discord", %{server: server} do
      Req.Test.stub(HllConditionalActions.Discord, fn conn ->
        Req.Test.json(conn, %{"name" => "Balance", "channel_id" => "1", "guild_id" => "2"})
      end)

      {:ok, webhook} =
        Discord.create_webhook(%{name: "Balance", url: "https://discord.com/api/webhooks/1/abc"})

      {:ok, _settings} =
        Balance.save_settings(Balance.get_settings(server.id), %{webhook_id: webhook.id})

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

      plan = Balance.plan_match(server, players, %{"allied_score" => 5, "axis_score" => 0})

      assert %Plan{status: "simulated", strong_team: "allies"} = plan
      assert plan.gap >= 15
      assert plan.gap_after < plan.gap
      assert Plan.moved(plan) > 0
      assert "a1" in plan.strong_ids

      assert [job] = all_enqueued(worker: DeliverWebhook)
      assert job.args["payload"]["content"] =~ "EU #1"

      # MATCH ENDED written twice: still one plan.
      assert Balance.plan_match(server, players, %{}) == nil
    end

    test "an even match is recorded as balanced and posts nothing", %{server: server} do
      players =
        live_players([
          {"a1", "allies", "able", 1000},
          {"a2", "allies", "able", 1010},
          {"x1", "axis", "able", 1005},
          {"x2", "axis", "able", 1000}
        ])

      assert %Plan{status: "balanced", moves: []} =
               Balance.plan_match(server, players, %{"allied_score" => 3, "axis_score" => 2})

      assert all_enqueued(worker: DeliverWebhook) == []
    end

    test "the next match says whether the stronger team won again", %{server: server} do
      first = DateTime.add(DateTime.utc_now(:second), -5400)

      players =
        live_players([
          {"a1", "allies", "able", 1400},
          {"a2", "allies", "able", 1380},
          {"x1", "axis", "able", 900},
          {"x2", "axis", "able", 920}
        ])

      plan =
        Balance.plan_match(server, players, %{"allied_score" => 5, "axis_score" => 0}, now: first)

      # The game swapped the factions: the strong pair now plays axis, and wins.
      swapped = %{
        "a1" => %{"player_id" => "a1", "team" => "axis", "unit_name" => "able"},
        "a2" => %{"player_id" => "a2", "team" => "axis", "unit_name" => "able"},
        "x1" => %{"player_id" => "x1", "team" => "allies", "unit_name" => "able"},
        "x2" => %{"player_id" => "x2", "team" => "allies", "unit_name" => "able"}
      }

      Balance.plan_match(server, swapped, %{"allied_score" => 0, "axis_score" => 5})

      assert %Plan{strong_won_again: true, next_axis_score: 5} = Repo.reload!(plan)
    end
  end

  test "a summary of the week", %{server: server} do
    players =
      live_players([
        {"a1", "allies", "able", 1400},
        {"x1", "axis", "able", 900}
      ])

    Balance.plan_match(server, players, %{"allied_score" => 5, "axis_score" => 0})

    assert %{matches: 1, unbalanced: 1} = Balance.summary([server.id])
  end
end
