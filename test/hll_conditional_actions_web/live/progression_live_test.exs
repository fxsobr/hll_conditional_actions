defmodule HllConditionalActionsWeb.ProgressionLiveTest do
  use HllConditionalActionsWeb.ConnCase, async: false

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Progression

  setup %{conn: conn} do
    # The forms read the match history for their previews, from a task.
    Req.Test.set_req_test_to_shared()

    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      Req.Test.json(conn, %{"result" => %{"maps" => [], "total" => 0}, "failed" => false})
    end)

    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, server: server_fixture(%{name: "EU #1"})}
  end

  describe "achievements" do
    test "the old address opens the first server's", %{conn: conn, server: server} do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/achievements")
      assert to == "/servers/#{server.id}/achievements"
    end

    test "an empty gallery offers the starter set", %{conn: conn, server: server} do
      {:ok, view, _html} = live(conn, ~p"/servers/#{server}/achievements")

      view |> element("#starter-set button") |> render_click()

      assert has_element?(view, "#achievements li", "Sharpshooter")
      assert has_element?(view, "#achievements li", "Simulation")
      assert has_element?(view, "#starter-set", "12")
    end

    test "the gallery filters by tier and scope", %{conn: conn, server: server} do
      Progression.create_starter_set(server.id)
      {:ok, view, _html} = live(conn, ~p"/servers/#{server}/achievements")

      assert has_element?(view, "#tier-legendary", "2")
      view |> element("#tier-legendary") |> render_click()
      assert has_element?(view, "#achievements li", "Regular")
      refute has_element?(view, "#achievements li", "Sharpshooter")

      view |> element("#tier-all") |> render_click()
      view |> element("#achievement-scope button", "Over the career") |> render_click()
      assert has_element?(view, "#achievements li", "Veteran")
      refute has_element?(view, "#achievements li", "Sharpshooter")
    end

    test "creating one, for the server", %{conn: conn, server: server} do
      {:ok, view, _html} = live(conn, ~p"/servers/#{server}/achievements/new")

      assert has_element?(view, "#achievement-preview")
      assert has_element?(view, "#achievement-game-message")

      view
      |> form("#achievement-form",
        achievement: %{
          name: "Iron wall",
          scope: "match",
          metric: "defense",
          threshold: "2000",
          tier: "gold",
          reward_vip_hours: "24"
        }
      )
      |> render_submit()

      assert_redirect(view, ~p"/servers/#{server}/achievements")

      {:ok, view, _html} = live(conn, ~p"/servers/#{server}/achievements")
      assert has_element?(view, "#achievements li", "Iron wall")
      assert has_element?(view, "#achievements li", "+24 h VIP")
      assert [%{server_id: server_id}] = Progression.list_achievements(server.id)
      assert server_id == server.id

      other = server_fixture(%{name: "US #1"})
      assert Progression.list_achievements(other.id) == []
    end
  end

  describe "seasons" do
    test "starting one with its own length and number of winners", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/seasons/new")

      # The start reads as the board writes it, over the native picker.
      view |> form("#season-form", season: %{starts_at: "2026-10-17T00:00"}) |> render_change()
      assert has_element?(view, "#season-starts-at-text", "17 oct, 00:00")

      # The stat picker only shows for a sum or an average.
      view |> form("#season-form", season: %{scoring: "sum"}) |> render_change()

      view
      |> form("#season-form",
        season: %{
          name: "Winter cup",
          metric: "support",
          duration_days: "14",
          winners_count: "5",
          min_matches: "3",
          reward_vip_hours: "72"
        }
      )
      |> render_submit()

      assert [%{name: "Winter cup", duration_days: 14, winners_count: 5} = season] =
               Progression.list_seasons()

      assert DateTime.diff(season.ends_at, season.starts_at, :day) == 14

      {path, _flash} = assert_redirect(view)
      assert path == "/seasons/#{season.id}"
    end

    test "a combined season from the formula rows, per match", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/seasons/new")

      assert has_element?(view, "#season-formula-editor")
      view |> element("#season-add-metric") |> render_click()

      view
      |> form("#season-form",
        season: %{
          name: "Autumn",
          formula: %{
            "0" => %{"metric" => "combat", "weight" => "1"},
            "1" => %{"metric" => "support", "weight" => "0,5"}
          }
        }
      )
      |> render_submit()

      assert [%{scoring: :weighted, per_match: true, weights: weights}] =
               Progression.list_seasons()

      assert weights["combat"] == 1
      assert weights["support"] == 0.5
    end

    test "a rating season across two servers", %{conn: conn, server: server} do
      other = server_fixture(%{name: "EU #2"})
      {:ok, view, _html} = live(conn, ~p"/seasons/new")

      view
      |> form("#season-form",
        season: %{name: "League", server_ids: ["", server.id, other.id], scoring: "elo"}
      )
      |> render_submit()

      assert [%{name: "League", game: :hll, rating: %{"preset" => "balanced"}} = season] =
               Progression.list_seasons()

      assert season.servers |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([server.id, other.id])

      {:ok, show, _html} = live(conn, ~p"/seasons/#{season.id}")
      assert has_element?(show, "#rating-summary")
    end

    test "the season page shows the podium and the prize line", %{conn: conn, server: server} do
      {:ok, season} =
        Progression.create_season(%{
          name: "Season 1",
          server_id: server.id,
          metric: :kills,
          duration_days: 7,
          winners_count: 1,
          min_matches: 1
        })

      Progression.record_match(server, %{
        "a" => player(%{"player_id" => "a", "name" => "Ana", "kills" => 30}),
        "b" => player(%{"player_id" => "b", "name" => "Bo", "kills" => 10})
      })

      {:ok, view, _html} = live(conn, ~p"/seasons/#{season.id}")

      assert has_element?(view, "#season-podium", "Ana")
      assert has_element?(view, "#season-standings", "Bo")
      assert has_element?(view, "#prize-line")
      assert has_element?(view, "#season-formula")

      {:ok, index, _html} = live(conn, ~p"/seasons")
      assert has_element?(index, "#season-name", "Season 1")
    end

    test "editing a season", %{conn: conn, server: server} do
      {:ok, season} =
        Progression.create_season(%{
          name: "Season 1",
          server_id: server.id,
          metric: :kills,
          duration_days: 7
        })

      {:ok, view, _html} = live(conn, ~p"/seasons/#{season.id}/edit")

      view
      |> form("#season-form", season: %{name: "Season one", reward_vip_hours: "48"})
      |> render_submit()

      assert_redirect(view, ~p"/seasons/#{season.id}")
      assert %{name: "Season one", reward_vip_hours: 48} = Progression.get_season!(season.id)
    end
  end
end
