defmodule HllConditionalActionsWeb.RuleBuilderUxTest do
  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Rules

  setup %{conn: conn} do
    user = user_fixture()
    server_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn}
  end

  test "the field picker is a searchable combobox with descriptions", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/rules/new")

    assert has_element?(view, "#rule_conditions_0_field-search[role=combobox]")
    assert has_element?(view, "#rule_conditions_0_field-listbox [data-group=popular]")

    assert has_element?(
             view,
             "#rule_conditions_0_field-listbox [role=option][data-value=player_level]",
             "account level"
           )
  end

  test "yes/no fields get a yes/no pick, lists get chips", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/rules/new")

    view
    |> form("#rule-form", rule: %{conditions: %{"0" => %{field: "is_vip"}}})
    |> render_change()

    assert has_element?(view, "select#rule_conditions_0_value option[value=true]")
    assert has_element?(view, "select#rule_conditions_0_value option[value=false]")

    view
    |> form("#rule-form", rule: %{conditions: %{"0" => %{field: "player_name"}}})
    |> render_change()

    view
    |> form("#rule-form",
      rule: %{conditions: %{"0" => %{field: "player_name", operator: "in_list"}}}
    )
    |> render_change()

    assert has_element?(view, "#rule_conditions_0_value-chips")
    assert has_element?(view, "#rule_conditions_0_value-entry[list=known-player-names]")
  end

  test "the regex tester says whether the sample matches", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/rules/new")

    view
    |> form("#rule-form", rule: %{conditions: %{"0" => %{field: "player_name"}}})
    |> render_change()

    view
    |> form("#rule-form",
      rule: %{conditions: %{"0" => %{field: "player_name", operator: "regex_match"}}}
    )
    |> render_change()

    view
    |> form("#rule-form",
      rule: %{
        conditions: %{
          "0" => %{
            field: "player_name",
            operator: "regex_match",
            value: "^ABC",
            sample: "ABC Ana"
          }
        }
      }
    )
    |> render_change()

    assert has_element?(view, "#rule_conditions_0_sample-verdict[data-match]")

    view
    |> form("#rule-form",
      rule: %{
        conditions: %{
          "0" => %{field: "player_name", operator: "regex_match", value: "(", sample: "x"}
        }
      }
    )
    |> render_change()

    refute has_element?(view, "#rule_conditions_0_sample-verdict[data-match]")
    assert render(view) =~ "This pattern is not valid"
  end

  test "limits read as a sentence and exemptions are saved", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/rules/new")

    view
    |> form("#rule-form", rule: %{cooldown_enabled: "true", cap_enabled: "true"})
    |> render_change()

    view
    |> form("#rule-form",
      rule: %{
        name: "Kick loud people",
        cooldown_enabled: "true",
        cooldown_value: "2",
        cooldown_unit: "min",
        cap_enabled: "true",
        max_executions_per_player: "3",
        actions: %{"0" => %{type: "message_player", parameters: %{message: "Hi {player_name}"}}}
      }
    )
    # The chips edit a hidden input from the browser; post what they would.
    |> render_change(%{rule: %{exemptions: %{exempt_vip: "true", exempt_flags: "staff"}}})

    assert has_element?(
             view,
             "#rule-limits-sentence",
             "at most 3× per day, at least 2 min apart"
           )

    view |> form("#rule-form") |> render_submit()

    [rule] = Rules.list_rules()
    assert rule.cooldown_seconds == 120
    assert rule.max_executions_per_player == 3
    assert rule.exemptions.exempt_vip
    assert rule.exemptions.exempt_flags == ["staff"]
  end

  test "an unknown placeholder is flagged", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/rules/new")

    html =
      view
      |> form("#rule-form",
        rule: %{
          actions: %{"0" => %{type: "message_player", parameters: %{message: "Hi {nope}"}}}
        }
      )
      |> render_change()

    assert html =~ "{nope}"
    assert has_element?(view, "#rule-placeholders[phx-hook]")
  end
end
