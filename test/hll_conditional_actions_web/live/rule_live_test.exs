defmodule HllConditionalActionsWeb.RuleLiveTest do
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

    %{conn: conn, user: user}
  end

  describe "the builder" do
    test "offers the condition fields the trigger can actually provide", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rules/new")

      # A brand new rule is triggered by a connect, where no weapon exists.
      refute render(view) =~ "Weapon"

      html =
        view
        |> form("#rule-form", rule: %{trigger_event: "player_kill"})
        |> render_change()

      assert html =~ "Weapon"
    end

    test "offers each game's own roles", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rules/new")

      # Picking the field is what makes the value input appear, so this is two
      # interactions for the user too.
      hll =
        view
        |> form("#rule-form",
          rule: %{game: "hll", conditions: %{"0" => %{field: "player_role"}}}
        )
        |> render_change()

      assert hll =~ "Artillery Observer"
      refute hll =~ "Squad Leader"

      hllv =
        view
        |> form("#rule-form",
          rule: %{game: "hllv", conditions: %{"0" => %{field: "player_role"}}}
        )
        |> render_change()

      assert hllv =~ "Squad Leader"
      assert hllv =~ "Pilot"
      refute hllv =~ "Artillery Observer"
    end

    test "the operator list follows the field's type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rules/new")

      numeric =
        view
        |> form("#rule-form", rule: %{conditions: %{"0" => %{field: "kills"}}})
        |> render_change()

      assert numeric =~ "is greater than"
      refute numeric =~ "starts with"

      text =
        view
        |> form("#rule-form", rule: %{conditions: %{"0" => %{field: "player_name"}}})
        |> render_change()

      assert text =~ "starts with"
      refute text =~ "is greater than"
    end

    test "adding a condition keeps the ones already there", %{conn: conn} do
      rule =
        rule_fixture(%{
          conditions: [
            %{field: :kills, operator: :greater_than, value: "10"},
            %{field: :deaths, operator: :less_than, value: "3"}
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}/edit")

      # Clicking straight after opening, before any change event has posted the
      # form, is the case that used to drop the stored rows.
      html = view |> element("button[phx-click=add_condition]") |> render_click()

      assert html =~ ~s(value="10")
      assert html =~ ~s(value="3")
      assert count_selects(html, "conditions") == 3
    end

    test "removing a condition removes the right one", %{conn: conn} do
      rule =
        rule_fixture(%{
          conditions: [
            %{field: :kills, operator: :greater_than, value: "10"},
            %{field: :deaths, operator: :less_than, value: "3"}
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}/edit")

      html =
        view
        |> element("button[phx-click=remove_condition][phx-value-index='0']")
        |> render_click()

      refute html =~ ~s(value="10")
      assert html =~ ~s(value="3")
    end

    test "adding an action keeps the ones already there", %{conn: conn} do
      rule = rule_fixture(%{actions: [%{type: :kick_player, parameters: %{"reason" => "Bye"}}]})

      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}/edit")

      html = view |> element("button[phx-click=add_action]") |> render_click()

      assert html =~ "Bye"
      assert count_selects(html, "actions") == 2
    end

    test "an action's parameter inputs follow its type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rules/new")

      html =
        view
        |> form("#rule-form",
          rule: %{actions: %{"0" => %{type: "temp_ban_player", parameters: %{}}}}
        )
        |> render_change()

      assert html =~ "Duration (hours)"
      assert html =~ "Reason"
    end

    # A nested <form> is a parse error: the browser closes the outer form at
    # the inner </form>, so anything after it - including the submit button -
    # stops belonging to the form and clicking Save does nothing at all.
    # `render_submit` on the form element cannot catch that, because it fires
    # the event directly; only the DOM can.
    # The switches are hand written rather than `<.input type="checkbox">`, and
    # a switch that silently posts nothing would turn a simulated rule into one
    # that really kicks people.
    test "the enabled and simulation switches round trip", %{conn: conn} do
      rule = rule_fixture(%{enabled: true, simulation: false})

      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}/edit")

      view
      |> form("#rule-form", rule: %{enabled: false, simulation: true})
      |> render_submit()

      assert_redirect(view, ~p"/rules")

      updated = Rules.get_rule!(rule.id)
      refute updated.enabled
      assert updated.simulation
    end

    test "the submit button belongs to the rule form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rules/new")

      assert has_element?(view, "#rule-form button[type=submit]"),
             "the save button is outside #rule-form, so clicking it submits nothing"
    end

    test "the builder contains no nested forms", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/rules/new")

      nested = html |> LazyHTML.from_document() |> LazyHTML.query("form form")

      assert Enum.empty?(nested),
             "a form contains another form; the parser closes the outer one at the inner </form>"
    end

    test "saving an existing rule persists the change", %{conn: conn} do
      rule = rule_fixture(%{name: "Before", priority: 0})

      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}/edit")

      view
      |> form("#rule-form", rule: %{name: "After", priority: "7"})
      |> render_submit()

      assert_redirect(view, ~p"/rules")

      updated = Rules.get_rule!(rule.id)
      assert updated.name == "After"
      assert updated.priority == 7
      assert updated.conditions == rule.conditions
      assert updated.actions == rule.actions
    end

    test "saving creates the rule", %{conn: conn} do
      server = server_fixture()

      {:ok, view, _html} = live(conn, ~p"/rules/new")

      # Choose the field first so its operator and value inputs are rendered.
      view
      |> form("#rule-form", rule: %{conditions: %{"0" => %{field: "player_level"}}})
      |> render_change()

      view
      |> form("#rule-form",
        rule: %{
          name: "Welcome new players",
          game: "hll",
          server_id: server.id,
          trigger_event: "player_connected",
          logical_operator: "and",
          conditions: %{"0" => %{field: "player_level", operator: "less_than", value: "10"}},
          actions: %{
            "0" => %{type: "message_player", parameters: %{"message" => "Hi {player_name}"}}
          }
        }
      )
      |> render_submit()

      assert_redirect(view, ~p"/rules")

      assert [rule] = Rules.list_rules()
      assert rule.name == "Welcome new players"
      assert [%{field: :player_level, value: "10"}] = rule.conditions
      assert [%{type: :message_player}] = rule.actions
    end
  end

  describe "the list" do
    test "shows rules and lets one be disabled", %{conn: conn} do
      rule = rule_fixture(%{name: "Greeter"})

      {:ok, view, html} = live(conn, ~p"/rules")
      assert html =~ "Greeter"

      # A row offers two ways to switch a rule off: the switch on the row
      # itself and the entry in its kebab menu. This is the switch, whose
      # clickable part is the checkbox the label hides.
      view
      |> element("input[type=checkbox][phx-click=toggle][phx-value-id='#{rule.id}']")
      |> render_click()

      refute Rules.get_rule!(rule.id).enabled
    end

    test "searches by name", %{conn: conn} do
      _greeter = rule_fixture(%{name: "Greeter"})
      _banner = rule_fixture(%{name: "Team kill ban"})

      {:ok, view, _html} = live(conn, ~p"/rules")

      html = view |> form("#rule-filters", %{search: "greet"}) |> render_change()

      assert html =~ "Greeter"
      refute html =~ "Team kill ban"
    end

    test "filters by game", %{conn: conn} do
      _hll = rule_fixture(%{name: "WW2 rule", game: :hll})
      _hllv = rule_fixture(%{name: "Vietnam rule", game: :hllv})

      {:ok, view, _html} = live(conn, ~p"/rules")

      html = view |> form("#rule-filters", %{game: "hllv"}) |> render_change()

      assert html =~ "Vietnam rule"
      refute html =~ "WW2 rule"
    end
  end

  # Each condition/action row renders its own `<select name="rule[<kind>][N][...]">`,
  # so counting the distinct row indexes counts the rows.
  defp count_selects(html, kind) do
    ~r/name="rule\[#{kind}\]\[(\d+)\]/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> length()
  end
end
