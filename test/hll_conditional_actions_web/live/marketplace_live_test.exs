defmodule HllConditionalActionsWeb.MarketplaceLiveTest do
  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Features
  alias HllConditionalActions.Features.Usage
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Tickets.Ticket

  doctest HllConditionalActionsWeb.FeatureGuard

  @shop_permissions ~w(can_view_structured_logs can_add_vip can_view_vip_ids can_view_player_history)

  setup %{conn: conn} do
    # CRCON answers the page's two reads: the match history and the key's
    # permissions. Tests that care stub it again.
    stub_crcon(total: 1204, permissions: @shop_permissions)

    %{conn: conn |> init_test_session(%{}) |> Plug.Conn.put_session(:user_id, user_fixture().id)}
  end

  test "installing a module opens its pages and lists it in the sidebar", %{conn: conn} do
    server = server_fixture(%{features: []})

    {:ok, view, html} = live(conn, ~p"/servers/#{server.id}/marketplace")
    refute html =~ ~s|href="/servers/#{server.id}/tickets"|

    view |> element("#install-tickets") |> render_click()

    assert Features.installed?(server.id, :tickets)
    assert has_element?(view, "#uninstall-tickets")
    assert has_element?(view, ~s|a[href="/servers/#{server.id}/tickets"]|)
    assert {:ok, _view, _html} = live(conn, ~p"/servers/#{server.id}/tickets")
  end

  test "a page of a module that is not installed sends you to the marketplace", %{conn: conn} do
    server = server_fixture(%{features: [:rules]})
    marketplace = "/servers/#{server.id}/marketplace"

    assert {:error, {:redirect, %{to: ^marketplace}}} =
             live(conn, ~p"/servers/#{server.id}/leaderboard")

    assert {:ok, _view, _html} = live(conn, ~p"/servers/#{server.id}/rules")
  end

  test "removing a module keeps the server and closes its pages", %{conn: conn} do
    server = server_fixture(%{features: [:live_feed]})

    {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/marketplace")
    view |> element("#uninstall-live_feed") |> render_click()

    refute Features.installed?(server.id, :live_feed)
    assert {:error, {:redirect, _to}} = live(conn, ~p"/servers/#{server.id}/feed")
  end

  test "organisation pages need the module on at least one server", %{conn: conn} do
    _without = server_fixture(%{features: []})

    assert {:error, {:redirect, %{to: "/servers"}}} = live(conn, ~p"/seasons")

    _with = server_fixture(%{features: [:progression]})
    assert {:ok, _view, _html} = live(conn, ~p"/seasons")
  end

  test "cards follow the board's order and show installed and available states", %{conn: conn} do
    server = server_fixture(%{features: [:rules, :stats]})

    {:ok, view, html} = live(conn, ~p"/servers/#{server.id}/marketplace")

    ids =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#marketplace article")
      |> LazyHTML.attribute("id")

    assert ids ==
             ~w(feature-rules feature-tickets feature-stats feature-live_feed feature-progression feature-vip_shop)

    assert has_element?(view, "#uninstall-rules")
    assert has_element?(view, "#install-tickets")
    assert has_element?(view, "#feature-tickets.mkt-card--available")
    assert has_element?(view, "#marketplace-count", "2")
  end

  describe "usage footers" do
    test "count what each installed module holds on this server", %{conn: conn} do
      server = server_fixture()
      other = server_fixture()

      rule_fixture(%{server_id: server.id})
      rule_fixture(%{server_id: server.id})
      rule_fixture(%{server_id: other.id})

      ticket(server, :open)
      ticket(server, :answered)
      ticket(server, :closed)
      ticket(other, :open)

      {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/marketplace")

      assert has_element?(view, "#usage-rules", "2 rules on this server")
      assert has_element?(view, "#usage-tickets", "2 open now")
      assert has_element?(view, "#usage-live_feed", "Keeps the last #{Usage.feed_lines()} lines")

      assert render_async(view) =~ "1,204 saved matches"
      assert has_element?(view, "#usage-stats", "1,204 saved matches")
    end

    test "say so when CRCON's match history does not answer", %{conn: conn} do
      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

      server = server_fixture(%{features: [:stats]})
      {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/marketplace")
      render_async(view)

      assert has_element?(view, "#usage-stats", "Match history unavailable")
    end

    test "available modules show what they come with instead", %{conn: conn} do
      server = server_fixture(%{features: []})
      {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/marketplace")

      refute has_element?(view, "#usage-rules")
      assert has_element?(view, "#feature-rules", "#{Usage.recipes()} recipes")

      assert has_element?(
               view,
               "#feature-progression",
               "Comes with #{Usage.starter_achievements()} achievements"
             )
    end
  end

  describe "VIP shop key warning" do
    test "shows when the key cannot read the VIP list, and remembers it", %{conn: conn} do
      stub_crcon(total: 3, permissions: ~w(can_view_structured_logs can_add_vip))
      server = server_fixture(%{features: []})

      {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/marketplace")
      render_async(view)

      assert has_element?(view, "#vip-shop-permissions", "can_view_vip_ids")
      refute has_element?(view, "#vip-shop-permissions", "can_add_vip")

      reloaded = Servers.get_server!(server.id)
      refute "can_view_vip_ids" in reloaded.known_permissions
      assert reloaded.permissions_checked_at
    end

    test "stays hidden when the key has what the shop needs", %{conn: conn} do
      server = server_fixture(%{features: []})

      {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/marketplace")
      render_async(view)

      refute has_element?(view, "#vip-shop-permissions")
    end

    test "does not ask CRCON again while the stored answer is fresh", %{conn: conn} do
      test_pid = self()
      server = server_fixture(%{features: []})

      server
      |> Ecto.Changeset.change(
        known_permissions: ["can_add_vip"],
        permissions_checked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        send(test_pid, {:crcon, conn.request_path})
        envelope(conn, %{"permissions" => []})
      end)

      {:ok, view, _html} = live(conn, ~p"/servers/#{server.id}/marketplace")
      render_async(view)

      refute_received {:crcon, "/api/get_own_user_permissions"}
      assert has_element?(view, "#vip-shop-permissions", "can_view_vip_ids")
    end
  end

  describe "copying modules from another server" do
    test "installs what the source runs and keeps extras by default", %{conn: conn} do
      source = server_fixture(%{features: [:rules, :tickets, :vip_shop]})
      target = server_fixture(%{features: [:rules, :live_feed]})

      {:ok, view, _html} = live(conn, ~p"/servers/#{target.id}/marketplace")

      view |> element("#copy-modules") |> render_click()
      assert has_element?(view, "#copy-dialog")
      assert has_element?(view, "#copy-confirm[disabled]")

      view |> element("#copy-source-#{source.id}") |> render_click()
      assert has_element?(view, "#copy-plan-install", "Tickets")

      view |> element("#copy-confirm") |> render_click()

      assert Features.installed(target.id) ==
               MapSet.new([:rules, :tickets, :vip_shop, :live_feed])

      refute has_element?(view, "#copy-dialog")
      assert has_element?(view, "#uninstall-tickets")
      assert has_element?(view, "#marketplace-count", "4")
    end

    test "removes the extras when asked", %{conn: conn} do
      source = server_fixture(%{features: [:rules, :tickets]})
      target = server_fixture(%{features: [:live_feed]})

      {:ok, view, _html} = live(conn, ~p"/servers/#{target.id}/marketplace")

      view |> element("#copy-modules") |> render_click()
      view |> element("#copy-source-#{source.id}") |> render_click()
      view |> element("#copy-remove-extras") |> render_click()
      view |> element("#copy-confirm") |> render_click()

      assert Features.installed(target.id) == MapSet.new([:rules, :tickets])
      assert has_element?(view, "#install-live_feed")
    end
  end

  defp ticket(server, status) do
    Repo.insert!(%Ticket{
      server_id: server.id,
      player_id: "7656119#{System.unique_integer([:positive])}",
      player_name: "Player",
      source: :chat,
      status: status,
      priority: :normal,
      last_activity_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  defp stub_crcon(opts) do
    total = Keyword.fetch!(opts, :total)
    permissions = Keyword.fetch!(opts, :permissions)

    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      case conn.request_path do
        "/api/get_scoreboard_maps" ->
          envelope(conn, %{"page" => 1, "page_size" => 1, "total" => total, "maps" => []})

        "/api/get_own_user_permissions" ->
          envelope(conn, %{
            "user_name" => "bot",
            "is_superuser" => false,
            "permissions" => Enum.map(permissions, &%{"permission" => "api." <> &1})
          })

        _other ->
          envelope(conn, nil)
      end
    end)
  end

  defp envelope(conn, result) do
    Req.Test.json(conn, %{"result" => result, "failed" => false, "error" => nil})
  end
end
