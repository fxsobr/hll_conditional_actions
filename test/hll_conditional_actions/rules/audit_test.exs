defmodule HllConditionalActions.Rules.AuditTest do
  @moduledoc """
  A rule can ban people, so its history has to answer "who changed this" —
  including after the rule itself is gone.
  """

  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Audit

  setup do
    # Through the fixture, which creates the system roles first. Reading
    # `list_roles()` here instead would pass only on a database that some
    # earlier run had already seeded.
    %{actor: user_fixture(%{username: "sarge", name: "Sarge"})}
  end

  test "records who created a rule", %{actor: actor} do
    rule = rule_fixture(%{name: "Greeter"}, actor: actor)

    assert [version] = Audit.list_versions(rule.id)
    assert version.action == :created
    assert version.user_name == "Sarge"
    assert version.rule_name == "Greeter"
  end

  test "records only the fields that moved", %{actor: actor} do
    rule = rule_fixture(%{name: "Greeter", priority: 0}, actor: actor)

    {:ok, _updated} = Rules.update_rule(rule, %{priority: 5}, actor: actor)

    assert [%{action: :updated, changes: changes} | _created] = Audit.list_versions(rule.id)
    assert changes["priority"] == %{"from" => "0", "to" => "5"}
    refute Map.has_key?(changes, "name")
  end

  test "counts the actions that remain, not the ones Ecto replaced", %{actor: actor} do
    rule =
      rule_fixture(
        %{
          actions: [
            %{type: :message_player, parameters: %{"message" => "one"}},
            %{type: :punish_player, parameters: %{"reason" => "two"}}
          ]
        },
        actor: actor
      )

    # Rewriting the two actions makes Ecto keep the outgoing pair in the
    # change list, marked `:replace`. The history must still say "2".
    {:ok, _updated} =
      Rules.update_rule(
        rule,
        %{
          actions: [
            %{type: :message_player, parameters: %{"message" => "one, edited"}},
            %{type: :punish_player, parameters: %{"reason" => "two"}}
          ]
        },
        actor: actor
      )

    assert [%{action: :updated, changes: changes} | _] = Audit.list_versions(rule.id)
    assert changes["actions"] == %{"from" => "2", "to" => "2", "edited" => true}
  end

  test "an action really removed is counted as removed", %{actor: actor} do
    rule =
      rule_fixture(
        %{
          actions: [
            %{type: :message_player, parameters: %{"message" => "one"}},
            %{type: :punish_player, parameters: %{"reason" => "two"}}
          ]
        },
        actor: actor
      )

    {:ok, _updated} =
      Rules.update_rule(
        rule,
        %{actions: [%{type: :message_player, parameters: %{"message" => "one"}}]},
        actor: actor
      )

    assert [%{changes: changes} | _] = Audit.list_versions(rule.id)
    assert changes["actions"] == %{"from" => "2", "to" => "1"}
  end

  test "a save that changed nothing writes nothing", %{actor: actor} do
    rule = rule_fixture(%{name: "Greeter"}, actor: actor)

    {:ok, _same} = Rules.update_rule(rule, %{name: "Greeter"}, actor: actor)

    assert [%{action: :created}] = Audit.list_versions(rule.id)
  end

  test "toggling is recorded as enabling or disabling", %{actor: actor} do
    rule = rule_fixture(%{enabled: true}, actor: actor)

    {:ok, disabled} = Rules.toggle_rule(rule, actor: actor)
    {:ok, _enabled} = Rules.toggle_rule(disabled, actor: actor)

    actions = rule.id |> Audit.list_versions() |> Enum.map(& &1.action)

    assert :enabled in actions
    assert :disabled in actions
  end

  test "a deleted rule keeps a readable history", %{actor: actor} do
    rule = rule_fixture(%{name: "Doomed"}, actor: actor)

    {:ok, _deleted} = Rules.delete_rule(rule, actor: actor)

    # The rule row is gone, so the entry carries no rule_id — but the name
    # and the actor survive, which is the whole point.
    assert [entry] =
             Repo.all(HllConditionalActions.Rules.Version)
             |> Enum.filter(&(&1.action == :deleted))

    assert entry.rule_name == "Doomed"
    assert entry.user_name == "Sarge"
    assert is_nil(entry.rule_id)
  end
end
