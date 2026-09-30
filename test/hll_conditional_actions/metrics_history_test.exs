defmodule HllConditionalActions.MetricsHistoryTest do
  use ExUnit.Case, async: false

  alias HllConditionalActions.Metrics
  alias HllConditionalActions.Metrics.History

  setup do
    :ok = Metrics.reset()
    :ok
  end

  # The history reads complete minutes; a minute from now, this one is.
  defp later, do: History.now_ms() + 60_000

  defp native(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  defp event(server_id) do
    :telemetry.execute([:hll_conditional_actions, :log_stream, :event], %{count: 1}, %{
      server_id: server_id,
      type: :player_kill
    })
  end

  defp status(server_id, status) do
    :telemetry.execute([:hll_conditional_actions, :log_stream, :status], %{count: 1}, %{
      server_id: server_id,
      status: status
    })
  end

  defp fired(ms, meta \\ %{}) do
    :telemetry.execute(
      [:hll_conditional_actions, :rule, :fired],
      %{duration: native(ms), count: 1},
      Map.merge(
        %{
          rule_id: 1,
          rule_name: "Boas-vindas",
          server_id: 1,
          trigger: :player_connected,
          status: :executed,
          simulation: false
        },
        meta
      )
    )
  end

  defp skipped(rule_id, reason) do
    :telemetry.execute([:hll_conditional_actions, :rule, :skipped], %{count: 1}, %{
      rule_id: rule_id,
      server_id: 1,
      trigger: :player_kill,
      reason: reason
    })
  end

  defp call(endpoint, server_id, ms, meta \\ %{}) do
    :telemetry.execute(
      [:hll_conditional_actions, :crcon, :request, :stop],
      %{duration: native(ms)},
      Map.merge(%{endpoint: endpoint, server_id: server_id, outcome: :ok, status: nil}, meta)
    )
  end

  test "counts game events per minute and per server" do
    server = System.unique_integer([:positive])
    other = System.unique_integer([:positive])

    for _ <- 1..3, do: event(server)
    event(other)

    events = History.events(30, later())

    assert length(events.per_minute) == 30
    assert List.last(events.per_minute).count == 4
    assert events.last_minute == 4
    assert events.by_server[server] == 3
    assert events.by_server[other] == 1
    assert History.last_event_at(server)
  end

  test "counts rules fired, skipped and simulated in the hour" do
    fired(10)
    fired(10, %{status: :simulated, simulation: true})
    skipped(7, :cooldown)
    skipped(7, :cooldown)
    skipped(8, :conditions_not_met)
    skipped(9, :cooldown)

    assert History.rules() == %{fired: 2, skipped: 4, simulated: 1}

    assert [%{reason: :cooldown, count: 3, top_rule_id: 7, top_rule_count: 2}, conditions] =
             History.skips()

    assert conditions.reason == :conditions_not_met
    assert History.rule_name(1) == "Boas-vindas"
  end

  test "reads percentiles from the histogram, within its resolution" do
    for _ <- 1..97, do: fired(40)
    for _ <- 1..3, do: fired(1_200)

    latency = History.latency()

    assert latency.count == 100
    assert_in_delta latency.p50, 40, 40 * 0.06
    assert_in_delta latency.p95, 40, 40 * 0.06
    assert_in_delta latency.p99, 1_200, 1_200 * 0.06
  end

  test "blames the CRCON endpoint that took most of the slowest firings" do
    for _ <- 1..50, do: fired(20)

    call("get_live_game_stats", 1, 900)
    fired(1_000, %{trigger: :match_end})

    assert %{endpoint: "get_live_game_stats", trigger: :match_end} = History.latency().p99_cause
  end

  test "groups CRCON calls per endpoint with errors by kind and server" do
    call("get_players", 1, 40)
    call("get_players", 2, 60)
    call("get_players", 2, 5_000, %{outcome: :transport_error, error: :timeout})
    call("message_player", 1, 90, %{outcome: :unauthorized, status: 403})
    call("message_player", 1, 110)

    assert [players, message] = History.crcon_calls()

    assert players.endpoint == "get_players"
    assert players.calls == 3
    assert players.errors == 1
    assert [%{kind: :no_answer, server_id: 2, count: 1}] = players.error_breakdown
    assert_in_delta players.average, 1_700, 1

    assert message.endpoint == "message_player"
    assert [%{kind: {:status, 403}, server_id: 1}] = message.error_breakdown

    assert [only_two] = History.crcon_calls(2)
    assert only_two.calls == 2
    assert Enum.sort(History.crcon_servers()) == [1, 2]
  end

  test "a stream that dropped and came back counts as a reconnect" do
    server = System.unique_integer([:positive])

    for s <- [:connecting, :connected, :error, :connecting, :connected], do: status(server, s)

    timeline = History.stream_timeline(server)

    assert timeline.status == :connected
    assert timeline.reconnects == 1
    assert timeline.attempts == 0
    assert List.last(timeline.segments).state == :up
    assert History.stream_down_since(server) == nil
  end

  test "a stream that is down says since when and how many attempts" do
    server = System.unique_integer([:positive])

    for s <- [:connecting, :connected, :error, :connecting, :error, :connecting, :error],
        do: status(server, s)

    timeline = History.stream_timeline(server)

    assert List.last(timeline.segments).state == :down
    assert timeline.attempts == 2
    assert %DateTime{} = timeline.down_since
    assert History.stream_down_since(server) == timeline.down_since
    assert History.last_status(server) |> elem(1) == :error
  end

  test "a reset clears the counters but keeps the connection history" do
    server = System.unique_integer([:positive])
    fired(10)
    status(server, :connected)

    :ok = Metrics.reset()

    assert History.rules().fired == 0
    assert History.last_status(server) |> elem(1) == :connected
  end

  test "hub_summary answers the p95 and the queue" do
    assert %{p95_ms: nil, queue: queue} = History.hub_summary()
    assert is_nil(queue) or is_integer(queue)

    fired(40)
    assert_in_delta History.hub_summary().p95_ms, 40, 3
  end

  test "an event with unexpected metadata does not detach the handler" do
    :telemetry.execute([:hll_conditional_actions, :rule, :fired], %{}, %{status: :executed})

    fired(10)
    assert History.rules().fired == 2
  end

  test "the CRCON client reports every request" do
    parent = self()
    handler = "history-test-#{System.unique_integer()}"

    :telemetry.attach(
      handler,
      [:hll_conditional_actions, :crcon, :request, :stop],
      fn _event, measurements, metadata, _config ->
        send(parent, {:call, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      Plug.Conn.send_resp(conn, 403, "forbidden")
    end)

    conn = %{id: 42, base_url: "https://rcon.example.com", api_key: "k"}

    assert {:error, _error} =
             HllConditionalActions.Crcon.Client.request(conn, "message_player", %{})

    assert_receive {:call, %{duration: _},
                    %{
                      endpoint: "message_player",
                      server_id: 42,
                      outcome: :unauthorized,
                      status: 403
                    }}
  end
end
