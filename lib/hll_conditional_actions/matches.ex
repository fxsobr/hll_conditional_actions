defmodule HllConditionalActions.Matches do
  @moduledoc """
  Past matches, read from CRCON's own match history.

  CRCON records every match (`get_scoreboard_maps`) and every player's stats
  in it (`get_map_scoreboard`). This module turns both into plain maps the
  pages can use, and turns a match's player stats into a *roster* shaped like
  `get_detailed_players`, so `HllConditionalActions.Leaderboards` ranks a
  finished match exactly the way it ranks the live one.

  A player's team and squad in a match come from their unit history (the
  last unit they were in); their team falls back to what CRCON detected.

  The unit history stores numbers, not names: the squad is the index of its
  letter (0 is Able, 1 Baker ... and -1 the command), the role is the game's
  role ID, and -111 means "none". They are turned back into the names
  `get_detailed_players` uses, per game, since Vietnam numbers its roles
  differently. CRCON also writes 0 for a player in no squad, so an unassigned
  player is counted in Able - a limit of the stored history, not of this
  page.
  """

  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Servers.Server

  @type summary :: %{
          id: term(),
          map: String.t(),
          mode: String.t() | nil,
          started_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil,
          duration_seconds: non_neg_integer() | nil,
          allied: integer() | nil,
          axis: integer() | nil,
          winner: :allies | :axis | :draw | nil
        }

  @doc """
  A page of the server's past matches, newest first, with the total count.
  """
  @spec list(Server.t(), keyword()) ::
          {:ok, %{matches: [summary()], total: non_neg_integer()}} | {:error, term()}
  def list(%Server{} = server, opts \\ []) do
    with {:ok, %{"maps" => maps} = result} <- Crcon.get_scoreboard_maps(server, opts) do
      {:ok, %{matches: Enum.map(maps, &summary/1), total: Map.get(result, "total", length(maps))}}
    else
      {:ok, _unexpected} -> {:error, :unexpected_payload}
      error -> error
    end
  end

  @doc """
  One match with its players, as a summary plus a `:roster`.
  """
  @spec get(Server.t(), term()) :: {:ok, map()} | {:error, term()}
  def get(%Server{} = server, id) do
    with {:ok, %{} = match} <- Crcon.get_map_scoreboard(server, id) do
      stats = Map.get(match, "player_stats") || []
      {:ok, match |> summary() |> Map.put(:roster, roster(stats, server.game))}
    else
      {:ok, _unexpected} -> {:error, :unexpected_payload}
      error -> error
    end
  end

  @doc """
  The stored stats of a match as a roster keyed by player ID, in the shape
  of `get_detailed_players`.
  """
  @spec roster([map()], atom()) :: %{String.t() => map()}
  def roster(stats, game \\ :hll) do
    Map.new(stats, fn stat ->
      unit = last_unit(stat)

      {stat["player_id"],
       %{
         "player_id" => stat["player_id"],
         "name" => stat["player"],
         "team" => team(stat, unit),
         "unit_name" => unit && squad_name(unit["squad"]),
         "role" => unit && role_name(unit["role"], game),
         "kills" => stat["kills"],
         "deaths" => stat["deaths"],
         "team_kills" => stat["teamkills"],
         "combat" => stat["combat"],
         "offense" => stat["offense"],
         "defense" => stat["defense"],
         "support" => stat["support"],
         "vehicles_destroyed" => stat["vehicles_destroyed"],
         "vehicle_kills" => stat["vehicle_kills"],
         "kills_streak" => stat["kills_streak"],
         "map_playtime_seconds" => stat["time_seconds"],
         "level" => stat["level"]
       }}
    end)
  end

  defp summary(match) do
    started_at = datetime(match["start"])
    ended_at = datetime(match["end"])
    result = match["result"] || %{}
    layer = match["map"] || %{}

    %{
      id: match["id"],
      map: map_name(layer, match),
      layer: layer,
      mode: layer["game_mode"],
      started_at: started_at,
      ended_at: ended_at,
      duration_seconds: started_at && ended_at && DateTime.diff(ended_at, started_at),
      allied: result["allied"],
      axis: result["axis"],
      winner: winner(result["allied"], result["axis"])
    }
  end

  defp map_name(layer, match) do
    get_in(layer, ["map", "pretty_name"]) || layer["pretty_name"] || match["map_name"] ||
      "?"
  end

  defp winner(allied, axis) when is_integer(allied) and is_integer(axis) do
    cond do
      allied > axis -> :allies
      axis > allied -> :axis
      true -> :draw
    end
  end

  defp winner(_allied, _axis), do: nil

  defp last_unit(stat) do
    case stat["units"] do
      [_first | _rest] = units -> Enum.max_by(units, &(&1["ts"] || 0))
      _none -> nil
    end
  end

  @squads ~w(able baker charlie dog easy fox george how item jig king love mike negat
              option prep queen roger sugar tare)

  defp squad_name(-1), do: "command"
  defp squad_name(index) when is_integer(index) and index >= 0, do: Enum.at(@squads, index)
  defp squad_name(name) when is_binary(name), do: String.downcase(name)
  defp squad_name(_none), do: nil

  # The game's role IDs, named the way `get_detailed_players` names them, so
  # squad types and leaders are recognised the same live and afterwards.
  @hll_roles %{
    0 => "rifleman",
    1 => "assault",
    2 => "automaticrifleman",
    3 => "medic",
    4 => "spotter",
    5 => "support",
    6 => "heavymachinegunner",
    7 => "antitank",
    8 => "engineer",
    9 => "officer",
    10 => "sniper",
    11 => "crewman",
    12 => "tankcommander",
    13 => "armycommander",
    14 => "artilleryobserver",
    15 => "operator",
    16 => "gunner"
  }

  # Vietnam: the mortar crew plays the artillery part, the squad leader the
  # officer's, and helicopters have no squad type of their own yet.
  @hllv_roles %{
    0 => "rifleman",
    3 => "medic",
    4 => "spotter",
    5 => "specialist",
    6 => "machinegunner",
    7 => "grenadier",
    8 => "engineer",
    9 => "officer",
    10 => "sniper",
    11 => "crewman",
    12 => "tankcommander",
    13 => "operator",
    14 => "artilleryobserver",
    15 => "gunner",
    16 => "pilot",
    17 => "logisticsofficer",
    20 => "armycommander"
  }

  defp role_name(id, :hllv) when is_integer(id), do: Map.get(@hllv_roles, id)
  defp role_name(id, _game) when is_integer(id), do: Map.get(@hll_roles, id)
  defp role_name(name, _game) when is_binary(name), do: String.downcase(name)
  defp role_name(_none, _game), do: nil

  # Unit history numbers the teams 1 (allies) and 2 (axis); CRCON's own guess
  # comes as a string or as %{"side" => ...}, depending on the version.
  defp team(_stat, %{"team" => 1}), do: "allies"
  defp team(_stat, %{"team" => 2}), do: "axis"

  defp team(stat, _unit) do
    case stat["team"] do
      %{"side" => side} when is_binary(side) -> String.downcase(side)
      side when is_binary(side) -> String.downcase(side)
      _unknown -> nil
    end
  end

  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = at), do: at

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} ->
        at

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
          {:error, _reason} -> nil
        end
    end
  end

  defp datetime(_value), do: nil
end
