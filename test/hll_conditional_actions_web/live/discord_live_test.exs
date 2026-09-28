defmodule HllConditionalActionsWeb.DiscordLiveTest do
  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Discord
  alias HllConditionalActions.Discord.Webhook
  alias HllConditionalActions.Repo

  @url "https://discord.com/api/webhooks/123/abc"

  setup %{conn: conn} do
    user = user_fixture()
    conn = conn |> init_test_session(%{}) |> Plug.Conn.put_session(:user_id, user.id)
    %{conn: conn}
  end

  test "registers a webhook after Discord confirms it", %{conn: conn} do
    Req.Test.stub(HllConditionalActions.Discord, &Req.Test.json(&1, %{"name" => "Hook"}))
    {:ok, view, _html} = live(conn, ~p"/discord/new")
    Req.Test.allow(HllConditionalActions.Discord, self(), view.pid)

    view
    |> form("#webhook-form", webhook: %{name: "Admin log", url: @url})
    |> render_submit()

    assert [%Webhook{name: "Admin log", remote_name: "Hook"}] = Discord.list_webhooks()
  end

  test "never sends the stored URL back to the browser", %{conn: conn} do
    webhook = Repo.insert!(%Webhook{name: "Log", url: @url})

    {:ok, _view, html} = live(conn, ~p"/discord/#{webhook.id}/edit")

    refute html =~ "api/webhooks/123"
  end

  test "sends a test message", %{conn: conn} do
    webhook = Repo.insert!(%Webhook{name: "Log", url: @url})
    Req.Test.stub(HllConditionalActions.Discord, &Req.Test.json(&1, %{"id" => "1"}))

    {:ok, view, _html} = live(conn, ~p"/discord")
    Req.Test.allow(HllConditionalActions.Discord, self(), view.pid)

    assert view |> element("button", "Send a test") |> render_click() =~ "Test message sent"
    assert Discord.get_webhook(webhook.id).last_delivered_at
  end

  test "the rule builder offers the webhooks and previews the message", %{conn: conn} do
    server_fixture()
    webhook = Repo.insert!(%Webhook{name: "Admin log", url: @url})

    {:ok, view, _html} = live(conn, ~p"/rules/new")

    view
    |> form("#rule-form", rule: %{actions: %{"0" => %{type: "send_discord_webhook"}}})
    |> render_change()

    html =
      view
      |> form("#rule-form",
        rule: %{
          actions: %{
            "0" => %{
              parameters: %{webhook_id: webhook.id, embed_title: "Ban of {player_name}"}
            }
          }
        }
      )
      |> render_change()

    assert html =~ "Admin log"
    assert html =~ "Ban of {player_name}"
  end
end
