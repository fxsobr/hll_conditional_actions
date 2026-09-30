defmodule HllConditionalActionsWeb.RuleBenchTest do
  @moduledoc """
  The builder as a test bench: the sentence, groups, the state switch, the
  run strip and its overlay, the 7-day replay, the action drawer and the
  expression view.
  """

  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Samples
  alias HllConditionalActions.Rules

  setup %{conn: conn} do
    user = user_fixture()
    conn = conn |> init_test_session(%{}) |> Plug.Conn.put_session(:user_id, user.id)
    %{conn: conn, user: user, server: server_fixture()}
  end

  defp record(server, trigger, id, attrs) do
    server
    |> Context.build(trigger, player_id: id, player: player(Map.put(attrs, "player_id", id)))
    |> Samples.record()
  end

  test "a new rule reads as a sentence and starts in simulation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/rules/new")

    for id <- ~w(bench-when bench-if bench-then bench-guards bench-details bench-recipes) do
      assert has_element?(view, "##{id}")
    end

    assert has_element?(view, ~s|#bench-state-simulating[aria-checked="true"]|)
    assert has_element?(view, ~s|#bench-state-live[aria-disabled="true"]|)

    # Live stays locked until the rule has simulated.
    render_click(view, "set_state", %{"state" => "live"})
    assert has_element?(view, ~s|#bench-state-simulating[aria-checked="true"]|)

    view |> element("#bench-state-off") |> render_click()
    assert has_element?(view, ~s|#bench-state-off[aria-checked="true"]|)
  end

  test "a second group combines with the first and is saved", %{conn: conn, server: server} do
    {:ok, view, _html} = live(conn, ~p"/rules/new?server_id=#{server.id}")

    view |> element("#bench-add-condition") |> render_click()
    view |> element("#bench-add-group") |> render_click()

    assert has_element?(view, "#bench-group-0")
    assert has_element?(view, "#bench-group-1")

    # The fields first, so their comparisons are on offer.
    view
    |> form("#rule-form",
      rule: %{conditions: %{"0" => %{field: "player_level"}, "1" => %{field: "kills"}}}
    )
    |> render_change()

    view
    |> form("#rule-form",
      rule: %{
        name: "Grouped",
        conditions: %{
          "0" => %{field: "player_level", operator: "less_than", value: "10"},
          "1" => %{field: "kills", operator: "greater_than", value: "20"}
        },
        actions: %{"0" => %{type: "message_player", parameters: %{message: "Hi"}}}
      }
    )
    |> render_submit()

    [rule] = Rules.list_rules()
    assert rule.logical_operator == :or

    assert [%{group: 0, group_operator: :and}, %{group: 1, group_operator: :and}] =
             rule.conditions
  end

  test "removing the last condition of a group makes the rule flat again", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/rules/new")

    view |> element("#bench-add-condition") |> render_click()
    view |> element("#bench-add-group") |> render_click()
    assert has_element?(view, ~s|#rule_logical_operator option[value="or"][selected]|)

    render_click(view, "remove_condition", %{"index" => "1"})

    refute has_element?(view, "#bench-group-1")
    assert has_element?(view, ~s|#rule_logical_operator option[value="and"][selected]|)
  end

  test "the replay judges the draft over last week's events", %{conn: conn, server: server} do
    for {id, kills} <- [{"a", 2}, {"b", 12}, {"c", 40}] do
      record(server, :player_connected, id, %{"kills" => kills})
    end

    {:ok, view, _html} = live(conn, ~p"/rules/new?server_id=#{server.id}")

    view
    |> form("#rule-form", rule: %{conditions: %{"0" => %{field: "kills"}}})
    |> render_change()

    view
    |> form("#rule-form",
      rule: %{conditions: %{"0" => %{field: "kills", operator: "greater_than", value: "10"}}}
    )
    |> render_change()

    assert has_element?(view, "#rule-replay-fires", "2×")

    view |> element("#rule-replay-toggle") |> render_click()
    assert has_element?(view, "#rule-replay-events")
  end

  test "the run strip overlays a past event on the rule", %{conn: conn, server: server} do
    rule =
      rule_fixture(%{
        server_id: server.id,
        simulation: true,
        conditions: [%{field: :player_level, operator: :greater_than, value: "10"}]
      })

    record(server, :player_connected, "low", %{"level" => 5, "name" => "Low"})
    record(server, :player_connected, "high", %{"level" => 50, "name" => "High"})

    {:ok, _execution} =
      Rules.record_execution(%{
        rule_id: rule.id,
        server_id: server.id,
        player_id: "high",
        player_name: "High",
        trigger_event: "player_connected",
        status: :simulated
      })

    {:ok, view, _html} = live(conn, ~p"/rules/#{rule}/edit")

    assert has_element?(view, "#bench-runs")
    assert has_element?(view, ~s|#bench-run-1[data-outcome="simulated"][aria-pressed="true"]|)
    assert has_element?(view, "#bench-overlay", "High")
    assert has_element?(view, ~s|#bench-condition-0[data-trace="ok"]|)

    view |> element("#bench-run-0") |> render_click()
    assert has_element?(view, ~s|#bench-condition-0[data-trace="fail"]|)

    view |> element("#bench-rerun") |> render_click()
    assert has_element?(view, "#bench-rerun-result")

    view |> element("#bench-overlay-close") |> render_click()
    refute has_element?(view, "#bench-overlay")
  end

  test "a step opens the action drawer, and cancel puts it back", %{conn: conn} do
    rule = rule_fixture(%{enabled: false})
    {:ok, view, _html} = live(conn, ~p"/rules/#{rule}/edit")

    assert has_element?(view, "#bench-drawer.hidden")
    view |> element("#bench-step-0") |> render_click()
    refute has_element?(view, "#bench-drawer.hidden")

    view
    |> form("#rule-form",
      rule: %{actions: %{"0" => %{type: "message_player", parameters: %{message: "Changed"}}}}
    )
    |> render_change()

    view |> element("#bench-action-cancel") |> render_click()
    assert has_element?(view, "#bench-drawer.hidden")
    assert render(view) =~ "Welcome!"
  end

  test "the expression view applies JSON back to the sentence", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/rules/new")

    view |> element("#bench-open-expression") |> render_click()
    assert has_element?(view, "#bench-expression-text")

    render_change(view, "validate", %{"rule" => %{}, "expression" => "{nope"})
    view |> element("#bench-expression-apply") |> render_click()
    assert has_element?(view, "#bench-expression-error")

    json =
      Jason.encode!(%{
        "name" => "From text",
        "trigger_event" => "player_kill",
        "conditions" => [%{"field" => "kills", "operator" => "greater_than", "value" => "5"}],
        "actions" => [%{"type" => "message_player", "parameters" => %{"message" => "Nice"}}]
      })

    render_change(view, "validate", %{"rule" => %{}, "expression" => json})
    view |> element("#bench-expression-apply") |> render_click()

    refute has_element?(view, "#bench-expression-text")
    assert has_element?(view, ~s|#rule_trigger_event option[value="player_kill"][selected]|)
    assert has_element?(view, ~s|#rule_name[value="From text"]|)
  end

  describe "the recipe wizard" do
    test "creates one rule per chosen server, in simulation", %{conn: conn, server: server} do
      # Servers are listed by name; this one must come after the setup's.
      other = server_fixture(%{name: "zz #{server.name}"})
      {:ok, view, _html} = live(conn, ~p"/rules/new?recipe=seeding_reward")

      # The first server is picked for the admin; the others are a choice.
      assert has_element?(
               view,
               ~s|#recipe-wizard-form input[name="servers[]"][value="#{server.id}"][checked]|
             )

      refute has_element?(
               view,
               ~s|#recipe-wizard-form input[name="servers[]"][value="#{other.id}"][checked]|
             )

      view
      |> form("#recipe-wizard-form", %{servers: ["#{server.id}", "#{other.id}"]})
      |> render_submit()

      rules = Rules.list_rules()
      assert length(rules) == 2
      assert Enum.all?(rules, & &1.simulation)
      assert rules |> Enum.map(& &1.server_id) |> Enum.sort() == Enum.sort([server.id, other.id])
    end

    test "asks for a server when none is chosen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rules/new?recipe=seeding_reward")

      view |> form("#recipe-wizard-form", %{servers: [""]}) |> render_submit()

      assert Rules.list_rules() == []
      assert render(view) =~ "Pick at least one server."
    end
  end
end
