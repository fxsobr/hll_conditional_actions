defmodule HllConditionalActions.ServerScopeTest do
  @moduledoc """
  Per-server access: a user with no assignment reaches everything, a user with
  one is confined to it.
  """

  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Servers

  setup do
    mine = server_fixture(%{name: "Mine", game: :hll})
    theirs = server_fixture(%{name: "Theirs", game: :hll})

    %{mine: mine, theirs: theirs}
  end

  describe "an unassigned user" do
    test "reaches every server", %{mine: mine, theirs: theirs} do
      user = user_fixture()

      refute Accounts.restricted?(user)
      assert Accounts.server_scope(user) == :all
      assert Accounts.can_access_server?(user, mine)
      assert Accounts.can_access_server?(user, theirs)
      assert length(Servers.list_servers_for(user)) == 2
    end
  end

  describe "an assigned user" do
    setup %{mine: mine} do
      {:ok, user} = Accounts.set_user_servers(user_fixture(), [mine.id])
      %{user: user}
    end

    test "is restricted to it", %{user: user, mine: mine, theirs: theirs} do
      assert Accounts.restricted?(user)
      assert Accounts.can_access_server?(user, mine)
      refute Accounts.can_access_server?(user, theirs)
    end

    test "sees only their own server", %{user: user, mine: mine} do
      assert Enum.map(Servers.list_servers_for(user), & &1.id) == [mine.id]
    end

    test "sees rules pinned to their server", %{user: user, mine: mine, theirs: theirs} do
      ours = rule_fixture(%{name: "Ours", server_id: mine.id})
      _other = rule_fixture(%{name: "Theirs", server_id: theirs.id})

      assert Enum.map(Rules.list_rules_for(user), & &1.id) == [ours.id]
    end

    test "also sees fleet-wide rules that reach their server", %{user: user, mine: mine} do
      fleet = rule_fixture(%{name: "Fleet", game: mine.game, server_id: nil})

      assert fleet.id in Enum.map(Rules.list_rules_for(user), & &1.id)
    end

    test "does not see fleet-wide rules for a game they do not run", %{user: user} do
      other_game = rule_fixture(%{name: "Vietnam fleet", game: :hllv, server_id: nil})

      refute other_game.id in Enum.map(Rules.list_rules_for(user), & &1.id)
    end

    test "may edit their own rules but not fleet-wide ones", %{user: user, mine: mine} do
      ours = rule_fixture(%{server_id: mine.id})
      fleet = rule_fixture(%{game: mine.game, server_id: nil})

      assert Rules.editable_by?(ours, user)
      refute Rules.editable_by?(fleet, user)
    end

    test "sees only their own server's history", %{user: user, mine: mine, theirs: theirs} do
      rule = rule_fixture()

      for server <- [mine, theirs] do
        {:ok, _execution} =
          Rules.record_execution(%{
            rule_id: rule.id,
            server_id: server.id,
            trigger_event: "player_connected",
            status: :executed
          })
      end

      assert Rules.list_executions_for(user) |> Enum.map(& &1.server_id) == [mine.id]
      assert length(Rules.list_executions_for(user_fixture())) == 2
    end

    test "clearing the assignment lifts the restriction", %{user: user} do
      {:ok, user} = Accounts.set_user_servers(user, [])

      refute Accounts.restricted?(user)
      assert Accounts.server_scope(user) == :all
      assert length(Servers.list_servers_for(user)) == 2
    end
  end

  test "an unrestricted user may edit anything" do
    user = user_fixture()

    assert Rules.editable_by?(rule_fixture(%{server_id: nil}), user)
  end
end
