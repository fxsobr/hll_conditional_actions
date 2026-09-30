defmodule HllConditionalActions.Players.Cache do
  @moduledoc """
  A small time-boxed cache for the players pages' CRCON reads: the live
  player list, the VIP list and the watchlist of each server, and the
  moments the background syncs last ran.

  However many admins keep the pages open, each CRCON is asked at most once
  per window. Values are computed in the caller (so a test's `Req.Test`
  stub applies) and only stored here.

  The ETS table is owned by a tiny process started on first use under the
  runtime's dynamic supervisor, so the cache needs no entry of its own in the
  application tree. While it is not there, reads simply miss.
  """

  use GenServer

  @table __MODULE__
  @supervisor HllConditionalActions.Runtime.ServerSupervisor

  @doc """
  The value under `key` if it is younger than `ttl_ms`, otherwise
  `fun.()` - stored for next time.
  """
  @spec fetch(term(), pos_integer(), (-> value)) :: value when value: term()
  def fetch(key, ttl_ms, fun) do
    now = System.monotonic_time(:millisecond)

    case lookup(key, now, ttl_ms) do
      {:ok, value} ->
        value

      :miss ->
        value = fun.()
        put(key, value, now)
        value
    end
  end

  @doc "The value under `key` if it is younger than `ttl_ms`, without computing it."
  @spec peek(term(), pos_integer()) :: {:ok, term()} | :miss
  def peek(key, ttl_ms), do: lookup(key, System.monotonic_time(:millisecond), ttl_ms)

  @doc """
  Whether `key` was touched less than `ttl_ms` ago; touches it when not.
  Used to run a sync at most once per window.
  """
  @spec due?(term(), pos_integer()) :: boolean()
  def due?(key, ttl_ms) do
    now = System.monotonic_time(:millisecond)

    case lookup(key, now, ttl_ms) do
      {:ok, _value} ->
        false

      :miss ->
        put(key, true, now)
        true
    end
  end

  @doc "Forgets `key`, so the next read asks CRCON again."
  @spec delete(term()) :: :ok
  def delete(key) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp lookup(key, now, ttl_ms) do
    case :ets.lookup(@table, key) do
      [{^key, value, at}] when now - at < ttl_ms -> {:ok, value}
      _missing_or_old -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp put(key, value, now) do
    ensure_table()
    :ets.insert(@table, {key, value, now})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      spec = %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, restart: :transient}

      case DynamicSupervisor.start_child(@supervisor, spec) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        _other -> :ok
      end
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
