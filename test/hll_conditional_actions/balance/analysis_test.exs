defmodule HllConditionalActions.Balance.AnalysisTest do
  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Balance
  alias HllConditionalActions.Balance.Analysis
  alias HllConditionalActions.Balance.PlayerRating
  alias HllConditionalActions.Players.MatchImport
  alias HllConditionalActions.Players.MatchStat

  doctest Analysis

  @t0 ~U[2026-11-20 20:00:00Z]

  # 32 a side, in squads of four; `strong` players are rated 1200.
  defp players(strong_allies, strong_axis, opts \\ []) do
    kills = Keyword.get(opts, :kills, {10, 10})

    for team <- [:allies, :axis], i <- 1..32 do
      strong = if team == :allies, do: strong_allies, else: strong_axis
      id = Keyword.get(opts, :ids, %{})[{team, i}] || "#{team}-#{i}"

      %{
        id: id,
        name: id,
        team: team,
        squad: "s#{div(i - 1, 4)}",
        rating: if(i <= strong, do: 1200, else: 1000),
        kills: if(team == :allies, do: elem(kills, 0), else: elem(kills, 1)),
        points: 100
      }
    end
  end

  defp match(id, start_minute, length, winner, players) do
    %{
      server_id: 1,
      id: id,
      map: "Foy",
      mode: "warfare",
      started_at: DateTime.add(@t0, start_minute, :minute),
      ended_at: DateTime.add(@t0, start_minute + length, :minute),
      minutes: length,
      winner: winner,
      players: players
    }
  end

  test "the gap rule acts on uneven matches and closes the gap" do
    matches = [
      match("1", 0, 25, :allies, players(16, 0)),
      match("2", 30, 80, :axis, players(0, 0))
    ]

    result = Analysis.replay(matches, MapSet.new(), %{"trigger_gap" => "35"})

    assert result.matches == 2
    assert result.fast == 1

    gap = result.rules.gap
    assert gap.fired == 1
    assert gap.fast_share == 1.0
    assert gap.gap_before > 35
    assert gap.gap_after < gap.gap_before
    assert gap.moved > 0
    assert gap.moved_median <= 12
  end

  test "the previous match rule finds a dominant group playing together again" do
    # Match 1: allies win with twice the kills. Match 2 starts five minutes
    # later; the game swapped the factions, so the same group is now axis,
    # and wins again.
    winners = for i <- 1..32, into: %{}, do: {{:axis, i}, "allies-#{i}"}
    losers = for i <- 1..32, into: %{}, do: {{:allies, i}, "axis-#{i}"}

    matches = [
      match("1", 0, 40, :allies, players(0, 0, kills: {20, 10})),
      match("2", 45, 40, :axis, players(0, 0, ids: Map.merge(winners, losers)))
    ]

    result = Analysis.replay(matches, MapSet.new(), %{"stack_bonus" => "40"})
    previous = result.rules.previous

    assert previous.fired == 1
    assert previous.repeat_share == 1.0
    assert previous.repeat_rate == 1.0
    # The bonus made the stack strong: the plan moves some of it.
    assert previous.moved > 0
    # Even teams on rating alone: the gap rule leaves it.
    assert result.rules.gap.fired == 0
    assert result.rules.either.fired == 1
    assert result.rules.both.fired == 0
  end

  test "two dominant wins in a row by the same group make a streak" do
    # The group is "allies-1".."allies-32": allies in match 1, axis in match
    # 2 (the game swapped the factions), allies again in match 3.
    swapped =
      for i <- 1..32, into: %{} do
        {{:axis, i}, "allies-#{i}"}
      end
      |> Map.merge(for i <- 1..32, into: %{}, do: {{:allies, i}, "axis-#{i}"})

    matches = [
      match("1", 0, 40, :allies, players(0, 0, kills: {20, 10})),
      match("2", 45, 40, :axis, players(0, 0, ids: swapped, kills: {10, 20})),
      match("3", 90, 40, :allies, players(0, 0))
    ]

    result = Analysis.replay(matches, MapSet.new(), %{})

    # Matches 2 and 3 follow a dominant win; only 3 follows two in a row.
    assert result.rules.previous.fired == 2
    assert result.rules.streak.fired == 1
    assert result.rules.streak.repeat_share == 0.5
  end

  # Allies: 4 stars at 1600, one in each of 4 squads, and 28 at 914, an
  # average of about 1000. Axis:
  # 32 steady players at 1001. The allies win.
  defp stars do
    allies =
      for i <- 1..32 do
        %{
          id: "a#{i}",
          name: "a#{i}",
          team: :allies,
          squad: "s#{div(i - 1, 4)}",
          rating: if(i in [1, 5, 9, 13], do: 1600, else: 914),
          kills: 10,
          points: 100
        }
      end

    axis =
      for i <- 1..32 do
        %{id: "x#{i}", name: "x#{i}", team: :axis, squad: "s#{div(i - 1, 4)}"}
        |> Map.merge(%{rating: 1001, kills: 10, points: 100})
      end

    allies ++ axis
  end

  test "weighing the stars finds the team the average misses" do
    matches = [match("1", 0, 25, :allies, stars())]

    prediction = Analysis.prediction(matches, 35)
    by = &Enum.find(prediction, fn m -> {m.kind, m.value} == &1 end)

    assert by.({:mean, 0}).favourite_won == 0.0
    assert by.({:top, 15}).favourite_won == 1.0
    assert by.({:weight, 100}).favourite_won == 1.0
    assert by.({:weight, 100}).fast_caught == 1.0

    # On the average the match is even; with the stars weighed, a plan.
    assert Analysis.replay(matches, MapSet.new(), %{}).rules.gap.fired == 0

    weighed = Analysis.replay(matches, MapSet.new(), %{"strong_weight" => "100"}).rules.gap
    assert weighed.fired == 1
    assert weighed.moved > 0
    assert weighed.gap_after < weighed.gap_before
  end

  test "calibration counts how often the stronger side won" do
    matches = [
      match("1", 0, 25, :allies, players(16, 0)),
      match("2", 100, 25, :axis, players(16, 0))
    ]

    band = Enum.find(Analysis.calibration(matches), &(&1.from == 70))
    assert band.matches == 2
    assert band.favourite_won == 0.5
    assert band.fast == 1.0
  end

  test "the history comes from the imported matches, with today's ratings" do
    server = server_fixture()
    ended = DateTime.add(DateTime.utc_now(:second), -2, :day)
    started = DateTime.add(ended, -25, :minute)
    now = DateTime.utc_now(:second)

    Repo.insert!(%MatchImport{
      server_id: server.id,
      match_id: "77",
      ended_at: ended,
      allied_score: 5,
      axis_score: 0
    })

    for team <- ["allies", "axis"], i <- 1..32 do
      Repo.insert!(%MatchStat{
        server_id: server.id,
        match_id: "77",
        player_id: "#{team}-#{i}",
        team: team,
        unit_name: "able",
        mode: "warfare",
        map: "Foy",
        started_at: started,
        ended_at: ended,
        playtime_seconds: 1500,
        inserted_at: now
      })
    end

    Repo.insert!(%PlayerRating{game: "hll", player_id: "allies-1", rating: 1500, matches: 20})

    assert [match] = Analysis.history_matches([server.id], 14, :hll)
    assert match.winner == :allies
    assert round(match.minutes) == 25
    assert Enum.find(match.players, &(&1.id == "allies-1")).rating == 1500.0

    result = Analysis.run([server.id], %{"days" => "14"}, :hll)
    assert result.matches == 1
  end

  test "a plan keeps the roster it saw" do
    server = server_fixture()
    Repo.insert!(%PlayerRating{game: "hll", player_id: "a1", rating: 1300, matches: 4})

    players = %{
      "a1" => %{
        "player_id" => "a1",
        "name" => "Ana",
        "team" => "allies",
        "unit_name" => "able",
        "kills" => 12,
        "combat" => 100,
        "offense" => 50
      },
      "x1" => %{"player_id" => "x1", "name" => "Xu", "team" => "axis", "unit_name" => "able"}
    }

    plan = Balance.close_match(server, players, %{"allied_score" => 5, "axis_score" => 0})

    assert %{"rating" => 1120, "matches" => 4, "kills" => 12, "points" => 150} =
             Enum.find(plan.roster, &(&1["id"] == "a1"))

    assert %{"allies" => %{"players" => 1, "kills" => 12}, "axis" => %{"players" => 1}} =
             plan.teams
  end
end
