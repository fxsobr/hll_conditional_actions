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

  Five rules decide whether a match B gets a plan:

    * `:gap` - the teams' average ratings are `trigger_gap` or more apart
    * `:previous` - the match before B on the server (A, ended at most ten
      minutes before B started) had a dominant winner - `kills_ratio`x the
      loser's kills or `points_ratio`x its points - and at least `together`%
      of those winners who play B are on one side
    * `:streak` - `:previous`, and A itself was won by the dominant group of
      the match before it: two dominant wins in a row by the same players
      (the rule Squad's TeamBalancer uses)
    * `:both` and `:either` of `:gap` and `:previous`

  With `strong_weight` above 0, every player above 1000 counts that much
  more (`strength/2`): a team of a few stars and many beginners then reads
  stronger than a team of steady players with the same average, and the
  plans break the stars up. `prediction/2` compares how well each way of
  measuring a team foresees the result.

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

  @rules [:gap, :previous, :streak, :both, :either]
  # Ways of measuring a team, compared by `prediction/2`.
  @measures [{:mean, 0}, {:top, 15}, {:weight, 50}, {:weight, 100}, {:weight, 200}]
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
    "stack_bonus" => 30,
    "cooldown_hours" => 3,
    "strong_weight" => 0
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
      "stack_bonus" => int(params["stack_bonus"], @defaults["stack_bonus"], 0, 200),
      "cooldown_hours" => int(params["cooldown_hours"], @defaults["cooldown_hours"], 0, 48),
      "strong_weight" => int(params["strong_weight"], @defaults["strong_weight"], 0, 300)
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
    prediction = prediction(matches, params["trigger_gap"])
    matches = weigh(matches, params["strong_weight"])
    calibration = calibration(matches)

    # In time order, so each rule's cooldown sees the moves it already made.
    {judged, _moved_at} =
      matches
      |> link_previous(params)
      |> Enum.sort_by(&(&1.started_at || &1.ended_at), DateTime)
      |> Enum.map_reduce(Map.new(@rules, &{&1, %{}}), &judge(&1, &2, partners, params))

    %{
      params: params,
      matches: length(matches),
      fast: Enum.count(matches, &fast?/1),
      calibration: calibration,
      prediction: prediction,
      rules: Map.new(@rules, &{&1, summarize(judged, &1, calibration)})
    }
  end

  # ── Measuring a team ───────────────────────────────────────────────────────

  @doc """
  A rating with the part above 1000 counted `weight`% more.

      iex> alias HllConditionalActions.Balance.Analysis
      iex> {Analysis.strength(1300, 100), Analysis.strength(900, 100), Analysis.strength(1300, 0)}
      {1600.0, 900, 1300}
  """
  @spec strength(number(), number()) :: number()
  def strength(rating, 0), do: rating
  def strength(rating, weight) when rating > 1000, do: rating + (rating - 1000) * weight / 100
  def strength(rating, _weight), do: rating

  defp weigh(matches, 0), do: matches

  defp weigh(matches, weight) do
    Enum.map(matches, fn match ->
      %{match | players: Enum.map(match.players, &%{&1 | rating: strength(&1.rating, weight)})}
    end)
  end

  @doc """
  How well each way of measuring the teams foresees the matches: the mean
  rating, the mean blended half and half with the mean of each side's 15
  best (Squad's TeamBalancer), and the mean with the players above 1000
  weighed 50, 100 and 200% more (Battlefield's AdKats counts its stars far
  more than linearly).

  For each: how often the stronger side won; among the quarter of matches
  it reads as most uneven, how often the stronger side won and how many
  were over in 30 minutes; the share of all fast matches inside that
  quarter; and the gap that flags as many matches as `trigger` points do
  on the mean, since the scales differ.
  """
  @spec prediction([map()], number()) :: [map()]
  def prediction(matches, trigger) do
    flagged = Enum.count(matches, &(abs(gap(&1.players)) >= trigger))
    fast_total = Enum.count(matches, &fast?/1)

    for measure <- @measures, do: predict(measure, matches, flagged, fast_total)
  end

  defp predict({kind, value} = measure, matches, flagged, fast_total) do
    scored =
      matches
      |> Enum.map(&{&1, measure_gap(measure, &1.players)})
      |> Enum.sort_by(&abs(elem(&1, 1)), :desc)

    quarter = Enum.take(scored, div(length(scored) + 3, 4))
    fast_in_quarter = Enum.count(quarter, &fast?(elem(&1, 0)))

    %{
      kind: kind,
      value: value,
      favourite_won: share(decided(scored), &favourite_won?/1),
      top_won: share(decided(quarter), &favourite_won?/1),
      top_fast: if(quarter != [], do: fast_in_quarter / length(quarter)),
      fast_caught: if(fast_total > 0, do: fast_in_quarter / fast_total),
      trigger: if(flagged > 0, do: scored |> Enum.at(flagged - 1) |> elem(1) |> abs() |> round())
    }
  end

  defp decided(scored), do: Enum.filter(scored, &(elem(&1, 0).winner != nil))

  defp favourite_won?({match, gap}),
    do: match.winner == if(gap >= 0, do: :allies, else: :axis)

  defp measure_gap({:mean, _}, players), do: gap(players)

  defp measure_gap({:top, n}, players) do
    top = fn team ->
      ratings = for p <- players, p.team == team, do: p.rating
      best = ratings |> Enum.sort(:desc) |> Enum.take(n)
      if best == [], do: 0, else: Enum.sum(best) / length(best)
    end

    (gap(players) + top.(:allies) - top.(:axis)) / 2
  end

  defp measure_gap({:weight, weight}, players),
    do: gap(Enum.map(players, &%{&1 | rating: strength(&1.rating, weight)}))

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

  # Each match with the one that ended just before it on the same server,
  # the previous match's dominant group found in it (`stack`), and whether
  # that group had already won the match before (`streak?`).
  defp link_previous(matches, params) do
    matches
    |> Enum.group_by(& &1.server_id)
    |> Enum.flat_map(fn {_server, list} -> link_server(list, params) end)
  end

  defp link_server(list, params) do
    list
    |> Enum.sort_by(& &1.ended_at, DateTime)
    |> Enum.map_reduce(nil, fn match, previous ->
      match = Map.put(match, :previous, if(follows?(previous, match), do: previous))
      match = Map.put(match, :stack, stack(match, params))
      match = Map.put(match, :streak?, streak?(match))
      # The chain stops one match back: the next one only needs this stack.
      {match, Map.delete(match, :previous)}
    end)
    |> elem(0)
  end

  # Two dominant wins in a row by the same players: the group dominant in
  # A (found in B) is mostly the group that won A after dominating the match
  # before it.
  defp streak?(%{stack: nil}), do: false
  defp streak?(%{previous: %{stack: nil}}), do: false

  defp streak?(%{stack: stack, previous: previous}) do
    previous.winner == previous.stack.side and
      MapSet.size(MapSet.intersection(stack.ids, previous.stack.ids)) * 2 >=
        MapSet.size(stack.ids)
  end

  defp follows?(nil, _match), do: false

  defp follows?(previous, match) do
    start = match.started_at || match.ended_at
    seconds = DateTime.diff(start, previous.ended_at)
    seconds >= -60 and seconds <= @link_seconds + if(match.started_at, do: 0, else: 3 * 3600)
  end

  # `moved_at` holds, per rule, when each player was last moved by it.
  defp judge(match, moved_at, partners, params) do
    gap = gap(match.players)
    stack = match.stack
    at = match.started_at || match.ended_at
    cooldown = params["cooldown_hours"] * 3600

    fired =
      Map.new(@rules, fn rule ->
        {rule, fires?(rule, abs(gap) >= params["trigger_gap"], stack != nil, match.streak?)}
      end)

    plans =
      for {rule, true} <- fired, into: %{} do
        resting =
          for {id, time} <- moved_at[rule],
              DateTime.diff(at, time) < cooldown,
              into: MapSet.new(),
              do: id

        {rule, plan(match, stack, resting, partners, params)}
      end

    moved_at =
      Enum.reduce(plans, moved_at, fn {rule, plan}, acc ->
        update_in(acc[rule], fn times ->
          Enum.reduce(plan.moved, times, &Map.put(&2, &1.id, at))
        end)
      end)

    {%{
       match: match,
       gap: abs(gap),
       stack: stack,
       fired: fired,
       plans: plans,
       repeat?: stack != nil and stack_won?(match, stack)
     }, moved_at}
  end

  defp fires?(:gap, gap?, _previous?, _streak?), do: gap?
  defp fires?(:previous, _gap?, previous?, _streak?), do: previous?
  defp fires?(:streak, _gap?, _previous?, streak?), do: streak?
  defp fires?(:both, gap?, previous?, _streak?), do: gap? and previous?
  defp fires?(:either, gap?, previous?, _streak?), do: gap? or previous?

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

  defp plan(match, stack, resting, partners, params) do
    bonus = params["stack_bonus"]

    players =
      Enum.map(match.players, fn p ->
        boost = if stack && MapSet.member?(stack.ids, p.id), do: bonus, else: 0

        %{
          id: p.id,
          name: p.name,
          team: p.team,
          squad: p.squad,
          rating: p.rating + boost,
          movable?: not MapSet.member?(resting, p.id)
        }
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
    moved = Enum.flat_map(fired, & &1.plans[rule].moved)
    per_player = Enum.frequencies_by(moved, & &1.id)
    names = Map.new(moved, &{&1.id, &1.name})

    %{
      fired: length(fired),
      share: share(judged, & &1.fired[rule]),
      fast_share: share(fast, & &1.fired[rule]),
      repeat_share: share(repeats, & &1.fired[rule]),
      repeat_rate: share(Enum.filter(fired, & &1.stack), & &1.repeat?),
      gap_before: mean(fired, & &1.gap),
      gap_after: mean(fired, & &1.plans[rule].gap_after),
      chance_before: mean_of(fired, &expected(&1.gap, calibration)),
      chance_after: mean_of(fired, &expected(&1.plans[rule].gap_after, calibration)),
      moved: length(moved),
      moved_median: median(Enum.map(fired, &length(&1.plans[rule].moved))),
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
    |> where([p], fragment("cardinality(?) > 0 OR cardinality(?) > 0", p.roster, p.end_roster))
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
          Enum.map(if(plan.end_roster != [], do: plan.end_roster, else: plan.roster), fn p ->
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
