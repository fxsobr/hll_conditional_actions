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
    qualified = Enum.filter(ranked, &(&1.matches >= min))

    %{
      matches: length(matches),
      players: length(ranked),
      qualified: length(qualified),
      top: Enum.take(qualified, count)
    }
  end

  # ── Achievements ───────────────────────────────────────────────────────────

  @doc """
  Who would have unlocked an achievement: in `matches` for a match goal, or
  from the career totals of `server_id` for a career one. `share` is the
  part of the players seen, 0.0 to 1.0.
  """
  @spec achievement(map(), [map()], term()) :: map()
  def achievement(%{scope: :career} = achievement, _matches, server_id) do
    totals = Repo.all(from t in PlayerTotal, where: t.server_id == ^server_id)

    reached =
      Enum.filter(
        totals,
        &(Metrics.career_value(&1, achievement.metric) >= achievement.threshold)
      )

    %{
      source: :career,
      seen: length(totals),
      count: length(reached),
      share: share(length(reached), length(totals)),
      names:
        reached
        |> Enum.sort_by(&(-Metrics.career_value(&1, achievement.metric)))
        |> Enum.take(5)
        |> Enum.map(&(&1.player_name || &1.player_id)),
      best:
        totals |> Enum.map(&Metrics.career_value(&1, achievement.metric)) |> Enum.max(fn -> 0 end)
    }
  end

  def achievement(achievement, matches, _server_id) do
    players = for m <- matches, p <- m.players, do: p
    seen = players |> Enum.map(& &1["player_id"]) |> Enum.uniq()

    best_by_player =
      players
      |> Enum.group_by(& &1["player_id"])
      |> Enum.map(fn {_id, games} ->
        best = Enum.max_by(games, &Metrics.match_value(&1, achievement.metric))
        {best["name"], Metrics.match_value(best, achievement.metric)}
      end)

    reached = Enum.filter(best_by_player, fn {_name, value} -> value >= achievement.threshold end)

    %{
      source: :matches,
      matches: length(matches),
      seen: length(seen),
      count: length(reached),
      share: share(length(reached), length(seen)),
      names: reached |> Enum.sort_by(&(-elem(&1, 1))) |> Enum.take(5) |> Enum.map(&elem(&1, 0)),
      best: best_by_player |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)
    }
  end

  defp share(_count, 0), do: 0.0
  defp share(count, total), do: count / total
end
