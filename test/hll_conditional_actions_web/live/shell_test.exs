defmodule HllConditionalActionsWeb.ShellTest do
  @moduledoc """
  The shell around every page: the rail and its badges, the area tabs in
  the header, the command palette's search, the bell's notifications and
  the phone's "Mais" sheet.
  """

  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Notifications
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Tickets.Message
  alias HllConditionalActions.Tickets.Ticket

  doctest HllConditionalActionsWeb.Layouts
  doctest HllConditionalActionsWeb.RelativeTime
  doctest HllConditionalActions.Search

  @rudi "76561198012345678"

  setup %{conn: conn} do
    user = user_fixture(%{username: "marcelo", name: "Marcelo Souza"})

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, user: user, server: server_fixture(%{name: "BR #1 Público"})}
  end

  defp ticket(server, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Ticket{
          server_id: server.id,
          player_id: @rudi,
          player_name: "Rudi_88",
          status: :open,
          last_activity_at: DateTime.utc_now(:second)
        },
        attrs
      )
    )
  end

  defp message(ticket, attrs) do
    Repo.insert!(struct(%Message{ticket_id: ticket.id, author: :player, body: "help"}, attrs))
  end

  defp hit(rule, server, attrs \\ %{}) do
    {:ok, execution} =
      Rules.record_execution(
        Map.merge(
          %{
            rule_id: rule.id,
            server_id: server.id,
            player_id: @rudi,
            player_name: "Rudi_88",
            trigger_event: "player_team_kill",
            status: :executed
          },
          attrs
        )
      )

    execution
  end

  describe "rail" do
    test "every area, Ajustes at the foot, the active one marked", %{conn: conn, server: server} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{#rail-briefing[aria-current="page"]})
      assert has_element?(view, ~s{#rail-live[href="/servers/#{server.id}"]})
      assert has_element?(view, ~s{#rail-rules[href="/rules"]})
      assert has_element?(view, ~s{#rail-inbox[href="/inbox"]})
      assert has_element?(view, "#rail-community")
      assert has_element?(view, ~s{#rail-players[href="/players"]})
      assert has_element?(view, ~s{#rail-modules[href="/servers/#{server.id}/marketplace"]})
      assert has_element?(view, ~s{#rail-settings[href="/settings"]})
      assert has_element?(view, "#account-menu-button")
      assert has_element?(view, ~s{#account-menu-panel a[href="/account"]})
    end

    test "Ao vivo follows the server in scope", %{conn: conn, server: server} do
      other = server_fixture(%{name: "BR #2 Eventos"})

      {:ok, view, _html} = live(conn, ~p"/servers/#{other}/rules")

      assert has_element?(view, ~s{#rail-live[href="/servers/#{other.id}"]})
      assert has_element?(view, ~s{#rail-rules[aria-current="page"]})
      refute has_element?(view, ~s{#rail-live[href="/servers/#{server.id}"]})
    end

    test "Caixa counts the open tickets", %{conn: conn, server: server} do
      ticket(server)

      {:ok, view, _html} = live(conn, ~p"/players")

      assert has_element?(view, "#rail-inbox [data-nav-badge]", "1")
      assert has_element?(view, "#tab-bar-inbox [data-nav-badge]", "1")
    end
  end

  describe "header" do
    test "an area's pages are tabs beside the title", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/seasons")

      assert has_element?(view, ~s{#section-tabs a[href="/seasons"][aria-current="page"]})
      assert has_element?(view, ~s{#section-tabs a[href="/achievements"]})
      assert has_element?(view, ~s{#section-tabs a[href="/matches"]})
      assert has_element?(view, ~s{#section-tabs a[href="/vip-shop"]})

      # Beside inline tabs the search and the bell step aside on wide screens.
      assert has_element?(view, ~s{#global-search[class*="xl:hidden"]})
      assert has_element?(view, ~s{#notifications[class*="xl:hidden"]})
    end

    test "Ao vivo: Feed is the cockpit, Placar and Squads the leaderboard", %{
      conn: conn,
      server: server
    } do
      # The pages ask CRCON for the live match; it is not there.
      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        Req.Test.json(conn, %{"result" => nil, "failed" => true, "error" => "offline"})
      end)

      {:ok, view, _html} = live(conn, ~p"/servers/#{server}/leaderboard")

      assert has_element?(view, ~s{#section-tabs a[href="/servers/#{server.id}"]}, "Feed")
      assert has_element?(view, ~s{#section-tabs a[aria-current="page"]}, "Scoreboard")

      {:ok, view, _html} = live(conn, ~p"/servers/#{server}/leaderboard?view=squads")

      assert has_element?(view, ~s{#section-tabs a[aria-current="page"]}, "Squads")

      # The cockpit has these views in its content: no tabs in its header.
      {:ok, view, _html} = live(conn, ~p"/servers/#{server}")

      refute has_element?(view, "#section-tabs")
      assert has_element?(view, ~s{#rail-live[aria-current="page"]})
    end

    test "the scope pill counts the servers and switches keeping the page", %{conn: conn} do
      other = server_fixture(%{name: "BR #2 Eventos"})

      {:ok, view, _html} = live(conn, ~p"/rules")

      assert has_element?(view, "#header-scope-button .scope-count", "2")
      assert has_element?(view, ~s{#header-scope-menu a[href="/servers/#{other.id}"]})
    end

    test "the global search opens the palette", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#global-search[data-open-palette]")
      assert has_element?(view, "#command-palette-dialog[phx-hook=CommandPalette]")
    end
  end

  describe "command palette" do
    # Past matches come from CRCON's history, asked once per page.
    setup do
      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        match = %{
          "id" => 8841,
          "map" => %{"map" => %{"pretty_name" => "Carentan"}, "game_mode" => "warfare"},
          "start" => "2026-09-29T21:02:00Z",
          "end" => "2026-09-29T22:32:00Z",
          "result" => %{"allied" => 3, "axis" => 2}
        }

        Req.Test.json(conn, %{
          "result" => %{"maps" => [match], "total" => 1},
          "failed" => false,
          "error" => nil
        })
      end)

      :ok
    end

    test "lists the pages before anything is typed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{#command-palette-results a[href="/settings"]})
      assert has_element?(view, ~s{#command-palette-results a[href="/rules/new"]})
    end

    test "finds players, the rules that hit them and their tickets", %{
      conn: conn,
      server: server
    } do
      rule = rule_fixture(%{name: "Tanque solo", server_id: server.id})
      hit(rule, server)
      hit(rule, server)
      help = ticket(server, %{category: "Tiro amigo no tanque"})
      message(help, %{body: "é o Rudi, já matou 3 da gente"})

      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#command-palette-form") |> render_change(%{"q" => "rudi"})

      assert has_element?(view, ~s{#command-palette-results a[href="/players/#{@rudi}"]}, "Rudi")

      assert has_element?(
               view,
               ~s{#command-palette-results a[href="/rules/#{rule.id}"]},
               "Tanque solo"
             )

      assert has_element?(view, ~s{#command-palette-results a[href="/inbox?ticket=#{help.id}"]})
      assert has_element?(view, ~s{#command-palette-results [data-action="ban"]})

      view |> element(~s{button[phx-value-filter="tickets"]}) |> render_click()

      refute has_element?(view, ~s{#command-palette-results a[href="/players/#{@rudi}"]})
      assert has_element?(view, ~s{#command-palette-results a[href="/inbox?ticket=#{help.id}"]})
    end

    test "offers Ban and Message only to who may act on players", %{
      conn: conn,
      server: server
    } do
      hit(rule_fixture(%{name: "Tanque solo", server_id: server.id}), server)

      role = role_fixture(%{permissions: ["view_servers", "view_stats", "manage_tickets"]})
      agent = user_fixture(%{role: role})
      conn = Plug.Conn.put_session(conn, :user_id, agent.id)

      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#command-palette-form") |> render_change(%{"q" => "rudi"})

      assert has_element?(view, ~s{#command-palette-results a[href="/players/#{@rudi}"]}, "Rudi")
      refute has_element?(view, ~s{#command-palette-results [data-action="ban"]})
      refute has_element?(view, ~s{#command-palette-results [data-action="message"]})
    end

    test "finds past matches by map", %{conn: conn, server: server} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#command-palette-form") |> render_change(%{"q" => "carentan"})
      # The history arrives in the background.
      render_async(view)

      assert has_element?(
               view,
               ~s{#command-palette-results a[href="/servers/#{server.id}/matches/8841"]},
               "Carentan"
             )
    end

    test "a query nothing matches says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> element("#command-palette-form") |> render_change(%{"q" => "zz"})

      assert html =~ "Nothing found"
    end
  end

  describe "notifications" do
    test "the bell opens the panel and marks everything read", %{
      conn: conn,
      server: server
    } do
      ticket(server, %{inserted_at: DateTime.utc_now(:second)})

      {:ok, view, _html} = live(conn, ~p"/players")

      assert has_element?(view, "#attention-bell .attention-bell-badge", "1")

      view |> element("#attention-bell") |> render_click()

      assert has_element?(view, "#notifications-panel")
      assert has_element?(view, "#notifications-panel .notif-item.is-unread", "Rudi_88")

      view |> element("#notifications-mark-all") |> render_click()

      refute has_element?(view, "#notifications-panel .notif-item.is-unread")
      refute has_element?(view, "#attention-bell .attention-bell-badge")
    end

    test "a note that names the user is a mention", %{user: user, server: server} do
      other = user_fixture(%{name: "Ana"})
      help = ticket(server)
      message(help, %{author: :note, user_id: other.id, body: "@Marcelo confere com o feed"})
      message(help, %{author: :note, user_id: other.id, body: "sem menção"})

      items = Notifications.list(user, [server], [])

      assert [mention] = Enum.filter(items, & &1.mention?)
      assert mention.kind == :mention and mention.unread?

      Notifications.mark_read(user, [mention.key])

      refute user
             |> Notifications.list([server], [])
             |> Enum.find(& &1.mention?)
             |> Map.get(:unread?)
    end
  end

  describe "header slots" do
    import Phoenix.Component, only: [sigil_H: 2]

    test "a greeting stands in for the title on phones, an eyebrow sits above it" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <HllConditionalActionsWeb.Layouts.app
          flash={%{}}
          page_title="Primeiros passos"
          eyebrow="Briefing de um servidor novo"
          greeting="Boa noite, Marcelo"
          greeting_eyebrow="Terça, 29 de setembro"
        >
          body
        </HllConditionalActionsWeb.Layouts.app>
        """)

      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("#page-greeting h1") |> LazyHTML.text() =~ "Boa noite, Marcelo"
      assert doc |> LazyHTML.query("#page-greeting p") |> LazyHTML.text() =~ "Terça"
      assert doc |> LazyHTML.query("#page-title") |> LazyHTML.text() =~ "Primeiros passos"
      assert LazyHTML.text(doc) =~ "Briefing de um servidor novo"
    end
  end

  describe "Mais sheet" do
    test "holds the other areas, the theme and signing out", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{#more-sheet-dialog a[href="/players"]})
      assert has_element?(view, ~s{#more-sheet-dialog a[href="/settings"]})
      assert has_element?(view, ~s{#more-sheet-dialog a[href="/account"]})
      assert has_element?(view, "#more-scheme [data-scheme=light]")
      assert has_element?(view, "#more-sheet-logout")
      assert has_element?(view, ~s{#more-tab-bar-more[aria-current="page"]})
    end
  end
end
