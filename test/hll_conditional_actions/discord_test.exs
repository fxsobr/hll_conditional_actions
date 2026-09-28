defmodule HllConditionalActions.DiscordTest do
  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Discord
  alias HllConditionalActions.Discord.Message
  alias HllConditionalActions.Discord.Webhook
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Action
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Rules.Transfer

  doctest HllConditionalActions.Discord.Message
  doctest HllConditionalActions.Discord.Webhook

  @url "https://discord.com/api/webhooks/123/abc"

  defp stub(fun), do: Req.Test.stub(HllConditionalActions.Discord, fun)

  defp webhook_fixture(name \\ "Log") do
    Repo.insert!(%Webhook{name: name, url: @url})
  end

  describe "create_webhook/1" do
    test "asks Discord about the webhook and keeps what it says" do
      stub(fn conn ->
        assert conn.method == "GET"
        Req.Test.json(conn, %{"name" => "Captain Hook", "channel_id" => "1", "guild_id" => "2"})
      end)

      assert {:ok, webhook} = Discord.create_webhook(%{"name" => "Log", "url" => @url})
      assert webhook.remote_name == "Captain Hook"
      assert webhook.channel_id == "1"
    end

    test "refuses a webhook Discord does not know" do
      stub(&(&1 |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Unknown Webhook"})))

      assert {:error, changeset} = Discord.create_webhook(%{"name" => "Log", "url" => @url})
      assert %{url: ["Discord does not know this webhook"]} = errors_on(changeset)
    end

    test "saves it anyway, with the error, when Discord cannot be reached" do
      stub(&Req.Test.transport_error(&1, :econnrefused))

      assert {:ok, webhook} = Discord.create_webhook(%{"name" => "Log", "url" => @url})
      assert webhook.last_error
    end

    test "only accepts Discord webhook URLs" do
      for url <- [
            "http://discord.com/api/webhooks/1/x",
            "https://evil.com/api/webhooks/1/x",
            "https://discord.com.evil.com/api/webhooks/1/x",
            "https://discord.com:8443/api/webhooks/1/x",
            "https://discord.com/api/users/@me",
            "https://a@discord.com/api/webhooks/1/x"
          ] do
        assert {:error, changeset} = Discord.create_webhook(%{"name" => "Log", "url" => url})
        assert %{url: [_message]} = errors_on(changeset), url
      end
    end

    test "stores the URL encrypted" do
      webhook = webhook_fixture()

      %{rows: [[raw]]} =
        Repo.query!("SELECT url FROM discord_webhooks WHERE id = $1", [webhook.id])

      refute raw =~ "discord.com"
      assert Discord.get_webhook(webhook.id).url == @url
    end
  end

  describe "delete_webhook/1" do
    test "refuses while a rule posts to it" do
      webhook = webhook_fixture()

      rule_fixture(%{
        actions: [
          %{
            type: :send_discord_webhook,
            parameters: %{"webhook_id" => webhook.id, "message" => "x"}
          }
        ]
      })

      assert Discord.delete_webhook(webhook) == {:error, :in_use}
    end
  end

  describe "the action" do
    test "needs a registered webhook and something to send" do
      changeset = Action.changeset(%Action{}, %{type: :send_discord_webhook, parameters: %{}})

      messages = Enum.map(changeset.errors, fn {_key, {message, _opts}} -> message end)
      assert "%{param} is required" in messages
      assert "a Discord message needs a text or an embed" in messages

      changeset =
        Action.changeset(%Action{}, %{
          type: :send_discord_webhook,
          parameters: %{"webhook_id" => "999999", "embed_title" => "Hi", "embed_color" => "red"}
        })

      messages = Enum.map(changeset.errors, fn {_key, {message, _opts}} -> message end)
      assert "%{param} must be a registered Discord webhook" in messages
      assert "%{param} must be a colour like #5865F2" in messages
    end
  end

  describe "Message.build/3" do
    defp identity(template), do: template || ""

    test "keeps mentions off except for the roles listed" do
      payload =
        Message.build(
          %{
            "message" => "@everyone <@&123456789012345678>",
            "mention_role_ids" => "123456789012345678"
          },
          &identity/1
        )

      assert payload["allowed_mentions"] == %{"parse" => [], "roles" => ["123456789012345678"]}
    end

    test "builds an embed with fields, colour and silent flag" do
      payload =
        Message.build(
          %{
            "embed_title" => "Match over",
            "embed_fields" => "Kills | 12\nDeaths | ",
            "embed_color" => "#FF0000",
            "embed_timestamp" => "false",
            "silent" => "true"
          },
          &identity/1
        )

      assert [embed] = payload["embeds"]
      assert embed["color"] == 0xFF0000

      assert [%{"name" => "Kills", "value" => "12"}, %{"name" => "Deaths", "value" => "​"}] =
               embed["fields"]

      refute Map.has_key?(embed, "timestamp")
      assert payload["flags"] == 4096
      refute Map.has_key?(payload, "content")
    end

    test "cuts every part to Discord's limits" do
      long = String.duplicate("a", 7000)

      payload =
        Message.build(
          %{
            "message" => long,
            "embed_title" => long,
            "embed_description" => long,
            "embed_fields" =>
              Enum.map_join(1..30, "\n", &"F#{&1} | #{String.duplicate("b", 1100)}")
          },
          &identity/1
        )

      [embed] = payload["embeds"]
      assert String.length(payload["content"]) == 2000
      assert String.length(embed["title"]) == 256
      # 25 is the cap, but 25 full values would pass the 6000 shared by the
      # whole embed, so the last ones give way.
      assert length(embed["fields"]) in 1..25
      assert Enum.all?(embed["fields"], &(String.length(&1["value"]) <= 1024))

      total =
        [embed["title"], embed["description"]] ++
          Enum.flat_map(embed["fields"], &[&1["name"], &1["value"]])

      assert total |> Enum.map(&String.length/1) |> Enum.sum() <= 6000
    end

    test "joins aggregated lines into the embed" do
      payload = Message.build(%{"embed_title" => "Top"}, &identity/1, lines: ["Ana", "Bo"])

      assert [%{"description" => "Ana\nBo"}] = payload["embeds"]
    end
  end

  describe "adopt_legacy_urls/0" do
    test "moves URLs out of the actions into encrypted webhooks, one per URL" do
      legacy = fn url ->
        %Action{
          type: :send_discord_webhook,
          parameters: %{"webhook_url" => url, "message" => "hi"}
        }
      end

      rules =
        for url <- [@url, @url, "https://discord.com/api/webhooks/9/z"] do
          rule = rule_fixture()

          rule
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.put_embed(:actions, [legacy.(url)])
          |> Repo.update!()
        end

      assert :ok = Discord.adopt_legacy_urls()

      ids =
        for rule <- rules do
          [action] = Repo.get!(Rule, rule.id).actions
          refute Map.has_key?(action.parameters, "webhook_url")
          action.parameters["webhook_id"]
        end

      assert [same, same, other] = ids
      assert same != other
      assert Discord.get_webhook(same).url == @url
      assert Discord.adopt_legacy_urls() == :ok
    end
  end

  describe "export and import" do
    test "carry the webhook's name, never its URL" do
      webhook = webhook_fixture("Admin log")

      rule =
        rule_fixture(%{
          actions: [
            %{
              type: :send_discord_webhook,
              parameters: %{"webhook_id" => webhook.id, "message" => "x"}
            }
          ]
        })

      json = Transfer.encode([rule])
      refute json =~ "discord.com"
      assert json =~ "Admin log"

      assert {:ok, [imported]} = Rules.import_rules(json)
      assert [%{parameters: %{"webhook_id" => id}}] = imported.actions
      assert id == webhook.id
    end
  end
end
