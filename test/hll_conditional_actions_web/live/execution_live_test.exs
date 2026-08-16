defmodule HllConditionalActionsWeb.ExecutionLiveTest do
  @moduledoc """
  The history is the page that grows without bound, so what matters is that
  it shows one page at a time, says how much there is, and does not move
  under somebody who is reading page two.
  """

  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Rules

  @per_page 50

  setup %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    server = server_fixture()
    rule = rule_fixture(%{name: "Greeter", server_id: server.id})

    %{conn: conn, user: user, server: server, rule: rule}
  end

  defp record(rule, server, index) do
    {:ok, execution} =
      Rules.record_execution(%{
        rule_id: rule.id,
        server_id: server.id,
        player_id: "7656119#{index}",
        player_name: "Player #{index}",
        trigger_event: "player_connected",
        status: :executed,
        # Newest first, so a higher index is more recent.
        executed_at: DateTime.add(DateTime.utc_now(), -1000 + index, :second)
      })

    execution
  end

  defp record_many(rule, server, count) do
    for index <- 1..count, do: record(rule, server, index)
  end

  describe "paging" do
    test "shows only the first page, and says how many there are", %{
      conn: conn,
      rule: rule,
      server: server
    } do
      record_many(rule, server, @per_page + 10)

      {:ok, _view, html} = live(conn, ~p"/executions")

      assert html =~ "Player 60"
      refute html =~ "Player 10<"
      assert html =~ "60"
    end

    test "the second page holds the rest", %{conn: conn, rule: rule, server: server} do
      record_many(rule, server, @per_page + 3)

      {:ok, view, _html} = live(conn, ~p"/executions")

      html = view |> element(~s(button[phx-click=page][aria-label="Page 2"])) |> render_click()

      # The oldest three rows are the ones that spilled onto page two. The id
      # is matched rather than the name, because "Player 1" is a prefix of
      # "Player 10".
      assert html =~ ~s(href="/players/76561191")
      refute html =~ "Player 53"
    end

    test "no paging controls when everything fits on one page", %{
      conn: conn,
      rule: rule,
      server: server
    } do
      record_many(rule, server, 3)

      {:ok, _view, html} = live(conn, ~p"/executions")

      refute html =~ ~s(phx-click="page")
    end

    test "filtering returns to the first page", %{conn: conn, rule: rule, server: server} do
      record_many(rule, server, @per_page + 5)

      {:ok, view, _html} = live(conn, ~p"/executions")

      view |> element(~s(button[phx-click=page][aria-label="Page 2"])) |> render_click()

      html =
        view
        |> form("#execution-filters", %{server_id: to_string(server.id)})
        |> render_change()

      # Back on page one, so the newest row is visible again.
      assert html =~ "Player 55"
    end

    test "a page number beyond the end lands on the last page with rows", %{
      conn: conn,
      rule: rule,
      server: server
    } do
      record_many(rule, server, 3)

      {:ok, view, _html} = live(conn, ~p"/executions")

      html = render_click(view, "page", %{"page" => "9"})

      assert html =~ "Player 3"
    end

    test "a page that is not a number is treated as the first", %{
      conn: conn,
      rule: rule,
      server: server
    } do
      record_many(rule, server, 3)

      {:ok, view, _html} = live(conn, ~p"/executions")

      assert render_click(view, "page", %{"page" => "nonsense"}) =~ "Player 3"
    end
  end

  describe "live updates" do
    test "a new execution appears while page one is open", %{
      conn: conn,
      rule: rule,
      server: server
    } do
      record_many(rule, server, 2)

      {:ok, view, _html} = live(conn, ~p"/executions")

      send(view.pid, {:rule_fired, record(rule, server, 999)})

      assert render(view) =~ "Player 999"
    end

    test "but not while a later page is being read", %{conn: conn, rule: rule, server: server} do
      record_many(rule, server, @per_page + 2)

      {:ok, view, _html} = live(conn, ~p"/executions")
      view |> element(~s(button[phx-click=page][aria-label="Page 2"])) |> render_click()

      send(view.pid, {:rule_fired, record(rule, server, 999)})

      refute render(view) =~ "Player 999"
    end
  end

  describe "Rules.count_executions_for/2" do
    test "counts the whole set, not the page", %{rule: rule, server: server} do
      record_many(rule, server, 12)

      assert Rules.count_executions_for(nil, limit: 5) == 12
    end

    test "respects the filters", %{rule: rule, server: server} do
      record_many(rule, server, 4)
      other = server_fixture()
      other_rule = rule_fixture(%{server_id: other.id})
      record(other_rule, other, 1)

      assert Rules.count_executions_for(nil, server_id: server.id) == 4
    end

    test "counts nothing when nothing matches", %{rule: rule, server: server} do
      record_many(rule, server, 4)

      assert Rules.count_executions_for(nil, status: :failed) == 0
    end
  end
end
