defmodule HllConditionalActionsWeb.RuleDraftsTest do
  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Audit
  alias HllConditionalActions.Rules.Transfer

  setup %{conn: conn} do
    user = user_fixture()
    conn = conn |> init_test_session(%{}) |> Plug.Conn.put_session(:user_id, user.id)
    %{conn: conn, user: user, server: server_fixture()}
  end

  describe "drafts in the context" do
    test "a draft leaves the live rule alone until published", %{user: user} do
      rule = rule_fixture(%{name: "Live"}, actor: user)

      {:ok, drafted} = Rules.save_draft(rule, %{"name" => "Renamed"}, actor: user)
      assert drafted.name == "Live"
      assert drafted.draft["name"] == "Renamed"
      assert Rules.get_rule!(rule.id).name == "Live"

      {:ok, published} = Rules.publish_draft(drafted, actor: user)
      assert published.name == "Renamed"
      assert is_nil(published.draft)

      assert [%{action: :published, snapshot: %{"name" => "Renamed"}} | _rest] =
               Audit.list_versions(rule.id)
    end

    test "an invalid draft is refused", %{user: user} do
      rule = rule_fixture(%{}, actor: user)
      assert {:error, changeset} = Rules.save_draft(rule, %{"name" => ""})
      assert Keyword.has_key?(changeset.errors, :name)
    end

    test "a version restores as a draft", %{user: user} do
      rule = rule_fixture(%{name: "First"}, actor: user)
      [created] = Audit.list_versions(rule.id)
      {:ok, rule} = Rules.publish(rule, %{"name" => "Second"}, actor: user)

      {:ok, rule} = Rules.restore_version(rule, created.id, actor: user)
      assert rule.name == "Second"
      assert rule.draft["name"] == "First"
    end

    test "versions written before snapshots cannot be restored", %{user: user} do
      rule = rule_fixture(%{}, actor: user)
      [version] = Audit.list_versions(rule.id)
      version |> Ecto.Changeset.change(snapshot: nil) |> Repo.update!()

      assert {:error, :not_restorable} = Rules.restore_version(rule, version.id)
    end
  end

  describe "the pages" do
    test "the form saves a live rule as a draft", %{conn: conn, user: user} do
      rule = rule_fixture(%{name: "Live"}, actor: user)
      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}/edit")

      assert has_element?(view, "#rule-save-draft")
      assert has_element?(view, "#rule-publish")

      view
      |> form("#rule-form", rule: %{name: "Drafted"})
      |> render_submit(%{"intent" => "draft"})

      assert Rules.get_rule!(rule.id).name == "Live"
      assert Rules.get_rule!(rule.id).draft["name"] == "Drafted"
    end

    test "a disabled rule still saves directly", %{conn: conn, user: user} do
      rule = rule_fixture(%{enabled: false}, actor: user)
      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}/edit")
      refute has_element?(view, "#rule-save-draft")
    end

    test "the rule page shows the draft and publishes it", %{conn: conn, user: user} do
      rule = rule_fixture(%{name: "Live"}, actor: user)
      {:ok, _rule} = Rules.save_draft(rule, %{"name" => "Pending"}, actor: user)

      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}")
      assert has_element?(view, "#rule-draft-diff", "Pending")

      view |> element("#rule-draft-publish") |> render_click()
      assert Rules.get_rule!(rule.id).name == "Pending"
      refute has_element?(view, "#rule-draft")
    end

    test "the list flags a draft", %{conn: conn, user: user} do
      rule = rule_fixture(%{}, actor: user)
      {:ok, _rule} = Rules.save_draft(rule, %{"priority" => 3}, actor: user)

      {:ok, _view, html} = live(conn, ~p"/rules")
      assert html =~ "Draft"
    end

    test "a version can be restored from the changes tab", %{conn: conn, user: user} do
      rule = rule_fixture(%{name: "First"}, actor: user)
      [created] = Audit.list_versions(rule.id)
      {:ok, _rule} = Rules.publish(rule, %{"name" => "Second"}, actor: user)

      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}?tab=changes")
      view |> element("#version-restore-#{created.id}") |> render_click()

      assert Rules.get_rule!(rule.id).draft["name"] == "First"
    end

    test "the JSON editor reports errors by path and saves a draft", %{conn: conn, user: user} do
      rule = rule_fixture(%{name: "Live"}, actor: user)
      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}?tab=definition")

      view |> element("#rule-json-open") |> render_click()

      json = rule |> Transfer.dump_rule() |> Map.put("actions", []) |> Jason.encode!()
      view |> form("#rule-json-form", json: json) |> render_change()
      assert has_element?(view, "#rule-json-errors", "actions")

      view |> form("#rule-json-form", json: "{nope") |> render_change()
      assert has_element?(view, "#rule-json-errors", "not valid JSON")

      json = rule |> Transfer.dump_rule() |> Map.put("name", "From JSON") |> Jason.encode!()

      view
      |> form("#rule-json-form", json: json)
      |> render_submit(%{"intent" => "draft"})

      assert Rules.get_rule!(rule.id).draft["name"] == "From JSON"
    end

    test "import accepts an uploaded file", %{conn: conn, user: user} do
      rule = rule_fixture(%{name: "Exported"}, actor: user)
      {:ok, view, _html} = live(conn, ~p"/rules")
      view |> element("button[phx-click=open_import]") |> render_click()

      file =
        file_input(view, "#import-form", :import_file, [
          %{name: "rules.json", content: Rules.export_rules([rule]), type: "application/json"}
        ])

      render_upload(file, "rules.json")
      assert render(view) =~ "1 rule found"
    end
  end
end
