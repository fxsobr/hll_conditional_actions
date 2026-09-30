defmodule HllConditionalActionsWeb.RuleLongConditionsTest do
  @moduledoc """
  Rules with dozens of conditions on one field stay readable: the rule
  page folds them into one chip that opens the whole list, a list that can
  never hold is flagged, the versions tab says what a version added to a
  list, and "why didn't it fire?" judges the list as one step. Shaped after
  two real rules (a K/D check plus ninety `weapon is not` rows; sixteen
  `message is` rows joined by *and*).
  """

  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Crcon.Events.Event
  alias HllConditionalActions.Engine.SavedEvents
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Audit

  setup %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, server: server_fixture()}
  end

  # 86 weapons, the first four written twice: 90 rows.
  defp weapons(count) do
    names = for n <- 1..count, do: "WEAPON #{n} [VARIANT #{n}]"
    {first, rest} = Enum.split(names, 4)
    Enum.flat_map(first, &[&1, &1]) ++ rest
  end

  defp kd_conditions(count) do
    [%{field: :kill_death_ratio, operator: :greater_than, value: "3"}] ++
      Enum.map(weapons(count), &%{field: :weapon, operator: :not_equal, value: &1})
  end

  defp kd_rule(server, count \\ 86) do
    rule_fixture(%{
      server_id: server.id,
      enabled: true,
      trigger_event: :player_team_kill,
      conditions: kd_conditions(count)
    })
  end

  defp items(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  describe "the rule page" do
    test "folds the weapon rows into one chip that opens the whole list", %{
      conn: conn,
      server: server
    } do
      rule = kd_rule(server)
      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}")

      assert has_element?(
               view,
               "#rule-sentence-text button[data-list-chip][popovertarget='rule-sentence-text-list-2']",
               "Weapon is none of 86 weapons"
             )

      assert has_element?(view, "#rule-sentence-text", "K/D ratio is greater than 3")
      # The sentence itself names two weapons; the rest wait in the popover.
      refute has_element?(view, "#rule-sentence-text > p", "WEAPON 30")
      assert has_element?(view, "#rule-sentence-text-list-2", "WEAPON 30")

      assert has_element?(view, "#rule-sentence-text-list-2[popover]")
      assert items(view, "#rule-sentence-text-list-2 li[data-filter]") == 86
      assert has_element?(view, "#rule-sentence-text-list-2 li", "2×")
      assert has_element?(view, "#rule-sentence-text-list-2-search")
    end

    test "flags equal rows joined by and as a contradiction", %{conn: conn, server: server} do
      words = ~w(vtnc desgraçado preto macaco mono mono vsf bicha sfd vtmnc a b c d e f)

      rule =
        rule_fixture(%{
          server_id: server.id,
          trigger_event: :player_chat,
          conditions: Enum.map(words, &%{field: :message_content, operator: :equal, value: &1})
        })

      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}")

      assert has_element?(view, "[role=alert]", "Contradicting conditions")
      assert has_element?(view, "[role=alert]", "These 16 conditions on Chat message")

      assert has_element?(
               view,
               "#rule-sentence-text [data-list-chip]",
               "Chat message is at the same time vtnc, desgraçado and +13"
             )
    end
  end

  describe "versions" do
    setup %{server: server} do
      rule = kd_rule(server, 22)

      {:ok, _rule} =
        Rules.update_rule(Rules.get_rule!(rule.id), %{conditions: kd_conditions(86)})

      %{rule: rule, latest: hd(Audit.list_versions(rule.id))}
    end

    test "a version that added weapons is titled by what it added", %{
      conn: conn,
      rule: rule,
      latest: latest
    } do
      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}?tab=versions")

      assert has_element?(view, "#version-row-#{latest.id}", "Weapon: +64 weapons")
      assert has_element?(view, "#version-compare", "1 field changed")

      assert has_element?(
               view,
               "#version-diff [data-list-chip][popovertarget='version-after-list-2']",
               "+64 weapons"
             )

      assert items(view, "#version-after-list-2 li[data-mark=added]") == 64
    end

    test "the overview's change card groups the list", %{conn: conn, rule: rule} do
      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}")

      assert has_element?(view, "#rule-latest-change", "changed weapon (+64 weapons)")
      assert has_element?(view, "#rule-latest-change-open-0", "+64 weapons")
      assert items(view, "#rule-latest-change-list-0 li[data-mark=added]") == 64
    end
  end

  describe "why didn't it fire" do
    test "judges the weapon list as one step and marks the weapon read", %{
      conn: conn,
      server: server
    } do
      rule = kd_rule(server)
      shooter = player(%{"name" => "Zed", "kills" => 12, "deaths" => 1})

      SavedEvents.store([
        %{
          server_id: server.id,
          trigger: :player_team_kill,
          player_id: shooter["player_id"],
          player_name: shooter["name"],
          player: shooter,
          player_profile: nil,
          gamestate: nil,
          squad: %{},
          ranks: %{},
          event: %Event{
            type: :player_team_kill,
            action: "TEAM KILL",
            occurred_at: DateTime.utc_now(),
            player_name: "Zed",
            target_player_name: "Ally",
            weapon: "WEAPON 7 [VARIANT 7]"
          },
          at: DateTime.utc_now(),
          at_us: System.os_time(:microsecond)
        }
      ])

      {:ok, view, _html} = live(conn, ~p"/rules/#{rule}?tab=why")

      view
      |> form("#why-not-form", %{why: %{player: "Zed"}})
      |> render_submit()

      assert has_element?(view, "#why-not-steps", "is none of 86 weapons")
      assert has_element?(view, "#why-not-steps", "on the list")
      assert has_element?(view, "#why-not-steps-conditions-list-2[popover]")

      assert has_element?(
               view,
               "#why-not-steps-conditions-list-2 li[data-mark=hit]",
               "WEAPON 7 [VARIANT 7]"
             )

      assert has_element?(
               view,
               "#why-not-steps-stop",
               "Weapon is none of 86 weapons, and read WEAPON 7 [VARIANT 7]"
             )
    end
  end
end
