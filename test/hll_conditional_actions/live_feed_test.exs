defmodule HllConditionalActions.LiveFeedTest do
  use HllConditionalActions.DataCase, async: false

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Crcon.Events
  alias HllConditionalActions.Engine
  alias HllConditionalActions.LiveFeed
  alias HllConditionalActions.LiveMatch
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Tickets.Ticket

  doctest HllConditionalActions.LiveFeed
  doctest HllConditionalActions.LiveMatch

  setup do
    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      result =
        case conn.request_path do
          "/api/get_recent_logs" ->
            %{
              "logs" => [
                log_line(%{"timestamp_ms" => 1_700_000_000_000}),
                log_line(%{"action" => "MATCH START", "timestamp_ms" => 1_700_000_100_000})
              ]
            }

          _other ->
            true
        end

      Req.Test.json(conn, %{"result" => result, "failed" => false, "error" => nil})
    end)

    %{server: server_fixture()}
  end

  test "the engine stores the key of the line that made a rule act", %{server: server} do
    rule = rule_fixture(%{trigger_event: :player_kill, simulation: true, server_id: server.id})
    event = Events.from_log(log_line(), server)

    [execution] =
      Engine.process_player_trigger(server, [rule], :player_kill,
        player_id: event.player_id,
        player_name: event.player_name,
        event: event
      )

    assert LiveFeed.execution_event_key(execution) == LiveFeed.event_key(event)
  end

  test "reads the recent log newest first", %{server: server} do
    assert {:ok, [first, second]} = LiveFeed.recent_events(server, 10)
    assert first.type == :match_start
    assert second.type == :player_kill
    assert LiveMatch.started_at_from([first, second]) == first.occurred_at
  end

  test "an execution becomes the pill of its line", %{server: server} do
    rule = rule_fixture(%{name: "Ladder", server_id: server.id})

    {:ok, execution} =
      Rules.record_execution(%{
        rule_id: rule.id,
        server_id: server.id,
        trigger_event: "player_kill",
        status: :simulated,
        results: [%{"type" => "punish_player", "status" => "ok"}],
        trace: %{"step" => 2, "steps" => 3}
      })

    assert %{rule_name: "Ladder", status: :simulated, step: 2, action: "punish_player"} =
             LiveFeed.annotation(execution, rule)
  end

  test "a ticket goes to the chat line of its player closest in time", %{server: server} do
    now = DateTime.utc_now()

    line = fn text, seconds_ago ->
      %{
        "action" => "CHAT[Allies][Team]",
        "message" => text,
        "sub_content" => text,
        "timestamp_ms" => now |> DateTime.add(-seconds_ago) |> DateTime.to_unix(:millisecond)
      }
      |> log_line()
      |> Events.from_log(server)
    end

    earlier = line.("hello", 120)
    command = line.("!admin tk at the church", 2)

    ticket =
      Repo.insert!(%Ticket{
        server_id: server.id,
        player_id: command.player_id,
        player_name: command.player_name,
        source: :chat,
        status: :open,
        priority: :normal,
        last_activity_at: DateTime.truncate(now, :second)
      })

    assert %{} = tickets = LiveFeed.tickets_for(server.id, [earlier, command])
    assert tickets[LiveFeed.event_key(command)].id == ticket.id
    refute Map.has_key?(tickets, LiveFeed.event_key(earlier))
  end

  test "counts what each rule did since the match started", %{server: server} do
    rule = rule_fixture(%{server_id: server.id})
    started = DateTime.add(DateTime.utc_now(), -600)

    for {status, at} <- [
          {:executed, DateTime.add(started, -60)},
          {:executed, DateTime.utc_now()},
          {:failed, DateTime.utc_now()}
        ] do
      {:ok, _execution} =
        Rules.record_execution(%{
          rule_id: rule.id,
          server_id: server.id,
          trigger_event: "player_connected",
          status: status,
          executed_at: at
        })
    end

    rule_id = rule.id

    assert %{total: 2, rules: %{^rule_id => %{count: 2, failed: 1}}} =
             LiveMatch.rule_counts(server.id, started)

    assert %{total: 0} = LiveMatch.rule_counts(server.id, nil)
  end
end
