defmodule HllConditionalActions.Workers.DeliverWebhookTest do
  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Discord
  alias HllConditionalActions.Discord.Webhook
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Workers.DeliverWebhook

  @url "https://discord.com/api/webhooks/123/abc"

  setup do
    Req.Test.verify_on_exit!()
    %{webhook: Repo.insert!(%Webhook{name: "Log", url: @url})}
  end

  defp perform(args) do
    DeliverWebhook.perform(%Oban.Job{args: stringify(args), attempt: 1, max_attempts: 5})
  end

  defp stringify(args), do: args |> Jason.encode!() |> Jason.decode!()

  defp expect(fun), do: Req.Test.expect(HllConditionalActions.Discord, fun)

  defp respond(conn, status, body \\ %{}) do
    conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
  end

  defp body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  defp args(webhook, extra \\ %{}) do
    Map.merge(%{webhook_id: webhook.id, payload: %{"content" => "hello"}}, extra)
  end

  describe "posting" do
    test "posts with wait=true and records the success", %{webhook: webhook} do
      expect(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/webhooks/123/abc"
        assert conn.query_string =~ "wait=true"
        {payload, conn} = body(conn)
        assert payload["content"] == "hello"
        respond(conn, 200, %{"id" => "900"})
      end)

      assert perform(args(webhook)) == :ok
      assert Discord.get_webhook(webhook.id).last_delivered_at
    end

    test "writes the outcome to the execution", %{webhook: webhook} do
      server = server_fixture()
      rule = rule_fixture()

      {:ok, execution} =
        Rules.record_execution(%{
          rule_id: rule.id,
          server_id: server.id,
          trigger_event: "player_connected",
          status: :executed
        })

      expect(&respond(&1, 400, %{"message" => "Invalid Form Body"}))

      assert {:cancel, reason} =
               perform(args(webhook, %{execution_id: execution.id, action_index: 1}))

      assert reason =~ "Invalid Form Body"

      assert %{"1" => %{"status" => "failed", "detail" => ^reason}} =
               Repo.reload!(execution).deliveries

      assert Discord.get_webhook(webhook.id).last_error == reason
    end

    test "cancels when the webhook was removed" do
      assert {:cancel, _reason} = perform(%{webhook_id: -1, payload: %{"content" => "x"}})
    end

    test "still delivers jobs queued with a bare URL" do
      expect(fn conn ->
        {payload, conn} = body(conn)
        assert payload["allowed_mentions"] == %{"parse" => []}
        respond(conn, 204)
      end)

      assert perform(%{url: @url, content: "old job"}) == :ok
    end
  end

  describe "rate limits and failures" do
    test "snoozes for the retry_after Discord asks on 429", %{webhook: webhook} do
      expect(&respond(&1, 429, %{"retry_after" => 1.2, "global" => false}))
      assert perform(args(webhook)) == {:snooze, 2}
    end

    test "falls back to the Retry-After header on 429", %{webhook: webhook} do
      expect(fn conn ->
        conn |> Plug.Conn.put_resp_header("retry-after", "7") |> Plug.Conn.send_resp(429, "")
      end)

      assert perform(args(webhook)) == {:snooze, 7}
    end

    test "retries server errors", %{webhook: webhook} do
      expect(&respond(&1, 502))
      assert {:error, _reason} = perform(args(webhook))
    end
  end

  describe "editing" do
    test "posts the first time and edits the same message after", %{webhook: webhook} do
      expect(fn conn ->
        assert conn.method == "POST"
        respond(conn, 200, %{"id" => "900", "channel_id" => "55"})
      end)

      assert perform(args(webhook, %{edit_key: "score"})) == :ok
      assert Discord.get_posted(webhook.id, "message:score").message_id == "900"

      expect(fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/api/webhooks/123/abc/messages/900"
        {payload, conn} = body(conn)
        refute Map.has_key?(payload, "username")
        respond(conn, 200, %{"id" => "900"})
      end)

      assert perform(args(webhook, %{edit_key: "score"})) == :ok
    end

    test "posts anew when the message was deleted on Discord", %{webhook: webhook} do
      Discord.put_posted(webhook.id, "message:score", %{message_id: "900"})

      expect(fn conn ->
        assert conn.method == "PATCH"
        respond(conn, 404, %{"message" => "Unknown Message"})
      end)

      expect(fn conn ->
        assert conn.method == "POST"
        respond(conn, 200, %{"id" => "901"})
      end)

      assert perform(args(webhook, %{edit_key: "score"})) == :ok
      assert Discord.get_posted(webhook.id, "message:score").message_id == "901"
    end
  end

  describe "threads" do
    test "opens a forum thread once and posts into it after", %{webhook: webhook} do
      expect(fn conn ->
        {payload, conn} = body(conn)
        assert payload["thread_name"] == "Carentan"
        respond(conn, 200, %{"id" => "900", "channel_id" => "777"})
      end)

      assert perform(args(webhook, %{thread_name: "Carentan"})) == :ok

      expect(fn conn ->
        assert conn.query_string =~ "thread_id=777"
        {payload, conn} = body(conn)
        refute Map.has_key?(payload, "thread_name")
        respond(conn, 200, %{"id" => "901", "channel_id" => "777"})
      end)

      assert perform(args(webhook, %{thread_name: "Carentan"})) == :ok
    end

    test "posts into a given thread", %{webhook: webhook} do
      expect(fn conn ->
        assert conn.query_string =~ "thread_id=42"
        respond(conn, 200, %{"id" => "900"})
      end)

      assert perform(args(webhook, %{thread_id: "42"})) == :ok
    end
  end
end
