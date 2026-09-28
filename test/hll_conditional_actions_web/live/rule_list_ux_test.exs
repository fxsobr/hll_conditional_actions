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

  defp record(rule, server, player_id, name, status \\ :executed) do
    {:ok, _execution} =
      Rules.record_execution(%{
        rule_id: rule.id,
        server_id: server.id,
        player_id: player_id,
        player_name: name,
        trigger_event: "player_connected",
        status: status
      })
  end

  test "each row reads the rule as a sentence and shows its activity", %{
    conn: conn,
    rule: rule,
    server: server
  } do
    record(rule, server, "1", "Fulano", :failed)

    {:ok, view, html} = live(conn, ~p"/rules")

    assert html =~ "When player connects, if always, then message the player."
    assert has_element?(view, "#rule-activity-#{rule.id}")
    assert render(view) =~ "100% failed"
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

  test "the rule page links to its full history", %{conn: conn, rule: rule, server: server} do
    record(rule, server, "1", "Fulano")

    {:ok, view, _html} = live(conn, ~p"/rules/#{rule}?tab=executions")

    assert has_element?(
             view,
             ~s(#rule-view-all-executions[href="/executions?rule_id=#{rule.id}"])
           )
  end
end
