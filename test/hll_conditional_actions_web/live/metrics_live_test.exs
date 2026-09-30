defmodule HllConditionalActionsWeb.MetricsLiveTest do
  use HllConditionalActionsWeb.ConnCase, async: false

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Metrics

  setup %{conn: conn} do
    :ok = Metrics.reset()
    conn = conn |> init_test_session(%{}) |> Plug.Conn.put_session(:user_id, user_fixture().id)
    %{conn: conn}
  end

  defp native(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  defp call(endpoint, server_id, ms, meta \\ %{}) do
    :telemetry.execute(
      [:hll_conditional_actions, :crcon, :request, :stop],
      %{duration: native(ms)},
      Map.merge(%{endpoint: endpoint, server_id: server_id, outcome: :ok, status: nil}, meta)
    )
  end

  test "renders every block of the board, empty or not", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/metrics")

    for id <- ~w(#metrics-kpis #metrics-events #metrics-rules #metrics-latency #metrics-crcon
                 #metrics-skipped #metrics-stream #metrics-refresh #metrics-reset) do
      assert has_element?(view, id)
    end

    refute has_element?(view, "#metrics-insight")
  end

  test "shows CRCON calls per endpoint, filters by server and explains a 403", %{conn: conn} do
    one = server_fixture(%{name: "BR #1 Público"})
    two = server_fixture(%{name: "BR #2 Eventos"})

    call("get_players", one.id, 40)
    call("get_players", two.id, 5_000, %{outcome: :transport_error, error: :timeout})
    call("message_player", one.id, 90, %{outcome: :unauthorized, status: 403})

    {:ok, view, _html} = live(conn, ~p"/metrics")

    assert has_element?(view, "#metrics-call-get_players", "no answer · BR #2")
    assert has_element?(view, "#metrics-call-message_player", "403 · BR #1")
    assert has_element?(view, "#metrics-insight", "can_message_players")

    view |> element("#metrics-crcon-server-#{one.id}") |> render_click()

    assert has_element?(view, "#metrics-call-message_player")
    refute has_element?(view, "#metrics-call-get_players", "no answer")
  end

  test "counts rules and skip reasons of the last hour", %{conn: conn} do
    :telemetry.execute(
      [:hll_conditional_actions, :rule, :fired],
      %{duration: native(40), count: 1},
      %{
        rule_id: 1,
        rule_name: "Boas-vindas",
        server_id: 1,
        trigger: :player_connected,
        status: :executed,
        simulation: false
      }
    )

    :telemetry.execute([:hll_conditional_actions, :rule, :skipped], %{count: 1}, %{
      rule_id: 1,
      server_id: 1,
      trigger: :player_connected,
      reason: :conditions_not_met
    })

    {:ok, view, _html} = live(conn, ~p"/metrics")

    assert has_element?(view, "#metrics-skip-conditions_not_met", "Boas-vindas")
    assert has_element?(view, "#metrics-latency", "ms")
  end

  test "shows each server's log stream, down ones with since when", %{conn: conn} do
    server = server_fixture(%{name: "BR #2 Eventos"})

    for status <- [:connecting, :connected, :error] do
      :telemetry.execute([:hll_conditional_actions, :log_stream, :status], %{count: 1}, %{
        server_id: server.id,
        status: status
      })
    end

    {:ok, view, _html} = live(conn, ~p"/metrics")

    assert has_element?(view, "#metrics-stream-#{server.id}", "down since")
    assert has_element?(view, "#metrics-stream-#{server.id}", "/ws/logs")
  end

  test "pauses, resumes and resets", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/metrics")

    view |> element("#metrics-pause") |> render_click()
    assert has_element?(view, "#metrics-refresh", "Paused")

    view |> element("#metrics-pause") |> render_click()
    refute has_element?(view, "#metrics-refresh", "Paused")

    view |> element("#metrics-reset") |> render_click()
    assert render(view) =~ "Counters reset."
  end
end
