defmodule HllConditionalActionsWeb.DiscordLiveTest do
  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Discord
  alias HllConditionalActions.Discord.Webhook
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules

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

    assert view |> element("#webhook-test") |> render_click() =~ "Test message sent"
    assert Discord.get_webhook(webhook.id).last_delivered_at
  end

  test "saves the channel label and shows it in the list", %{conn: conn} do
    webhook = Repo.insert!(%Webhook{name: "Chat", url: @url})

    {:ok, view, _html} = live(conn, ~p"/discord/#{webhook.id}/edit")

    view
    |> form("#webhook-form", webhook: %{channel_label: "#chat-do-jogo"})
    |> render_submit()

    assert Discord.get_webhook(webhook.id).channel_label == "#chat-do-jogo"
    assert view |> element("#webhook-#{webhook.id}-channel") |> render() =~ "#chat-do-jogo"
  end

  test "shows only the end of the stored URL's token", %{conn: conn} do
    webhook =
      Repo.insert!(%Webhook{
        name: "Chat",
        url: "https://discord.com/api/webhooks/123/secret-k2Qx"
      })

    {:ok, view, html} = live(conn, ~p"/discord/#{webhook.id}/edit")

    assert view |> element("#webhook-url-hint") |> render() =~ "k2Qx"
    refute html =~ "secret-k2Qx"
  end

  test "opens the failing webhook with its delivery log and the streak", %{conn: conn} do
    server = server_fixture()

    ok =
      Repo.insert!(%Webhook{
        name: "Alerts",
        url: @url,
        last_delivered_at: DateTime.utc_now(:second)
      })

    failing =
      Repo.insert!(%Webhook{
        name: "Chat",
        url: @url,
        last_error: "Discord rejected the message with HTTP 404 (Unknown Webhook)",
        last_error_at: DateTime.utc_now(:second)
      })

    rule =
      rule_fixture(%{
        name: "Chat mirror",
        actions: [
          %{
            type: :send_discord_webhook,
            parameters: %{"webhook_id" => failing.id, "message" => "x"}
          }
        ]
      })

    {:ok, execution} =
      Rules.record_execution(%{
        rule_id: rule.id,
        server_id: server.id,
        player_name: "Santos",
        trigger_event: "chat_command",
        status: :executed,
        trace: %{"conditions" => [%{"field" => "command", "actual" => "discord"}]}
      })

    Discord.record_delivery(
      execution.id,
      0,
      :failed,
      "Discord rejected the message with HTTP 404 (Unknown Webhook)",
      404
    )

    {:ok, view, _html} = live(conn, ~p"/discord")

    assert has_element?(view, "#webhook-#{failing.id}[aria-current]")
    refute has_element?(view, "#webhook-#{ok.id}[aria-current]")
    assert has_element?(view, "#webhook-error")
    assert view |> element("#webhook-#{failing.id}") |> render() =~ "Chat mirror"

    log = view |> element("#delivery-log") |> render()
    assert log =~ "404"
    assert log =~ "Unknown Webhook"
    assert log =~ "!discord"
    assert log =~ "Santos"

    assert view |> element("#webhook-#{failing.id}-last") |> render() =~ "1 failure"
  end

  test "closing the editor leaves the list", %{conn: conn} do
    Repo.insert!(%Webhook{name: "Chat", url: @url})

    {:ok, view, _html} = live(conn, ~p"/discord")
    assert has_element?(view, "#webhook-editor")

    view |> element("#webhook-editor-close") |> render_click()

    refute has_element?(view, "#webhook-editor")
    assert has_element?(view, "#webhook-help")
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
