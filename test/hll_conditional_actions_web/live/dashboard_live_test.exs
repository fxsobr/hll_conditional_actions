defmodule HllConditionalActionsWeb.DashboardLiveTest do
  use HllConditionalActionsWeb.ConnCase, async: true

  import Ecto.Query
  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Features
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Rule

  setup %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, user: user}
  end

  defp record(rule, server, attrs \\ %{}) do
    {:ok, execution} =
      Rules.record_execution(
        Map.merge(
          %{
            rule_id: rule.id,
            server_id: server.id,
            player_id: "76561190000000001",
            trigger_event: "player_connected",
            status: :executed,
            trace: %{"duration_ms" => 120}
          },
          attrs
        )
      )

    execution
  end

  # CRCON answering `get_public_info` for every server.
  defp stub_public_info(info) do
    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      Req.Test.json(conn, %{"result" => info, "failed" => false, "error" => nil})
    end)
  end

  describe "first steps" do
    test "a fresh install is walked through them", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#onboarding")
      assert has_element?(view, "#onboarding-step-server[data-state=current]")
      assert has_element?(view, "#onboarding-connect")
      refute has_element?(view, "#briefing")
    end

    test "a new server gets its own, with the modules to install", %{conn: conn} do
      server_fixture(%{name: "BR #1"})
      server = server_fixture(%{name: "BR #4 Treino", features: []})

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#onboarding-title", "BR #4 Treino")
      assert has_element?(view, "#onboarding-step-modules #onboarding-modules")
      assert has_element?(view, "#onboarding-server", "BR #4 Treino")
      assert has_element?(view, "#onboarding-copy-modules", "BR #1")

      view
      |> form("#onboarding-modules", %{"modules" => ["rules", "tickets"]})
      |> render_submit()

      assert Features.installed(server.id) == MapSet.new([:rules, :tickets])
    end

    test "the modules can be copied from another server", %{conn: conn} do
      source = server_fixture(%{features: [:rules, :stats]})
      server = server_fixture(%{features: []})

      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#onboarding-copy-modules") |> render_click()

      assert Features.installed(server.id) == Features.installed(source.id)
    end

    test "an install where a rule acts for real gets the briefing", %{conn: conn} do
      server = server_fixture()
      rule_fixture(%{server_id: server.id})

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#onboarding")
      assert has_element?(view, "#briefing")
    end

    test "can be opened for one server on purpose", %{conn: conn} do
      server = server_fixture(%{name: "BR #3 Seeding"})
      rule_fixture(%{server_id: server.id})

      {:ok, view, _html} = live(conn, ~p"/?setup=#{server.id}")

      assert has_element?(view, "#onboarding-title", "BR #3 Seeding")
      assert has_element?(view, "#onboarding-step-modules[data-state=done]")
    end

    test "can be skipped for now", %{conn: conn} do
      server_fixture(%{features: []})

      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#onboarding-skip") |> render_click()

      assert_patch(view, ~p"/?onboarding=skip")
      refute has_element?(view, "#onboarding")
      assert has_element?(view, "#briefing")
    end
  end

  describe "the briefing" do
    test "shows the week and the period's numbers once rules have fired", %{conn: conn} do
      server = server_fixture()
      rule = rule_fixture(%{name: "Greeter", server_id: server.id})
      record(rule, server)

      {:ok, view, _html} = live(conn, ~p"/?onboarding=skip")

      assert has_element?(view, "#briefing-greeting")
      assert has_element?(view, "#overview-kpis #kpi-rules")
      assert has_element?(view, "#overview-kpis #kpi-players")
      assert has_element?(view, "#overview-kpis #kpi-success", "100%")
      assert has_element?(view, "#briefing-week")
      assert has_element?(view, "#overview-chart")
      refute has_element?(view, "#overview-rules")

      view |> element("#overview-period-7") |> render_click()
      assert_patch(view, ~p"/?period=7")
    end

    test "the chart switches metric and series", %{conn: conn} do
      server = server_fixture()
      rule = rule_fixture(%{server_id: server.id})
      record(rule, server)
      record(rule, server, %{status: :failed})

      {:ok, view, _html} = live(conn, ~p"/?onboarding=skip")

      assert has_element?(view, "#chart-metric-fired[aria-pressed=true]")
      assert has_element?(view, "#chart-series-all[aria-pressed=true]")

      view |> element("#chart-series-live") |> render_click()
      assert has_element?(view, "#chart-series-live[aria-pressed=true]")

      for metric <- ~w(players failed duration) do
        view |> element("#chart-metric-#{metric}") |> render_click()
        assert has_element?(view, "#chart-metric-#{metric}[aria-pressed=true]")
        assert has_element?(view, "#overview-chart")
      end

      # Only simulated fires: none here, so the chart gives way to the quiet state.
      view |> element("#chart-series-simulated") |> render_click()
      assert has_element?(view, "#overview-quiet")
    end

    test "a quiet period says so instead of drawing an empty chart", %{conn: conn} do
      server_fixture()

      {:ok, view, _html} = live(conn, ~p"/?onboarding=skip")

      assert has_element?(view, "#overview-quiet")
      refute has_element?(view, "#overview-chart")
    end

    test "each server gets a card with its match, read from CRCON", %{conn: conn} do
      stub_public_info(%{
        "player_count" => 98,
        "max_player_count" => 100,
        "player_count_by_team" => %{"allied" => 49, "axis" => 49},
        "score" => %{"allied" => 3, "axis" => 2},
        "time_remaining" => 2820.0,
        "current_map" => %{
          "map" => %{"game_mode" => "warfare", "map" => %{"pretty_name" => "Carentan"}}
        }
      })

      server = server_fixture(%{name: "BR #1 Público"})

      {:ok, view, _html} = live(conn, ~p"/?onboarding=skip")
      render_async(view)

      assert has_element?(
               view,
               "#briefing-servers #briefing-server-#{server.id}",
               "BR #1 Público"
             )

      assert has_element?(view, "#briefing-server-#{server.id}", "98/100")
      assert has_element?(view, "#briefing-server-#{server.id}", "47")
      assert has_element?(view, "#briefing-chip-#{server.id}")
      assert has_element?(view, "#kpi-players", "98")
    end

    test "a server CRCON does not answer still gets its card", %{conn: conn} do
      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        Plug.Conn.send_resp(conn, 500, "down")
      end)

      server = server_fixture()

      {:ok, view, _html} = live(conn, ~p"/?onboarding=skip")
      render_async(view)

      assert has_element?(view, "#briefing-server-#{server.id}")
      assert has_element?(view, "#kpi-players", "–")
    end

    test "what needs an admin is listed, and nothing when all is clear", %{conn: conn} do
      server = server_fixture()

      {:ok, view, _html} = live(conn, ~p"/?onboarding=skip")
      assert has_element?(view, "#briefing-attention-empty")

      rule = rule_fixture(%{name: "No squad leader", server_id: server.id})
      record(rule, server, %{status: :failed, error: "missing permission"})

      {:ok, view, _html} = live(conn, ~p"/?onboarding=skip")

      assert has_element?(view, "#briefing-attention", "No squad leader")
      assert has_element?(view, "#briefing-attention", "missing permission")
      refute has_element?(view, "#briefing-attention-empty")
      assert has_element?(view, "#overview-kpis #kpi-attention")
    end

    test "a rule that simulated long enough is put forward with what it would have done",
         %{conn: conn} do
      server = server_fixture()
      rule = rule_fixture(%{name: "Solo tank", server_id: server.id, simulation: true})

      long_ago = DateTime.utc_now() |> DateTime.add(-4, :day) |> DateTime.truncate(:second)
      Repo.update_all(from(r in Rule, where: r.id == ^rule.id), set: [inserted_at: long_ago])

      for _run <- 1..10 do
        record(rule, server, %{
          status: :simulated,
          results: [%{"type" => "message_player", "status" => "simulated", "detail" => "hi"}]
        })
      end

      {:ok, view, _html} = live(conn, ~p"/?onboarding=skip")

      assert has_element?(view, "#briefing-suggestion", "Solo tank")
      assert has_element?(view, "#briefing-suggestion", "Would have warned")
      assert has_element?(view, "#briefing-suggestion-runs", "10")
      # Lifted out of the list, not shown twice.
      refute has_element?(view, "#briefing-attention", "Solo tank")
    end
  end
end
