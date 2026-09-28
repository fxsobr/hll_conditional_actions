defmodule HllConditionalActionsWeb.RuleTestingLiveTest do
  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Engine.SavedEvents
  alias HllConditionalActions.Rules

  setup %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, user: user, server: server_fixture()}
  end

  defp save_event(server, trigger, attrs) do
    player = player(attrs)

    SavedEvents.store([
      %{
        server_id: server.id,
        trigger: trigger,
        player_id: player["player_id"],
        player_name: player["name"],
        player: player,
        player_profile: nil,
        gamestate: nil,
        squad: %{},
        ranks: %{},
        event: nil,
        at: DateTime.utc_now(),
        at_us: System.os_time(:microsecond)
      }
    ])

    hd(SavedEvents.list([server.id], trigger: trigger, limit: 1))
  end

  test "try it judges the rule as typed against a saved event, and edits apply", %{
    conn: conn,
    server: server
  } do
    rule =
      rule_fixture(%{
        server_id: server.id,
        conditions: [%{field: :player_level, operator: :greater_than, value: "50"}],
        actions: [%{type: :message_player, parameters: %{"message" => "Hi {player_name}"}}]
      })

    saved = save_event(server, :player_connected, %{"name" => "Zed", "level" => 42})

    {:ok, view, _html} = live(conn, ~p"/rules/#{rule}/edit")

    html =
      view
      |> form("#try-it-event-picker", %{event_id: saved.id})
      |> render_change()

    assert html =~ "would not fire for Zed"
    assert html =~ "Hi Zed"

    html =
      view
      |> form("#try-it-fields", %{player: %{level: "60"}})
      |> render_change()

    assert html =~ "would fire for Zed"
  end

  test "why didn't it fire explains each saved event of a player", %{conn: conn, server: server} do
    rule =
      rule_fixture(%{
        server_id: server.id,
        conditions: [%{field: :player_level, operator: :greater_than, value: "50"}]
      })

    save_event(server, :player_connected, %{"name" => "Zed", "level" => 42})

    {:ok, view, _html} = live(conn, ~p"/rules/#{rule}?tab=why")

    html =
      view
      |> form("#why-not-form", %{why: %{player: "Zed"}})
      |> render_submit()

    assert html =~ "Condition failed"
    assert html =~ "42"
  end

  test "the simulator lists the rules that would answer and flags conflicts", %{
    conn: conn,
    server: server
  } do
    rule_fixture(%{
      name: "Kick TK",
      trigger_event: :player_team_kill,
      actions: [%{type: :kick_player, parameters: %{"reason" => "TK"}}]
    })

    rule_fixture(%{
      name: "Warn TK",
      trigger_event: :player_team_kill,
      actions: [%{type: :message_player, parameters: %{"message" => "Careful"}}]
    })

    {:ok, view, html} = live(conn, ~p"/rules/simulate")
    assert html =~ "Event simulator"

    html =
      view
      |> form("#simulate-setup", %{server_id: server.id, trigger: "player_team_kill"})
      |> render_change()

    assert html =~ "Kick TK"
    assert html =~ "Warn TK"
    assert html =~ "never read"
  end

  describe "recipe wizard" do
    test "creates the answered rule in simulation", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/rules/new?recipe=team_kill_ladder")
      assert html =~ "In one sentence"

      html =
        view
        |> form("#recipe-wizard-form", %{answers: %{limit: "3", final_action: "kick_player"}})
        |> render_change()

      assert html =~ "team kill number 3"

      view
      |> form("#recipe-wizard-form", %{answers: %{limit: "3", final_action: "kick_player"}})
      |> render_submit()

      assert [rule] = Rules.list_rules()
      assert rule.simulation
      assert Enum.map(rule.actions, & &1.type) == [:message_player, :punish_player, :kick_player]
    end

    test "customize opens the full builder pre-filled", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rules/new?recipe=welcome")

      view
      |> form("#recipe-wizard-form", %{answers: %{message: "Olá {player_name}"}})
      |> render_change()

      view |> element("button", "Customize") |> render_click()
      # The wizard hands the answers to the page, which renders the builder.
      html = render(view)
      assert html =~ "Save rule"
      assert html =~ "Olá {player_name}"
    end
  end

  test "the empty rules list leads with the recipes", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/rules")
    assert html =~ "Popular starting points"
    assert html =~ "/rules/new?recipe=team_kill_ladder"
  end
end
