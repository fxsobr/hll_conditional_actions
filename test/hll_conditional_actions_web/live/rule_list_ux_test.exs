defmodule HllConditionalActionsWeb.RuleListUxTest do
  @moduledoc """
  The rules list reads a rule as a sentence, says how it is doing, and can
  pause it; the history can be filtered from a link.
  """

  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Rules

  setup %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    server = server_fixture()
    rule = rule_fixture(%{name: "Greeter", server_id: server.id})

    %{conn: conn, server: server, rule: rule}
  end

  defp record(rule, server, player_id, name, status \\ :executed, ago \\ 0) do
    {:ok, _execution} =
      Rules.record_execution(%{
        rule_id: rule.id,
        server_id: server.id,
        player_id: player_id,
        player_name: name,
        trigger_event: "player_connected",
        status: status,
        executed_at: DateTime.add(DateTime.utc_now(), -ago, :second)
      })
  end

  test "each row reads the rule as a sentence and shows its activity", %{
    conn: conn,
    rule: rule,
    server: server
  } do
    record(rule, server, "1", "Fulano", :failed)

    {:ok, view, html} = live(conn, ~p"/rules")

    assert html =~ "When player connects · message the player"
    assert has_element?(view, "#rule-activity-#{rule.id}")
    # A failure in the last day marks the row and says what went wrong.
    assert render(view) =~ "Failed once"
    assert has_element?(view, "#rule-attention-failing-#{rule.id}")
  end

  test "pausing from the list and resuming", %{conn: conn, rule: rule} do
    {:ok, view, _html} = live(conn, ~p"/rules")

    render_click(view, "pause", %{"id" => to_string(rule.id), "preset" => "30m"})

    assert has_element?(view, "#rule-paused-#{rule.id}")
    assert Rules.get_rule!(rule.id).paused_until

    render_click(view, "pause", %{"id" => to_string(rule.id), "preset" => "resume"})

    refute has_element?(view, "#rule-paused-#{rule.id}")
    refute Rules.get_rule!(rule.id).paused_until
  end

  test "the history filters come from the URL", %{conn: conn, rule: rule, server: server} do
    other = rule_fixture(%{name: "Other", server_id: server.id})
    record(rule, server, "1", "Fulano")
    record(other, server, "2", "Beltrano")

    {:ok, _view, html} = live(conn, ~p"/executions?#{[rule_id: rule.id]}")
    assert html =~ "Fulano"
    refute html =~ "Beltrano"

    {:ok, _view, html} = live(conn, ~p"/executions?#{[player: "beltr"]}")
    assert html =~ "Beltrano"
    refute html =~ "Fulano"
  end

  test "rows are grouped by folder and carry a week of runs", %{
    conn: conn,
    rule: rule,
    server: server
  } do
    seeder = rule_fixture(%{name: "Seeder", group: "Seeding", server_id: server.id})
    record(rule, server, "1", "Fulano")
    record(rule, server, "2", "Beltrano")

    {:ok, view, _html} = live(conn, ~p"/rules")

    assert has_element?(view, "#rule-list details #rule-#{seeder.id}")
    assert has_element?(view, "#rule-list details summary", "Seeding")

    assert has_element?(
             view,
             ~s(#rule-#{rule.id} [role=img][aria-label="2 runs in the last 7 days"])
           )
  end

  test "the state pills filter the list", %{conn: conn, rule: rule, server: server} do
    simulating = rule_fixture(%{name: "Watcher", simulation: true, server_id: server.id})

    {:ok, view, _html} = live(conn, ~p"/rules")

    view |> element("#rule-filters") |> render_change(%{"state" => "simulating"})

    assert has_element?(view, "#rule-#{simulating.id}")
    refute has_element?(view, "#rule-#{rule.id}")
  end

  describe "the rule page" do
    test "a clean simulation reads as ready and can go live", %{conn: conn, server: server} do
      rule = rule_fixture(%{name: "Watcher", simulation: true, server_id: server.id})
      # Ready means at least three days of clean simulated runs.
      record(rule, server, "1", "Fulano", :simulated, 4 * 86_400)

      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}")

      assert has_element?(view, "#rule-readiness", "Ready to act for real")
      assert has_element?(view, "#rule-checklist")

      view |> element("#rule-go-live") |> render_click()

      refute Rules.get_rule!(rule.id).simulation
      refute has_element?(view, "#rule-readiness")
    end

    test "a simulation that failed is not ready", %{conn: conn, server: server} do
      rule = rule_fixture(%{name: "Watcher", simulation: true, server_id: server.id})
      record(rule, server, "1", "Fulano", :simulated, 4 * 86_400)
      record(rule, server, "2", "Beltrano", :failed)

      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}")

      assert has_element?(view, "#rule-readiness", "Still simulating")
      refute has_element?(view, "#rule-go-live")
    end

    test "the ladder counts the runs of each step", %{conn: conn, server: server} do
      rule =
        rule_fixture(%{
          name: "Ladder",
          server_id: server.id,
          escalation_window_seconds: 3600,
          actions: [
            %{type: :message_player, parameters: %{"message" => "Careful"}},
            %{type: :kick_player, parameters: %{"reason" => "TK"}}
          ]
        })

      for {step, player} <- [{1, "1"}, {1, "2"}, {2, "1"}, {5, "3"}] do
        {:ok, _execution} =
          Rules.record_execution(%{
            rule_id: rule.id,
            server_id: server.id,
            player_id: player,
            trigger_event: "player_connected",
            status: :executed,
            trace: %{"step" => step, "steps" => 2}
          })
      end

      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}")

      # Past the end of the ladder the last step repeats, so step 5 counts
      # towards step 2.
      assert has_element?(view, "#rule-ladder-step-1", "2")
      assert has_element?(view, "#rule-ladder-step-2", "2")
    end

    test "an execution opens into its trace", %{conn: conn, rule: rule, server: server} do
      record(rule, server, "1", "Fulano")
      [execution] = Rules.list_executions(rule_id: rule.id)

      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}?tab=executions")

      view |> element("#rule-execution-#{execution.id}-toggle") |> render_click()

      assert has_element?(view, "#rule-execution-#{execution.id}-trace")
    end

    test "versions compare a change with the one before", %{conn: conn} do
      user = user_fixture()
      rule = rule_fixture(%{name: "First"}, actor: user)
      {:ok, _rule} = Rules.publish(rule, %{"name" => "Second"}, actor: user)

      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}?tab=changes")

      assert has_element?(view, "#version-diff", "First")
      assert has_element?(view, "#version-diff", "Second")
    end
  end

  test "the rule page links to its full history", %{conn: conn, rule: rule, server: server} do
    record(rule, server, "1", "Fulano")

    {:ok, view, _html} = live(conn, ~p"/rules/#{rule}?tab=executions")

    assert has_element?(
             view,
             ~s(#rule-view-all-executions[href="/executions?rule_id=#{rule.id}"])
           )
  end
end
