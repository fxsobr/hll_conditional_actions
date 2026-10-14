defmodule HllConditionalActions.CacheTest do
  use ExUnit.Case, async: false

  alias HllConditionalActions.Cache

  setup do
    Application.put_env(:hll_conditional_actions, :cache, true)
    on_exit(fn -> Application.put_env(:hll_conditional_actions, :cache, false) end)
    Cache.drop(:cache_test)
  end

  test "computes once while fresh, again once dropped" do
    counter = :counters.new(1, [])
    compute = fn -> :counters.add(counter, 1, 1) && :counters.get(counter, 1) end

    assert Cache.fetch({:cache_test, 1}, :timer.minutes(1), compute) == 1
    assert Cache.fetch({:cache_test, 1}, :timer.minutes(1), compute) == 1

    Cache.drop(:cache_test)
    assert Cache.fetch({:cache_test, 1}, :timer.minutes(1), compute) == 2
  end

  test "an expired entry is computed again" do
    assert Cache.fetch({:cache_test, 2}, 0, fn -> :first end) == :first
    assert Cache.fetch({:cache_test, 2}, 0, fn -> :second end) == :second
  end

  test "off, it always computes" do
    Application.put_env(:hll_conditional_actions, :cache, false)

    assert Cache.fetch({:cache_test, 3}, :timer.minutes(1), fn -> :a end) == :a
    assert Cache.fetch({:cache_test, 3}, :timer.minutes(1), fn -> :b end) == :b
  end
end
