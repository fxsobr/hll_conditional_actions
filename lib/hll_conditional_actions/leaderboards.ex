defmodule HllConditionalActions.Leaderboards do
  @moduledoc """
  Who is on top, right now: players by category and squads by type.

  Everything is computed from the roster the engine already fetches
  (`get_detailed_players`), so a leaderboard costs no CRCON call of its own
  and is exactly as fresh as the snapshot the rules are judged against.

  ## Players

  Each category ranks by one number. Two need a floor so a lucky start does
  not top the table: the K/D ratio counts only players with at least five
  kills, and kills per minute only players with five minutes on the map.
  `:teamplay` (combat + support) and `:offdef` (offense + defense) are the
  combined scores the community top stats plugin made popular.

  ## Squads

  Players are grouped by team and unit. A squad's type is guessed from its
  members' roles the way CRCON's `get_team_view` does - tank crew is armor,
  spotter and sniper are recon, artillery roles are artillery, everything
  else infantry - and squads rank within their type by the sum of their
  members' four scores. The commander is not a squad.
  """

  @min_kills_for_ratio 5
  @min_seconds_for_rate 300

  @categories [
    :kills,
    :kill_death_ratio,
    :kills_per_minute,
    :combat,
    :offense,
    :defense,
    :support,
    :vehicles_destroyed,
    :teamplay,
    :offdef
  ]

  @squad_types [:infantry, :armor, :recon, :artillery]

  @armor_roles ~w(tankcommander crewman)
  @recon_roles ~w(spotter sniper)
  @artillery_roles ~w(artilleryobserver operator gunner)
  @commander_roles ~w(armycommander)

  @doc "Every player category, in display order."
  @spec categories() :: [atom()]
  def categories, do: @categories

  @doc "Every squad type, in display order."
  @spec squad_types() :: [atom()]
  def squad_types, do: @squad_types

  # ── Players ────────────────────────────────────────────────────────────────

  @doc """
  The top `count` players of a category, best first, as
  `%{player_id, name, team, value}`. Ties keep the roster's order.

      iex> roster = %{
      ...>   "a" => %{"player_id" => "a", "name" => "Ana", "kills" => 12},
      ...>   "b" => %{"player_id" => "b", "name" => "Bo", "kills" => 30},
      ...>   "c" => %{"player_id" => "c", "name" => "Cy", "kills" => 0}
      ...> }
      iex> HllConditionalActions.Leaderboards.top_players(roster, :kills, 2)
      ...> |> Enum.map(&{&1.name, &1.value})
      [{"Bo", 30}, {"Ana", 12}]
  """
  @spec top_players(map() | [map()], atom(), pos_integer()) :: [map()]
  def top_players(roster, category, count) when category in @categories do
    roster
    |> ranked(category)
    |> Enum.take(count)
  end

  @doc """
  Where a player stands in a category, 1 being the best, or `nil` when they
  are not ranked (no score yet, or under the floor the category needs).

      iex> roster = %{
      ...>   "a" => %{"player_id" => "a", "kills" => 12},
      ...>   "b" => %{"player_id" => "b", "kills" => 30}
      ...> }
      iex> HllConditionalActions.Leaderboards.rank(roster, "a", :kills)
      2
  """
  @spec rank(map() | [map()], String.t() | nil, atom()) :: pos_integer() | nil
  def rank(_roster, nil, _category), do: nil

  def rank(roster, player_id, category) when category in @categories do
    roster
    |> ranked(category)
    |> Enum.find_index(&(&1.player_id == player_id))
    |> case do
      nil -> nil
      index -> index + 1
    end
  end

  @doc """
  A player's rank in every category at once, for storing alongside a sample.
  """
  @spec ranks(map() | [map()], String.t() | nil) :: %{atom() => pos_integer() | nil}
  def ranks(roster, player_id) do
    squad_rank = squad_rank(roster, player_id)

    @categories
    |> Map.new(&{&1, rank(roster, player_id, &1)})
    |> Map.put(:squad, squad_rank)
  end

  defp ranked(roster, category) do
    roster
    |> players()
    |> Enum.map(fn player -> {player, value(player, category)} end)
    |> Enum.reject(fn {_player, value} -> is_nil(value) or value <= 0 end)
    |> Enum.sort_by(fn {_player, value} -> value end, :desc)
    |> Enum.map(fn {player, value} ->
      %{
        player_id: player["player_id"],
        name: player["name"],
        team: player["team"],
        value: value
      }
    end)
  end

  @doc """
  A player's value in a category, or `nil` when it cannot be ranked.
  """
  @spec value(map(), atom()) :: number() | nil
  def value(player, :kill_death_ratio) do
    kills = number(player, "kills")

    if kills >= @min_kills_for_ratio do
      Float.round(kills / max(number(player, "deaths"), 1), 2)
    end
  end

  def value(player, :kills_per_minute) do
    seconds = number(player, "map_playtime_seconds")

    if seconds >= @min_seconds_for_rate do
      Float.round(number(player, "kills") / (seconds / 60), 2)
    end
  end

  def value(player, :teamplay), do: number(player, "combat") + number(player, "support")
  def value(player, :offdef), do: number(player, "offense") + number(player, "defense")
  def value(player, category), do: number(player, Atom.to_string(category))

  # ── Squads ─────────────────────────────────────────────────────────────────

  @doc """
  The squads of the server, grouped by type and best first within it, as
  `%{type => [%{team, name, size, has_leader, score, kills, members}]}`.
  """
  @spec squads(map() | [map()]) :: %{atom() => [map()]}
  def squads(roster) do
    roster
    |> players()
    |> Enum.reject(&(role(&1) in @commander_roles or blank?(&1["unit_name"])))
    |> Enum.group_by(&{&1["team"], &1["unit_name"]})
    |> Enum.map(fn {{team, unit}, members} ->
      %{
        team: team,
        name: unit,
        type: squad_type(members),
        size: length(members),
        has_leader: Enum.any?(members, &(role(&1) in ~w(officer tankcommander spotter))),
        score: Enum.sum_by(members, &squad_score/1),
        kills: Enum.sum_by(members, &number(&1, "kills")),
        members: Enum.map(members, & &1["name"])
      }
    end)
    |> Enum.reject(&(&1.score <= 0))
    |> Enum.group_by(& &1.type)
    |> Map.new(fn {type, squads} -> {type, Enum.sort_by(squads, & &1.score, :desc)} end)
  end

  @doc "The top `count` squads of a type."
  @spec top_squads(map() | [map()], atom(), pos_integer()) :: [map()]
  def top_squads(roster, type, count) when type in @squad_types do
    roster |> squads() |> Map.get(type, []) |> Enum.take(count)
  end

  @doc """
  Where the player's squad stands among the squads of its own type.
  """
  @spec squad_rank(map() | [map()], String.t() | nil) :: pos_integer() | nil
  def squad_rank(_roster, nil), do: nil

  def squad_rank(roster, player_id) do
    players = players(roster)

    with %{} = player <- Enum.find(players, &(&1["player_id"] == player_id)),
         unit when is_binary(unit) and unit != "" <- player["unit_name"],
         {_type, squads} <- find_type(squads(players), player["team"], unit),
         index when is_integer(index) <-
           Enum.find_index(squads, &(&1.team == player["team"] and &1.name == unit)) do
      index + 1
    else
      _unranked -> nil
    end
  end

  @doc """
  The type of the player's squad, or `nil` when they are not in one.
  """
  @spec squad_type_of(map() | [map()], String.t() | nil) :: atom() | nil
  def squad_type_of(roster, player_id) do
    players = players(roster)

    case Enum.find(players, &(&1["player_id"] == player_id)) do
      %{"unit_name" => unit, "team" => team}
      when is_binary(unit) and unit not in ["", "command"] ->
        players
        |> Enum.filter(&(&1["unit_name"] == unit and &1["team"] == team))
        |> squad_type()

      _no_squad ->
        nil
    end
  end

  defp find_type(squads_by_type, team, unit) do
    Enum.find(squads_by_type, fn {_type, squads} ->
      Enum.any?(squads, &(&1.team == team and &1.name == unit))
    end)
  end

  defp squad_type(members) do
    roles = Enum.map(members, &role/1)

    cond do
      Enum.any?(roles, &(&1 in @armor_roles)) -> :armor
      Enum.any?(roles, &(&1 in @recon_roles)) -> :recon
      Enum.any?(roles, &(&1 in @artillery_roles)) -> :artillery
      true -> :infantry
    end
  end

  defp squad_score(player) do
    number(player, "combat") + number(player, "offense") + number(player, "defense") +
      number(player, "support")
  end

  # ── Text for messages ──────────────────────────────────────────────────────

  @doc """
  A category as one line for an in-game message: `"Ana (30), Bo (12)"`.
  Language free on purpose - the admin writes the headings in the rule's own
  message, so the line reads right in whatever language the server speaks.

      iex> roster = %{"a" => %{"player_id" => "a", "name" => "Ana", "kills" => 30}}
      iex> HllConditionalActions.Leaderboards.line(roster, :kills, 3)
      "Ana (30)"
  """
  @spec line(map() | [map()], atom(), pos_integer()) :: String.t()
  def line(roster, category, count) do
    roster
    |> top_players(category, count)
    |> Enum.map_join(", ", &"#{&1.name} (#{format(&1.value)})")
    |> blank_to_dash()
  end

  @doc """
  The top squads of a type as one line: `"Able (4210), Baker (3900)"`.
  """
  @spec squad_line(map() | [map()], atom(), pos_integer()) :: String.t()
  def squad_line(roster, type, count) do
    roster
    |> top_squads(type, count)
    |> Enum.map_join(", ", &"#{String.capitalize(&1.name)} (#{&1.score})")
    |> blank_to_dash()
  end

  defp blank_to_dash(""), do: "-"
  defp blank_to_dash(text), do: text

  defp format(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format(value), do: to_string(value)

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp players(roster) when is_map(roster), do: Map.values(roster)
  defp players(roster) when is_list(roster), do: roster

  defp role(player), do: player |> Map.get("role") |> to_string() |> String.downcase()

  defp number(player, key) do
    case Map.get(player, key) do
      value when is_number(value) -> value
      _missing -> 0
    end
  end

  defp blank?(value), do: not is_binary(value) or value == ""
end
