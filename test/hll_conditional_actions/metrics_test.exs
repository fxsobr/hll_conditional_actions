defmodule HllConditionalActions.MetricsTest do
  use ExUnit.Case, async: false

  alias HllConditionalActions.Metrics

  setup do
    :ok = Metrics.reset()
    :ok
  end

  defp emit_fired(status, ms) do
    :telemetry.execute(
      [:hll_conditional_actions, :rule, :fired],
      %{duration: System.convert_time_unit(ms, :millisecond, :native), count: 1},
      %{
        rule_id: 1,
        rule_name: "r",
        server_id: 1,
        trigger: :player_connected,
        status: status,
        simulation: false
      }
    )
  end

  test "counts rule outcomes and summarizes their duration" do
    emit_fired(:executed, 10)
    emit_fired(:executed, 30)
    emit_fired(:failed, 20)

    snapshot = Metrics.snapshot()

    assert snapshot.rules.fired == [executed: 2, failed: 1]
    assert snapshot.rules.duration.count == 3
    assert snapshot.rules.duration.average == 20.0
    assert snapshot.rules.duration.max == 30
    assert snapshot.rules.duration.last == 20
  end

  test "counts skips by reason" do
    for reason <- [:cooldown, :cooldown, :conditions_not_met] do
      :telemetry.execute(
        [:hll_conditional_actions, :rule, :skipped],
        %{count: 1},
        %{rule_id: 1, server_id: 1, trigger: :player_kill, reason: reason}
      )
    end

    assert Metrics.snapshot().rules.skipped == [cooldown: 2, conditions_not_met: 1]
  end

  test "tracks CRCON latency per endpoint and outcome" do
    for {endpoint, outcome, ms} <- [
          {"get_gamestate", :ok, 40},
          {"get_gamestate", :ok, 80},
          {"kick", :command_failed, 15}
        ] do
      :telemetry.execute(
        [:hll_conditional_actions, :crcon, :request, :stop],
        %{duration: System.convert_time_unit(ms, :millisecond, :native)},
        %{endpoint: endpoint, method: :get, outcome: outcome}
      )
    end

    snapshot = Metrics.snapshot()

    assert {{"get_gamestate", :ok}, 2} in snapshot.crcon.requests
    assert {{"kick", :command_failed}, 1} in snapshot.crcon.requests

    assert [{"get_gamestate", gamestate} | _rest] = snapshot.crcon.duration_by_endpoint
    assert gamestate.count == 2
    assert gamestate.average == 60.0
    assert gamestate.max == 80
  end

  test "counts log stream events and connection changes" do
    :telemetry.execute([:hll_conditional_actions, :log_stream, :event], %{count: 1}, %{
      server_id: 1,
      type: :player_kill
    })

    :telemetry.execute([:hll_conditional_actions, :log_stream, :status], %{count: 1}, %{
      server_id: 1,
      status: :connected
    })

    snapshot = Metrics.snapshot()

    assert snapshot.log_stream.events == [player_kill: 1]
    assert snapshot.log_stream.statuses == [connected: 1]
  end

  test "total_events answers whether anything has happened" do
    assert Metrics.total_events() == 0

    emit_fired(:executed, 5)

    assert Metrics.total_events() == 1
  end

  test "reset clears the counters and restarts the window" do
    emit_fired(:executed, 5)
    before = Metrics.snapshot().started_at

    :ok = Metrics.reset()
    snapshot = Metrics.snapshot()

    assert snapshot.rules.fired == []
    assert snapshot.rules.duration == nil
    assert DateTime.compare(snapshot.started_at, before) in [:gt, :eq]
  end

  test "an event with unexpected metadata does not take the collector down" do
    :telemetry.execute([:hll_conditional_actions, :rule, :fired], %{}, %{status: :executed})

    assert Process.alive?(Process.whereis(Metrics))
    assert Metrics.snapshot().rules.fired == [executed: 1]
  end
end
