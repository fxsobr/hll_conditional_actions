defmodule HllConditionalActionsWeb.AuthorizationTest do
  @moduledoc """
  Every permission-gated page is checked from both sides: somebody who has the
  permission gets in, somebody who does not is redirected. Hiding a link in the
  sidebar is presentation; these are the checks that actually enforce access.
  """

  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Accounts

  @pages [
    {"/servers", :view_servers},
    {"/rules", :view_rules},
    {"/feed", :view_live_feed},
    {"/executions", :view_executions},
    {"/metrics", :view_executions},
    {"/players/76561190000000000", :view_executions},
    {"/users", :manage_users},
    {"/roles", :manage_roles}
  ]

  setup %{conn: conn} do
    %{conn: init_test_session(conn, %{})}
  end

  for {path, permission} <- @pages do
    test "#{path} is reachable with #{permission}", %{conn: conn} do
      user = user_with(unquote(permission))

      assert {:ok, _view, _html} = conn |> log_in(user) |> live(unquote(path))
    end

    test "#{path} redirects without #{permission}", %{conn: conn} do
      user = user_without(unquote(permission))

      assert {:error, {:redirect, %{to: "/"}}} = conn |> log_in(user) |> live(unquote(path))
    end
  end

  # A nested <form> is a parse error: the browser closes the outer form at the
  # inner </form>, quietly detaching every control after it. It costs nothing
  # to check on every page rather than rediscovering it one broken button at a
  # time.
  for {path, permission} <- @pages do
    test "#{path} has no nested forms", %{conn: conn} do
      user = user_with(unquote(permission))
      {:ok, _view, html} = conn |> log_in(user) |> live(unquote(path))

      nested = html |> LazyHTML.from_document() |> LazyHTML.query("form form")

      assert Enum.empty?(nested),
             "#{unquote(path)} nests a form inside another form"
    end
  end

  test "a user who must change their password is pushed to the password form", %{conn: conn} do
    user = user_fixture(%{must_change_password?: true})

    assert {:error, {:redirect, %{to: "/account/password"}}} = conn |> log_in(user) |> live("/")
  end

  test "the password form itself stays reachable in that state", %{conn: conn} do
    user = user_fixture(%{must_change_password?: true})

    assert {:ok, _view, html} = conn |> log_in(user) |> live("/account/password")
    assert html =~ "Change password"
  end

  test "the sidebar only lists what the user may open", %{conn: conn} do
    user = user_with(:view_servers)

    {:ok, _view, html} = conn |> log_in(user) |> live("/")

    assert html =~ ~s|href="/servers"|
    refute html =~ ~s|href="/users"|
    refute html =~ ~s|href="/roles"|
  end

  # Exactly one permission, so a page opening for this user proves that this
  # permission is what opens it.
  # The dashboard is the one authenticated page with no permission of its own:
  # everybody lands on it. What it shows has to be gated instead, or it becomes
  # the way to read what the pages themselves refuse.
  describe "the dashboard" do
    test "shows the servers to somebody who may see servers", %{conn: conn} do
      server = server_fixture(%{name: "Caveiras Brasil #1"})
      user = user_with(:view_servers)

      {:ok, _view, html} = conn |> log_in(user) |> live(~p"/")

      assert html =~ server.name
    end

    test "does not name the servers to somebody who may not", %{conn: conn} do
      server = server_fixture(%{name: "Caveiras Brasil #1"})
      user = user_without(:view_servers)

      {:ok, _view, html} = conn |> log_in(user) |> live(~p"/")

      refute html =~ server.name
    end

    test "does not show rule activity without :view_executions", %{conn: conn} do
      server = server_fixture()
      rule = rule_fixture(%{name: "Greeter", server_id: server.id})

      {:ok, _execution} =
        HllConditionalActions.Rules.record_execution(%{
          rule_id: rule.id,
          server_id: server.id,
          player_id: "7656119",
          player_name: "Kapitan",
          trigger_event: "player_connected",
          status: :executed
        })

      user = user_without(:view_executions)

      {:ok, _view, html} = conn |> log_in(user) |> live(~p"/")

      refute html =~ "Kapitan"
    end
  end

  defp user_with(permission) do
    user_fixture(%{role: role_fixture(%{permissions: [to_string(permission)]})})
  end

  # Everything except one permission. `manage_*` implies `view_*`, so any
  # permission that would grant the excluded one back is dropped too.
  defp user_without(permission) do
    excluded = to_string(permission)

    permissions =
      Enum.reject(
        Accounts.Permission.all_strings(),
        &(excluded in Accounts.Permission.expand([&1]))
      )

    user_fixture(%{role: role_fixture(%{permissions: permissions})})
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Conn.put_session(:user_id, user.id)
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:#{user.id}")
  end
end
