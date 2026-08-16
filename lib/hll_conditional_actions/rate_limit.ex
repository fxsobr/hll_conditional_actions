defmodule HllConditionalActions.RateLimit do
  @moduledoc """
  Counts attempts in fixed time windows, in memory.

  This exists for one reason: a sign in form on the public internet is a
  password guessing oracle unless something counts the guesses. Caddy limits
  by address in front, which stops a flood from one machine; this limits by
  *account*, which is what stops a slow spray from a botnet — the two catch
  different attacks and neither replaces the other.

  Deliberately not a dependency and deliberately not distributed: the counters
  live in one ETS table, so a two node deployment allows twice the attempts.
  That is an acceptable trade for a tool a game community runs on one box, and
  the alternative — a shared counter in the database — would put a write on the
  path of every failed login, which is the path an attacker controls.

  Windows are fixed rather than rolling, so a burst that straddles a boundary
  can spend two windows' worth of attempts at once. The limits used are low
  enough that twice them is still not a useful number of guesses.

  ## Use

      RateLimit.check("login:ip:203.0.113.4", limit: 10, window_ms: 60_000)
      #=> :ok | {:error, :rate_limited, retry_after_seconds}

  A successful sign in should call `reset/1`, so somebody who mistyped their
  password four times is not still being counted an hour later.
  """

  use GenServer

  require Logger

  @table __MODULE__

  # Counters are only dead weight once their window has passed; sweeping keeps
  # the table proportional to recent traffic rather than to all of it.
  @sweep_every_ms :timer.minutes(1)
  @keep_for_ms :timer.hours(1)

  # ── API ────────────────────────────────────────────────────────────────────

  @doc """
  Records one attempt against `key` and says whether it is allowed.

  Returns the seconds until the window rolls over, so the caller can tell the
  user when to come back rather than leaving them guessing.
  """
  @spec check(String.t(), keyword()) :: :ok | {:error, :rate_limited, pos_integer()}
  def check(key, opts) do
    limit = Keyword.fetch!(opts, :limit)
    window_ms = Keyword.fetch!(opts, :window_ms)
    now = System.system_time(:millisecond)
    started_at = window_start(now, window_ms)

    count = :ets.update_counter(@table, {key, started_at}, {2, 1}, {{key, started_at}, 0})

    if count > limit do
      {:error, :rate_limited, retry_after(now, started_at, window_ms)}
    else
      :ok
    end
  rescue
    # A limiter that crashes the request it was meant to protect is worse than
    # no limiter: fail open, but say so.
    error ->
      Logger.error("[rate_limit] check failed for #{inspect(key)}: #{inspect(error)}")
      :ok
  end

  @doc """
  Whether `key` is over its limit, without recording an attempt.

  For a caller that only wants to count *failures*: the plug asks this on the
  way in, and the thing that knows the attempt was wrong records it afterwards.
  Counting on the way in as well would charge two per attempt.
  """
  @spec peek(String.t(), keyword()) :: :ok | {:error, :rate_limited, pos_integer()}
  def peek(key, opts) do
    limit = Keyword.fetch!(opts, :limit)
    window_ms = Keyword.fetch!(opts, :window_ms)
    now = System.system_time(:millisecond)
    started_at = window_start(now, window_ms)

    if count(key, window_ms) >= limit do
      {:error, :rate_limited, retry_after(now, started_at, window_ms)}
    else
      :ok
    end
  rescue
    error ->
      Logger.error("[rate_limit] peek failed for #{inspect(key)}: #{inspect(error)}")
      :ok
  end

  @doc """
  Forgets every attempt recorded against `key`.
  """
  @spec reset(String.t()) :: :ok
  def reset(key) do
    :ets.match_delete(@table, {{key, :_}, :_})
    :ok
  rescue
    _error -> :ok
  end

  @doc """
  How many attempts `key` has spent in the current window. For tests, and for
  the occasional "why am I locked out".
  """
  @spec count(String.t(), pos_integer()) :: non_neg_integer()
  def count(key, window_ms) do
    started_at = window_start(System.system_time(:millisecond), window_ms)

    case :ets.lookup(@table, {key, started_at}) do
      [{_key, count}] -> count
      [] -> 0
    end
  rescue
    _error -> 0
  end

  # ── Process ────────────────────────────────────────────────────────────────

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    # Public and write_concurrency: every request writes, and none of them
    # should have to queue behind this process to do it.
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    schedule_sweep()

    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  # Exposed for the test, which cannot wait a minute for the timer.
  def sweep do
    cutoff = System.system_time(:millisecond) - @keep_for_ms

    # The key holds the window's start time rather than its index, so a single
    # comparison retires old counters regardless of the window size that
    # created them.
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}])
  rescue
    error ->
      Logger.error("[rate_limit] sweep failed: #{inspect(error)}")
      0
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every_ms)

  defp window_start(now, window_ms), do: div(now, window_ms) * window_ms

  defp retry_after(now, started_at, window_ms) do
    started_at |> Kernel.+(window_ms) |> Kernel.-(now) |> div(1000) |> max(1)
  end
end
