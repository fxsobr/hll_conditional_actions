defmodule HllConditionalActions.Engine.PriorityTest do
  @moduledoc """
  What priority does, and — the part the documentation gets wrong if nobody
  checks — what it does not.

  Rules are evaluated highest first, but they all see the same picture: the
  context is built once, before any of them runs. One rule cannot set something
  up for another within the same event.
  """

  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Engine
  alias HllConditionalActions.Rules.Rule

  describe "sort/1" do
    test "puts the higher priority first" do
      low = %Rule{id: 1, priority: 0}
      high = %Rule{id: 2, priority: 10}

      assert Rule.sort([low, high]) == [high, low]
    end

    test "breaks a tie by the order the rules were created" do
      first = %Rule{id: 1, priority: 5}
      second = %Rule{id: 2, priority: 5}

      assert Rule.sort([second, first]) == [first, second]
    end

    test "a negative priority goes last" do
      normal = %Rule{id: 1, priority: 0}
      last = %Rule{id: 2, priority: -10}

      assert Rule.sort([last, normal]) == [normal, last]
    end
  end

  describe "priority does not stop the rules below it" do
    test "every matching rule runs, whatever its priority" do
      server = server_fixture()

      high =
        rule_fixture(%{
          name: "First",
          server_id: server.id,
          priority: 10,
          simulation: true,
          trigger_event: :player_connected
        })

      low =
        rule_fixture(%{
          name: "Second",
          server_id: server.id,
          priority: 0,
          simulation: true,
          trigger_event: :player_connected
        })

      executions =
        Engine.process_player_trigger(server, [low, high], :player_connected,
          player_id: "7656119",
          player_name: "Kapitan"
        )

      ran = Enum.map(executions, & &1.rule_id)

      # Both, and the higher priority one first.
      assert ran == [high.id, low.id]
    end
  end
end
