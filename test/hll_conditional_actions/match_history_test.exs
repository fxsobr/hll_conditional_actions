defmodule HllConditionalActions.MatchHistoryTest do
  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.MatchHistory
  alias HllConditionalActions.MatchReport

  defp match(map, allied, axis, seconds) do
    %{
      map: map,
      allied: allied,
      axis: axis,
      duration_seconds: seconds,
      winner:
        cond do
          allied > axis -> :allies
          axis > allied -> :axis
          true -> :draw
        end
    }
  end

  test "the numbers of a period" do
    summary =
      MatchHistory.summary([
        match("Foy", 5, 0, 3600),
        match("Foy", 2, 3, 5400),
        match("Kursk", 3, 2, 1800)
      ])

    assert %{count: 3, average_seconds: 3600, allies: 2, axis: 1, total_wins: 1} = summary

    assert [%{map: "Foy", count: 2, allies: 1, axis: 1}, %{map: "Kursk", count: 1}] =
             summary.by_map
  end

  test "the rule that posts matches to Discord" do
    server = server_fixture()
    assert MatchHistory.discord_rule([server.id]) == nil
  end

  test "a report ranks the match and finds the MVP" do
    roster = %{
      "a" =>
        player(%{
          "player_id" => "a",
          "name" => "Ana",
          "combat" => 900,
          "support" => 10,
          "unit_name" => "able",
          "role" => "officer"
        }),
      "b" =>
        player(%{
          "player_id" => "b",
          "name" => "Bo",
          "combat" => 100,
          "support" => 50,
          "team_kills" => 2,
          "team" => "axis"
        })
    }

    report =
      MatchReport.build(
        %{roster: roster, started_at: nil, ended_at: nil, map: "Foy", allied: 3, axis: 2},
        []
      )

    assert %{players: 2, team_kills: 2, mvp: %{name: "Ana"}, fired: 0} = report
    assert [%{name: "Ana"} | _rest] = report.best.combat
  end
end
