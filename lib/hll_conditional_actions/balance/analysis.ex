defmodule HllConditionalActions.Balance.Analysis do
  @moduledoc """
  "What if": the team balance replayed over past matches with settings an
  admin picks, comparing ways of deciding when to act.

  Every match is a roster with each player's team, squad and rating, the
  result and how long it lasted, from one of two sources:

    * `:history` - the matches read from CRCON (`Players.MatchStat`), with
      today's balance ratings. Months of data, but optimistic: the ratings
      have already learned from those very results.
    * `:live` - the plans the module recorded at the end of each match, with
      the ratings they had then (`Plan.roster`). Honest, and growing.

  Four rules decide whether a match B gets a plan:

    * `:gap` - the teams' average ratings are `trigger_gap` or more apart
    * `:previous` - the match before B on the server (A, ended at most ten
      minutes before B started) had a dominant winner - `kills_ratio`x the
      loser's kills or `points_ratio`x its points - and at least `together`%
      of those winners who play B are on one side
    * `:both` and `:either` of those

  A triggered match is planned the way the module plans
  (`Balance.Planner`), with A's winners counted `stack_bonus` points
  stronger when A was dominant, so the plan breaks the group up rather than
  only evening the averages.

  The gap -> outcome relation of the same matches (`calibration/1`) turns a
  gap into the chance the stronger side wins, to compare before and after.
  """

  import Ecto.Query

  alias HllConditionalActions.Balance
  alias HllConditionalActions.Balance.Partner
  alias HllConditionalActions.Balance.Plan
  alias HllConditionalActions.Balance.Planner
  alias HllConditionalActions.Players.MatchImport
  alias HllConditionalActions.Players.MatchStat
  alias HllConditionalActions.Repo

  @rules [:gap, :previous, :both, :either]
  @buckets [{0, 10}, {10, 20}, {20, 35}, {35, 50}, {50, 70}, {70, nil}]
  # Under ten minutes played, a player says little about a team.
  @min_seconds 600
  @min_players 60
  @fast_minutes 30
  # A started at most this long after B ended to be "the match before".
  @link_seconds 600

  @defaults %{
    "source" => "history",
    "days" => 14,
    "trigger_gap" => 35,
    "max_moves" => 12,
    "max_count_gap" => 2,
    "partner_matches" => 3,
    "kills_ratio" => 150,
    "points_ratio" => 130,
    "together" => 85,
    "stack_bonus" => 30
  }

  @doc "The rules compared, in display order."
  @spec rules() :: [atom()]
  def rules, do: @rules

  @doc "The settings a replay starts from."
  @spec defaults() :: map()
  def defaults, do: @defaults

  @doc """
  Settings from a form, every key present and within range.

      iex> alias HllConditionalActions.Balance.Analysis
      iex> Analysis.normalize(%{"trigger_gap" => "500", "source" => "nope"})["trigger_gap"]
      200
      iex> Analysis.normalize(%{})["source"]
      "history"
  """
  @spec normalize(map()) :: map()
  def normalize(params) do
    params = params || %{}

    %{
      "source" => if(params["source"] == "live", do: "live", else: "history"),
      "days" => pick(params["days"], [7, 14, 30, 45], @defaults["days"]),
      "trigger_gap" => int(params["trigger_gap"], @defaults["trigger_gap"], 5, 200),
      "max_moves" => int(params["max_moves"], @defaults["max_moves"], 1, 30),
      "max_count_gap" => int(params["max_count_gap"], @defaults["max_count_gap"], 0, 6),
      "partner_matches" => int(params["partner_matches"], @defaults["partner_matches"], 2, 20),
      "kills_ratio" => int(params["kills_ratio"], @defaults["kills_ratio"], 100, 400),
      "points_ratio" => int(params["points_ratio"], @defaults["points_ratio"], 100, 400),
      "together" => int(params["together"], @defaults["together"], 50, 100),
      "stack_bonus" => int(params["stack_bonus"], @defaults["stack_bonus"], 0, 200)
    }
  end

  # ── Running ────────────────────────────────────────────────────────────────

  @doc """
  Replays the balance over the matches of some servers. Returns the matches
  considered, the calibration of those matches, and one summary per rule
  (`summarize/2`).
  """
  @spec run([term()], map(), atom() | String.t()) :: map()
  def run(server_ids, params, game \\ :hll) do
    params = normalize(params)

    matches =
      case params["source"] do
        "live" -> live_matches(server_ids, params["days"])
        _history -> history_matches(server_ids, params["days"], game)
      end

    partners = partner_pairs(params["partner_matches"])
    replay(matches, partners, params)
  end

  @doc """
  The replay itself, on matches already loaded (see the moduledoc for their
  shape). Pure, so it can be tested without a database.
  """
  @spec replay([map()], MapSet.t(), map()) :: map()
  def replay(matches, partners, params) do
    params = normalize(params)
    calibration = calibration(matches)

    judged =
      matches
      |> link_previous()
      |> Enum.map(&judge(&1, partners, params))

    %{
      params: params,
      matches: length(matches),
      fast: Enum.count(matches, &fast?/1),
      calibration: calibration,
      rules: Map.new(@rules, &{&1, summarize(judged, &1, calibration)})
    }
  end

  # ── Calibration ────────────────────────────────────────────────────────────

  @doc """
  For each band of rating gap: how many matches, how often the side with the
  higher average rating won, and how often the match ended in thirty
  minutes or less.
  """
  @spec calibration([map()]) :: [map()]
  def calibration(matches) do
    for {from, to} <- @buckets do
      in_band = Enum.filter(matches, &in_band?(abs(gap(&1.players)), from, to))
      decided = Enum.filter(in_band, &(&1.winner != nil))

      %{
        from: from,
        to: to,
        matches: length(in_band),
        favourite_won: share(decided, &(favourite(&1.players) == &1.winner)),
        fast: share(Enum.filter(in_band, &(&1.minutes != nil)), &fast?/1)
      }
    end
  end

  @doc """
  The chance the stronger side wins at a gap, read from a calibration;
  nil where the calibration has no match.
  """
  @spec expected(number(), [map()]) :: float() | nil
  def expected(gap, calibration) do
    case Enum.find(calibration, &in_band?(abs(gap), &1.from, &1.to)) do
      %{favourite_won: rate} -> rate
      nil -> nil
    end
  end

  defp in_band?(value, from, nil), do: value >= from
  defp in_band?(value, from, to), do: value >= from and value < to

  # ── Judging one match ──────────────────────────────────────────────────────

  # Each match with the one that ended just before it on the same server.
  defp link_previous(matches) do
    matches
    |> Enum.group_by(& &1.server_id)
    |> Enum.flat_map(fn {_server, list} -> link_server(list) end)
  end

  defp link_server(list) do
    list = Enum.sort_by(list, & &1.ended_at, DateTime)

    [nil | list]
    |> Enum.zip(list)
    |> Enum.map(fn {previous, match} ->
      Map.put(match, :previous, if(follows?(previous, match), do: previous))
    end)
  end

  defp follows?(nil, _match), do: false

  defp follows?(previous, match) do
    start = match.started_at || match.ended_at
    seconds = DateTime.diff(start, previous.ended_at)
    seconds >= -60 and seconds <= @link_seconds + if(match.started_at, do: 0, else: 3 * 3600)
  end

  defp judge(match, partners, params) do
    gap = gap(match.players)
    stack = stack(match, params)

    fired =
      Map.new(@rules, fn rule ->
        {rule, fires?(rule, abs(gap) >= params["trigger_gap"], stack != nil)}
      end)

    plan =
      if Enum.any?(Map.values(fired)),
        do: plan(match, stack, partners, params)

    %{
      match: match,
      gap: abs(gap),
      stack: stack,
      fired: fired,
      plan: plan,
      repeat?: stack != nil and stack_won?(match, stack)
    }
  end

  defp fires?(:gap, gap?, _previous?), do: gap?
  defp fires?(:previous, _gap?, previous?), do: previous?
  defp fires?(:both, gap?, previous?), do: gap? and previous?
  defp fires?(:either, gap?, previous?), do: gap? or previous?

  # A's winners, when A was dominant and they are together in B.
  defp stack(%{previous: nil}, _params), do: nil

  defp stack(%{previous: previous} = match, params) do
    with winner when winner in [:allies, :axis] <- previous.winner,
         true <- dominant?(previous, winner, params) do
      winners = for p <- previous.players, p.team == winner, into: MapSet.new(), do: p.id
      here = Enum.filter(match.players, &MapSet.member?(winners, &1.id))
      by_side = Enum.frequencies_by(here, & &1.team)
      {side, count} = Enum.max_by(by_side, &elem(&1, 1), fn -> {nil, 0} end)

      if length(here) >= 10 and count * 100 >= params["together"] * length(here) do
        %{side: side, ids: MapSet.new(for p <- here, p.team == side, do: p.id)}
      end
    else
      _not_dominant -> nil
    end
  end

  defp dominant?(match, winner, params) do
    loser = other(winner)

    totals = fn team, key ->
      match.players |> Enum.filter(&(&1.team == team)) |> Enum.sum_by(&Map.get(&1, key, 0))
    end

    ratio = fn key -> totals.(winner, key) * 100 / max(totals.(loser, key), 1) end

    ratio.(:kills) >= params["kills_ratio"] or ratio.(:points) >= params["points_ratio"]
  end

  defp stack_won?(match, stack), do: match.winner == stack.side

  defp plan(match, stack, partners, params) do
    bonus = params["stack_bonus"]

    players =
      Enum.map(match.players, fn p ->
        boost = if stack && MapSet.member?(stack.ids, p.id), do: bonus, else: 0
        %{id: p.id, name: p.name, team: p.team, squad: p.squad, rating: p.rating + boost}
      end)

    result =
      Planner.plan(players, partners,
        target_gap: max(div(params["trigger_gap"], 2), 5),
        max_moves: params["max_moves"],
        max_count_gap: params["max_count_gap"]
      )

    moved = result.moves |> Enum.flat_map(& &1.players) |> MapSet.new(& &1.id)

    after_players =
      Enum.map(match.players, fn p ->
        if MapSet.member?(moved, p.id), do: %{p | team: other(p.team)}, else: p
      end)

    %{
      moved: Enum.filter(match.players, &MapSet.member?(moved, &1.id)),
      gap_after: abs(gap(after_players)),
      stack_left:
        if(stack,
          do:
            Enum.count(
              after_players,
              &(MapSet.member?(stack.ids, &1.id) and &1.team == stack.side)
            )
        )
    }
  end

  # ── Summaries ──────────────────────────────────────────────────────────────

  @doc """
  What one rule would have done over the judged matches: how many it acts
  on (and of the fast ones, and of the repeated stomps), the gap and the
  stronger side's chance before and after, and the players it moves.
  """
  @spec summarize([map()], atom(), [map()]) :: map()
  def summarize(judged, rule, calibration) do
    fired = Enum.filter(judged, & &1.fired[rule])
    fast = Enum.filter(judged, &fast?(&1.match))
    repeats = Enum.filter(judged, & &1.repeat?)
    moved = Enum.flat_map(fired, & &1.plan.moved)
    per_player = Enum.frequencies_by(moved, & &1.id)
    names = Map.new(moved, &{&1.id, &1.name})

    %{
      fired: length(fired),
      share: share(judged, & &1.fired[rule]),
      fast_share: share(fast, & &1.fired[rule]),
      repeat_share: share(repeats, & &1.fired[rule]),
      repeat_rate: share(Enum.filter(fired, & &1.stack), & &1.repeat?),
      gap_before: mean(fired, & &1.gap),
      gap_after: mean(fired, & &1.plan.gap_after),
      chance_before: mean_of(fired, &expected(&1.gap, calibration)),
      chance_after: mean_of(fired, &expected(&1.plan.gap_after, calibration)),
      moved: length(moved),
      moved_median: median(Enum.map(fired, &length(&1.plan.moved))),
      players_moved: map_size(per_player),
      most_moved:
        per_player
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> Enum.take(10)
        |> Enum.map(fn {id, count} -> %{id: id, name: names[id], times: count} end)
    }
  end

  # ── Loading ────────────────────────────────────────────────────────────────

  @doc false
  def history_matches(server_ids, days, game) do
    since = DateTime.add(DateTime.utc_now(), -days, :day)

    imports =
      MatchImport
      |> where([i], i.server_id in ^server_ids and i.ended_at > ^since)
      |> where([i], not is_nil(i.allied_score))
      |> Repo.all()

    keys = MapSet.new(imports, &{&1.server_id, &1.match_id})

    lines =
      MatchStat
      |> where([s], s.server_id in ^server_ids and s.ended_at > ^since)
      |> where([s], s.playtime_seconds >= @min_seconds and s.team in ["allies", "axis"])
      |> select([s], %{
        server_id: s.server_id,
        match_id: s.match_id,
        id: s.player_id,
        name: s.player_name,
        team: s.team,
        squad: s.unit_name,
        kills: s.kills,
        points: s.combat + s.offense + s.defense + s.support,
        mode: s.mode,
        map: s.map,
        started_at: s.started_at,
        ended_at: s.ended_at
      })
      |> Repo.all()
      |> Enum.filter(&MapSet.member?(keys, {&1.server_id, &1.match_id}))

    ratings = Balance.ratings(game, lines |> Enum.map(& &1.id) |> Enum.uniq())
    by_match = Enum.group_by(lines, &{&1.server_id, &1.match_id})

    imports
    |> Enum.map(&history_match(&1, Map.get(by_match, {&1.server_id, &1.match_id}, []), ratings))
    |> Enum.filter(&usable?/1)
  end

  defp history_match(import, [], _ratings), do: %{id: import.match_id, ended_at: nil}

  defp history_match(import, [first | _rest] = rows, ratings) do
    %{
      server_id: import.server_id,
      id: import.match_id,
      map: first.map,
      mode: first.mode,
      started_at: first.started_at,
      ended_at: import.ended_at || first.ended_at,
      minutes: minutes(first),
      winner: winner(import.allied_score, import.axis_score),
      players: Enum.map(rows, &history_player(&1, ratings))
    }
  end

  defp history_player(row, ratings) do
    r = ratings[row.id]

    %{
      id: row.id,
      name: row.name,
      team: team(row.team),
      squad: row.squad,
      rating: Balance.effective_rating(r && r.rating, (r && r.matches) || 0),
      kills: row.kills || 0,
      points: row.points || 0
    }
  end

  @doc false
  def live_matches(server_ids, days) do
    since = DateTime.add(DateTime.utc_now(), -days, :day)

    Plan
    |> where([p], p.server_id in ^server_ids and p.ended_at > ^since)
    |> where([p], fragment("cardinality(?) > 0", p.roster))
    |> Repo.all()
    |> Enum.map(fn plan ->
      %{
        server_id: plan.server_id,
        id: plan.id,
        map: plan.map,
        mode: "warfare",
        started_at: nil,
        ended_at: plan.ended_at,
        minutes: nil,
        winner: winner(plan.allied_score, plan.axis_score),
        players:
          Enum.map(plan.roster, fn p ->
            %{
              id: p["id"],
              name: p["name"],
              team: team(p["team"]),
              squad: p["squad"],
              rating: p["rating"] || 1000,
              kills: p["kills"] || 0,
              points: p["points"] || 0
            }
          end)
      }
    end)
    |> Enum.filter(&usable?/1)
  end

  defp usable?(%{ended_at: nil}), do: false

  defp usable?(match) do
    match.mode in [nil, "warfare"] and
      length(match.players) >= @min_players and
      Enum.any?(match.players, &(&1.team == :allies)) and
      Enum.any?(match.players, &(&1.team == :axis))
  end

  defp partner_pairs(min_matches) do
    Partner
    |> where([p], p.matches >= ^min_matches)
    |> select([p], {p.player_a, p.player_b})
    |> Repo.all()
    |> MapSet.new()
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @doc """
  The gap between the teams' average ratings, allies minus axis.

      iex> alias HllConditionalActions.Balance.Analysis
      iex> Analysis.gap([%{team: :allies, rating: 1100}, %{team: :axis, rating: 1000}])
      100.0
  """
  @spec gap([map()]) :: float()
  def gap(players) do
    avg = fn team ->
      ratings = for p <- players, p.team == team, do: p.rating
      if ratings == [], do: nil, else: Enum.sum(ratings) / length(ratings)
    end

    case {avg.(:allies), avg.(:axis)} do
      {a, x} when is_number(a) and is_number(x) -> a - x
      _empty -> 0.0
    end
  end

  defp favourite(players), do: if(gap(players) >= 0, do: :allies, else: :axis)

  defp fast?(%{minutes: minutes}) when is_number(minutes), do: minutes <= @fast_minutes
  defp fast?(_match), do: false

  defp minutes(%{started_at: %DateTime{} = a, ended_at: %DateTime{} = b}),
    do: DateTime.diff(b, a) / 60

  defp minutes(_row), do: nil

  defp winner(allied, axis) when is_integer(allied) and is_integer(axis) do
    cond do
      allied > axis -> :allies
      axis > allied -> :axis
      true -> nil
    end
  end

  defp winner(_allied, _axis), do: nil

  defp team("allies"), do: :allies
  defp team("axis"), do: :axis
  defp team(_other), do: nil

  defp other(:allies), do: :axis
  defp other(:axis), do: :allies

  defp share([], _fun), do: nil
  defp share(list, fun), do: Enum.count(list, fun) / length(list)

  defp mean([], _fun), do: nil
  defp mean(list, fun), do: Enum.sum_by(list, fun) / length(list)

  defp mean_of(list, fun) do
    values = list |> Enum.map(fun) |> Enum.reject(&is_nil/1)
    if values == [], do: nil, else: Enum.sum(values) / length(values)
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp int(value, _default, min, max) when is_integer(value), do: value |> max(min) |> min(max)

  defp int(value, default, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> int(parsed, default, min, max)
      :error -> default
    end
  end

  defp int(_value, default, _min, _max), do: default

  defp pick(value, allowed, default) do
    case int(value, default, 0, 10_000) do
      parsed -> if parsed in allowed, do: parsed, else: default
    end
  end
end
