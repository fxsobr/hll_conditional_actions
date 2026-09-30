defmodule HllConditionalActionsWeb.SettingsLiveTest do
  @moduledoc """
  Ajustes, the hub: a card for every settings page the user may open, and
  none for the ones they may not.
  """

  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Accounts.Sessions
  alias HllConditionalActions.Discord.Webhook
  alias HllConditionalActions.Repo

  defp log_in(conn, user) do
    conn |> init_test_session(%{}) |> Plug.Conn.put_session(:user_id, user.id)
  end

  test "an administrator gets every door", %{conn: conn} do
    server = server_fixture(%{name: "Caveiras Brasil #1"})

    Repo.insert!(%Webhook{
      name: "Log",
      url: "https://discord.com/api/webhooks/1/a",
      last_error: "404"
    })

    {:ok, view, _html} = conn |> log_in(user_fixture()) |> live(~p"/settings")

    assert has_element?(view, "#settings-server-#{server.id}", "Caveiras Brasil #1")
    assert has_element?(view, ~s|#settings-users[href="/users"]|)
    assert has_element?(view, ~s|#settings-roles[href="/roles"]|)
    assert has_element?(view, ~s|#settings-discord[href="/discord"]|, "1")
    assert has_element?(view, ~s|#settings-metrics[href="/metrics"]|)
    assert has_element?(view, ~s|#settings-modules[href="/servers/#{server.id}/marketplace"]|)
    assert has_element?(view, ~s|#settings-account-link[href="/account"]|)
    assert has_element?(view, "#settings-about #settings-version")
  end

  test "somebody who may only see servers gets only that and their own account", %{conn: conn} do
    server_fixture()
    user = user_fixture(%{role: role_fixture(%{permissions: ["view_servers"]})})

    {:ok, view, _html} = conn |> log_in(user) |> live(~p"/settings")

    assert has_element?(view, "#settings-servers")
    assert has_element?(view, "#settings-account")
    refute has_element?(view, "#settings-people")
    refute has_element?(view, "#settings-integrations")
    refute has_element?(view, "#settings-engine")
    refute has_element?(view, "#settings-about")
  end

  test "a user with no permission at all still reaches their preferences", %{conn: conn} do
    user = user_fixture(%{role: role_fixture(%{permissions: []})})

    {:ok, view, _html} = conn |> log_in(user) |> live(~p"/settings")

    refute has_element?(view, "#settings-servers")
    assert has_element?(view, "#settings-preferences")
    assert has_element?(view, "#settings-scheme")

    assert has_element?(
             view,
             ~s|#settings-language a[href^="/locale/"][href*="return_to=%2Fsettings"]|
           )
  end

  test "the search narrows the doors", %{conn: conn} do
    {:ok, view, _html} = live(conn |> log_in(user_fixture()), ~p"/settings")

    view |> element("#settings-search-form") |> render_change(%{"q" => "discord"})

    assert has_element?(view, "#settings-discord")
    refute has_element?(view, "#settings-users")
    refute has_element?(view, "#settings-preferences")

    view |> element("#settings-search-form") |> render_change(%{"q" => "zzz nothing"})
    assert has_element?(view, "#settings-search-empty")
  end

  test "counts the open sessions of the account", %{conn: conn} do
    user = user_fixture()
    Sessions.create(user, %{})
    Sessions.create(user, %{})

    {:ok, view, _html} = conn |> log_in(user) |> live(~p"/settings")

    assert has_element?(view, "#settings-account-link", "2")
  end

  test "points at two factor when the account has none", %{conn: conn} do
    {:ok, view, _html} = conn |> log_in(user_fixture()) |> live(~p"/settings")

    assert has_element?(view, ~s|#settings-two-factor[href="/account"]|)
  end
end

defmodule HllConditionalActionsWeb.SettingsPagesTest do
  @moduledoc """
  The pages the hub opens, in their new shape: each renders its key pieces
  and still does what it did.
  """

  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Discord.Webhook
  alias HllConditionalActions.Repo

  setup %{conn: conn} do
    %{conn: conn |> init_test_session(%{}) |> Plug.Conn.put_session(:user_id, user_fixture().id)}
  end

  test "the server form puts the connection test beside the fields", %{conn: conn} do
    server = server_fixture()

    {:ok, view, _html} = live(conn, ~p"/servers/new")

    assert has_element?(view, "#server-form")
    assert has_element?(view, "#server-check #server-check-button")

    assert has_element?(
             view,
             ~s|#server-modal button[type="submit"][form="server-form"][disabled]|
           )

    {:ok, view, _html} = live(conn, ~p"/servers")
    assert has_element?(view, "#server-#{server.id}", server.name)
  end

  test "users are listed and searchable, and the form picks a role", %{conn: conn} do
    other = user_fixture(%{name: "Ana Paula"})

    {:ok, view, _html} = live(conn, ~p"/users")

    assert has_element?(view, "#user-#{other.id}")

    view |> element("#user-search") |> render_change(%{"search" => "zzz-nobody"})
    refute has_element?(view, "#user-#{other.id}")

    {:ok, view, _html} = live(conn, ~p"/users/#{other.id}/edit")

    assert has_element?(view, "#user-form #user-role-choices input[type=radio][checked]")
  end

  test "ticking every server clears the list, ticking a server narrows it", %{conn: conn} do
    server = server_fixture()
    other = user_fixture()

    {:ok, view, _html} = live(conn, ~p"/users/#{other.id}/edit")
    assert has_element?(view, "#user-all-servers input[type=checkbox][checked]")

    view
    |> form("#user-form")
    |> render_change(%{"user" => %{"server_ids" => ["", to_string(server.id)]}})

    refute has_element?(view, "#user-all-servers input[type=checkbox][checked]")

    view |> form("#user-form") |> render_submit()
    assert Enum.map(Accounts.get_user!(other.id).servers, & &1.id) == [server.id]
  end

  test "a built-in role is read-only and can be duplicated", %{conn: conn} do
    role =
      Repo.insert!(%HllConditionalActions.Accounts.Role{
        name: "Built in #{System.unique_integer([:positive])}",
        permissions: ["view_servers", "view_rules"],
        system?: true
      })

    {:ok, view, _html} = live(conn, ~p"/roles/#{role.id}/edit")

    refute has_element?(view, "#role-save")
    view |> element("#role-duplicate") |> render_click()

    copy =
      Enum.find(
        Accounts.list_roles(),
        &(&1.name != role.name and String.starts_with?(&1.name, role.name))
      )

    assert copy
    refute copy.system?
    assert Enum.sort(copy.permissions) == Enum.sort(role.permissions)
  end

  test "the roles page opens a role and edits it with switches", %{conn: conn} do
    role = role_fixture(%{name: "Event crew", permissions: ["view_servers"]})

    {:ok, view, _html} = live(conn, ~p"/roles")

    assert has_element?(view, "#role-#{role.id}", "Event crew")
    assert has_element?(view, "#role-editor #role-form")

    {:ok, view, _html} = live(conn, ~p"/roles/#{role.id}/edit")

    assert has_element?(view, "#role-permission-view_servers[checked]")

    view
    |> form("#role-form", role: %{name: "Event crew", permissions: ["manage_tickets"]})
    |> render_submit()

    assert Accounts.get_role!(role.id).permissions == ["manage_tickets"]
  end

  test "a role granted manage shows its view as included", %{conn: conn} do
    role = role_fixture(%{permissions: ["manage_servers"]})

    {:ok, view, _html} = live(conn, ~p"/roles/#{role.id}/edit")

    assert has_element?(view, "#role-permission-manage_servers[checked]")
    refute has_element?(view, "#role-permission-view_servers")
  end

  test "the Discord editor sits beside the list", %{conn: conn} do
    webhook =
      Repo.insert!(%Webhook{
        name: "Log",
        url: "https://discord.com/api/webhooks/1/a",
        last_error: "Unknown Webhook"
      })

    {:ok, view, _html} = live(conn, ~p"/discord/#{webhook.id}/edit")

    assert has_element?(view, "#webhook-#{webhook.id}", "Log")
    assert has_element?(view, "#webhook-editor #webhook-form")
  end

  test "the forced password form is there", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/account/password")

    assert has_element?(view, "#password-form")
  end

  test "the account page lists what the role allows", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/account")

    refute has_element?(view, "#account-profile #profile-form")
    view |> element("#account-edit-profile") |> render_click()
    assert has_element?(view, "#account-profile #profile-form")
    assert has_element?(view, "#account-permissions li")
  end
end

defmodule HllConditionalActionsWeb.MetricsPageTest do
  @moduledoc """
  The metrics page with something measured. Synchronous: the counters are
  one table for the whole node.
  """

  use HllConditionalActionsWeb.ConnCase, async: false

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Metrics

  setup %{conn: conn} do
    :ok = Metrics.reset()
    on_exit(fn -> Metrics.reset() end)

    %{conn: conn |> init_test_session(%{}) |> Plug.Conn.put_session(:user_id, user_fixture().id)}
  end

  test "shows the engine's counters", %{conn: conn} do
    native = System.convert_time_unit(40, :millisecond, :native)

    :telemetry.execute(
      [:hll_conditional_actions, :rule, :fired],
      %{duration: native, count: 1},
      %{rule_id: 1, rule_name: "r", server_id: 1, trigger: :player_connected, status: :executed}
    )

    :telemetry.execute([:hll_conditional_actions, :rule, :skipped], %{count: 1}, %{
      reason: :cooldown
    })

    :telemetry.execute(
      [:hll_conditional_actions, :crcon, :request, :stop],
      %{duration: native},
      %{endpoint: "get_players", outcome: :ok}
    )

    :telemetry.execute(
      [:hll_conditional_actions, :crcon, :request, :stop],
      %{duration: native},
      %{endpoint: "get_players", outcome: :unauthorized}
    )

    :telemetry.execute([:hll_conditional_actions, :log_stream, :event], %{count: 1}, %{
      type: :player_kill
    })

    {:ok, view, _html} = live(conn, ~p"/metrics")

    assert has_element?(view, "#metrics-kpis")
    assert has_element?(view, "#metrics-crcon", "get_players")
    assert has_element?(view, "#metrics-skipped")

    view |> element("#metrics-pause") |> render_click()
    assert has_element?(view, "#metrics-refresh", "Paused")
  end
end
