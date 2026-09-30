defmodule HllConditionalActions.VipShop.LiveServers do
  @moduledoc """
  What the shop's servers are playing right now, for the public storefront:
  players and slots, the queue, the map and its time of day.

  One CRCON call per server - `get_public_info`, or `get_gamestate` when a
  deployment does not answer the public one - with a short timeout and no
  retries. Answers are kept for `ttl/0` in a public ETS table, so however
  many visitors keep the shop open, each CRCON is asked at most once per
  window.

  The table belongs to this module's process, in the application's
  supervision tree; while it restarts, reads simply miss the cache.
  """

  use GenServer

  alias HllConditionalActions.Briefing.LiveStatus
  alias HllConditionalActions.Crcon.Client

  @table __MODULE__
  @ttl_ms :timer.seconds(15)
  @timeout_ms :timer.seconds(4)

  @typedoc """
  A server's live state: `:error` when it could not be read, otherwise the
  counts, the layer CRCON reports and when it was read.
  """
  @type t ::
          :error
          | %{
              players: non_neg_integer(),
              max_players: pos_integer() | nil,
              queue: non_neg_integer() | nil,
              map: String.t() | nil,
              mode: String.t() | nil,
              environment: String.t() | nil,
              layer: map() | nil,
              read_at: DateTime.t()
            }

  @doc "How long an answer is reused, in milliseconds."
  @spec ttl() :: pos_integer()
  def ttl, do: @ttl_ms

  @doc """
  The live state of each server, by id. Fresh cached answers are returned as
  they are; the others are read concurrently in the caller (so a test's
  `Req.Test` stub applies).
  """
  @spec fetch([map()]) :: %{term() => t()}
  def fetch(servers) do
    now = System.monotonic_time(:millisecond)

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

  @doc """
  The cached state of each server, by id, without asking CRCON: servers
  with no fresh answer are left out.
  """
  @spec cached([map()]) :: %{term() => t()}
  def cached(servers) do
    now = System.monotonic_time(:millisecond)

    for server <- servers, {:ok, value} <- [lookup(server.id, now)], into: %{} do
      {server.id, value}
    end
  end

  @doc "Drops every cached answer."
  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  # ── Reading CRCON ──────────────────────────────────────────────────────────

  defp read(%{enabled: false}), do: :error

  defp read(server) do
    case request(server, "get_public_info") do
      {:ok, info} when is_map(info) ->
        info |> LiveStatus.from_public_info() |> finish(info["queue_count"])

      _other ->
        case request(server, "get_gamestate") do
          {:ok, gamestate} when is_map(gamestate) ->
            gamestate |> LiveStatus.from_gamestate() |> finish(gamestate["queue_count"])

          _other ->
            :error
        end
    end
  end

  defp finish(status, queue) do
    %{
      players: status.players,
      max_players: status.max_players,
      queue: if(is_integer(queue) and queue >= 0, do: queue),
      map: status.map,
      mode: status.mode,
      environment: environment(status.layer),
      layer: status.layer,
      read_at: DateTime.utc_now(:second)
    }
  end

  defp environment(%{"environment" => env}) when is_binary(env), do: env
  defp environment(_layer), do: nil

  defp request(server, endpoint) do
    Client.request(server, endpoint, %{}, receive_timeout: @timeout_ms, retry: false)
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

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
    if :ets.whereis(@table) == :undefined,
      do: :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    {:ok, nil}
  end
end
