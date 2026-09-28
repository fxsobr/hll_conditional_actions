defmodule HllConditionalActions.Engine.DiscordActionTest do
  use HllConditionalActions.DataCase, async: false

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Discord.Webhook
  alias HllConditionalActions.Engine
  alias HllConditionalActions.Engine.Snapshot
  alias HllConditionalActions.Repo

  setup do
    webhook = Repo.insert!(%Webhook{name: "Log", url: "https://discord.com/api/webhooks/1/a"})
    %{server: server_fixture(), webhook: webhook}
  end

  defp jobs do
    Repo.all(
      from j in Oban.Job, where: j.worker == "HllConditionalActions.Workers.DeliverWebhook"
    )
  end

  defp snapshot do
    %Snapshot{
      players: %{
        "1" => player(%{"player_id" => "1", "name" => "*Ana*"}),
        "2" => player(%{"player_id" => "2", "name" => "Bo"})
      },
      gamestate: gamestate(),
      stale?: false
    }
  end

  defp discord(webhook, parameters) do
    %{type: :send_discord_webhook, parameters: Map.put(parameters, "webhook_id", webhook.id)}
  end

  test "queues the rendered payload, escaping values from players", %{
    server: server,
    webhook: webhook
  } do
    rule =
      rule_fixture(%{
        trigger_event: :match_end,
        actions: [discord(webhook, %{"message" => "**GG** {player_name}"})]
      })

    Engine.process_batch_trigger(server, [rule], :match_end, snapshot: snapshot())

    # Server wide: once per sweep, not once per player.
    assert [job] = jobs()
    assert job.args["payload"]["content"] =~ ~r/^\*\*GG\*\* /
    assert job.args["execution_id"]
    assert job.args["action_index"] == 0
  end

  test "gathers the whole sweep into one message when asked", %{
    server: server,
    webhook: webhook
  } do
    rule =
      rule_fixture(%{
        trigger_event: :match_end,
        actions: [
          discord(webhook, %{
            "message" => "{player_name}",
            "embed_title" => "Players",
            "aggregate" => "true"
          })
        ]
      })

    Engine.process_batch_trigger(server, [rule], :match_end, snapshot: snapshot())

    assert [job] = jobs()
    [embed] = job.args["payload"]["embeds"]
    lines = embed["description"] |> String.split("\n") |> Enum.sort()
    assert lines == ["Bo", "\\*Ana\\*"]
  end

  test "keys an edited message by rule and server", %{server: server, webhook: webhook} do
    rule =
      rule_fixture(%{
        trigger_event: :match_end,
        actions: [discord(webhook, %{"message" => "score", "mode" => "edit"})]
      })

    Engine.process_batch_trigger(server, [rule], :match_end, snapshot: snapshot())

    assert [job] = jobs()
    assert job.args["edit_key"] == "rule:#{rule.id}:server:#{server.id}"
  end
end
