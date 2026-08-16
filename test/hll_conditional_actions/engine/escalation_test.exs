defmodule HllConditionalActions.Engine.EscalationTest do
  @moduledoc """
  An escalating rule must run one rung per offence, remember the count across
  firings, and keep repeating its last rung once the ladder runs out.
  """

  use HllConditionalActions.DataCase, async: false

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Engine
  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Escalation
  alias HllConditionalActions.Rules

  @player_id "76561198000000001"

  setup do
    test_pid = self()

    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      send(test_pid, {:crcon_called, conn.request_path})
      Req.Test.json(conn, %{"result" => true, "failed" => false, "error" => nil})
    end)

    %{server: server_fixture()}
  end

  defp context(server) do
    Context.build(server, :player_connected,
      player_id: @player_id,
      player_name: "Sarge",
      player: player(),
      gamestate: gamestate()
    )
  end

  defp ladder_rule(attrs \\ %{}) do
    rule_fixture(
      Map.merge(
        %{
          escalation_window_seconds: 3600,
          actions: [
            %{type: :message_player, parameters: %{"message" => "First warning"}},
            %{type: :punish_player, parameters: %{"reason" => "Second time"}},
            %{type: :kick_player, parameters: %{"reason" => "Enough"}}
          ]
        },
        attrs
      )
    )
  end

  # Executions come back from the database with JSON (string) keys.
  defp types(execution), do: Enum.map(execution.results, & &1["type"])

  describe "steps_for/2" do
    test "hands back every action when the rule does not escalate" do
      rule = ladder_rule(%{escalation_window_seconds: 0})

      assert length(Escalation.steps_for(rule, @player_id)) == 3
    end

    test "hands back every action when there is no player to escalate against" do
      assert length(Escalation.steps_for(ladder_rule(), nil)) == 3
    end
  end

  describe "running an escalating rule" do
    test "runs one rung per offence and climbs", %{server: server} do
      rule = ladder_rule()

      assert {:ok, first} = Engine.run_rule(rule, context(server))
      assert types(first) == ["message_player"]

      assert {:ok, second} = Engine.run_rule(rule, context(server))
      assert types(second) == ["punish_player"]

      assert {:ok, third} = Engine.run_rule(rule, context(server))
      assert types(third) == ["kick_player"]
    end

    test "repeats the last rung once the ladder runs out", %{server: server} do
      rule = ladder_rule()

      for _offence <- 1..4, do: Engine.run_rule(rule, context(server))

      assert {:ok, fifth} = Engine.run_rule(rule, context(server))
      assert types(fifth) == ["kick_player"]
    end

    test "counts only offences inside the window", %{server: server} do
      rule = ladder_rule(%{escalation_window_seconds: 60})

      assert {:ok, _first} = Engine.run_rule(rule, context(server))

      # Age the first offence out of the window: the ladder resets.
      Rules.list_executions(rule_id: rule.id)
      |> Enum.each(fn execution ->
        Rules.update_execution(execution, %{
          executed_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })
      end)

      assert {:ok, second} = Engine.run_rule(rule, context(server))
      assert types(second) == ["message_player"]
    end

    test "escalates per player, not per rule", %{server: server} do
      rule = ladder_rule()

      assert {:ok, _first} = Engine.run_rule(rule, context(server))

      other =
        Context.build(server, :player_connected,
          player_id: "76561198000000002",
          player_name: "Rook",
          player: player(),
          gamestate: gamestate()
        )

      assert {:ok, execution} = Engine.run_rule(rule, other)
      assert types(execution) == ["message_player"]
    end

    test "a rule that does not escalate still runs every action", %{server: server} do
      rule = ladder_rule(%{escalation_window_seconds: 0})

      assert {:ok, execution} = Engine.run_rule(rule, context(server))
      assert length(execution.results) == 3
    end
  end

  describe "the strikes condition field" do
    test "sees the count from before this firing", %{server: server} do
      rule =
        ladder_rule(%{
          escalation_window_seconds: 0,
          conditions: [%{field: :strikes, operator: :greater_than_or_equal, value: "1"}]
        })

      # Nothing recorded yet, so the rule must not fire.
      assert {:skip, :conditions_not_met} = Engine.run_rule(rule, context(server))
    end
  end
end
