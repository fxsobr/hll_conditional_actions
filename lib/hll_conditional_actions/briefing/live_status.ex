defmodule HllConditionalActions.Briefing.LiveStatus do
  @moduledoc """
  What each server is playing right now, for the Briefing: players and slots,
  the score, the time left and the map.

  One call per server - CRCON's `get_public_info`, which carries all of it,
  or `get_gamestate` when a deployment does not answer the public one - read
  with a short timeout and no retries, so a server that is down costs the
  page a few seconds in the background and never blocks it.

  Answers are cached for `ttl/0` in a public ETS table, so however many
  admins keep the Briefing open, each CRCON is asked at most once per window.
  The table is owned by a small process in the application's supervision
  tree; while it restarts, reads simply miss the cache.
  """

  use GenServer

  alias HllConditionalActions.Crcon.Client

  @table __MODULE__
  @ttl_ms :timer.seconds(15)
  @timeout_ms :timer.seconds(5)

  @typedoc "The live state of one server."
  @type t :: %{
          players: non_neg_integer(),
          max_players: pos_integer() | nil,
          allied_players: non_neg_integer() | nil,
          axis_players: non_neg_integer() | nil,
          allied_score: non_neg_integer() | nil,
          axis_score: non_neg_integer() | nil,
          time_remaining: non_neg_integer() | nil,
          layer: map() | nil,
          map: String.t() | nil,
          mode: String.t() | nil
        }

  @doc "How long an answer is reused, in milliseconds."
  @spec ttl() :: pos_integer()
  def ttl, do: @ttl_ms

  @doc """
  The live state of every enabled server, by id: a map, or `:error` when the
  server could not be read. Disabled servers are left out.

  Fresh cached answers are returned as they are; the others are fetched
  concurrently, in the caller (so a test's `Req.Test` stub applies).
  """
  @spec fetch([map()]) :: %{term() => t() | :error}
  def fetch(servers) do
    now = System.monotonic_time(:millisecond)
    servers = Enum.filter(servers, & &1.enabled)

    {cached, stale} =
      Enum.reduce(servers, {%{}, []}, fn server, {cached, stale} ->
        case lookup(server.id, now) do
          {:ok, value} -> {Map.put(cached, server.id, value), stale}
          :miss -> {cached, [server | stale]}
        end
      end)

    fetched =
      stale
      |> Task.async_stream(&{&1.id, read(&1)},
        timeout: @timeout_ms * 2 + 1_000,
        on_timeout: :kill_task,
        max_concurrency: 8
      )
      |> Enum.zip(stale)
      |> Map.new(fn
        {{:ok, {id, value}}, _server} -> {id, value}
        {{:exit, _reason}, server} -> {server.id, :error}
      end)

    Enum.each(fetched, fn {id, value} -> store(id, value, now) end)
    Map.merge(cached, fetched)
  end

  @doc "Players online across the servers that answered, and how many did."
  @spec players_online(%{term() => t() | :error}) :: {non_neg_integer(), non_neg_integer()} | nil
  def players_online(live) do
    answered = for {_id, %{players: players}} <- live, do: players

    if answered == [], do: nil, else: {Enum.sum(answered), length(answered)}
  end

  @doc "Drops every cached answer."
  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  # ── Reading CRCON ──────────────────────────────────────────────────────────

  defp read(server) do
    case request(server, "get_public_info") do
      {:ok, info} when is_map(info) ->
        from_public_info(info)

      _other ->
        case request(server, "get_gamestate") do
          {:ok, gamestate} when is_map(gamestate) -> from_gamestate(gamestate)
          _other -> :error
        end
    end
  end

  defp request(server, endpoint) do
    Client.request(server, endpoint, %{}, receive_timeout: @timeout_ms, retry: false)
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  @doc false
  @spec from_public_info(map()) :: t()
  def from_public_info(info) do
    layer = get_in(info, ["current_map", "map"])
    allied = integer(get_in(info, ["player_count_by_team", "allied"]))
    axis = integer(get_in(info, ["player_count_by_team", "axis"]))

    %{
      players: integer(info["player_count"]) || (allied || 0) + (axis || 0),
      max_players: integer(info["max_player_count"]),
      allied_players: allied,
      axis_players: axis,
      allied_score: integer(get_in(info, ["score", "allied"])),
      axis_score: integer(get_in(info, ["score", "axis"])),
      time_remaining: integer(info["time_remaining"]),
      layer: if(is_map(layer), do: layer),
      map: map_name(layer),
      mode: mode(layer)
    }
  end

  @doc false
  @spec from_gamestate(map()) :: t()
  def from_gamestate(gamestate) do
    layer = gamestate["current_map"]
    allied = integer(gamestate["num_allied_players"])
    axis = integer(gamestate["num_axis_players"])

    %{
      players: (allied || 0) + (axis || 0),
      max_players: nil,
      allied_players: allied,
      axis_players: axis,
      allied_score: integer(gamestate["allied_score"]),
      axis_score: integer(gamestate["axis_score"]),
      time_remaining: seconds(gamestate["time_remaining"] || gamestate["raw_time_remaining"]),
      layer: if(is_map(layer), do: layer),
      map: map_name(layer),
      mode: mode(layer) || gamestate["game_mode"]
    }
  end

  defp map_name(%{"map" => %{"pretty_name" => name}}) when is_binary(name), do: name
  defp map_name(%{"pretty_name" => name}) when is_binary(name), do: name
  defp map_name(_layer), do: nil

  defp mode(%{"game_mode" => mode}) when is_binary(mode), do: mode
  defp mode(_layer), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: round(value)
  defp integer(_value), do: nil

  # "1:23:45" (what `raw_time_remaining` holds) or a number of seconds.
  defp seconds(value) when is_number(value), do: round(value)

  defp seconds(value) when is_binary(value) do
    value
    |> String.split(":")
    |> Enum.map(&Integer.parse/1)
    |> Enum.reduce_while(0, fn
      {part, ""}, acc -> {:cont, acc * 60 + part}
      _bad, _acc -> {:halt, nil}
    end)
  end

  defp seconds(_value), do: nil

  # ── Cache ──────────────────────────────────────────────────────────────────

  defp lookup(id, now) do
    case :ets.lookup(@table, id) do
      [{^id, value, at}] when now - at < @ttl_ms -> {:ok, value}
      _missing_or_old -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp store(id, value, now) do
    :ets.insert(@table, {id, value, now})
  rescue
    ArgumentError -> true
  end

  @doc "Starts the table's owner; the application supervises it."
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
