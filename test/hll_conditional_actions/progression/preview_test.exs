defmodule HllConditionalActions.Progression.PreviewTest do
  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Progression.Preview

  defp p(id, attrs) do
    player(Map.merge(%{"player_id" => id, "name" => id, "map_playtime_seconds" => 1800}, attrs))
  end

  defp match(players, outcome \\ nil),
    do: %{server_id: 1, ended_at: DateTime.utc_now(), outcome: outcome, players: players}

  defp matches,
    do: [
      match([p("ana", %{"kills" => 30}), p("bo", %{"kills" => 5})]),
      match([p("ana", %{"kills" => 10}), p("cy", %{"kills" => 22})])
    ]

  test "a season shows the standings it would have after the matches" do
    season = %{scoring: :sum, metric: :kills, weights: %{}, rating: %{}, min_matches: 2}

    assert %{matches: 2, players: 3, qualified: 1, top: [%{player_id: "ana", score: 40}]} =
             Preview.season(season, matches())
  end

  test "a match achievement counts who reached the goal once" do
    achievement = %{scope: :match, metric: :kills, threshold: 20}

    assert %{count: 2, seen: 3, names: ["ana", "cy"], best: 30} =
             Preview.achievement(achievement, matches(), nil)
  end

  test "a career achievement reads the totals of the server" do
    server = server_fixture()

    HllConditionalActions.Progression.record_match(server, %{
      "ana" => p("ana", %{"kills" => 50}),
      "bo" => p("bo", %{"kills" => 2})
    })

    achievement = %{scope: :career, metric: :kills, threshold: 40}

    assert %{source: :career, count: 1, seen: 2, names: ["ana"]} =
             Preview.achievement(achievement, [], server.id)
  end
end
