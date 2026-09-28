defmodule HllConditionalActionsWeb.AttentionLiveTest do
  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Attention
  alias HllConditionalActions.Rules

  setup %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    server = server_fixture(%{name: "EU #1"})
    %{conn: conn, user: user, server: server}
  end

  defp record(rule, server, attrs) do
    {:ok, execution} =
      Rules.record_execution(
        Map.merge(
          %{
            rule_id: rule.id,
            server_id: server.id,
            player_id: "76561190000000001",
            player_name: "Chris",
            trigger_event: "vehicle_destroyed",
            status: :executed
          },
          attrs
        )
      )

    execution
  end

  test "an empty inbox says all clear", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/attention")
    assert html =~ "All clear"
  end

  test "a player a rule put on the watchlist waits for review, until handled", %{
    conn: conn,
    server: server
  } do
    rule = rule_fixture(%{name: "HQ guard", server_id: server.id})

    execution =
      record(rule, server, %{
        results: [
          %{"type" => "add_to_watchlist", "status" => "ok", "detail" => "Check the HQ vehicle"}
        ]
      })

    {:ok, view, _html} = live(conn, ~p"/attention")

    item = "#attention-review-#{execution.id}"
    assert has_element?(view, item, "Review Chris")
    assert has_element?(view, item, "Check the HQ vehicle")
    # The header's bell counts it as unread.
    assert has_element?(view, "#attention-bell .attention-bell-badge", "1")

    view |> element("#{item} button[phx-click=resolve]") |> render_click()

    refute has_element?(view, item)
    refute has_element?(view, "#attention-bell .attention-bell-badge")
    assert has_element?(view, "#attention-kpis", "1")
  end

  test "the bell counts a new item without a reload", %{conn: conn, server: server} do
    {:ok, view, _html} = live(conn, ~p"/rules")
    refute has_element?(view, "#attention-bell .attention-bell-badge")

    rule = rule_fixture(%{name: "HQ guard", server_id: server.id})

    record(rule, server, %{
      results: [%{"type" => "add_to_watchlist", "status" => "ok", "detail" => "Check it"}]
    })

    HllConditionalActions.Attention.notify_changed()
    # The recount waits a second to gather bursts; skip the wait.
    send(view.pid, :recount_attention)

    assert has_element?(view, "#attention-bell .attention-bell-badge", "1")
  end

  test "failures come back when the rule fails again", %{user: user, server: server} do
    rule = rule_fixture(%{name: "Kicker", server_id: server.id})
    record(rule, server, %{status: :failed, error: "Player not found"})

    %{open: [first]} = Attention.items(user, [server], %{})
    assert first.kind == :failures
    Attention.resolve(first.key, user)

    assert %{open: [], handled: 1} = Attention.items(user, [server], %{})

    record(rule, server, %{status: :failed, error: "Player not found"})

    assert %{open: [%{kind: :failures, subject: %{count: 2}}]} =
             Attention.items(user, [server], %{})
  end

  test "a stream in error is urgent", %{user: user, server: server} do
    assert %{open: [%{kind: :stream_down, severity: :error}]} =
             Attention.items(user, [server], %{server.id => {:error, "502 Bad Gateway"}})
  end
end
