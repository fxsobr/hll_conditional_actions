defmodule HllConditionalActions.Players.MatchHistory do
  @moduledoc """
  Each player's line of every finished match, for "the last 10 matches".

  CRCON keeps every match (`get_scoreboard_maps`) with every player's stats
  (`get_map_scoreboard`); `sync/1` reads the latest ones a server has not
  had read yet into `HllConditionalActions.Players.MatchStat`, at most once
  per window per server. A finished match never changes, so each is read
  once - `MatchImport` remembers which. The first sync backfills the most
  recent 25 matches; every later one picks up what finished since.
  """

  import Ecto.Query

  require Logger

  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Matches
  alias HllConditionalActions.Players.Cache
  alias HllConditionalActions.Players.MatchImport
  alias HllConditionalActions.Players.MatchStat
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Servers.Server

  @every :timer.minutes(3)
  @page 30
  @max_new 25

  @doc """
  Reads the finished matches of `server` not read yet, when the last sync
  of that server is older than the window. Returns how many were read.
  """
  @spec sync(Server.t(), keyword()) :: non_neg_integer()
  def sync(%Server{} = server, opts \\ []) do
    if Keyword.get(opts, :force, false) or Cache.due?({:match_sync, server.id}, @every) do
      do_sync(server)
    else
      0
    end
  end

  defp do_sync(server) do
    case Crcon.get_scoreboard_maps(server, page: 1, limit: @page) do
      {:ok, %{"maps" => maps}} when is_list(maps) ->
        maps = Enum.filter(maps, &(is_map(&1) and not is_nil(&1["id"]) and &1["end"]))
        ids = Enum.map(maps, &to_string(&1["id"]))

        known =
          MatchImport
          |> where([i], i.server_id == ^server.id and i.match_id in ^ids)
          |> select([i], i.match_id)
          |> Repo.all()
          |> MapSet.new()

        maps
        |> Enum.reject(&MapSet.member?(known, to_string(&1["id"])))
        |> Enum.take(@max_new)
        |> Task.async_stream(&import_match(server, &1["id"]),
          max_concurrency: 3,
          timeout: :timer.seconds(30),
          on_timeout: :kill_task
        )
        |> Enum.count(&match?({:ok, :ok}, &1))

      _error ->
        0
    end
  rescue
    error ->
      Logger.warning("[players] match sync of #{server.name} failed: #{Exception.message(error)}")
      0
  end

  defp import_match(server, id) do
    case Matches.get(server, id) do
      {:ok, match} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        rows = rows(server, match, now)

        Repo.transaction(fn ->
          rows
          |> Enum.chunk_every(200)
          |> Enum.each(&Repo.insert_all(MatchStat, &1, on_conflict: :nothing))

          Repo.insert_all(
            MatchImport,
            [
              %{
                server_id: server.id,
                match_id: to_string(id),
                players: length(rows),
                ended_at: truncate(match.ended_at),
                inserted_at: now
              }
            ],
            on_conflict: :nothing
          )
        end)

        :ok

      _error ->
        :error
    end
  end

  @doc false
  @spec rows(Server.t(), map(), DateTime.t()) :: [map()]
  def rows(server, match, now) do
    for {player_id, player} <- match.roster,
        is_binary(player_id),
        seconds(player) > 0 do
      %{
        server_id: server.id,
        match_id: to_string(match.id),
        player_id: player_id,
        player_name: player["name"],
        map: match.map,
        mode: match.mode,
        started_at: truncate(match.started_at),
        ended_at: truncate(match.ended_at),
        team: player["team"],
        role: player["role"],
        level: int(player["level"]),
        kills: stat(player, "kills"),
        deaths: stat(player, "deaths"),
        team_kills: stat(player, "team_kills"),
        combat: stat(player, "combat"),
        offense: stat(player, "offense"),
        defense: stat(player, "defense"),
        support: stat(player, "support"),
        vehicles_destroyed: stat(player, "vehicles_destroyed"),
        playtime_seconds: seconds(player),
        inserted_at: now
      }
    end
  end

  defp seconds(player), do: stat(player, "map_playtime_seconds")

  defp stat(player, key), do: int(player[key]) || 0

  # ── Reading ────────────────────────────────────────────────────────────────

  @doc "A player's latest matches on the servers in `scope`, newest first."
  @spec recent(String.t(), :all | [term()], pos_integer()) :: [MatchStat.t()]
  def recent(player_id, scope, count \\ 10) do
    MatchStat
    |> where([m], m.player_id == ^player_id)
    |> scoped(scope)
    |> order_by([m], desc: m.ended_at, desc: m.id)
    |> limit(^count)
    |> preload(:server)
    |> Repo.all()
  end

  @doc "The team kills of a player in the matches that ended since `since`."
  @spec team_kills_since(String.t(), :all | [term()], DateTime.t()) :: non_neg_integer()
  def team_kills_since(player_id, scope, since) do
    MatchStat
    |> where([m], m.player_id == ^player_id and m.ended_at >= ^since)
    |> scoped(scope)
    |> select([m], coalesce(sum(m.team_kills), 0))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc "A player's first recorded match, or nil."
  @spec first(String.t(), :all | [term()]) :: MatchStat.t() | nil
  def first(player_id, scope) do
    MatchStat
    |> where([m], m.player_id == ^player_id)
    |> scoped(scope)
    |> order_by([m], asc: m.ended_at, asc: m.id)
    |> limit(1)
    |> preload(:server)
    |> Repo.one()
  end

  @doc "How many matches of a player were read, on the servers in `scope`."
  @spec count(String.t(), :all | [term()]) :: non_neg_integer()
  def count(player_id, scope) do
    MatchStat
    |> where([m], m.player_id == ^player_id)
    |> scoped(scope)
    |> select([m], count(m.id))
    |> Repo.one()
  end

  @doc "A page of a player's matches, newest first."
  @spec list(String.t(), :all | [term()], keyword()) :: [MatchStat.t()]
  def list(player_id, scope, opts \\ []) do
    MatchStat
    |> where([m], m.player_id == ^player_id)
    |> scoped(scope)
    |> order_by([m], desc: m.ended_at, desc: m.id)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> preload(:server)
    |> Repo.all()
  end

  @doc "The last level recorded for each of `player_ids`."
  @spec last_levels([String.t()]) :: %{String.t() => integer()}
  def last_levels([]), do: %{}

  def last_levels(player_ids) do
    MatchStat
    |> where([m], m.player_id in ^player_ids and not is_nil(m.level))
    |> distinct([m], m.player_id)
    |> order_by([m], asc: m.player_id, desc: m.ended_at)
    |> select([m], {m.player_id, m.level})
    |> Repo.all()
    |> Map.new()
  end

  defp scoped(query, :all), do: query
  defp scoped(query, ids), do: where(query, [m], m.server_id in ^ids)

  defp int(value) when is_integer(value), do: value
  defp int(value) when is_float(value), do: round(value)
  defp int(_value), do: nil

  defp truncate(nil), do: nil
  defp truncate(%DateTime{} = at), do: DateTime.truncate(at, :second)
end
