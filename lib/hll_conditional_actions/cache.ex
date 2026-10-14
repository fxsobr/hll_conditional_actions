defmodule HllConditionalActions.Cache do
  @moduledoc """
  A short lived, node local cache for numbers that are expensive to compute
  and fine to show a few seconds old.

  The Briefing's totals and the attention count are read by every open page
  - the dashboard refreshes itself, the bell recounts while rules fire - and
  each read used to run the same queries again. Shared here, a busy evening
  costs one computation per window instead of one per page.

      Cache.fetch({:activity, scope, 30}, :timer.seconds(60), fn -> expensive() end)

  Entries carry a tag (the first element of a tuple key) so a change that
  must show at once can drop everything of its kind: `drop(:attention)`.

  Off in tests (`config :hll_conditional_actions, :cache, false`), where a
  stale value would hide what the test just wrote.
  """

  use GenServer

  @table __MODULE__

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The cached value for `key`, or the result of `fun`, kept for `ttl_ms`.
  """
  @spec fetch(term(), non_neg_integer(), (-> value)) :: value when value: term()
  def fetch(key, ttl_ms, fun) do
    if enabled?() do
      now = System.monotonic_time(:millisecond)

      case :ets.lookup(@table, key) do
        [{^key, _tag, expires_at, value}] when expires_at > now ->
          value

        _missing_or_stale ->
          value = fun.()
          :ets.insert(@table, {key, tag(key), now + ttl_ms, value})
          value
      end
    else
      fun.()
    end
  end

  @doc """
  Forgets every entry whose key is a tuple starting with `tag`.
  """
  @spec drop(atom()) :: :ok
  def drop(tag) do
    if enabled?(), do: :ets.match_delete(@table, {:_, tag, :_, :_})
    :ok
  end

  defp tag(key) when is_tuple(key) and tuple_size(key) > 0, do: elem(key, 0)
  defp tag(key), do: key

  defp enabled? do
    Application.get_env(:hll_conditional_actions, :cache, true) and
      :ets.whereis(@table) != :undefined
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  # Nothing but the table's owner, plus a sweep so entries nobody asks for
  # again do not stay around forever.
  @sweep_ms :timer.minutes(5)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, nil}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1", :_}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end
end
