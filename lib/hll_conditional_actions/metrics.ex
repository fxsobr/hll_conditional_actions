defmodule HllConditionalActions.Metrics do
  @moduledoc """
  In-memory aggregation of the application's `:telemetry` events.

  `HllConditionalActionsWeb.Telemetry.metrics/0` declares what is worth
  measuring, but declarations alone show nothing: they need a reporter. Rather
  than require Prometheus or StatsD just to answer "is anything happening",
  this collector attaches to the same events and keeps running totals in an ETS
  table for the metrics page to read.

  It is deliberately small:

    * counters are cumulative since the node started
    * durations keep count, total, maximum and the last value, which is enough
      for an average and a worst case without storing a histogram
    * nothing is persisted, so a restart resets the view

  For long-term data, attach a real reporter to `Telemetry.metrics/0` instead;
  this is the at-a-glance view.
  """

  use GenServer

  @table __MODULE__
  @handler_id "hll-conditional-actions-metrics"

  @events [
    [:hll_conditional_actions, :rule, :fired],
    [:hll_conditional_actions, :rule, :skipped],
    [:hll_conditional_actions, :crcon, :request, :stop],
    [:hll_conditional_actions, :crcon, :request, :exception],
    [:hll_conditional_actions, :log_stream, :event],
    [:hll_conditional_actions, :log_stream, :status]
  ]

  # ── Public API ─────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Everything the metrics page renders, already grouped.
  """
  @spec snapshot() :: map()
  def snapshot do
    %{
      started_at: safe_lookup({:meta, :started_at}),
      rules: %{
        fired: counters(:rule_fired),
        skipped: counters(:rule_skipped),
        duration: duration(:rule_duration)
      },
      crcon: %{
        requests: crcon_requests(),
        duration_by_endpoint: crcon_durations()
      },
      log_stream: %{
        events: counters(:stream_event),
        statuses: counters(:stream_status)
      }
    }
  end

  @doc """
  Clears every counter, for when you want to watch a change in isolation.
  """
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc """
  Total number of events recorded, which is what tells the page whether
  anything has happened at all.
  """
  @spec total_events() :: non_neg_integer()
  def total_events do
    :ets.select(@table, [{{{:counter, :_}, :"$1"}, [], [:"$1"]}]) |> Enum.sum()
  rescue
    ArgumentError -> 0
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    # Public and write-concurrent: the telemetry handlers run in whichever
    # process emitted the event, not in this one.
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :ets.insert(@table, {{:meta, :started_at}, DateTime.utc_now()})

    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)

    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    :ets.match_delete(@table, {{:counter, :_}, :_})
    :ets.match_delete(@table, {{:duration, :_}, :_})
    :ets.insert(@table, {{:meta, :started_at}, DateTime.utc_now()})
    {:reply, :ok, state}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  # ── Telemetry handler ──────────────────────────────────────────────────────

  @doc false
  def handle_event([_app, :rule, :fired], measurements, metadata, _config) do
    count({:rule_fired, metadata.status})
    observe(:rule_duration, measurements[:duration])
  end

  def handle_event([_app, :rule, :skipped], _measurements, metadata, _config) do
    count({:rule_skipped, metadata.reason})
  end

  def handle_event([_app, :crcon, :request, :stop], measurements, metadata, _config) do
    count({:crcon, metadata.endpoint, metadata.outcome})
    observe({:crcon_duration, metadata.endpoint}, measurements[:duration])
  end

  def handle_event([_app, :crcon, :request, :exception], _measurements, metadata, _config) do
    count({:crcon, metadata.endpoint, :exception})
  end

  def handle_event([_app, :log_stream, :event], _measurements, metadata, _config) do
    count({:stream_event, metadata.type})
  end

  def handle_event([_app, :log_stream, :status], _measurements, metadata, _config) do
    count({:stream_status, metadata.status})
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  # ── Storage ────────────────────────────────────────────────────────────────

  defp count(key) do
    :ets.update_counter(@table, {:counter, key}, 1, {{:counter, key}, 0})
  rescue
    ArgumentError -> :ok
  end

  defp observe(_key, nil), do: :ok

  defp observe(key, duration) do
    ms = System.convert_time_unit(duration, :native, :millisecond)

    # {count, total, max, last}: enough for an average and a worst case, at a
    # fixed size per key.
    :ets.insert(
      @table,
      case :ets.lookup(@table, {:duration, key}) do
        [{_key, {n, total, max, _last}}] ->
          {{:duration, key}, {n + 1, total + ms, max(max, ms), ms}}

        [] ->
          {{:duration, key}, {1, ms, ms, ms}}
      end
    )
  rescue
    ArgumentError -> :ok
  end

  # Every row is read and filtered in Elixir rather than through a nested match
  # spec. The table holds a few dozen rows at most, and a match spec that has
  # to construct tuples is far easier to get subtly wrong than to read.
  defp all_counters do
    :ets.select(@table, [{{{:counter, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
  rescue
    ArgumentError -> []
  end

  defp all_durations do
    :ets.select(@table, [{{{:duration, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
  rescue
    ArgumentError -> []
  end

  defp counters(tag) do
    for({{^tag, key}, value} <- all_counters(), do: {key, value})
    |> Enum.sort_by(fn {_key, value} -> -value end)
  end

  defp crcon_requests do
    for({{:crcon, endpoint, outcome}, value} <- all_counters(), do: {{endpoint, outcome}, value})
    |> Enum.sort_by(fn {_key, value} -> -value end)
  end

  defp crcon_durations do
    for({{:crcon_duration, endpoint}, stats} <- all_durations(), do: {endpoint, summarize(stats)})
    |> Enum.sort_by(fn {_endpoint, stats} -> -stats.count end)
  end

  defp duration(key) do
    case safe_lookup({:duration, key}) do
      nil -> nil
      stats -> summarize(stats)
    end
  end

  defp summarize({count, total, max, last}) do
    %{count: count, average: Float.round(total / count, 1), max: max, last: last}
  end

  defp safe_lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end
end
