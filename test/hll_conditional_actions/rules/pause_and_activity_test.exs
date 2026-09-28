defmodule HllConditionalActions.Rules.PauseAndActivityTest do
  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Engine
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Audit
  alias HllConditionalActions.Rules.Rule

  doctest HllConditionalActionsWeb.RulePause

  defp in_minutes(minutes), do: DateTime.add(DateTime.utc_now(), minutes * 60, :second)

  describe "pause" do
    test "a paused rule is skipped by the engine until the time passes" do
      rule = rule_fixture()
      assert Engine.rules_for([rule], :player_connected) == [rule]

      {:ok, paused} = Rules.pause_rule(rule, in_minutes(30), reason: "  event night ")

      assert paused.enabled
      assert paused.pause_reason == "event night"
      assert Rule.paused?(paused)
      assert Engine.rules_for([paused], :player_connected) == []

      # No job resumes it: once the moment is past it is simply live again.
      expired = %{paused | paused_until: DateTime.add(DateTime.utc_now(), -1, :second)}
      refute Rule.paused?(expired)
      assert Engine.rules_for([expired], :player_connected) == [expired]
    end

    test "resume clears the pause and the reason" do
      {:ok, paused} = Rules.pause_rule(rule_fixture(), in_minutes(120), reason: "testing")
      {:ok, resumed} = Rules.resume_rule(paused)

      assert resumed.paused_until == nil
      assert resumed.pause_reason == nil
      refute Rule.paused?(resumed)
    end

    test "a moment in the past is refused" do
      assert {:error, :in_the_past} = Rules.pause_rule(rule_fixture(), in_minutes(-5))
    end

    test "pausing and resuming are recorded in the history" do
      rule = rule_fixture()
      {:ok, rule} = Rules.pause_rule(rule, in_minutes(30))
      {:ok, _rule} = Rules.resume_rule(rule)

      actions = rule.id |> Audit.list_versions() |> Enum.map(& &1.action)
      assert :paused in actions
      assert :resumed in actions
    end
  end

  describe "groups" do
    test "a group differing only in case or spacing joins the existing one" do
      rule_fixture(%{group: "Seeding"})
      other = rule_fixture(%{group: "  seeding  "})

      assert other.group == "Seeding"
      assert Rules.list_groups() == ["Seeding"]
    end

    test "a blank group is no group" do
      assert rule_fixture(%{group: "   "}).group == nil
    end

    test "canonical_group/2" do
      assert Rules.canonical_group(" anti  cheat ", ["Anti cheat"]) == "Anti cheat"
      assert Rules.canonical_group("Events", ["Anti cheat"]) == "Events"
      assert Rules.canonical_group("", ["Anti cheat"]) == nil
    end
  end

  describe "activity_for_rules/1" do
    test "last fired, runs and failures in 24h, in one map" do
      server = server_fixture()
      busy = rule_fixture(%{server_id: server.id})
      quiet = rule_fixture(%{server_id: server.id})

      for {status, age} <- [executed: 60, failed: 120, executed: 2 * 24 * 3600] do
        {:ok, _execution} =
          Rules.record_execution(%{
            rule_id: busy.id,
            server_id: server.id,
            player_id: "1",
            trigger_event: "player_connected",
            status: status,
            executed_at: DateTime.add(DateTime.utc_now(), -age, :second)
          })
      end

      activity = Rules.activity_for_rules([busy.id, quiet.id])

      assert %{last_24h: 2, failed_24h: 1, last_executed_at: %DateTime{}} = activity[busy.id]
      refute Map.has_key?(activity, quiet.id)
      assert Rules.activity_for_rules([]) == %{}
    end
  end

  describe "player filter" do
    test "matches the exact ID or part of the name" do
      server = server_fixture()
      rule = rule_fixture(%{server_id: server.id})

      for {id, name} <- [{"111", "Fulano"}, {"222", "Beltrano"}] do
        {:ok, _execution} =
          Rules.record_execution(%{
            rule_id: rule.id,
            server_id: server.id,
            player_id: id,
            player_name: name,
            trigger_event: "player_connected",
            status: :executed
          })
      end

      assert Rules.count_executions_for(nil, player: "fula") == 1
      assert Rules.count_executions_for(nil, player: "222") == 1
      assert Rules.count_executions_for(nil, player: "an") == 2
    end
  end
end
