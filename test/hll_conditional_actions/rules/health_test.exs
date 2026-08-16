defmodule HllConditionalActions.Rules.HealthTest do
  @moduledoc """
  A rule that cannot work fails quietly. These checks are what turn that
  silence into something the list can show, so they have to be right about
  both the alarm and the calm.
  """

  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Health

  defp ids(issues), do: Enum.map(issues, & &1.id)

  defp aged(rule, days) do
    # Ecto will not let `inserted_at` be cast, so the age is set directly.
    at = DateTime.add(DateTime.utc_now(), -days * 24 * 60 * 60, :second)

    Repo.update_all(
      from(r in Rules.Rule, where: r.id == ^rule.id),
      set: [inserted_at: DateTime.truncate(at, :second)]
    )

    Rules.get_rule!(rule.id)
  end

  describe "a rule nobody should worry about" do
    test "a fresh rule that has not fired yet is fine" do
      rule = rule_fixture()

      assert Health.for_rule(rule, []) == []
    end

    test "a disabled rule is never flagged" do
      rule = rule_fixture(%{enabled: false}) |> aged(90)

      assert Health.for_rule(rule, []) == []
    end
  end

  describe "never fired" do
    test "is flagged once the grace period has passed" do
      rule = rule_fixture() |> aged(30)

      assert :never_fired in ids(Health.for_rule(rule, []))
    end
  end

  describe "missing permission" do
    test "warns when the server key cannot do what the rule asks" do
      server =
        server_fixture(%{
          known_permissions: ["can_view_structured_logs", "can_message_players"]
        })

      rule =
        rule_fixture(%{
          server_id: server.id,
          actions: [%{type: :kick_player, parameters: %{"reason" => "bye"}}]
        })

      assert :missing_permission in ids(Health.for_rule(rule, [server]))
    end

    test "stays quiet when the key holds the permission" do
      server =
        server_fixture(%{
          known_permissions: ["can_view_structured_logs", "can_kick_players"]
        })

      rule =
        rule_fixture(%{
          server_id: server.id,
          actions: [%{type: :kick_player, parameters: %{"reason" => "bye"}}]
        })

      refute :missing_permission in ids(Health.for_rule(rule, [server]))
    end

    test "an unchecked key is unknown, not broken" do
      server = server_fixture(%{known_permissions: []})

      rule =
        rule_fixture(%{
          server_id: server.id,
          actions: [%{type: :kick_player, parameters: %{"reason" => "bye"}}]
        })

      refute :missing_permission in ids(Health.for_rule(rule, [server]))
    end

    test "a fleet-wide rule is judged against every server of its game" do
      server = server_fixture(%{game: :hll, known_permissions: ["can_view_structured_logs"]})

      rule =
        rule_fixture(%{
          server_id: nil,
          game: :hll,
          actions: [%{type: :kick_player, parameters: %{"reason" => "bye"}}]
        })

      assert :missing_permission in ids(Health.for_rule(rule, [server]))
    end
  end

  describe "for_rules/2" do
    test "answers for a whole page in one pass" do
      first = rule_fixture() |> aged(30)
      second = rule_fixture()

      health = Health.for_rules([first, second], [])

      assert :never_fired in ids(health[first.id])
      assert health[second.id] == []
    end

    test "handles an empty list" do
      assert Health.for_rules([], []) == %{}
    end
  end
end
