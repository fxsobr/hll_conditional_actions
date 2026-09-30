defmodule HllConditionalActions.Metrics.History do
  @moduledoc """
  The last hour of the engine, minute by minute, for the metrics page.

  `HllConditionalActions.Metrics` keeps running totals since the node started;
  this keeps the same `:telemetry` events in per-minute buckets so the page
  can say what happened *in the last hour*: events per minute and per server,
  rules fired and skipped (and why, and by which rule), how long the engine
  takes from a rule firing to its actions finishing, every CRCON call per
  endpoint and server, and each server's log stream connection over time.

  ## Storage

  One public ETS table owned by the `HllConditionalActions.Metrics` process.
  Every key carries the minute it belongs to (`div(unix_ms, 60_000)`), and
  every write is an atomic `:ets.update_counter/4`, because the handlers run in
  whichever process emitted the event. The first event of each minute drops
  the buckets older than 62 minutes, so the table stays the same size no
  matter how long nobody opens the page.

  ## Percentiles

  Latencies are not stored one by one. Each goes into a fixed, log-spaced
  histogram bucket (every bucket is 10% wider than the one before), counted
  per minute. A percentile over the hour merges the hour's buckets and
  answers the middle of the bucket the rank falls in, so it is within ±5% of
  the exact value at a constant cost per event, however many there are.

  ## What slowed a firing down

  CRCON calls report in the calling process, and a rule's actions run in its
  server's runner process. Each call leaves a short trail in that process's
  dictionary (the last 24 calls: when it ended, which endpoint, how long);
  when the rule reports it fired, the calls that ended during its run are
  added up, and the endpoint that took at least half of the run is kept next
  to its duration and trigger. That is what "p99 driven by X at match end"
  is read from.

  ## Log stream

  Every status change of a server's stream is kept with its time (the last
  hour and the change before it), so the page can draw the hour as a bar,
  count reconnects and say since when a stream is down. Unlike the counters
  these survive a reset: they describe the connection, not a tally.
  """

  alias HllConditionalActions.Metrics

  @table __MODULE__
  @handler_id "hll-conditional-actions-metrics-history"

  @events [
    [:hll_conditional_actions, :rule, :fired],
    [:hll_conditional_actions, :rule, :skipped],
    [:hll_conditional_actions, :crcon, :request, :stop],
    [:hll_conditional_actions, :crcon, :request, :exception],
    [:hll_conditional_actions, :log_stream, :event],
    [:hll_conditional_actions, :log_stream, :status]
  ]

  @minute_ms 60_000
  @window 60
  @keep 62
  @trail_key {__MODULE__, :crcon_calls}
  @trail_size 24
  @stream_entries 1_000
  @log_step :math.log(1.1)

  @typedoc "Milliseconds since the Unix epoch."
  @type unix_ms :: integer()

  # ── Setup ──────────────────────────────────────────────────────────────────

  @doc """
  Creates the table and attaches the handler. Idempotent; must run in the
  process that owns the table (`HllConditionalActions.Metrics`).
  """
  @spec setup() :: :ok
  def setup do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        write_concurrency: true,
        read_concurrency: true
      ])

      :ets.insert(@table, {{:meta, :since}, now_ms()})
      seed_streams()
    end

    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc """
  Makes sure the history is recording: after a code reload the collector's
  process predates this module, so the first reader sets it up.
  """
  @spec ensure() :: :ok
  def ensure do
    if :ets.whereis(@table) == :undefined or not attached?(), do: Metrics.ensure_history()
    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec detach() :: :ok
  def detach do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc """
  Clears the counters and restarts the window. The log stream's connection
  history is kept.
  """
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined do
      Enum.each(minute_patterns(), fn pattern -> :ets.match_delete(@table, pattern) end)
      :ets.insert(@table, {{:meta, :since}, now_ms()})
    end

    :ok
  end

  defp attached? do
    [:hll_conditional_actions, :rule, :fired]
    |> :telemetry.list_handlers()
    |> Enum.any?(&(&1.id == @handler_id))
  end

  # What the streams are doing right now, for a history created after they
  # started (a code reload). Marked as a seed: the time is when we looked, not
  # when the stream got there.
  defp seed_streams do
    Task.start(fn ->
      for server_id <- running(:log_stream) do
        status = HllConditionalActions.Crcon.LogStream.status(server_id)
        seed_status(server_id, status_name(status))
      end
    end)
  end

  defp seed_status(server_id, status) do
    if stream_entries(server_id) == [] do
      :ets.insert(@table, {{:stream, server_id}, [{now_ms(), status, :seed}]})
    end
  rescue
    ArgumentError -> :ok
  end

  defp status_name({:error, _reason}), do: :error
  defp status_name(status), do: status

  # ── Telemetry handler ──────────────────────────────────────────────────────

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    record(event, measurements || %{}, metadata || %{})
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp record([_app, :log_stream, :event], _measurements, metadata) do
    now = now_ms()
    server_id = Map.get(metadata, :server_id)
    bump({:ev, minute(now), server_id})
    :ets.insert(@table, {{:last_event, server_id}, now})
  end

  defp record([_app, :log_stream, :status], _measurements, metadata) do
    append_status(Map.get(metadata, :server_id), status_name(Map.get(metadata, :status)))
  end

  defp record([_app, :rule, :fired], measurements, metadata) do
    m = minute(now_ms())
    status = Map.get(metadata, :status)
    bump({:fired, m, status})

    if Map.get(metadata, :simulation) == true or status == :simulated, do: bump({:sim, m})

    if name = Map.get(metadata, :rule_name) do
      :ets.insert(@table, {{:rule_name, Map.get(metadata, :rule_id)}, name})
    end

    case Map.get(measurements, :duration) do
      duration when is_integer(duration) ->
        bucket = bucket(to_ms(duration))
        bump({:dh, m, bucket, Map.get(metadata, :trigger), slowest_call(duration)})

      _none ->
        :ok
    end
  end

  defp record([_app, :rule, :skipped], _measurements, metadata) do
    bump({:skip, minute(now_ms()), Map.get(metadata, :reason), Map.get(metadata, :rule_id)})
  end

  defp record([_app, :crcon, :request, stage], measurements, metadata)
       when stage in [:stop, :exception] do
    m = minute(now_ms())
    endpoint = Map.get(metadata, :endpoint)
    server_id = Map.get(metadata, :server_id)
    duration = Map.get(measurements, :duration)
    ms = if is_integer(duration), do: to_ms(duration), else: 0

    key = {:cc, m, endpoint, server_id}
    :ets.update_counter(@table, key, [{2, 1}, {3, round(ms)}], {key, 0, 0})
    bump({:ch, m, endpoint, server_id, bucket(ms)})

    outcome = if stage == :exception, do: :exception, else: Map.get(metadata, :outcome, :ok)

    if outcome != :ok do
      bump({:ce, m, endpoint, server_id, error_kind(outcome, metadata)})
    end

    if is_integer(duration), do: leave_trail(endpoint, duration)
  end

  defp record(_event, _measurements, _metadata), do: :ok

  defp error_kind(:transport_error, _metadata), do: :no_answer
  defp error_kind(:exception, _metadata), do: :exception

  defp error_kind(outcome, metadata) do
    case Map.get(metadata, :status) do
      status when is_integer(status) -> {:status, status}
      _other -> outcome
    end
  end

  defp bump(key) do
    maybe_prune(elem(key, 1))
    :ets.update_counter(@table, key, 1, {key, 0})
  end

  # ── Pruning ────────────────────────────────────────────────────────────────

  defp maybe_prune(m) when is_integer(m) do
    if :ets.insert_new(@table, {{:pruned, m}, true}) do
      cutoff = m - @keep

      Enum.each(minute_patterns(), fn pattern ->
        :ets.select_delete(@table, [{pattern, [{:<, :"$1", cutoff}], [true]}])
      end)
    end
  end

  defp maybe_prune(_other), do: :ok

  # Every key that belongs to a minute, with the minute bound to `$1`.
  defp minute_patterns do
    [
      {{:ev, :"$1", :_}, :_},
      {{:fired, :"$1", :_}, :_},
      {{:sim, :"$1"}, :_},
      {{:skip, :"$1", :_, :_}, :_},
      {{:dh, :"$1", :_, :_, :_}, :_},
      {{:cc, :"$1", :_, :_}, :_, :_},
      {{:ch, :"$1", :_, :_, :_}, :_},
      {{:ce, :"$1", :_, :_, :_}, :_},
      {{:pruned, :"$1"}, :_}
    ]
  end

  # ── The CRCON trail ────────────────────────────────────────────────────────

  defp leave_trail(endpoint, duration) do
    trail = Process.get(@trail_key, [])

    Process.put(
      @trail_key,
      Enum.take([{System.monotonic_time(), endpoint, duration} | trail], @trail_size)
    )
  end

  # The endpoint that took at least half of a firing that just ended, if any.
  defp slowest_call(duration) do
    started = System.monotonic_time() - duration

    @trail_key
    |> Process.get([])
    |> Enum.filter(fn {ended, _endpoint, _duration} -> ended >= started end)
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 2))
    |> Enum.map(fn {endpoint, durations} -> {endpoint, Enum.sum(durations)} end)
    |> Enum.max_by(&elem(&1, 1), fn -> nil end)
    |> case do
      {endpoint, spent} when spent * 2 >= duration -> endpoint
      _other -> nil
    end
  end

  # ── Log stream ─────────────────────────────────────────────────────────────

  defp append_status(server_id, status) do
    now = now_ms()
    cutoff = now - @keep * @minute_ms
    entries = [{now, status, :event} | stream_entries(server_id)]

    # Newest first; everything inside the window plus the change before it,
    # which says what the stream was doing when the window opens.
    {inside, before} = Enum.split_with(entries, fn {at, _s, _o} -> at >= cutoff end)
    kept = Enum.take(inside ++ Enum.take(before, 1), @stream_entries)

    :ets.insert(@table, {{:stream, server_id}, kept})
  end

  defp stream_entries(server_id) do
    case :ets.lookup(@table, {:stream, server_id}) do
      [{_key, entries}] -> entries
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  @doc """
  When a server's log stream went down and has not come back: the change
  from connected to error or connecting (or, for a stream that never
  connected since the app started, its first attempt). `nil` when connected,
  or when it is not known.
  """
  @spec stream_down_since(term()) :: DateTime.t() | nil
  def stream_down_since(server_id) do
    server_id |> stream_entries() |> down_since() |> to_datetime()
  end

  # Newest first. The oldest entry of the stretch without :connected.
  defp down_since([{_at, :connected, _origin} | _rest]), do: nil
  defp down_since([]), do: nil

  defp down_since(entries) do
    {down, rest} = Enum.split_while(entries, fn {_at, status, _o} -> status != :connected end)

    case {List.last(down), rest} do
      {{_at, _status, :seed}, _rest} -> nil
      {{at, _status, _origin}, _rest} -> at
    end
  end

  @doc """
  A server's latest stream status and when it was reported, or `nil`.
  """
  @spec last_status(term()) :: {unix_ms(), atom()} | nil
  def last_status(server_id) do
    case stream_entries(server_id) do
      [{at, status, _origin} | _rest] -> {at, status}
      [] -> nil
    end
  end

  @doc """
  When the last game event arrived from a server's log stream, or `nil`.
  """
  @spec last_event_at(term()) :: DateTime.t() | nil
  def last_event_at(server_id) do
    case :ets.lookup(@table, {:last_event, server_id}) do
      [{_key, at}] -> to_datetime(at)
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  A server's log stream over the last hour, oldest first, as segments of
  `:up`, `:blip` (a drop it came back from), `:down` (the stretch it is still
  down in) and `:unknown` (before anything was recorded), each with its
  length in milliseconds. Also the reconnects in the hour, the attempts since
  it went down and the status it is in.
  """
  @spec stream_timeline(term(), unix_ms()) :: %{
          segments: [%{state: atom(), ms: non_neg_integer()}],
          reconnects: non_neg_integer(),
          attempts: non_neg_integer(),
          down_since: DateTime.t() | nil,
          status: atom() | nil
        }
  def stream_timeline(server_id, now \\ now_ms()) do
    entries = stream_entries(server_id)
    start = now - @window * @minute_ms
    {inside, before} = entries |> Enum.split_with(fn {at, _s, _o} -> at >= start end)

    initial =
      case before do
        [{_at, status, _origin} | _rest] -> state(status)
        [] -> :unknown
      end

    points =
      [
        {start, initial}
        | inside |> Enum.reverse() |> Enum.map(fn {at, s, _o} -> {at, state(s)} end)
      ]
      |> Enum.chunk_by(&elem(&1, 1))
      |> Enum.map(&hd/1)

    segments =
      points
      |> Enum.zip(tl(points) ++ [{now, nil}])
      |> Enum.map(fn {{at, state}, {next, _}} -> %{state: state, ms: max(next - at, 0)} end)
      |> classify()

    trailing_down? = match?([%{state: :down} | _], Enum.reverse(segments))

    %{
      segments: segments,
      reconnects: Enum.count(segments, &(&1.state == :blip)),
      attempts: if(trailing_down?, do: attempts(entries), else: 0),
      down_since: if(trailing_down?, do: to_datetime(down_since(entries))),
      status:
        case entries do
          [{_at, status, _origin} | _rest] -> status
          [] -> nil
        end
    }
  end

  defp state(:connected), do: :up
  defp state(_other), do: :down

  # A drop between two connected stretches is a blip; the stretch the stream
  # is still in is down; the first connect after an unknown start is part of
  # the unknown.
  defp classify(segments) do
    last = length(segments) - 1

    segments
    |> Enum.with_index()
    |> Enum.map(fn {segment, index} ->
      previous = if index > 0, do: Enum.at(segments, index - 1).state

      state =
        cond do
          segment.state != :down -> segment.state
          index == last -> :down
          # Down when the window opened, or right after a connected stretch.
          index == 0 or previous == :up -> :blip
          true -> :unknown
        end

      %{segment | state: state}
    end)
    |> Enum.chunk_by(& &1.state)
    |> Enum.map(fn [first | _] = run -> %{first | ms: run |> Enum.map(& &1.ms) |> Enum.sum()} end)
  end

  defp attempts(entries) do
    entries
    |> Enum.take_while(fn {_at, status, _o} -> status != :connected end)
    |> Enum.count(fn {_at, status, origin} -> status == :connecting and origin != :seed end)
  end

  # The minutes in which some stream dropped, for the events chart.
  defp drop_minutes(from) do
    select([{{{:stream, :_}, :"$1"}, [], [:"$1"]}])
    |> Enum.flat_map(fn entries ->
      entries
      |> Enum.reverse()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn
        [{_a, :connected, _o}, {at, status, :event}] when status != :connected -> [minute(at)]
        _pair -> []
      end)
    end)
    |> Enum.filter(&(&1 >= from))
    |> MapSet.new()
  end

  # ── Reading ────────────────────────────────────────────────────────────────

  @doc """
  When the counters started (the collector's start, or the last reset).
  """
  @spec since() :: DateTime.t() | nil
  def since do
    case :ets.lookup(@table, {:meta, :since}) do
      [{_key, at}] -> to_datetime(at)
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Game events per minute over the last `count` complete minutes (oldest
  first, with whether a stream dropped in that minute), the last complete
  minute per server, and how the rate moved within the hour: the last half
  hour against the one before, in percent, once a whole hour is covered.
  """
  @spec events(pos_integer(), unix_ms()) :: map()
  def events(count \\ 30, now \\ now_ms()) do
    current = minute(now)
    last = current - 1
    from = current - @window

    rows =
      select([{{{:ev, :"$1", :"$2"}, :"$3"}, [{:>=, :"$1", from}], [{{:"$1", :"$2", :"$3"}}]}])

    per_minute =
      Enum.reduce(rows, %{}, fn {m, _s, n}, acc -> Map.update(acc, m, n, &(&1 + n)) end)

    drops = drop_minutes(last - count + 1)

    %{
      per_minute:
        for m <- (last - count + 1)..last do
          %{minute: m, count: Map.get(per_minute, m, 0), drop?: MapSet.member?(drops, m)}
        end,
      last_minute: Map.get(per_minute, last, 0),
      by_server:
        for({^last, server_id, n} <- rows, do: {server_id, n})
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {server_id, counts} -> {server_id, Enum.sum(counts)} end),
      seen_servers: rows |> Enum.map(&elem(&1, 1)) |> Enum.uniq(),
      change: change(per_minute, last, now)
    }
  end

  defp change(per_minute, last, now) do
    since = safe_meta(:since)

    if since && since <= now - @window * @minute_ms do
      recent = sum_range(per_minute, (last - 29)..last)
      before = sum_range(per_minute, (last - 59)..(last - 30))
      if before > 0, do: (recent - before) / before * 100
    end
  end

  defp sum_range(per_minute, range), do: Enum.reduce(range, 0, &(Map.get(per_minute, &1, 0) + &2))

  @doc """
  Rules fired, skipped and simulated over the last hour.
  """
  @spec rules(unix_ms()) :: %{
          fired: non_neg_integer(),
          skipped: non_neg_integer(),
          simulated: non_neg_integer()
        }
  def rules(now \\ now_ms()) do
    from = minute(now) - @window + 1

    %{
      fired: sum([{{{:fired, :"$1", :_}, :"$2"}, [{:>=, :"$1", from}], [:"$2"]}]),
      skipped: sum([{{{:skip, :"$1", :_, :_}, :"$2"}, [{:>=, :"$1", from}], [:"$2"]}]),
      simulated: sum([{{{:sim, :"$1"}, :"$2"}, [{:>=, :"$1", from}], [:"$2"]}])
    }
  end

  @doc """
  Why rules were skipped over the last hour, most common reason first, each
  with the rule that hit it most.
  """
  @spec skips(unix_ms()) :: [
          %{reason: atom(), count: pos_integer(), top_rule_id: term(), top_rule_count: integer()}
        ]
  def skips(now \\ now_ms()) do
    from = minute(now) - @window + 1

    [{{{:skip, :"$1", :"$2", :"$3"}, :"$4"}, [{:>=, :"$1", from}], [{{:"$2", :"$3", :"$4"}}]}]
    |> select()
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {reason, rows} ->
      {top_rule, top_count} =
        rows
        |> Enum.group_by(&elem(&1, 1), &elem(&1, 2))
        |> Enum.map(fn {rule_id, counts} -> {rule_id, Enum.sum(counts)} end)
        |> Enum.max_by(&elem(&1, 1))

      %{
        reason: reason,
        count: rows |> Enum.map(&elem(&1, 2)) |> Enum.sum(),
        top_rule_id: top_rule,
        top_rule_count: top_count
      }
    end)
    |> Enum.sort_by(&(-&1.count))
  end

  @doc """
  The name a rule had when it last fired, if it fired since the node started.
  """
  @spec rule_name(term()) :: String.t() | nil
  def rule_name(rule_id) do
    case :ets.lookup(@table, {:rule_name, rule_id}) do
      [{_key, name}] -> name
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Time from a rule firing to its actions finishing, over the last hour:
  p50, p95 and p99 in milliseconds (`nil` when nothing fired), and what the
  firings at or above the p99 had in common - the CRCON endpoint that took
  most of their time (`nil` when none did) and their trigger.
  """
  @spec latency(unix_ms()) :: %{
          count: non_neg_integer(),
          p50: number() | nil,
          p95: number() | nil,
          p99: number() | nil,
          p99_cause: %{endpoint: String.t() | nil, trigger: atom() | nil} | nil
        }
  def latency(now \\ now_ms()) do
    from = minute(now) - @window + 1

    rows =
      select([
        {{{:dh, :"$1", :"$2", :"$3", :"$4"}, :"$5"}, [{:>=, :"$1", from}],
         [{{:"$2", :"$3", :"$4", :"$5"}}]}
      ])

    histogram =
      Enum.reduce(rows, %{}, fn {b, _t, _e, n}, acc -> Map.update(acc, b, n, &(&1 + n)) end)

    p99_bucket = percentile_bucket(histogram, 0.99)

    cause =
      if p99_bucket do
        rows
        |> Enum.filter(fn {b, _t, _e, _n} -> b >= p99_bucket end)
        |> Enum.group_by(fn {_b, t, e, _n} -> {e, t} end, &elem(&1, 3))
        |> Enum.map(fn {key, counts} -> {key, Enum.sum(counts)} end)
        # Prefer an endpoint over "nothing in particular" when they tie.
        |> Enum.max_by(fn {{e, _t}, n} -> {n, if(e, do: 1, else: 0)} end, fn -> nil end)
        |> case do
          {{endpoint, trigger}, _n} -> %{endpoint: endpoint, trigger: trigger}
          nil -> nil
        end
      end

    %{
      count: histogram |> Map.values() |> Enum.sum(),
      p50: percentile(histogram, 0.5),
      p95: percentile(histogram, 0.95),
      p99: percentile(histogram, 0.99),
      p99_cause: cause
    }
  end

  @doc """
  CRCON calls over the last hour, one row per endpoint, busiest first. With
  a server id, only that server's calls.

  Each row: calls, errors, average and p95 in milliseconds, and the errors
  broken down by `{kind, server_id}` (most frequent first), where a kind is
  `:no_answer`, `{:status, 403}`, `:command_failed`, `:invalid_response` or
  `:exception`.
  """
  @spec crcon_calls(term() | :all, unix_ms()) :: [map()]
  def crcon_calls(server \\ :all, now \\ now_ms()) do
    from = minute(now) - @window + 1

    counts =
      select([
        {{{:cc, :"$1", :"$2", :"$3"}, :"$4", :"$5"}, [{:>=, :"$1", from}],
         [{{:"$2", :"$3", :"$4", :"$5"}}]}
      ])
      |> only(server)

    buckets =
      select([
        {{{:ch, :"$1", :"$2", :"$3", :"$4"}, :"$5"}, [{:>=, :"$1", from}],
         [{{:"$2", :"$3", :"$4", :"$5"}}]}
      ])
      |> only(server)
      |> Enum.group_by(&elem(&1, 0))

    errors =
      select([
        {{{:ce, :"$1", :"$2", :"$3", :"$4"}, :"$5"}, [{:>=, :"$1", from}],
         [{{:"$2", :"$3", :"$4", :"$5"}}]}
      ])
      |> only(server)
      |> Enum.group_by(&elem(&1, 0))

    counts
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {endpoint, rows} ->
      calls = rows |> Enum.map(&elem(&1, 2)) |> Enum.sum()
      total_ms = rows |> Enum.map(&elem(&1, 3)) |> Enum.sum()

      histogram =
        buckets
        |> Map.get(endpoint, [])
        |> Enum.reduce(%{}, fn {_e, _s, b, n}, acc -> Map.update(acc, b, n, &(&1 + n)) end)

      breakdown =
        errors
        |> Map.get(endpoint, [])
        |> Enum.group_by(fn {_e, s, kind, _n} -> {kind, s} end, &elem(&1, 3))
        |> Enum.map(fn {{kind, s}, ns} -> %{kind: kind, server_id: s, count: Enum.sum(ns)} end)
        |> Enum.sort_by(&(-&1.count))

      %{
        endpoint: endpoint,
        calls: calls,
        errors: breakdown |> Enum.map(& &1.count) |> Enum.sum(),
        error_breakdown: breakdown,
        average: if(calls > 0, do: total_ms / calls),
        p95: percentile(histogram, 0.95)
      }
    end)
    |> Enum.sort_by(&{-&1.calls, &1.endpoint})
  end

  @doc """
  The servers CRCON was called for in the last hour.
  """
  @spec crcon_servers(unix_ms()) :: [term()]
  def crcon_servers(now \\ now_ms()) do
    from = minute(now) - @window + 1

    [{{{:cc, :"$1", :_, :"$2"}, :_, :_}, [{:>=, :"$1", from}], [:"$2"]}]
    |> select()
    |> Enum.uniq()
  end

  @doc """
  Events waiting for the engine: the messages queued in every server's
  runner. `nil` when no runner is running.
  """
  @spec queue() :: non_neg_integer() | nil
  def queue do
    case running_pids(:runner) do
      [] ->
        nil

      pids ->
        pids |> Enum.map(&queue_len/1) |> Enum.sum()
    end
  end

  defp queue_len(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} -> n
      nil -> 0
    end
  end

  @doc """
  For the settings hub: the p95 from a rule firing to its actions finishing
  over the last hour, and the events waiting for the engine.
  """
  @spec hub_summary() :: %{p95_ms: number() | nil, queue: non_neg_integer() | nil}
  def hub_summary do
    ensure()
    %{p95_ms: latency().p95, queue: queue()}
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @doc false
  def now_ms, do: System.os_time(:millisecond)

  @doc false
  def minute(unix_ms), do: div(unix_ms, @minute_ms)

  defp to_ms(native), do: System.convert_time_unit(native, :native, :microsecond) / 1000

  # Log-spaced buckets, each 10% wider than the last; bucket 0 is under 1 ms.
  defp bucket(ms) when ms < 1, do: 0
  defp bucket(ms), do: trunc(:math.log(ms) / @log_step) + 1

  defp bucket_value(0), do: 1
  defp bucket_value(b), do: round(:math.exp((b - 0.5) * @log_step))

  defp percentile(histogram, q) do
    case percentile_bucket(histogram, q) do
      nil -> nil
      b -> bucket_value(b)
    end
  end

  defp percentile_bucket(histogram, q) do
    total = histogram |> Map.values() |> Enum.sum()
    if total > 0, do: bucket_at_rank(histogram, max(ceil(q * total), 1))
  end

  defp bucket_at_rank(histogram, rank) do
    histogram
    |> Enum.sort()
    |> Enum.reduce_while(0, fn {b, n}, seen ->
      if seen + n >= rank, do: {:halt, {:found, b}}, else: {:cont, seen + n}
    end)
    |> case do
      {:found, b} -> b
      _none -> nil
    end
  end

  defp only(rows, :all), do: rows
  defp only(rows, server), do: Enum.filter(rows, &(elem(&1, 1) == server))

  defp select(spec) do
    :ets.select(@table, spec)
  rescue
    ArgumentError -> []
  end

  defp sum(spec), do: spec |> select() |> Enum.sum()

  defp safe_meta(key) do
    case :ets.lookup(@table, {:meta, key}) do
      [{_key, value}] -> value
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp to_datetime(nil), do: nil
  defp to_datetime(unix_ms), do: DateTime.from_unix!(unix_ms, :millisecond)

  defp running(kind) do
    Registry.select(HllConditionalActions.Runtime.Registry, [
      {{{kind, :"$1"}, :_, :_}, [], [:"$1"]}
    ])
  rescue
    ArgumentError -> []
  end

  defp running_pids(kind) do
    Registry.select(HllConditionalActions.Runtime.Registry, [
      {{{kind, :_}, :"$1", :_}, [], [:"$1"]}
    ])
  rescue
    ArgumentError -> []
  end
end
