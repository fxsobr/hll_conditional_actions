defmodule HllConditionalActions.Balance.Report do
  @moduledoc """
  What stomps and maps cost a server in players, from the matches read from
  CRCON (`Players.MatchStat`).

  For every match followed by another on the same server (the next one
  starting within ten minutes of its end):

    * **retention** - of the players who played ten minutes or more, the
      share who are in the next match
    * **next population** - how many more or fewer players the next match
      had

  grouped by how the match went (a Warfare 5-0 in thirty minutes or less, a
  slower 5-0, a 4-1 or 3-2) and by map. Maps played the least are compared
  with the rest: a map few people know, or like, can empty a server as
  surely as a stomp.
  """

  import Ecto.Query

  alias HllConditionalActions.Players.MatchImport
  alias HllConditionalActions.Players.MatchStat
  alias HllConditionalActions.Repo

  @stayed_seconds 600
  @link_seconds 600
  @fast_minutes 30
  # A map is "less played" when it holds under this share of the matches.
  @rare_share 0.03

  @doc """
  The report for some servers over the last `days`.
  """
  @spec run([term()], pos_integer()) :: map()
  def run(server_ids, days) do
    since = DateTime.add(DateTime.utc_now(), -days, :day)

    server_ids
    |> load(since)
    |> build()
  end

  @doc """
  The report from matches already loaded: maps with `server_id`, `id`,
  `map`, `mode`, `started_at`, `ended_at`, `allied`, `axis`, `players`
  (every player id) and `stayed` (ids of those who played ten minutes or
  more). Pure, for tests.
  """
  @spec build([map()]) :: map()
  def build(matches) do
    linked = link(matches)
    total = length(matches)

    %{
      matches: total,
      linked: length(linked),
      kinds: kinds(linked),
      maps: maps(linked, total),
      rare: rare(linked, total)
    }
  end

  # ── Pairs ──────────────────────────────────────────────────────────────────

  # Each match with what the next one on its server kept of it.
  defp link(matches) do
    matches
    |> Enum.group_by(& &1.server_id)
    |> Enum.flat_map(fn {_server, list} -> link_server(list) end)
  end

  defp link_server(list) do
    list = Enum.sort_by(list, & &1.started_at, DateTime)

    for {match, next} <- Enum.zip(list, tl(list)), follows?(match, next), do: pair(match, next)
  end

  defp follows?(match, next) do
    seconds = DateTime.diff(next.started_at, match.ended_at)
    seconds >= -60 and seconds <= @link_seconds
  end

  defp pair(match, next) do
    next_ids = MapSet.new(next.players)
    stayed = match.stayed

    Map.merge(match, %{
      population: length(match.players),
      retention:
        if(stayed != [],
          do: Enum.count(stayed, &MapSet.member?(next_ids, &1)) / length(stayed)
        ),
      next_delta: length(next.players) - length(match.players),
      minutes: DateTime.diff(match.ended_at, match.started_at) / 60
    })
  end

  # ── Groups ─────────────────────────────────────────────────────────────────

  @doc "How a Warfare match went, for grouping."
  @spec kind(map()) :: atom()
  def kind(%{mode: mode} = match) when mode in [nil, "warfare"] do
    margin = abs((match.allied || 0) - (match.axis || 0))

    cond do
      is_nil(match.allied) -> :other
      margin == 5 and match.minutes <= @fast_minutes -> :fast_stomp
      margin == 5 -> :stomp
      margin > 0 -> :close
      true -> :other
    end
  end

  def kind(_match), do: :other

  defp kinds(pairs) do
    for kind <- [:fast_stomp, :stomp, :close] do
      group = Enum.filter(pairs, &(kind(&1) == kind))
      stats(group) |> Map.put(:kind, kind)
    end
  end

  defp maps(pairs, total) do
    pairs
    |> Enum.group_by(&{&1.map, &1.mode})
    |> Enum.map(fn {{map, mode}, group} ->
      group
      |> stats()
      |> Map.merge(%{
        map: map,
        mode: mode,
        share: if(total > 0, do: length(group) / total),
        stomps:
          share(
            Enum.filter(group, &(&1.mode in [nil, "warfare"])),
            &(kind(&1) in [:fast_stomp, :stomp])
          )
      })
    end)
    |> Enum.sort_by(& &1.matches, :desc)
  end

  # Less played maps against the rest.
  defp rare(pairs, total) do
    counts = Enum.frequencies_by(pairs, &{&1.map, &1.mode})
    rare? = fn pair -> total > 0 and counts[{pair.map, pair.mode}] / total < @rare_share end
    {rare, common} = Enum.split_with(pairs, rare?)

    %{
      threshold: @rare_share,
      maps: rare |> Enum.map(&{&1.map, &1.mode}) |> Enum.uniq() |> length(),
      rare: stats(rare),
      common: stats(common)
    }
  end

  defp stats(group) do
    %{
      matches: length(group),
      population: mean(group, & &1.population),
      retention: mean_of(group, & &1.retention),
      next_delta: mean(group, & &1.next_delta),
      minutes: mean(group, & &1.minutes)
    }
  end

  # ── Loading ────────────────────────────────────────────────────────────────

  defp load(server_ids, since) do
    scores =
      MatchImport
      |> where([i], i.server_id in ^server_ids and i.ended_at > ^since)
      |> select([i], {{i.server_id, i.match_id}, {i.allied_score, i.axis_score}})
      |> Repo.all()
      |> Map.new()

    MatchStat
    |> where([s], s.server_id in ^server_ids and s.ended_at > ^since and s.playtime_seconds > 0)
    |> select([s], %{
      server_id: s.server_id,
      match_id: s.match_id,
      player_id: s.player_id,
      seconds: s.playtime_seconds,
      map: s.map,
      mode: s.mode,
      started_at: s.started_at,
      ended_at: s.ended_at
    })
    |> Repo.all()
    |> Enum.group_by(&{&1.server_id, &1.match_id})
    |> Enum.flat_map(fn {{server_id, match_id} = key, [first | _] = rows} ->
      {allied, axis} = Map.get(scores, key, {nil, nil})

      if first.started_at && first.ended_at do
        [
          %{
            server_id: server_id,
            id: match_id,
            map: first.map,
            mode: first.mode,
            started_at: first.started_at,
            ended_at: first.ended_at,
            allied: allied,
            axis: axis,
            players: rows |> Enum.map(& &1.player_id) |> Enum.uniq(),
            stayed: for(r <- rows, r.seconds >= @stayed_seconds, uniq: true, do: r.player_id)
          }
        ]
      else
        []
      end
    end)
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp share([], _fun), do: nil
  defp share(list, fun), do: Enum.count(list, fun) / length(list)

  defp mean([], _fun), do: nil
  defp mean(list, fun), do: Enum.sum_by(list, fun) / length(list)

  defp mean_of(list, fun) do
    values = list |> Enum.map(fun) |> Enum.reject(&is_nil/1)
    if values == [], do: nil, else: Enum.sum(values) / length(values)
  end
end
