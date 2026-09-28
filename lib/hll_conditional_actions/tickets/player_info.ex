defmodule HllConditionalActions.Tickets.PlayerInfo do
  @moduledoc """
  What an admin wants to know about the player behind a ticket before
  answering: are they still on the server, and who are they - level, clan,
  VIP, past penalties, watchlist, other names.

  Two CRCON calls: the live player list (`get_detailed_players`) says whether
  they are online and carries the in-game details; the profile
  (`get_player_profile`) carries the history. Either can fail on its own - a
  player who left has no live entry but still has a profile.
  """

  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Servers.Server

  @type t :: %{
          online: boolean() | :unknown,
          name: String.t() | nil,
          level: integer() | nil,
          team: String.t() | nil,
          clan_tag: String.t() | nil,
          vip?: boolean() | nil,
          penalties: %{String.t() => non_neg_integer()},
          watched?: boolean(),
          blacklisted?: boolean(),
          flags: [String.t()],
          sessions: integer() | nil,
          playtime_seconds: integer() | nil,
          names: [String.t()],
          profile?: boolean()
        }

  @doc """
  Fetches both, and folds them into one map.
  """
  @spec fetch(Server.t(), String.t()) :: t()
  def fetch(%Server{} = server, player_id) do
    live =
      case Crcon.get_detailed_players(server) do
        {:ok, %{"players" => players}} when is_map(players) -> {:ok, Map.get(players, player_id)}
        _error -> :error
      end

    profile =
      case Crcon.get_player_profile(server, player_id) do
        {:ok, profile} when is_map(profile) -> profile
        _error -> nil
      end

    build(live, profile)
  end

  @doc """
  Folds a live entry and a profile into the ticket's player card.

      iex> alias HllConditionalActions.Tickets.PlayerInfo
      iex> info = PlayerInfo.build({:ok, %{"name" => "Sarge", "level" => 42, "is_vip" => true}},
      ...>   %{"penalty_count" => %{"KICK" => 1, "PUNISH" => 0}, "watchlist" => %{"is_watched" => true}})
      iex> {info.online, info.level, info.vip?, info.penalties, info.watched?}
      {true, 42, true, %{"KICK" => 1}, true}
      iex> PlayerInfo.build({:ok, nil}, nil).online
      false
      iex> PlayerInfo.build(:error, nil).online
      :unknown
  """
  @spec build({:ok, map() | nil} | :error, map() | nil) :: t()
  def build(live, profile) do
    player =
      case live do
        {:ok, player} when is_map(player) -> player
        _missing -> %{}
      end

    profile = profile || %{}

    %{
      online:
        case live do
          {:ok, nil} -> false
          {:ok, _player} -> true
          :error -> :unknown
        end,
      name: player["name"] || last_name(profile),
      level: player["level"],
      team: player["team"],
      clan_tag: blank_to_nil(player["clan_tag"]),
      vip?: vip?(player, profile),
      penalties: penalties(profile["penalty_count"]),
      watched?: watched?(profile["watchlist"]),
      blacklisted?: blacklisted?(profile),
      flags: flags(profile["flags"]),
      sessions: profile["sessions_count"],
      playtime_seconds: profile["total_playtime_seconds"],
      names: names(profile["names"]),
      profile?: profile != %{}
    }
  end

  defp vip?(%{"is_vip" => vip}, _profile) when is_boolean(vip), do: vip
  defp vip?(_player, %{"vips" => vips}) when is_list(vips), do: vips != []
  defp vip?(_player, _profile), do: nil

  defp penalties(counts) when is_map(counts),
    do:
      counts |> Enum.filter(fn {_type, count} -> is_integer(count) and count > 0 end) |> Map.new()

  defp penalties(_counts), do: %{}

  defp watched?(%{"is_watched" => watched}), do: watched == true
  defp watched?(watchlist) when is_map(watchlist), do: watchlist != %{}
  defp watched?(_watchlist), do: false

  defp blacklisted?(%{"is_blacklisted" => value}), do: value == true
  defp blacklisted?(%{"blacklists" => blacklists}) when is_list(blacklists), do: blacklists != []
  defp blacklisted?(_profile), do: false

  defp flags(flags) when is_list(flags) do
    Enum.flat_map(flags, fn
      %{"flag" => flag} when is_binary(flag) -> [flag]
      flag when is_binary(flag) -> [flag]
      _other -> []
    end)
  end

  defp flags(_flags), do: []

  defp names(names) when is_list(names) do
    names
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _other -> []
    end)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp names(_names), do: []

  defp last_name(profile), do: profile |> Map.get("names") |> names() |> List.first()

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
