defmodule HllConditionalActionsWeb.RulePowerToolsTest do
  @moduledoc """
  The tools for somebody running many rules across servers: selecting rules
  and acting on them together, sorting the list by what needs looking at,
  copying a rule to a sibling server, exporting exactly what is selected, and
  a builder that does not lose unsaved work.
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

    %{conn: conn, user: user, server: server}
  end

  defp record(rule, server, status) do
    {:ok, _execution} =
      Rules.record_execution(%{
        rule_id: rule.id,
        server_id: server.id,
        player_id: "1",
        player_name: "Fulano",
        trigger_event: "player_connected",
        status: status
      })
  end

  describe "bulk actions" do
    setup %{server: server} do
      a = rule_fixture(%{name: "Alpha", server_id: server.id, enabled: true})
      b = rule_fixture(%{name: "Bravo", server_id: server.id, enabled: true})
      c = rule_fixture(%{name: "Charlie", server_id: server.id, enabled: true})
      %{a: a, b: b, c: c}
    end

    test "disables only the selected rules", %{conn: conn, a: a, b: b, c: c} do
      {:ok, view, _html} = live(conn, ~p"/rules")

      refute has_element?(view, "#rule-bulk-bar")

      view |> element("#rule-select-#{a.id}") |> render_click()
      view |> element("#rule-select-#{b.id}") |> render_click()
      assert has_element?(view, "#rule-bulk-bar")

      view |> element("#bulk-disable") |> render_click()

      refute Rules.get_rule!(a.id).enabled
      refute Rules.get_rule!(b.id).enabled
      assert Rules.get_rule!(c.id).enabled
      # The selection is spent once used.
      refute has_element?(view, "#rule-bulk-bar")
    end

    test "select all, then move into a group", %{conn: conn, a: a, b: b, c: c} do
      {:ok, view, _html} = live(conn, ~p"/rules")

      view |> element("#rule-select-all") |> render_click()
      view |> form("#bulk-group-form", %{group: "Seeding"}) |> render_submit()

      assert Enum.all?([a, b, c], &(Rules.get_rule!(&1.id).group == "Seeding"))
    end

    test "removes the selected rules", %{conn: conn, a: a, b: b} do
      {:ok, view, _html} = live(conn, ~p"/rules")

      view |> element("#rule-select-#{a.id}") |> render_click()
      view |> element("#bulk-delete") |> render_click()

      assert_raise Ecto.NoResultsError, fn -> Rules.get_rule!(a.id) end
      assert Rules.get_rule!(b.id)
    end

    test "the export button downloads only the selection", %{conn: conn, a: a} do
      {:ok, view, _html} = live(conn, ~p"/rules")

      view |> element("#rule-select-#{a.id}") |> render_click()

      assert has_element?(view, ~s|#bulk-export[href="/rules/export?ids=#{a.id}"]|)

      body = conn |> get(~p"/rules/export?ids=#{a.id}") |> response(200)
      assert body =~ "Alpha"
      refute body =~ "Bravo"
    end

    test "somebody who may only look gets no checkboxes", %{conn: conn, a: a} do
      viewer = user_fixture(%{role: role_fixture(%{permissions: ["view_rules"]})})
      conn = Plug.Conn.put_session(conn, :user_id, viewer.id)

      {:ok, view, _html} = live(conn, ~p"/rules")

      refute has_element?(view, "#rule-select-#{a.id}")
      refute has_element?(view, "#rule-select-all")
      # Even a crafted event changes nothing.
      render_click(view, "select", %{"id" => to_string(a.id)})
      render_click(view, "bulk", %{"op" => "delete"})
      assert Rules.get_rule!(a.id)
    end
  end

  test "the export honours the group and search filters", %{conn: conn, server: server} do
    rule_fixture(%{name: "Seeder", group: "Seeding", server_id: server.id})
    rule_fixture(%{name: "Other", server_id: server.id})

    body = conn |> get(~p"/rules/export?group=Seeding") |> response(200)
    assert body =~ "Seeder"
    refute body =~ "Other"

    body = conn |> get(~p"/rules/export?search=oth") |> response(200)
    assert body =~ "Other"
    refute body =~ "Seeder"
  end

  test "sorts by failures, the failing rule first", %{conn: conn, server: server} do
    _calm = rule_fixture(%{name: "Aaa calm", server_id: server.id})
    broken = rule_fixture(%{name: "Zzz broken", server_id: server.id})
    record(broken, server, :failed)

    {:ok, view, _html} = live(conn, ~p"/rules")

    html = view |> element("#rule-filters") |> render_change(%{"sort" => "failures"})

    [first | _rest] =
      html |> LazyHTML.from_fragment() |> LazyHTML.query("#rule-list > li") |> Enum.to_list()

    assert LazyHTML.attribute(first, "id") == ["rule-#{broken.id}"]
  end

  describe "copying to another server" do
    test "arrives on the target switched off", %{conn: conn, server: server} do
      other = server_fixture(%{name: "Second"})

      rule =
        rule_fixture(%{
          name: "Greeter",
          server_id: server.id,
          enabled: true,
          exemptions: %{exempt_vip: true}
        })

      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}")

      refute has_element?(view, "#rule-copy-to-#{server.id}")

      assert {:error, {:live_redirect, %{to: "/rules/" <> id}}} =
               view |> element("#rule-copy-to-#{other.id}") |> render_click()

      copy = Rules.get_rule!(id)
      assert copy.server_id == other.id
      assert copy.name == "Greeter"
      refute copy.enabled
      assert copy.exemptions.exempt_vip
      # The original is untouched.
      assert Rules.get_rule!(rule.id).server_id == server.id
    end
  end

  test "field search ignores accents, so nivel finds Nível" do
    assert HllConditionalActionsWeb.RuleBuilder.fold("Nível do Jogador") == "nivel do jogador"
    assert HllConditionalActionsWeb.RuleBuilder.fold("AÇÃO") == "acao"
  end

  describe "the builder's unsaved changes guard" do
    test "is clean on open and dirty after an edit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rules/new")

      assert has_element?(view, ~s|#rule-form[data-dirty="false"]|)

      view |> form("#rule-form", %{"rule" => %{"name" => "Draft"}}) |> render_change()

      assert has_element?(view, ~s|#rule-form[data-dirty="true"]|)
    end

    test "adding a condition counts as an edit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rules/new")

      render_click(view, "add_condition", %{})

      assert has_element?(view, ~s|#rule-form[data-dirty="true"]|)
    end
  end
end
