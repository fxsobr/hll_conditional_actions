defmodule HllConditionalActions.Progression.ScoringTest do
  use ExUnit.Case, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Progression.Scoring

  doctest HllConditionalActions.Progression.Scoring

  defp p(id, team, attrs \\ %{}) do
    player(
      Map.merge(
        %{
          "player_id" => id,
          "name" => id,
          "team" => team,
          "combat" => 0,
          "support" => 0,
          "map_playtime_seconds" => 3600
        },
        attrs
      )
    )
  end

  defp season(attrs), do: Map.merge(%{scoring: :sum, metric: :kills, weights: %{}}, attrs)

  defp rated(score), do: %{score: score, total: score, matches: 1, wins: 0, losses: 0}

  test "a sum adds the stat up" do
    assert %{"a" => %{score: 25, matches: 2}} =
             Scoring.score_match(
               season(%{}),
               [p("a", "allies", %{"kills" => 15})],
               %{"a" => rated(10)},
               nil
             )
  end

  test "an average divides by the matches played" do
    assert %{"a" => %{score: 15, total: 30, matches: 2}} =
             Scoring.score_match(
               season(%{scoring: :average}),
               [p("a", "allies", %{"kills" => 20})],
               %{"a" => rated(10)},
               nil
             )
  end

  test "a combined score weighs each stat" do
    weighted = season(%{scoring: :weighted, weights: %{"kills" => 1, "support" => "2"}})
    player = p("a", "allies", %{"kills" => 10, "support" => 100, "combat" => 999})

    assert %{"a" => %{score: 210}} = Scoring.score_match(weighted, [player], %{}, nil)
  end

  test "weights may have decimals, and a combined score can be per match" do
    weighted =
      season(%{
        scoring: :weighted,
        weights: %{"kills" => "0,5", "support" => 1.5},
        per_match: true
      })

    player = p("a", "allies", %{"kills" => 10, "support" => 100})

    assert %{"a" => %{total: 155, score: 155, matches: 1}} =
             Scoring.score_match(weighted, [player], %{}, nil)

    assert %{"a" => %{total: 310, score: 155, matches: 2}} =
             Scoring.score_match(
               weighted,
               [player],
               %{"a" => %{score: 155, total: 155, matches: 1, wins: 0, losses: 0}},
               nil
             )
  end

  describe "Elo" do
    @elo %{scoring: :elo, metric: nil, weights: %{}, rating: %{}}

    defp won(:allies), do: %{winner: :allies, allies: 5, axis: 0}
    defp won(nil), do: nil

    defp star(id, team) do
      p(id, team, %{
        "combat" => 900,
        "offense" => 900,
        "defense" => 900,
        "support" => 900,
        "kills" => 40,
        "deaths" => 5
      })
    end

    defp weak(id, team) do
      p(id, team, %{
        "combat" => 10,
        "offense" => 0,
        "defense" => 0,
        "support" => 0,
        "kills" => 1,
        "deaths" => 20
      })
    end

    defp match(winner) do
      players = [
        star("star", "allies"),
        weak("ally", "allies"),
        star("foe_star", "axis"),
        weak("foe", "axis")
      ]

      Scoring.score_match(@elo, players, %{}, won(winner))
    end

    test "winners gain, losers lose, from an even start" do
      result = match(:allies)

      assert result["star"].score > 1000 and result["ally"].score > 1000
      assert result["foe_star"].score < 1000 and result["foe"].score < 1000
      assert result["star"].wins == 1 and result["foe"].losses == 1
    end

    test "the best of a team gains the most and loses the least" do
      result = match(:allies)

      assert result["star"].score > result["ally"].score
      assert result["foe_star"].score > result["foe"].score
    end

    test "beating a stronger team earns more" do
      players = [p("a", "allies"), p("b", "axis")]

      upset =
        Scoring.score_match(@elo, players, %{"a" => rated(900), "b" => rated(1300)}, won(:allies))

      expected =
        Scoring.score_match(@elo, players, %{"a" => rated(1300), "b" => rated(900)}, won(:allies))

      assert upset["a"].score - 900 > expected["a"].score - 1300
    end

    test "an unknown result changes nothing but the match count" do
      assert %{"star" => %{score: 1000, matches: 1}} = match(nil)
    end
  end
end
