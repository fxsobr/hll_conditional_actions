defmodule HllConditionalActions.Rules.RegrasInsightsTest do
  @moduledoc """
  The numbers and readings behind the Regras pages: the rules list's week,
  the evaluations of the executions tab, the expression editor and the
  simulator's saved tests.
  """

  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Engine.SavedEvents
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Evaluations
  alias HllConditionalActions.Rules.Expression
  alias HllConditionalActions.Rules.Insights
  alias HllConditionalActions.Rules.SimulatorTests

  doctest HllConditionalActions.Rules.Insights
  doctest HllConditionalActions.Rules.Expression

  defp record(rule, server, status, ago_seconds, attrs \\ %{}) do
    {:ok, execution} =
      Rules.record_execution(
        Map.merge(
          %{
            rule_id: rule.id,
            server_id: server.id,
            player_id: "76561190000000001",
            player_name: "Chris",
            trigger_event: "player_connected",
            status: status,
            executed_at: DateTime.add(DateTime.utc_now(), -ago_seconds, :second)
          },
          attrs
        )
      )

    execution
  end

  defp save_event(server, trigger, attrs) do
    player = player(attrs)

    SavedEvents.store([
      %{
        server_id: server.id,
        trigger: trigger,
        player_id: player["player_id"],
        player_name: player["name"],
        player: player,
        player_profile: nil,
        gamestate: nil,
        squad: %{},
        ranks: %{},
        event: nil,
        at: DateTime.utc_now(),
        at_us: System.os_time(:microsecond)
      }
    ])
  end

  describe "the rules list" do
    test "a week of runs per rule, and what failed" do
      server = server_fixture()
      rule = rule_fixture(%{server_id: server.id})

      record(rule, server, :executed, 60)
      record(rule, server, :failed, 120, %{error: "CRCON said no"})
      record(rule, server, :executed, 9 * 86_400)

      week = Insights.week_activity(nil, [rule.id])
      assert %{total: 2, failed: 1, days: days} = week[rule.id]
      assert length(days) == 7

      assert %{count: 1, error: "CRCON said no"} = Insights.failures(nil, [rule.id])[rule.id]

      assert %{runs: 2, previous: 1, failures: 1, failing_rules: 1} =
               Insights.week_summary(nil, [rule.id])
    end

    test "a simulation's days, runs and players" do
      server = server_fixture()
      rule = rule_fixture(%{server_id: server.id, simulation: true})
      record(rule, server, :simulated, 4 * 86_400)
      record(rule, server, :simulated, 60, %{player_id: "2"})

      assert %{runs: 2, players: 2, failures: 0, days: 4} = Insights.simulation(rule)
      assert Insights.simulation(%{rule | simulation: false}) == nil
    end

    test "the history's month, against the month before" do
      server = server_fixture()
      rule = rule_fixture(%{name: "Noisy", server_id: server.id})
      record(rule, server, :executed, 60)
      record(rule, server, :failed, 60)
      record(rule, server, :executed, 40 * 86_400)

      overview = Insights.overview(nil, 30)
      assert overview.fired >= 2
      assert overview.previous >= 1
      assert %{name: _name, count: count} = overview.top_failing
      assert count >= 1
    end
  end

  describe "evaluations" do
    test "the events a rule let pass, judged again" do
      server = server_fixture()

      rule =
        rule_fixture(%{
          server_id: server.id,
          conditions: [%{field: :player_level, operator: :greater_than, value: "50"}]
        })

      save_event(server, :player_connected, %{"name" => "Zed", "level" => 42})

      %{rows: [row], counts: counts} = Evaluations.list(rule, [server])
      assert row.outcome == :no_match
      assert row.player_name == "Zed"
      assert counts == %{no_match: 1}
    end

    test "an exempt VIP says why" do
      server = server_fixture()

      rule =
        rule_fixture(%{
          server_id: server.id,
          exemptions: %{exempt_vip: true}
        })

      save_event(server, :player_connected, %{"name" => "Vip", "is_vip" => true})

      assert %{rows: [%{outcome: :exempt, detail: {:vip}}]} = Evaluations.list(rule, [server])
    end

    test "an event the rule fired for is its execution" do
      server = server_fixture()
      rule = rule_fixture(%{server_id: server.id})
      save_event(server, :player_connected, %{"name" => "Chris"})
      record(rule, server, :executed, 0)

      assert %{rows: [%{outcome: :executed, event: %{}}]} = Evaluations.list(rule, [server])
    end

    test "a replay counts what each version would accept" do
      server = server_fixture()
      save_event(server, :player_connected, %{"name" => "Zed", "level" => 42})

      strict =
        rule_fixture(%{
          server_id: server.id,
          conditions: [%{field: :player_level, operator: :greater_than, value: "50"}]
        })

      loose = %{
        strict
        | conditions: [
            %HllConditionalActions.Rules.Condition{
              field: :player_level,
              operator: :greater_than,
              value: "10"
            }
          ]
      }

      assert %{events: 1, before: %{fires: 0}, after: %{fires: 1, players: 1}} =
               Evaluations.replay(strict, loose, [server])
    end
  end

  describe "the expression" do
    test "writes a rule and reads it back" do
      rule =
        rule_fixture(%{
          trigger_event: :player_kill,
          logical_operator: :or,
          conditions: [
            %{field: :player_level, operator: :greater_than_or_equal, value: "10"},
            %{field: :player_name, operator: :contains, value: "[TAG]"}
          ]
        })

      text = Expression.to_text(rule, "When: a kill")
      assert text =~ "event.type eq \"player_kill\""
      assert text =~ "player.level ge 10"
      assert text =~ "or player.name contains \"[TAG]\""

      assert {:ok, attrs} = Expression.parse(text)
      assert attrs.trigger_event == :player_kill
      assert attrs.logical_operator == :or

      assert [
               %{
                 "field" => "player_level",
                 "operator" => "greater_than_or_equal",
                 "value" => "10"
               },
               %{"field" => "player_name", "operator" => "contains", "value" => "[TAG]"}
             ] = attrs.conditions
    end

    test "not around a group is nand" do
      text = """
      event.type eq "player_connected"
      and not (
          player.is_vip eq true
          and player.level lt 5
      )
      """

      assert {:ok, %{logical_operator: :nand, conditions: [_, _]}} = Expression.parse(text)
    end

    test "says where it went wrong" do
      assert {:error, {{:unknown_field, "player.nope"}, 2, 5}} =
               Expression.parse("event.type eq \"player_kill\"\nand player.nope eq 1")

      assert {:error, {:mixed, 3, 26}} =
               Expression.parse(
                 "event.type eq \"player_kill\"\nand (player.level gt 1\n    and match.kills gt 1 or match.deaths gt 1)"
               )

      assert {:error, {:missing_trigger, 1, 1}} = Expression.parse("player.level gt 1")
    end

    test "highlights every piece of a line" do
      pieces = Expression.highlight(~s(and player.level ge 10 # note))

      assert {:keyword, "and"} in pieces
      assert {:field, "player.level"} in pieces
      assert {:operator, "ge"} in pieces
      assert {:number, "10"} in pieces
      assert {:comment, "# note"} in pieces
    end
  end

  describe "simulator tests" do
    test "a composed event is saved and read back" do
      server = server_fixture()
      sample = HllConditionalActionsWeb.EventEditor.blank_sample(server.id, :player_kill)

      assert {:ok, _test} = SimulatorTests.create(sample, "Knife kill", "Chris")

      assert [%{name: "Knife kill", sample: %{trigger: :player_kill}}] =
               SimulatorTests.list([server.id])

      [test] = SimulatorTests.list([server.id])
      :ok = SimulatorTests.delete([server.id], test.id)
      assert SimulatorTests.list([server.id]) == []
    end
  end
end
