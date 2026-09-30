defmodule HllConditionalActions.Discord.DeliveriesTest do
  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Discord
  alias HllConditionalActions.Discord.Deliveries
  alias HllConditionalActions.Discord.Webhook
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules

  doctest HllConditionalActions.Discord.Deliveries

  @url "https://discord.com/api/webhooks/123/abc"

  defp webhook_fixture(name) do
    Repo.insert!(%Webhook{name: name, url: @url, channel_label: "#" <> String.downcase(name)})
  end

  defp discord_action(webhook) do
    %{
      type: :send_discord_webhook,
      parameters: %{"webhook_id" => webhook.id, "message" => "x"}
    }
  end

  defp execution(rule, server, minutes_ago, deliveries, extra \\ %{}) do
    at = DateTime.add(DateTime.utc_now(), -minutes_ago, :minute)

    {:ok, execution} =
      Rules.record_execution(
        Map.merge(
          %{
            rule_id: rule.id,
            server_id: server.id,
            player_name: "Santos",
            trigger_event: "chat_command",
            status: :executed,
            executed_at: at
          },
          extra
        )
      )

    execution |> Ecto.Changeset.change(deliveries: deliveries) |> Repo.update!()
  end

  defp delivery(status, minutes_ago, detail \\ nil, http \\ nil) do
    at = DateTime.add(DateTime.utc_now(), -minutes_ago, :minute) |> DateTime.truncate(:second)

    %{"status" => status, "detail" => detail, "at" => DateTime.to_iso8601(at)}
    |> then(&if(http, do: Map.put(&1, "http", http), else: &1))
  end

  @not_found "Discord rejected the message with HTTP 404 (Unknown Webhook)"

  describe "summaries/1" do
    test "attributes each delivery to the webhook of the action at its index" do
      chat = webhook_fixture("Chat")
      staff = webhook_fixture("Staff")
      server = server_fixture()

      rule =
        rule_fixture(%{
          name: "Chat to Discord",
          trigger_event: :chat_command,
          conditions: [%{field: :command, operator: :equal, value: "discord"}],
          actions: [
            discord_action(chat),
            %{type: :message_player, parameters: %{"message" => "sent"}},
            discord_action(staff)
          ]
        })

      execution(
        rule,
        server,
        30,
        %{
          "0" => delivery("delivered", 30, nil, 204),
          "2" => delivery("failed", 30, @not_found, 404)
        },
        %{trace: %{"conditions" => [%{"field" => "command", "actual" => "discord"}]}}
      )

      summaries = Deliveries.summaries()

      assert [%{status: :delivered, http: 204, command: "discord", player_name: "Santos"}] =
               Deliveries.summary(summaries, chat.id).log

      assert [%{status: :failed, http: 404, rule_name: "Chat to Discord"}] =
               Deliveries.summary(summaries, staff.id).log
    end

    test "counts the failures in a row and when they started" do
      chat = webhook_fixture("Chat")
      server = server_fixture()
      rule = rule_fixture(%{actions: [discord_action(chat)]})

      execution(rule, server, 90, %{"0" => delivery("delivered", 90, nil, 204)})
      execution(rule, server, 60, %{"0" => delivery("failed", 60, @not_found)})
      execution(rule, server, 30, %{"0" => delivery("failed", 30, @not_found)})

      summary = Deliveries.summary(Deliveries.summaries(), chat.id)

      assert summary.streak == 2
      assert %{status: :failed, http: 404} = summary.last
      assert DateTime.diff(DateTime.utc_now(), summary.streak_since, :minute) in 59..61
      assert length(summary.log) == 3
    end

    test "keeps only the last seven days" do
      chat = webhook_fixture("Chat")
      server = server_fixture()
      rule = rule_fixture(%{actions: [discord_action(chat)]})

      execution(rule, server, 8 * 24 * 60, %{"0" => delivery("delivered", 8 * 24 * 60)})

      assert Deliveries.summary(Deliveries.summaries(), chat.id).log == []
    end

    test "follows the step an escalating rule ran" do
      chat = webhook_fixture("Chat")
      staff = webhook_fixture("Staff")
      server = server_fixture()
      rule = rule_fixture(%{actions: [discord_action(chat), discord_action(staff)]})

      execution(rule, server, 5, %{"0" => delivery("delivered", 5)}, %{
        trace: %{"step" => 2, "steps" => 2}
      })

      summaries = Deliveries.summaries()

      assert Deliveries.summary(summaries, chat.id).log == []
      assert [%{status: :delivered}] = Deliveries.summary(summaries, staff.id).log
    end
  end

  describe "users/0" do
    test "names the rules posting to each webhook" do
      chat = webhook_fixture("Chat")
      rule_fixture(%{name: "Chat mirror", actions: [discord_action(chat)]})

      assert [%{kind: :rule, name: "Chat mirror"}] = Map.fetch!(Deliveries.users(), chat.id)
    end
  end

  describe "record_delivery/5" do
    test "stores Discord's HTTP status with the outcome" do
      server = server_fixture()
      rule = rule_fixture()

      {:ok, execution} =
        Rules.record_execution(%{
          rule_id: rule.id,
          server_id: server.id,
          trigger_event: "player_connected",
          status: :executed
        })

      :ok = Discord.record_delivery(execution.id, 0, :delivered, nil, 204)

      assert %{"0" => %{"status" => "delivered", "http" => 204}} =
               Repo.reload!(execution).deliveries
    end
  end
end
