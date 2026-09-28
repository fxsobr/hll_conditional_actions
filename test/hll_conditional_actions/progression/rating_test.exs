defmodule HllConditionalActions.Progression.RatingTest do
  use ExUnit.Case, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Progression.Rating

  doctest HllConditionalActions.Progression.Rating

  @even %{gap: 0, performance: 0.0, matches: 30, share: 1.0}

  defp config(changes \\ %{}), do: Rating.normalize(Map.merge(Rating.defaults(), changes))

  defp p(id, team, attrs \\ %{}) do
    player(
      Map.merge(
        %{"player_id" => id, "name" => id, "team" => team, "map_playtime_seconds" => 3600},
        attrs
      )
    )
  end

  describe "presets" do
    test "competitive ranks by the result alone" do
      competitive = Rating.normalize(Rating.preset("competitive"))
      best = Map.merge(@even, %{result: 1.0, won: true, performance: 0.5})
      worst = Map.merge(@even, %{result: 1.0, won: true, performance: -0.5})

      assert Rating.change(competitive, best) == Rating.change(competitive, worst)
      assert Rating.change(competitive, best) == 25
    end

    test "performance moves the best far from the worst of the same win" do
      performance = Rating.normalize(Rating.preset("performance"))
      best = Map.merge(@even, %{result: 1.0, won: true, performance: 0.45})
      worst = Map.merge(@even, %{result: 1.0, won: true, performance: -0.45})

      assert Rating.change(performance, best) - Rating.change(performance, worst) > 15
    end
  end

  describe "change/2" do
    test "a loss never raises a rating when guarded" do
      loss = Map.merge(@even, %{result: 0.0, won: false, performance: 0.5})

      assert Rating.change(config(%{"result_weight" => 10}), loss) == 0
      assert Rating.change(config(%{"result_weight" => 10, "no_gain_on_loss" => false}), loss) > 0
    end

    test "placement matches count double" do
      win = Map.merge(@even, %{result: 1.0, won: true})
      fixed = config(%{"k_mode" => "fixed"})

      assert Rating.change(fixed, %{win | matches: 0}) == 2 * Rating.change(fixed, win)
    end

    test "a decreasing K settles as a player plays" do
      decreasing = config(%{"placement" => 0})

      assert Rating.k(decreasing, 0) == 64.0
      assert Rating.k(decreasing, 1000) == 16.0
    end

    test "never more than the most per match" do
      win = Map.merge(@even, %{result: 1.0, won: true, gap: 800, matches: 0})
      assert Rating.change(config(%{"max_change" => 20}), win) == 20
    end

    test "half a match is worth half, when scaled by time" do
      win = Map.merge(@even, %{result: 1.0, won: true})
      fixed = config(%{"k_mode" => "fixed", "result_weight" => 100})

      assert Rating.change(fixed, %{win | share: 0.5}) == 8
      assert Rating.change(%{fixed | "time_scaled" => false}, %{win | share: 0.5}) == 16
    end
  end

  describe "score_match/4" do
    test "sectors held soften a close loss" do
      players = [p("a", "allies"), p("b", "axis")]
      caps = config(%{"result_weight" => 100, "k_mode" => "fixed", "placement" => 0})

      close = Rating.score_match(caps, players, %{}, %{winner: :axis, allies: 2, axis: 3})
      rout = Rating.score_match(caps, players, %{}, %{winner: :axis, allies: 0, axis: 5})

      assert close["a"].score > rout["a"].score
      assert close["a"].losses == 1
    end

    test "a player below the minutes does not count" do
      players = [
        p("a", "allies", %{"map_playtime_seconds" => 300}),
        p("b", "axis"),
        p("c", "allies")
      ]

      result = Rating.score_match(config(), players, %{}, %{winner: :allies, allies: 5, axis: 0})

      refute Map.has_key?(result, "a")
      assert result["c"].score > 1000
    end

    test "teamkills cost performance" do
      clean = p("clean", "allies", %{"team_kills" => 0})
      reckless = p("reckless", "allies", %{"team_kills" => 6})
      teammates = [clean, reckless]

      assert Rating.performance(reckless, teammates, config()) <
               Rating.performance(clean, teammates, config())
    end

    test "never below the floor" do
      players = [p("a", "allies"), p("b", "axis")]
      standing = %{score: 105, total: 0, matches: 0, wins: 0, losses: 0}
      low = %{"a" => standing, "b" => standing}

      result =
        Rating.score_match(config(%{"floor" => 100}), players, low, %{
          winner: :axis,
          allies: 0,
          axis: 5
        })

      assert result["a"].score == 100
    end
  end

  test "normalize keeps what is set and clamps the rest" do
    config = Rating.normalize(%{"k" => "20", "decay" => "-3", "time_scaled" => "false"})

    assert config["k"] == 20
    assert config["decay"] == 0
    assert config["time_scaled"] == false
    assert config["performance"] == Rating.defaults()["performance"]
  end

  test "tiers start from the starting rating" do
    assert {:gold, 1550} in Rating.tiers(%{"initial" => 1500})
    assert Rating.tier(899, %{}) == :bronze
  end
end
