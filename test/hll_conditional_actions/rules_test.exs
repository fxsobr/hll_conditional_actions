defmodule HllConditionalActions.RulesTest do
  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Rule

  doctest HllConditionalActions.Rules.Rule
  doctest HllConditionalActions.Rules.Action
  doctest HllConditionalActions.Rules.Catalog

  describe "validation" do
    test "a rule needs at least one condition and one action" do
      assert {:error, changeset} =
               Rules.create_rule(%{name: "Empty", game: :hll, trigger_event: :player_connected})

      errors = errors_on(changeset)
      assert errors[:conditions]
      assert errors[:actions]
    end

    test "an action's required parameters are enforced" do
      assert {:error, changeset} =
               Rules.create_rule(%{
                 name: "Ban",
                 game: :hll,
                 trigger_event: :player_connected,
                 conditions: [%{field: :always_true, operator: :equal, value: ""}],
                 actions: [%{type: :temp_ban_player, parameters: %{"reason" => "Cheating"}}]
               })

      assert %{actions: [%{parameters: ["duration_hours is required"]}]} = errors_on(changeset)
    end

    test "an operator that does not fit the field is rejected" do
      assert {:error, changeset} =
               Rules.create_rule(%{
                 name: "Bad operator",
                 game: :hll,
                 trigger_event: :player_connected,
                 conditions: [%{field: :kills, operator: :starts_with, value: "1"}],
                 actions: [%{type: :message_player, parameters: %{"message" => "hi"}}]
               })

      assert %{conditions: [%{operator: ["is not valid for this field"]}]} = errors_on(changeset)
    end

    test "a numeric field rejects a non numeric value" do
      assert {:error, changeset} =
               Rules.create_rule(%{
                 name: "Bad value",
                 game: :hll,
                 trigger_event: :player_connected,
                 conditions: [%{field: :kills, operator: :greater_than, value: "many"}],
                 actions: [%{type: :message_player, parameters: %{"message" => "hi"}}]
               })

      assert %{conditions: [%{value: ["must be a whole number"]}]} = errors_on(changeset)
    end

    test "an invalid regex is caught before the rule is saved" do
      assert {:error, changeset} =
               Rules.create_rule(%{
                 name: "Bad regex",
                 game: :hll,
                 trigger_event: :player_connected,
                 conditions: [%{field: :player_name, operator: :regex_match, value: "[unclosed"}],
                 actions: [%{type: :message_player, parameters: %{"message" => "hi"}}]
               })

      assert %{conditions: [%{value: [message]}]} = errors_on(changeset)
      assert message =~ "not a valid regex"
    end

    test "a condition field that the trigger cannot provide is rejected" do
      assert {:error, changeset} =
               Rules.create_rule(%{
                 name: "Weapon on connect",
                 game: :hll,
                 trigger_event: :player_connected,
                 conditions: [%{field: :weapon, operator: :equal, value: "M1 GARAND"}],
                 actions: [%{type: :message_player, parameters: %{"message" => "hi"}}]
               })

      assert %{conditions: [message]} = errors_on(changeset)
      assert message =~ "cannot be used with this trigger"
    end

    test "the same field is accepted for the trigger that produces it" do
      assert {:ok, _rule} =
               Rules.create_rule(%{
                 name: "Weapon on kill",
                 game: :hll,
                 trigger_event: :player_kill,
                 conditions: [%{field: :weapon, operator: :equal, value: "M1 GARAND"}],
                 actions: [%{type: :message_player, parameters: %{"message" => "hi"}}]
               })
    end

    test "unknown action parameters are dropped rather than stored" do
      {:ok, rule} =
        Rules.create_rule(%{
          name: "Extra params",
          game: :hll,
          trigger_event: :player_connected,
          conditions: [%{field: :always_true, operator: :equal, value: ""}],
          actions: [
            %{type: :message_player, parameters: %{"message" => "hi", "duration_hours" => 5}}
          ]
        })

      assert [%{parameters: %{"message" => "hi"}}] = rule.actions
    end

    test "the periodic interval has a floor" do
      assert {:error, changeset} =
               Rules.create_rule(%{
                 name: "Too often",
                 game: :hll,
                 trigger_event: :periodic,
                 trigger_interval_seconds: 1,
                 conditions: [%{field: :always_true, operator: :equal, value: ""}],
                 actions: [%{type: :message_player, parameters: %{"message" => "hi"}}]
               })

      assert %{trigger_interval_seconds: _} = errors_on(changeset)
    end
  end

  describe "scoping across servers" do
    test "a rule with no server applies to every server of its game" do
      hll = server_fixture(%{game: :hll})
      hllv = server_fixture(%{game: :hllv})

      rule = rule_fixture(%{game: :hll, server_id: nil})

      assert Rule.applies_to?(rule, hll)
      refute Rule.applies_to?(rule, hllv)

      assert Enum.map(Rules.list_active_rules_for(hll), & &1.id) == [rule.id]
      assert Rules.list_active_rules_for(hllv) == []
    end

    test "a pinned rule applies only to its own server" do
      first = server_fixture(%{game: :hll})
      second = server_fixture(%{game: :hll})

      rule = rule_fixture(%{game: :hll, server_id: first.id})

      assert Enum.map(Rules.list_active_rules_for(first), & &1.id) == [rule.id]
      assert Rules.list_active_rules_for(second) == []
    end

    test "disabled rules are left out of the engine's list" do
      server = server_fixture()
      rule = rule_fixture(%{enabled: false})

      refute rule.id in Enum.map(Rules.list_active_rules_for(server), & &1.id)
    end

    test "the server page's list keeps the disabled rules" do
      server = server_fixture()
      off = rule_fixture(%{enabled: false})
      on = rule_fixture(%{enabled: true})

      ids = Enum.map(Rules.list_rules_applying_to(server), & &1.id)

      assert off.id in ids
      assert on.id in ids
    end

    test "the engine's list is ordered by priority" do
      server = server_fixture()
      low = rule_fixture(%{priority: 1})
      high = rule_fixture(%{priority: 9})

      assert Enum.map(Rules.list_active_rules_for(server), & &1.id) == [high.id, low.id]
    end
  end

  describe "the escalation switch" do
    test "a window on its own turns the switch on" do
      changeset = Rules.change_rule(%Rule{}, %{"escalation_window_seconds" => "900"})

      assert Ecto.Changeset.get_field(changeset, :escalate)
      assert Ecto.Changeset.get_field(changeset, :escalation_window_seconds) == 900
    end

    test "switching escalation on without a window gives it an hour" do
      changeset = Rules.change_rule(%Rule{}, %{"escalate" => "true"})

      assert Ecto.Changeset.get_field(changeset, :escalation_window_seconds) == 3600
    end

    test "switching escalation off zeroes the window" do
      rule = rule_fixture(%{escalation_window_seconds: 3600})

      {:ok, updated} = Rules.update_rule(rule, %{"escalate" => "false"})

      assert updated.escalation_window_seconds == 0
    end

    test "a rule without escalation reports the switch as off" do
      changeset = Rules.change_rule(%Rule{}, %{})

      refute Ecto.Changeset.get_field(changeset, :escalate)
    end
  end

  describe "duplicate_rule/2" do
    test "copies the conditions and actions under a new name" do
      rule =
        rule_fixture(%{
          name: "Welcome",
          conditions: [%{field: :player_level, operator: :less_than, value: "10"}],
          actions: [%{type: :message_player, parameters: %{"message" => "Hi"}}]
        })

      assert {:ok, copy} = Rules.duplicate_rule(rule, "(copy)")

      assert copy.name == "Welcome (copy)"
      assert [%{field: :player_level, value: "10"}] = copy.conditions
      assert [%{type: :message_player}] = copy.actions
      assert copy.id != rule.id
    end
  end

  describe "prune_executions/1" do
    test "removes only rows older than the retention window" do
      server = server_fixture()
      rule = rule_fixture()

      {:ok, _recent} =
        Rules.record_execution(%{
          rule_id: rule.id,
          server_id: server.id,
          trigger_event: "player_connected",
          status: :executed
        })

      {:ok, _old} =
        Rules.record_execution(%{
          rule_id: rule.id,
          server_id: server.id,
          trigger_event: "player_connected",
          status: :executed,
          executed_at: DateTime.add(DateTime.utc_now(), -60 * 24 * 60 * 60, :second)
        })

      assert {1, nil} = Rules.prune_executions(30)
      assert length(Rules.list_executions()) == 1
    end
  end
end
