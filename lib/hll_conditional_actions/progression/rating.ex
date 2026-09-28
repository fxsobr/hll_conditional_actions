defmodule HllConditionalActions.Progression.Rating do
  @moduledoc """
  The rating of an Elo season, built from blocks the season's admin tunes.

  The base is Elo on team strength, as FACEIT does for CS: each team's
  strength is the average rating of its players, and the chance of winning
  follows from the gap between the two,

      expected = 1 / (1 + 10 ^ ((opponents - team) / 400))

  A player's rating then moves by

      change = K × (w × (result − expected) + (1 − w) × performance)

  with every piece a setting:

    * **result** - `"win"`: 1 for a win, 0.5 for a draw, 0 for a loss; or
      `"caps"`: the sectors the team held at the end out of five, the way the
      HeLO clan ranking scores Hell Let Loose, so a 4-1 loss is not a 0-5.
    * **result_weight** (`w`, in %) - how much of the change comes from the
      result and how much from the player's own performance: 100 is a pure
      team result (FACEIT), a low value ranks mostly by performance (the way
      hellor.pro's H-Score looks at a player).
    * **performance** - weights for combat, offense, defense, support, kills
      per minute and K/D. Each stat is ranked within the player's own team
      (a percentile, so a map full of kills does not inflate anybody), and
      the weighted mean, from -0.5 to +0.5, is the performance. Teamkills
      take `teamkill_penalty` hundredths each.
    * **K** - the size of a change: `"fixed"`, or `"decreasing"` from 2K
      towards K/2 as a player plays more (20 matches halve the extra), so
      newcomers find their level fast and veterans stay stable. The first
      `placement` matches count double.
    * **no_gain_on_loss** - a loss never raises a rating and a win never
      lowers it, whatever the performance, as in Valorant.
    * **min_minutes** and **time_scaled** - below the minimum a match does
      not count; above it, the change is scaled by the share of the match
      the player was there for.
    * **max_change** and **floor** - caps on one match and on how low a
      rating goes.
    * **decay** - % per week a rating drifts back to the start after two
      weeks without playing, so the top cannot be held by not playing.

  Every setting is kept as a whole number or a string, in `Season.rating`.
  """

  @perf_stats ~w(combat offense defense support kpm kd)

  @defaults %{
    "preset" => "balanced",
    "initial" => 1000,
    "result" => "caps",
    "result_weight" => 70,
    "k" => 32,
    "k_mode" => "decreasing",
    "placement" => 10,
    "performance" => %{
      "combat" => 25,
      "offense" => 15,
      "defense" => 15,
      "support" => 15,
      "kpm" => 15,
      "kd" => 15
    },
    "teamkill_penalty" => 5,
    "no_gain_on_loss" => true,
    "min_minutes" => 15,
    "time_scaled" => true,
    "max_change" => 50,
    "floor" => 100,
    "decay" => 2
  }

  @presets %{
    # FACEIT: the team result and nothing else.
    "competitive" => %{
      "result" => "win",
      "result_weight" => 100,
      "k" => 50,
      "k_mode" => "fixed",
      "placement" => 10,
      "no_gain_on_loss" => true,
      "decay" => 2
    },
    "balanced" => %{},
    # Mostly what the player did, the result only tilting it.
    "performance" => %{
      "result" => "win",
      "result_weight" => 30,
      "k" => 32,
      "k_mode" => "decreasing",
      "no_gain_on_loss" => false,
      "performance" => %{
        "combat" => 20,
        "offense" => 20,
        "defense" => 20,
        "support" => 20,
        "kpm" => 10,
        "kd" => 10
      }
    }
  }

  # Where each tier starts, from the starting rating: a newcomer is silver.
  @tiers [
    bronze: nil,
    silver: -100,
    gold: 50,
    platinum: 200,
    diamond: 350,
    master: 500,
    legend: 650
  ]

  @doc "The settings of a new rating season."
  @spec defaults() :: map()
  def defaults, do: @defaults

  @doc "The preset names, in the order they are offered."
  @spec presets() :: [String.t()]
  def presets, do: ~w(competitive balanced performance)

  @doc "The settings of a preset."
  @spec preset(String.t()) :: map()
  def preset(name) do
    @defaults
    |> Map.merge(Map.get(@presets, name, %{}))
    |> Map.put("preset", name)
  end

  @doc "The stats performance can weigh."
  @spec perf_stats() :: [String.t()]
  def perf_stats, do: @perf_stats

  @doc """
  Settings as they are stored: every key present, numbers as integers
  within their range, booleans as booleans. Anything unknown is dropped.

      iex> alias HllConditionalActions.Progression.Rating
      iex> Rating.normalize(%{"k" => "500", "result" => "nope"})["k"]
      100
      iex> Rating.normalize(nil)["result"]
      "caps"
  """
  @spec normalize(map() | nil) :: map()
  def normalize(config) do
    config = stringify(config || %{})

    %{
      "preset" => pick(config["preset"], ["custom" | presets()], "custom"),
      "initial" => int(config["initial"], @defaults["initial"], 100, 5000),
      "result" => pick(config["result"], ~w(win caps), @defaults["result"]),
      "result_weight" => int(config["result_weight"], @defaults["result_weight"], 0, 100),
      "k" => int(config["k"], @defaults["k"], 1, 100),
      "k_mode" => pick(config["k_mode"], ~w(fixed decreasing), @defaults["k_mode"]),
      "placement" => int(config["placement"], @defaults["placement"], 0, 50),
      "performance" =>
        Map.new(@perf_stats, fn stat ->
          weights = stringify(config["performance"] || @defaults["performance"])
          {stat, int(weights[stat], 0, 0, 100)}
        end),
      "teamkill_penalty" => int(config["teamkill_penalty"], @defaults["teamkill_penalty"], 0, 50),
      "no_gain_on_loss" => bool(config["no_gain_on_loss"], @defaults["no_gain_on_loss"]),
      "min_minutes" => int(config["min_minutes"], @defaults["min_minutes"], 0, 120),
      "time_scaled" => bool(config["time_scaled"], @defaults["time_scaled"]),
      "max_change" => int(config["max_change"], @defaults["max_change"], 1, 500),
      "floor" => int(config["floor"], @defaults["floor"], 0, 5000),
      "decay" => int(config["decay"], @defaults["decay"], 0, 50)
    }
  end

  # ── One match ──────────────────────────────────────────────────────────────

  @doc """
  New standings for everybody who played long enough. `current` maps a
  player ID to their standing so far; `outcome` is `Scoring.outcome/1` of
  the match's final game state, and without it nobody moves - a rating
  cannot be updated without knowing who won.
  """
  @spec score_match(map(), [map()], %{String.t() => map()}, map() | nil) :: %{
          String.t() => map()
        }
  def score_match(config, players, current, outcome) do
    config = normalize(config)
    blank = blank(config["initial"])
    standing = fn player -> Map.get(current, player["player_id"], blank) end

    counted =
      Enum.filter(players, &(team(&1) != nil and minutes(&1) >= config["min_minutes"]))

    teams = Enum.group_by(counted, &team/1)
    match_minutes = players |> Enum.map(&minutes/1) |> Enum.max(fn -> 0 end)

    strength =
      Map.new(teams, fn {team, members} ->
        {team, strength(members, standing, config["time_scaled"])}
      end)

    Map.new(counted, fn player ->
      before = standing.(player)
      team = team(player)
      result = result(team, outcome, config["result"])

      delta =
        with true <- result != nil,
             {:ok, opponents} <- Map.fetch(strength, other(team)) do
          change(config, %{
            gap: opponents - strength[team],
            result: result,
            won: won(team, outcome),
            performance: performance(player, Map.fetch!(teams, team), config),
            matches: before.matches,
            share: if(match_minutes > 0, do: minutes(player) / match_minutes, else: 1.0)
          })
        else
          _unknown -> 0
        end

      won = won(team, outcome)

      {player["player_id"],
       %{
         before
         | score: max(before.score + delta, config["floor"]),
           matches: before.matches + 1,
           total: before.total + delta,
           wins: before.wins + if(won == true, do: 1, else: 0),
           losses: before.losses + if(won == false, do: 1, else: 0)
       }}
    end)
  end

  @doc """
  The change of one player's rating, from the pieces of the formula. Also
  used to show an admin what their settings do before they save them.

    * `gap` - the opponents' strength minus the team's
    * `result` - 0.0 to 1.0
    * `won` - true, false, or nil for a draw
    * `performance` - -0.5 to +0.5
    * `matches` - matches the player had before this one
    * `share` - the part of the match they played, 0.0 to 1.0
  """
  @spec change(map(), map()) :: integer()
  def change(config, %{} = match) do
    expected = 1 / (1 + :math.pow(10, match.gap / 400))
    weight = config["result_weight"] / 100

    raw =
      k(config, match.matches) *
        (weight * (match.result - expected) + (1 - weight) * match.performance)

    raw = if config["time_scaled"], do: raw * min(match.share, 1.0), else: raw

    raw =
      case {config["no_gain_on_loss"], match.won} do
        {true, false} -> min(raw, 0)
        {true, true} -> max(raw, 0)
        _either -> raw
      end

    raw |> round() |> max(-config["max_change"]) |> min(config["max_change"])
  end

  @doc "The K of a player with `matches` behind them."
  @spec k(map(), non_neg_integer()) :: float()
  def k(config, matches) do
    base =
      case config["k_mode"] do
        "decreasing" -> max(config["k"] / 2, 2 * config["k"] / (1 + matches / 20))
        _fixed -> config["k"] * 1.0
      end

    if matches < config["placement"], do: base * 2, else: base
  end

  @doc """
  How a player did against their own team, from -0.5 (worst in every
  weighted stat) to +0.5 (best), minus the teamkill penalty.
  """
  @spec performance(map(), [map()], map()) :: float()
  def performance(player, teammates, config) do
    weights = Enum.filter(config["performance"], fn {_stat, weight} -> weight > 0 end)
    total = Enum.sum_by(weights, &elem(&1, 1))

    base =
      if total == 0 or length(teammates) < 2 do
        0.0
      else
        Enum.sum_by(weights, fn {stat, weight} ->
          weight * (percentile(player, teammates, stat) - 0.5)
        end) / total
      end

    penalty =
      int(player["team_kills"] || player["teamkills"], 0, 0, 1000) * config["teamkill_penalty"] /
        100

    (base - penalty) |> max(-0.5) |> min(0.5)
  end

  # Share of teammates below the player in a stat; ties count half.
  defp percentile(player, teammates, stat) do
    value = stat(player, stat)
    others = Enum.reject(teammates, &(&1["player_id"] == player["player_id"]))
    below = Enum.count(others, &(stat(&1, stat) < value))
    equal = Enum.count(others, &(stat(&1, stat) == value))
    (below + equal / 2) / max(length(others), 1)
  end

  defp stat(player, "kpm"), do: int(player["kills"], 0, 0, 10_000) / max(minutes(player), 1)

  defp stat(player, "kd"),
    do: int(player["kills"], 0, 0, 10_000) / max(int(player["deaths"], 0, 0, 10_000), 1)

  defp stat(player, stat), do: int(player[stat], 0, 0, 1_000_000)

  # Time-weighted, so somebody who played five minutes weighs less in how
  # strong their team was.
  defp strength(members, standing, time_scaled?) do
    weighted =
      Enum.map(members, fn player ->
        {standing.(player).score, if(time_scaled?, do: max(minutes(player), 1), else: 1)}
      end)

    Enum.sum_by(weighted, fn {rating, weight} -> rating * weight end) /
      max(Enum.sum_by(weighted, &elem(&1, 1)), 1)
  end

  defp result(_team, nil, _mode), do: nil

  defp result(team, %{allies: allies, axis: axis}, "caps")
       when is_integer(allies) and is_integer(axis),
       do: if(team == :allies, do: allies, else: axis) / 5

  defp result(team, outcome, _win) do
    case won(team, outcome) do
      true -> 1.0
      false -> 0.0
      nil -> if outcome.winner == :draw, do: 0.5
    end
  end

  defp won(_team, nil), do: nil
  defp won(_team, %{winner: winner}) when winner in [nil, :draw], do: nil
  defp won(team, %{winner: winner}), do: team == winner

  # ── Over time ──────────────────────────────────────────────────────────────

  @doc """
  A rating after a week of decay: `decay` % of the way back to the start.

      iex> alias HllConditionalActions.Progression.Rating
      iex> Rating.decayed(1200, %{"decay" => 5, "initial" => 1000})
      1190
      iex> Rating.decayed(900, %{"decay" => 5, "initial" => 1000})
      905
  """
  @spec decayed(integer(), map()) :: integer()
  def decayed(score, config),
    do: round(score - (score - config["initial"]) * config["decay"] / 100)

  @doc """
  The tier of a rating.

      iex> alias HllConditionalActions.Progression.Rating
      iex> Rating.tier(1000, %{"initial" => 1000})
      :silver
      iex> Rating.tier(1700, %{"initial" => 1000})
      :legend
  """
  @spec tier(integer(), map()) :: atom()
  def tier(score, config) do
    config
    |> tiers()
    |> Enum.filter(fn {_tier, from} -> from == nil or score >= from end)
    |> List.last()
    |> elem(0)
  end

  @doc "Every tier, lowest first, with the rating it starts at (nil for the first)."
  @spec tiers(map()) :: [{atom(), integer() | nil}]
  def tiers(config) do
    initial = normalize(config)["initial"]
    Enum.map(@tiers, fn {tier, offset} -> {tier, offset && initial + offset} end)
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp minutes(player), do: int(player["map_playtime_seconds"], 0, 0, 100_000) / 60

  defp team(player) do
    case player |> Map.get("team") |> to_string() |> String.downcase() do
      "allies" -> :allies
      "axis" -> :axis
      _other -> nil
    end
  end

  defp other(:allies), do: :axis
  defp other(:axis), do: :allies

  defp blank(score), do: %{score: score, total: 0, matches: 0, wins: 0, losses: 0}

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_other), do: %{}

  defp pick(value, allowed, default) do
    value = if is_atom(value) and value != nil, do: Atom.to_string(value), else: value
    if value in allowed, do: value, else: default
  end

  defp int(value, _default, min, max) when is_integer(value), do: value |> max(min) |> min(max)

  defp int(value, default, min, max) when is_float(value),
    do: int(round(value), default, min, max)

  defp int(value, default, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> int(parsed, default, min, max)
      :error -> default
    end
  end

  defp int(_value, default, _min, _max), do: default

  defp bool(value, _default) when is_boolean(value), do: value
  defp bool("true", _default), do: true
  defp bool("false", _default), do: false
  defp bool(_value, default), do: default
end
