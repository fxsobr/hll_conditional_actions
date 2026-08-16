defmodule HllConditionalActions.Rules.CoordinationTest do
  @moduledoc """
  The three things that only make sense across rules rather than inside one:
  which rules answer the same event, which belong to the same group, and what
  the app has been doing to a given player.
  """

  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Rules

  defp names(rules), do: rules |> Enum.map(& &1.name) |> Enum.sort()

  describe "overlapping_rules/1" do
    test "finds another rule waiting on the same event" do
      server = server_fixture()
      rule = rule_fixture(%{name: "Greeter", server_id: server.id})
      _other = rule_fixture(%{name: "Logger", server_id: server.id})

      assert names(Rules.overlapping_rules(rule)) == ["Logger"]
    end

    test "never reports the rule against itself" do
      rule = rule_fixture(%{name: "Greeter"})

      refute "Greeter" in names(Rules.overlapping_rules(rule))
    end

    test "ignores rules on a different event" do
      server = server_fixture()
      rule = rule_fixture(%{server_id: server.id, trigger_event: :player_connected})
      _other = rule_fixture(%{server_id: server.id, trigger_event: :player_disconnected})

      assert Rules.overlapping_rules(rule) == []
    end

    test "ignores disabled rules, which cannot collide with anything" do
      server = server_fixture()
      rule = rule_fixture(%{server_id: server.id})
      _off = rule_fixture(%{server_id: server.id, enabled: false})

      assert Rules.overlapping_rules(rule) == []
    end

    test "a rule pinned to one server does not collide with another server's" do
      first = server_fixture()
      second = server_fixture()

      rule = rule_fixture(%{server_id: first.id})
      _elsewhere = rule_fixture(%{server_id: second.id})

      assert Rules.overlapping_rules(rule) == []
    end

    test "a fleet-wide rule reaches every server, so it collides with all of them" do
      server = server_fixture()
      _pinned = rule_fixture(%{name: "Pinned", server_id: server.id})
      fleet = rule_fixture(%{name: "Fleet", server_id: nil})

      assert names(Rules.overlapping_rules(fleet)) == ["Pinned"]
    end

    test "and a pinned rule sees the fleet-wide one above it" do
      server = server_fixture()
      _fleet = rule_fixture(%{name: "Fleet", server_id: nil})
      pinned = rule_fixture(%{name: "Pinned", server_id: server.id})

      assert names(Rules.overlapping_rules(pinned)) == ["Fleet"]
    end

    test "a rule with no trigger yet asks nothing of the database" do
      assert Rules.overlapping_rules(%Rules.Rule{trigger_event: nil}) == []
    end
  end

  describe "groups" do
    test "list_groups/1 returns each name once, sorted, ignoring the ungrouped" do
      rule_fixture(%{group: "Seeding"})
      rule_fixture(%{group: "Seeding"})
      rule_fixture(%{group: "Anti-cheat"})
      rule_fixture(%{group: nil})
      rule_fixture(%{group: ""})

      assert Rules.list_groups() == ["Anti-cheat", "Seeding"]
    end

    test "set_group_enabled/3 moves the whole group and counts what moved" do
      a = rule_fixture(%{group: "Seeding", enabled: true})
      b = rule_fixture(%{group: "Seeding", enabled: true})
      other = rule_fixture(%{group: "Anti-cheat", enabled: true})

      assert Rules.set_group_enabled("Seeding", false) == 2

      refute Rules.get_rule!(a.id).enabled
      refute Rules.get_rule!(b.id).enabled
      assert Rules.get_rule!(other.id).enabled
    end

    test "rules already in the wanted state are not touched, and not counted" do
      rule_fixture(%{group: "Seeding", enabled: false})
      rule_fixture(%{group: "Seeding", enabled: true})

      assert Rules.set_group_enabled("Seeding", false) == 1
      assert Rules.set_group_enabled("Seeding", false) == 0
    end
  end

  describe "the player view" do
    setup do
      server = server_fixture()
      rule = rule_fixture(%{name: "Greeter", server_id: server.id})

      record = fn player_id, name, ago ->
        {:ok, execution} =
          Rules.record_execution(%{
            rule_id: rule.id,
            server_id: server.id,
            player_id: player_id,
            player_name: name,
            trigger_event: "player_connected",
            status: :executed,
            executed_at: DateTime.add(DateTime.utc_now(), -ago, :second)
          })

        execution
      end

      %{server: server, rule: rule, record: record}
    end

    test "search_players/3 finds somebody by part of their name", %{record: record} do
      record.("7656119", "Kapitan Blyat", 60)
      record.("7656120", "Someone Else", 60)

      assert [%{player_name: "Kapitan Blyat"}] = Rules.search_players(nil, "blya")
    end

    test "search_players/3 also takes the player id verbatim", %{record: record} do
      record.("7656119", "Kapitan Blyat", 60)

      assert [%{player_id: "7656119"}] = Rules.search_players(nil, "7656119")
    end

    test "a player is listed once, with their most recent sighting", %{record: record} do
      record.("7656119", "Kapitan", 3600)
      record.("7656119", "Kapitan", 60)

      assert [%{last_seen: last_seen}] = Rules.search_players(nil, "kapitan")
      assert DateTime.diff(DateTime.utc_now(), last_seen) < 120
    end

    test "the wildcards in a search term are stripped, not honoured", %{record: record} do
      record.("7656119", "Kapitan", 60)

      assert Rules.search_players(nil, "%") == []
    end

    test "rules_for_player/2 counts hits per rule, busiest first", %{
      record: record,
      server: server
    } do
      quiet = rule_fixture(%{name: "Quiet", server_id: server.id})

      record.("7656119", "Kapitan", 60)
      record.("7656119", "Kapitan", 30)

      {:ok, _} =
        Rules.record_execution(%{
          rule_id: quiet.id,
          server_id: server.id,
          player_id: "7656119",
          player_name: "Kapitan",
          trigger_event: "player_connected",
          status: :executed
        })

      assert [%{rule_name: "Greeter", count: 2}, %{rule_name: "Quiet", count: 1}] =
               Rules.rules_for_player("7656119")
    end

    test "somebody the app never touched has an empty history" do
      assert Rules.rules_for_player("0000000") == []
    end
  end
end
