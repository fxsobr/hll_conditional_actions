defmodule HllConditionalActionsWeb.WeaponGroupTest do
  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    user = user_fixture()
    server_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn}
  end

  test "\"is one of\" on the weapon type offers the categories as a group", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/rules/new")

    # The weapon only exists on a kill, so the trigger comes first.
    view |> form("#rule-form", rule: %{trigger_event: "player_kill"}) |> render_change()

    view
    |> form("#rule-form", rule: %{conditions: %{"0" => %{field: "weapon_type"}}})
    |> render_change()

    html =
      view
      |> form("#rule-form",
        rule: %{conditions: %{"0" => %{operator: "in_list"}}}
      )
      |> render_change()

    assert has_element?(view, "#rule_conditions_0_value-group")
    assert html =~ "Melee (knife, spade)"
    assert html =~ "Grenade"
  end

  test "picking weapons by name, grouped by type", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/rules/new")

    view |> form("#rule-form", rule: %{trigger_event: "player_kill"}) |> render_change()

    view
    |> form("#rule-form", rule: %{conditions: %{"0" => %{field: "weapon"}}})
    |> render_change()

    view
    |> form("#rule-form", rule: %{conditions: %{"0" => %{operator: "in_list"}}})
    |> render_change()

    picker = "#rule_conditions_0_value-weapons"
    assert has_element?(view, picker)
    assert has_element?(view, "#{picker} [data-group=melee]", "FELDSPATEN")
    assert has_element?(view, "#{picker} [data-group=melee]", "M3 KNIFE")
    assert has_element?(view, "#{picker} [data-group=machine_gun]", "MG42")
  end

  test "recipe messages come in the admin's language" do
    attrs = %{actions: [%{type: :message_player, parameters: %{"message" => "Team killing"}}]}

    Gettext.with_locale(HllConditionalActionsWeb.Gettext, "pt_BR", fn ->
      assert %{actions: [%{parameters: %{"message" => "Abate aliado"}}]} =
               HllConditionalActionsWeb.RecipeText.translate_attrs(attrs)
    end)
  end
end
