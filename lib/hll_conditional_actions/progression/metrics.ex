defmodule HllConditionalActions.Progression.Metrics do
  @moduledoc """
  What achievements and seasons can count.

  Match metrics are read from a player's end of match stats; career metrics
  from their `PlayerTotal`, which adds every match up. A few only exist over
  a career - matches played, matches as commander or squad leader - because
  they count matches, not what happened in one.

  The commander and squad leader counts are how the server rewards the
  people who help it run: a match counts when the player ended it in that
  role having played at least twenty minutes of it.
  """

  @match [
    :kills,
    :combat,
    :offense,
    :defense,
    :support,
    :teamplay,
    :vehicles_destroyed,
    :playtime_minutes
  ]

  @career_only [:matches, :commander_matches, :leader_matches]

  @role_minutes 20

  @doc "Every metric."
  @spec all() :: [atom()]
  def all, do: @match ++ @career_only

  @doc "Metrics a single match can reach."
  @spec match() :: [atom()]
  def match, do: @match

  @doc "Metrics that only exist over a career."
  @spec career_only() :: [atom()]
  def career_only, do: @career_only

  @doc "Minutes a player must play in a role for the match to count for it."
  @spec role_minutes() :: pos_integer()
  def role_minutes, do: @role_minutes

  @doc """
  A metric's value in one match, from a `get_detailed_players` entry.

      iex> player = %{"combat" => 300, "support" => 700, "map_playtime_seconds" => 1800}
      iex> alias HllConditionalActions.Progression.Metrics
      iex> {Metrics.match_value(player, :teamplay), Metrics.match_value(player, :playtime_minutes)}
      {1000, 30}
  """
  @spec match_value(map(), atom()) :: integer()
  def match_value(player, :teamplay), do: int(player, "combat") + int(player, "support")
  def match_value(player, :playtime_minutes), do: div(int(player, "map_playtime_seconds"), 60)
  def match_value(player, metric), do: int(player, Atom.to_string(metric))

  @doc "A metric's value over a career, from a `PlayerTotal`."
  @spec career_value(map(), atom()) :: integer()
  def career_value(total, :teamplay), do: total.combat + total.support
  def career_value(total, :playtime_minutes), do: div(total.playtime_seconds, 60)
  def career_value(total, metric), do: Map.fetch!(total, metric)

  @doc """
  Whether a player's end of match role counts for a helper metric.
  """
  @spec role_match(map()) :: :commander | :leader | nil
  def role_match(player) do
    played? = int(player, "map_playtime_seconds") >= @role_minutes * 60

    case player |> Map.get("role") |> to_string() |> String.downcase() do
      "armycommander" when played? -> :commander
      role when played? and role in ~w(officer tankcommander spotter) -> :leader
      _other -> nil
    end
  end

  defp int(player, key) do
    case Map.get(player, key) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      _missing -> 0
    end
  end
end
