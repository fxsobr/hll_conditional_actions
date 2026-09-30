defmodule HllConditionalActions.Progression.Preview do
  @moduledoc """
  What a season or an achievement would have done, had it existed during
  the servers' last matches - shown while it is being set up, so a goal
  nobody can reach or one everybody reaches is seen before it is saved.

  The matches come from CRCON's match history (`get_scoreboard_maps`), read
  once when the form opens; the previews themselves are plain functions over
  them, cheap enough to run on every keystroke.
  """

  import Ecto.Query

  alias HllConditionalActions.Matches
  alias HllConditionalActions.Progression.Metrics
  alias HllConditionalActions.Progression.PlayerTotal
  alias HllConditionalActions.Progression.Scoring
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Servers.Server

  # Same rule as the real thing: a few minutes are needed for a match to count.
  @min_seconds_played 300

  @doc """
  The last `limit` finished matches of each server, oldest first, each as
  `%{server_id, ended_at, outcome, players}` with the players who count.
  Servers CRCON cannot answer for are left out.
  """
  @spec recent_matches([Server.t()], pos_integer()) :: [map()]
  def recent_matches(servers, limit \\ 10) do
    servers
    |> Task.async_stream(&server_matches(&1, limit), timeout: 30_000, on_timeout: :kill_task)
    |> Enum.flat_map(fn
      {:ok, matches} -> matches
      _failed -> []
    end)
    |> Enum.sort_by(& &1.ended_at, fn a, b -> DateTime.compare(a, b) != :gt end)
  end

  defp server_matches(server, limit) do
    case Matches.list(server, limit: limit) do
      {:ok, %{matches: matches}} ->
        matches
        |> Enum.filter(& &1.ended_at)
        |> Task.async_stream(&with_players(server, &1), timeout: 20_000, on_timeout: :kill_task)
        |> Enum.flat_map(fn
          {:ok, %{players: [_ | _]} = match} -> [match]
          _empty -> []
        end)

      _error ->
        []
    end
  end

  defp with_players(server, summary) do
    case Matches.get(server, summary.id) do
      {:ok, %{roster: roster}} ->
        %{
          server_id: server.id,
          ended_at: summary.ended_at,
          outcome:
            summary.winner &&
              %{winner: summary.winner, allies: summary.allied, axis: summary.axis},
          players:
            roster
            |> Map.values()
            |> Enum.filter(&((&1["map_playtime_seconds"] || 0) >= @min_seconds_played))
        }

      _error ->
        %{players: []}
    end
  end

  # ── Seasons ────────────────────────────────────────────────────────────────

  @doc """
  The standings a season would show after `matches`: the top `count`, how
  many players scored and how many played enough to be ranked.
  `season` needs `scoring`, `metric`, `weights`, `rating` and `min_matches`.

  Also returned: `below`, the best players still under the minimum matches,
  and `parts`, how much each stat of a combined season adds to the scores
  (`[{metric, points}]`, largest first).
  """
  @spec season(map(), [map()], pos_integer()) :: map()
  def season(season, matches, count \\ 5) do
    names = for m <- matches, p <- m.players, into: %{}, do: {p["player_id"], p["name"]}

    standings =
      Enum.reduce(matches, %{}, fn match, current ->
        Map.merge(current, Scoring.score_match(season, match.players, current, match.outcome))
      end)

    ranked =
      standings
      |> Enum.map(fn {id, standing} -> Map.merge(standing, %{player_id: id, name: names[id]}) end)
      |> Enum.sort_by(&{-&1.score, -&1.matches})

    min = season.min_matches || 0
    {qualified, below} = Enum.split_with(ranked, &(&1.matches >= min))

    %{
      matches: length(matches),
      players: length(ranked),
      qualified: length(qualified),
      top: Enum.take(qualified, count),
      below: Enum.take(below, 3),
      parts: parts(season, matches)
    }
  end

  defp parts(%{scoring: :weighted} = season, matches) do
    Scoring.weighted_metrics()
    |> Enum.map(fn metric ->
      weight = Scoring.weight(season.weights, metric)

      points =
        for m <- matches, p <- m.players, reduce: 0 do
          sum -> sum + weight * Metrics.match_value(p, metric)
        end

      {metric, round(points)}
    end)
    |> Enum.filter(fn {_metric, points} -> points > 0 end)
    |> Enum.sort_by(fn {_metric, points} -> -points end)
  end

  defp parts(_season, _matches), do: []

  # ── Achievements ───────────────────────────────────────────────────────────

  @bins 16

  @doc """
  Who would have unlocked an achievement: in `matches` for a match goal, or
  from the career totals of `server_id` for a career one. `share` is the
  part of the players seen, 0.0 to 1.0.

  Beside the count: `times` (how many matches reached it; the players for a
  career goal), `top` (the best players, with how often they reached it and
  their best), `best_name`, `median_top` (the median of the ten best) and
  `histogram` - the values seen in #{@bins} bins, `%{bins, from, to}`.
  """
  @spec achievement(map(), [map()], term()) :: map()
  def achievement(%{scope: :career} = achievement, _matches, server_id) do
    totals = Repo.all(from t in PlayerTotal, where: t.server_id == ^server_id)
    value = &Metrics.career_value(&1, achievement.metric)
    reached = Enum.filter(totals, &(value.(&1) >= achievement.threshold))
    best = totals |> Enum.sort_by(&(-value.(&1)))

    %{
      source: :career,
      seen: length(totals),
      count: length(reached),
      times: length(reached),
      share: share(length(reached), length(totals)),
      names:
        reached
        |> Enum.sort_by(&(-value.(&1)))
        |> Enum.take(5)
        |> Enum.map(&(&1.player_name || &1.player_id)),
      best: totals |> Enum.map(value) |> Enum.max(fn -> 0 end),
      best_name: best |> List.first() |> then(&(&1 && (&1.player_name || &1.player_id))),
      median_top: best |> Enum.take(10) |> Enum.map(value) |> median(),
      top:
        reached
        |> Enum.sort_by(&(-value.(&1)))
        |> Enum.take(5)
        |> Enum.map(
          &%{name: &1.player_name || &1.player_id, team: nil, times: 1, best: value.(&1)}
        ),
      histogram: histogram(Enum.map(totals, value), achievement.threshold)
    }
  end

  def achievement(achievement, matches, _server_id) do
    players = for m <- matches, p <- m.players, do: p
    seen = players |> Enum.map(& &1["player_id"]) |> Enum.uniq()
    value = &Metrics.match_value(&1, achievement.metric)

    by_player =
      players
      |> Enum.group_by(& &1["player_id"])
      |> Enum.map(fn {_id, games} ->
        best = Enum.max_by(games, value)

        %{
          name: best["name"],
          team: List.last(games)["team"],
          best: value.(best),
          times: Enum.count(games, &(value.(&1) >= achievement.threshold))
        }
      end)

    reached = by_player |> Enum.filter(&(&1.times > 0)) |> Enum.sort_by(&{-&1.times, -&1.best})
    best = Enum.sort_by(by_player, &(-&1.best))

    %{
      source: :matches,
      matches: length(matches),
      seen: length(seen),
      count: length(reached),
      times: Enum.sum_by(reached, & &1.times),
      share: share(length(reached), length(seen)),
      names: reached |> Enum.sort_by(&(-&1.best)) |> Enum.take(5) |> Enum.map(& &1.name),
      best: best |> List.first() |> then(&((&1 && &1.best) || 0)),
      best_name: best |> List.first() |> then(&(&1 && &1.name)),
      median_top: best |> Enum.take(10) |> Enum.map(& &1.best) |> median(),
      top: Enum.take(reached, 5),
      histogram: histogram(Enum.map(players, value), achievement.threshold)
    }
  end

  defp median([]), do: 0

  defp median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted) - 1, 2))
  end

  # The values in equal bins from 0, wide enough to show the threshold in
  # the middle of the range; the last bin takes everything above.
  defp histogram(values, threshold) do
    top = max(threshold * 2, 2)
    width = max(top / @bins, 1)

    counts =
      Enum.reduce(values, List.duplicate(0, @bins), fn value, bins ->
        index = value |> Kernel./(width) |> trunc() |> max(0) |> min(@bins - 1)
        List.update_at(bins, index, &(&1 + 1))
      end)

    %{bins: counts, from: 0, to: round(width * (@bins - 1)), width: width}
  end

  defp share(_count, 0), do: 0.0
  defp share(count, total), do: count / total
end
