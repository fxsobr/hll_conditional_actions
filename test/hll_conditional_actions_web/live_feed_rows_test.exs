defmodule HllConditionalActionsWeb.LiveFeedRowsTest do
  use ExUnit.Case, async: true

  import HllConditionalActions.Fixtures, only: [log_line: 1]

  alias HllConditionalActions.Crcon.Events
  alias HllConditionalActions.LiveFeed
  alias HllConditionalActions.Rules.Execution
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActionsWeb.LiveComponents
  alias HllConditionalActionsWeb.LiveFeedRows

  @now 1_790_000_000_000

  defp event(attrs) do
    attrs |> log_line() |> Events.from_log()
  end

  defp row(event),
    do: LiveComponents.event_row(event, LiveFeedRows.row_id(LiveFeed.event_key(event), "x"))

  defp execution(id, key, status \\ :executed) do
    %Execution{
      id: id,
      rule_id: 7,
      rule: %Rule{id: 7, name: "Kill feed"},
      status: status,
      player_name: "Chris",
      executed_at: DateTime.from_unix!(@now + id, :millisecond),
      results: [],
      trace: if(key, do: %{"event_key" => key}, else: %{})
    }
  end

  test "keeps the newest rows up to its limit, replacing a row by id" do
    kill = row(event(%{"timestamp_ms" => @now}))
    later = row(event(%{"timestamp_ms" => @now + 1}))

    buffer =
      LiveFeedRows.new(2)
      |> LiveFeedRows.add(kill)
      |> LiveFeedRows.add(later)
      |> LiveFeedRows.add(kill)

    assert Enum.map(buffer.rows, & &1.id) == [kill.id, later.id]
    assert length(LiveFeedRows.add(buffer, row(event(%{"timestamp_ms" => @now + 2}))).rows) == 2
  end

  test "puts an execution on the line that triggered it, and filters by what acted" do
    kill = event(%{"timestamp_ms" => @now})

    chat =
      event(%{
        "action" => "CHAT[Allies][Team]",
        "sub_content" => "hi",
        "timestamp_ms" => @now + 5
      })

    buffer = LiveFeedRows.new(10) |> LiveFeedRows.add(row(kill)) |> LiveFeedRows.add(row(chat))

    annotation = LiveFeed.annotation(execution(1, LiveFeed.event_key(kill)), %{name: "Kill feed"})

    assert {:ok, annotated, buffer} =
             LiveFeedRows.annotate(buffer, LiveFeed.event_key(kill), annotation)

    assert [%{rule_name: "Kill feed"}] = annotated.acted
    assert :error = LiveFeedRows.annotate(buffer, "nope", annotation)

    assert [%{type: :player_kill}] = LiveFeedRows.visible(buffer, "acted")
    assert [%{type: :player_kill}] = LiveFeedRows.visible(buffer, "kills")
    assert [%{type: :player_chat}] = LiveFeedRows.visible(buffer, "chat")
    assert length(LiveFeedRows.visible(buffer, "all")) == 2
    assert LiveFeedRows.shown?(buffer, "kills", annotated.id, 5)
    refute LiveFeedRows.shown?(buffer, "chat", annotated.id, 5)
  end

  test "opens with the log's lines, their executions on them, the others on their own" do
    kill = event(%{"timestamp_ms" => @now})
    linked = execution(1, LiveFeed.event_key(kill), :simulated)
    periodic = execution(2, nil)

    [first, second] = LiveFeedRows.seed([kill], [linked, periodic], %{})

    assert first.id == "execution-2"
    assert second.key == LiveFeed.event_key(kill)
    assert [%{status: :simulated, rule_name: "Kill feed"}] = second.acted
  end

  test "a leaving player's time comes from their joining line" do
    joined =
      event(%{
        "action" => "CONNECTED",
        "player_name_2" => nil,
        "player_id_2" => nil,
        "timestamp_ms" => @now
      })

    left =
      event(%{
        "action" => "DISCONNECTED",
        "player_name_2" => nil,
        "player_id_2" => nil,
        "timestamp_ms" => @now + 4_320_000
      })

    rows = LiveFeedRows.seed([left, joined], [], %{})
    assert %{details: %{played: 4320}} = Enum.find(rows, &(&1.type == :player_disconnected))
  end

  test "labels a rule's pill by how it ended" do
    base = %{rule_name: "Friendly fire", status: :simulated, step: 2}

    assert LiveComponents.pill_label(base) == "Friendly fire · simulated step 2"
    assert LiveComponents.pill_label(base, :short) == "Friendly fire · step 2"
    assert LiveComponents.pill_label(%{base | status: :executed, step: nil}) == "Friendly fire"
    assert LiveComponents.pill_label(%{base | status: :failed}) == "Friendly fire · failed"
  end
end
