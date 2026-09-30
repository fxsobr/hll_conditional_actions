defmodule HllConditionalActionsWeb.RuleFidelityTest do
  @moduledoc """
  Details of the rule pages that follow the design boards: the versions tab
  reachable as `?tab=versions`, the JSON export read top to bottom, the
  one-word action names of tight rows, and the phone search of the list.
  """

  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Rules
  alias HllConditionalActionsWeb.RuleComponents
  alias HllConditionalActionsWeb.RuleLive.ShowTabs

  setup %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    server = server_fixture()
    rule = rule_fixture(%{name: "Ladder", server_id: server.id, enabled: true})

    %{conn: conn, server: server, rule: rule}
  end

  test "?tab=versions opens the versions tab", %{conn: conn, rule: rule} do
    {:ok, view, _html} = live(conn, ~p"/rules/#{rule}?tab=versions")

    assert has_element?(view, "#rule-versions")
  end

  test "the JSON export starts with the rule's name and keeps actions after conditions",
       %{rule: rule} do
    json = rule.id |> Rules.get_rule!() |> ShowTabs.export_json()

    assert json =~ ~r/\A\{\s*"name": "Ladder"/
    {conditions_at, _length} = :binary.match(json, ~s("conditions"))
    {actions_at, _length} = :binary.match(json, ~s("actions"))
    assert conditions_at < actions_at
    assert {:ok, %{"name" => "Ladder"}} = Jason.decode(json)
  end

  test "execution rows name the action in one word" do
    execution = %{
      trace: %{"step" => 2, "steps" => 4},
      results: [%{"type" => "punish_player", "status" => "simulated"}]
    }

    assert RuleComponents.summary(execution) == "Offence 2 of 4 · Punish"
    assert RuleComponents.short_action_label("kick_player") == "Kick"
    assert RuleComponents.short_action_label("not_an_action_type") == "not_an_action_type"
  end

  test "the phone has its own search field behind a button", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/rules")

    assert has_element?(view, "#rule-search-toggle")
    assert has_element?(view, "#rule-search-m input[name=search]")
  end
end
