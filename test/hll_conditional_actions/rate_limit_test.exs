defmodule HllConditionalActions.RateLimitTest do
  @moduledoc """
  The counter behind the sign in throttle. A limiter that miscounts is worse
  than none: too loose and it protects nothing, too tight and it locks people
  out of their own server.
  """

  use ExUnit.Case, async: true

  alias HllConditionalActions.RateLimit

  # Every test gets its own key, so they can run together against the one
  # shared table.
  setup do
    %{key: "test:#{System.unique_integer([:positive])}"}
  end

  @opts [limit: 3, window_ms: 60_000]

  test "allows attempts up to the limit", %{key: key} do
    for _attempt <- 1..3 do
      assert RateLimit.check(key, @opts) == :ok
    end
  end

  test "refuses the one after, and says when to come back", %{key: key} do
    for _attempt <- 1..3, do: RateLimit.check(key, @opts)

    assert {:error, :rate_limited, seconds} = RateLimit.check(key, @opts)
    assert seconds > 0
    assert seconds <= 60
  end

  test "stays refused for the rest of the window", %{key: key} do
    for _attempt <- 1..5, do: RateLimit.check(key, @opts)

    assert {:error, :rate_limited, _seconds} = RateLimit.check(key, @opts)
  end

  test "keys do not borrow each other's budget", %{key: key} do
    for _attempt <- 1..4, do: RateLimit.check(key, @opts)

    assert RateLimit.check("#{key}:other", @opts) == :ok
  end

  test "a new window starts fresh", %{key: key} do
    # A one millisecond window has rolled over by the time the next call runs.
    tiny = [limit: 1, window_ms: 1]

    assert RateLimit.check(key, tiny) == :ok
    Process.sleep(3)
    assert RateLimit.check(key, tiny) == :ok
  end

  test "reset/1 forgets the attempts", %{key: key} do
    for _attempt <- 1..5, do: RateLimit.check(key, @opts)
    assert {:error, :rate_limited, _seconds} = RateLimit.check(key, @opts)

    RateLimit.reset(key)

    assert RateLimit.check(key, @opts) == :ok
  end

  test "count/2 reports what has been spent", %{key: key} do
    assert RateLimit.count(key, 60_000) == 0

    RateLimit.check(key, @opts)
    RateLimit.check(key, @opts)

    assert RateLimit.count(key, 60_000) == 2
  end

  test "the sweep drops old windows but keeps the current one", %{key: key} do
    RateLimit.check(key, @opts)

    RateLimit.sweep()

    assert RateLimit.count(key, 60_000) == 1
  end
end
