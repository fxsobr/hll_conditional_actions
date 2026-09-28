defmodule HllConditionalActions.Progression.Scoring do
  @moduledoc """
  How a season turns a finished match into points.

    * `:sum` - one stat, added up match after match. Rewards playing a lot.
    * `:average` - the same stat divided by the matches played. Rewards
      playing well, whatever the volume (with the season's minimum matches
      keeping one lucky game from winning it).
    * `:weighted` - a mix: each stat times its weight, added up. How a
      server says what it values ("support counts double, kills half").
    * `:elo` - a rating driven by results and performance, the way
      competitive games rank players; its formula is the season's own, see
      `HllConditionalActions.Progression.Rating`.
  """

  alias HllConditionalActions.Progression.Metrics
  alias HllConditionalActions.Progression.Rating

  @weighted_metrics [:kills, :combat, :offense, :defense, :support, :vehicles_destroyed]

  @doc "Every way a season can rank."
  @spec methods() :: [atom()]
  def methods, do: [:sum, :average, :weighted, :elo]

  @doc "The stats a weighted season can mix."
  @spec weighted_metrics() :: [atom()]
  def weighted_metrics, do: @weighted_metrics

  @doc """
  The new standing of every player of a match.

  `current` maps a player ID to their standing so far (`%{score, total,
  matches, wins, losses}`, missing for a newcomer); `outcome` is
  `outcome/1` of the final game state, or `nil` when it is unknown. Returns
  one standing per player who counts, keyed by player ID.
  """
  @spec score_match(map(), [map()], %{String.t() => map()}, map() | nil) :: %{
          String.t() => map()
        }
  def score_match(season, players, current, outcome) do
    case season.scoring do
      :elo -> Rating.score_match(season.rating, players, current, outcome)
      scoring -> Map.new(players, &{&1["player_id"], add(scoring, season, &1, current)})
    end
  end

  # ── Sum, average, weighted ─────────────────────────────────────────────────

  defp add(scoring, season, player, current) do
    before = Map.get(current, player["player_id"], blank(0))
    value = match_value(scoring, season, player)
    total = before.total + value
    matches = before.matches + 1

    %{
      before
      | total: total,
        matches: matches,
        score: if(scoring == :average, do: div(total, matches), else: total)
    }
  end

  defp match_value(:weighted, season, player) do
    Enum.reduce(@weighted_metrics, 0, fn metric, sum ->
      sum + weight(season.weights, metric) * Metrics.match_value(player, metric)
    end)
  end

  defp match_value(_sum_or_average, season, player),
    do: Metrics.match_value(player, season.metric)

  @doc "A stat's weight in a weighted season (0 when not set)."
  @spec weight(map() | nil, atom()) :: non_neg_integer()
  def weight(weights, metric) do
    case Map.get(weights || %{}, to_string(metric)) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, _rest} when int > 0 -> int
          _other -> 0
        end

      _unset ->
        0
    end
  end

  defp blank(score), do: %{score: score, total: 0, matches: 0, wins: 0, losses: 0}

  @doc """
  Who won a match, from its final game state: the side holding more of the
  five sectors, or `nil` when the state does not say.

      iex> alias HllConditionalActions.Progression.Scoring
      iex> Scoring.winner(%{"allied_score" => 4, "axis_score" => 1})
      :allies
      iex> Scoring.winner(%{"allied_score" => 2, "axis_score" => 2})
      :draw
      iex> Scoring.winner(nil)
      nil
  """
  @spec winner(map() | nil) :: :allies | :axis | :draw | nil
  def winner(%{"allied_score" => allied, "axis_score" => axis})
      when is_integer(allied) and is_integer(axis) do
    cond do
      allied > axis -> :allies
      axis > allied -> :axis
      true -> :draw
    end
  end

  def winner(_gamestate), do: nil

  @doc """
  The result of a match: who won and the sectors each side held.

      iex> alias HllConditionalActions.Progression.Scoring
      iex> Scoring.outcome(%{"allied_score" => 4, "axis_score" => 1})
      %{winner: :allies, allies: 4, axis: 1}
      iex> Scoring.outcome(%{})
      nil
  """
  @spec outcome(map() | nil) :: map() | nil
  def outcome(gamestate) do
    case winner(gamestate) do
      nil ->
        nil

      winner ->
        %{winner: winner, allies: gamestate["allied_score"], axis: gamestate["axis_score"]}
    end
  end
end
