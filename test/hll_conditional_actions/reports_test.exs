defmodule HllConditionalActions.ReportsTest do
  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Onboarding
  alias HllConditionalActions.Reports
  alias HllConditionalActions.Rules

  doctest HllConditionalActions.Reports

  defp record(rule, server, status, days_ago, player_id \\ "p1", duration \\ 100) do
    {:ok, execution} =
      Rules.record_execution(%{
        rule_id: rule.id,
        server_id: server.id,
        player_id: player_id,
        trigger_event: "player_kill",
        status: status,
        trace: %{"duration_ms" => duration},
        executed_at: DateTime.add(DateTime.utc_now(), -days_ago, :day)
      })

    execution
  end

  describe "overview/2" do
    setup do
      server = server_fixture()
      rule = rule_fixture(%{name: "Kills", server_id: server.id, trigger_event: :player_kill})
      %{server: server, rule: rule}
    end

    test "counts this period against the one before", %{server: server, rule: rule} do
      record(rule, server, :executed, 1, "a", 100)
      record(rule, server, :failed, 2, "b", 300)
      record(rule, server, :simulated, 3, "a")
      # The previous 7 days.
      record(rule, server, :executed, 10)

      report = Reports.overview(nil, 7)

      assert %{
               fired: 3,
               live: 2,
               failed: 1,
               simulated: 1,
               success_rate: 50,
               players: 2
             } = report.totals

      assert report.previous.fired == 1
      assert length(report.daily) == 8
      assert Enum.sum(Enum.map(report.daily, & &1.fired)) == 3
      assert [{"player_kill", 3}] = report.by_trigger
      assert [%{name: "Kills", fired: 3, failed: 1, simulated: 1}] = report.rules
    end

    test "only counts the servers the user may see", %{server: server, rule: rule} do
      record(rule, server, :executed, 1)

      {:ok, restricted} = Accounts.set_user_servers(user_fixture(), [server_fixture().id])

      assert Reports.overview(restricted, 7).totals.fired == 0
      assert Reports.overview(nil, 7).totals.fired == 1
    end
  end

  describe "onboarding" do
    defp state_of(steps, id), do: Enum.find(steps, &(&1.id == id)).state

    test "a fresh install can only connect a server; the rest is locked" do
      user = user_fixture()
      steps = Onboarding.steps(user, [], %{})

      assert Onboarding.show?(user, steps)
      assert %{id: :server} = Onboarding.focus(steps)
      assert state_of(steps, :server) == :current
      assert state_of(steps, :stream) == :locked
      assert state_of(steps, :rule) == :locked
      assert state_of(steps, :simulation) == :locked
      assert state_of(steps, :live) == :locked
      # Never held back by anything.
      assert state_of(steps, :two_factor) == :available
    end

    test "with a server, rules unlock while the stream connects" do
      user = user_fixture()
      server = server_fixture()

      steps = Onboarding.steps(user, [server], %{server.id => :connecting})

      assert state_of(steps, :server) == :done
      assert state_of(steps, :stream) == :waiting
      assert state_of(steps, :rule) == :available
      assert state_of(steps, :simulation) == :locked
    end

    test "a server without modules asks for the marketplace before any rule" do
      user = user_fixture()
      server = server_fixture(%{features: []})

      steps = Onboarding.steps(user, [server], %{server.id => :connected})

      assert %{id: :modules, state: :current} = Onboarding.focus(steps)
      assert state_of(steps, :rule) == :locked

      :ok = HllConditionalActions.Features.install(server.id, :tickets)
      steps = Onboarding.steps(user, [server], %{server.id => :connected})

      assert state_of(steps, :modules) == :done
      assert %{id: :rule, context: %{rules_installed?: false}} = Onboarding.focus(steps)
    end

    test "a stream in error is flagged with what CRCON said" do
      user = user_fixture()
      server = server_fixture()

      steps = Onboarding.steps(user, [server], %{server.id => {:error, "502 Bad Gateway"}})

      assert %{id: :stream, state: :blocked, context: %{error: "502 Bad Gateway"}} =
               Onboarding.focus(steps)
    end

    test "a simulated rule waits for its first result, then going live unlocks" do
      user = user_fixture()
      server = server_fixture()
      rule = rule_fixture(%{server_id: server.id, simulation: true})
      streaming = %{server.id => :connected}

      steps = Onboarding.steps(user, [server], streaming)
      assert state_of(steps, :rule) == :done
      assert state_of(steps, :simulation) == :waiting
      assert state_of(steps, :live) == :locked

      record(rule, server, :simulated, 0)

      steps = Onboarding.steps(user, [server], streaming)
      assert state_of(steps, :simulation) == :done
      assert %{id: :live, state: :current, context: %{rule: %{id: id}}} = Onboarding.focus(steps)
      assert id == rule.id
    end
  end
end
