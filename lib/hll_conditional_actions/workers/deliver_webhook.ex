defmodule HllConditionalActions.Workers.DeliverWebhook do
  @moduledoc """
  Delivers a rule's message to a Discord webhook.

  Discord rate limits aggressively and can be briefly unavailable, neither of
  which should hold up an in-game punishment or be silently dropped. Queuing
  the delivery gives it retries while the rest of the rule runs at full speed.

  ## Pace

  The `:discord` queue runs one job at a time, which keeps the app well under
  Discord's per-webhook limit (about five requests every two seconds). When
  Discord still answers 429, the job is snoozed for exactly the wait Discord
  asked for, which does not spend one of its attempts.

  ## What it does

    * posts the payload with `wait=true` and keeps the message id when the
      action edits a message instead of posting new ones (`edit_key`);
    * posts into a thread (`thread_id`), or opens a forum thread by name the
      first time and reuses it after that (`thread_name`);
    * writes the outcome to the execution's `deliveries`, and the webhook's
      last success or error to the webhook, so both show in the UI.
  """

  use Oban.Worker, queue: :discord, max_attempts: 5

  alias HllConditionalActions.Discord
  alias HllConditionalActions.Discord.Client
  alias HllConditionalActions.Discord.Message

  # A 429 without a usable hint still waits this long before trying again.
  @default_retry_after 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_id" => webhook_id} = args} = job) do
    case Discord.get_webhook(webhook_id) do
      nil ->
        finish(job, :failed, "the webhook was removed")
        {:cancel, "webhook #{webhook_id} no longer exists"}

      webhook ->
        webhook |> deliver(args) |> outcome(job, webhook)
    end
  end

  # Jobs queued before webhooks were registered carry the URL itself.
  def perform(%Oban.Job{args: %{"url" => url, "content" => content}} = job) do
    payload = Message.limit(%{"content" => content, "allowed_mentions" => %{"parse" => []}})

    url |> Client.post(payload) |> outcome(job, nil)
  end

  @doc """
  Queues a delivery.

  ## Options

    * `:edit_key` - edit the message stored under this key instead of posting
    * `:thread_id` / `:thread_name` - post into a thread, or open a forum one
    * `:execution_id` / `:action_index` - where to record the outcome
  """
  @spec enqueue(integer(), Message.payload(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(webhook_id, payload, opts \\ []) do
    %{"webhook_id" => webhook_id, "payload" => payload}
    |> Map.merge(Map.new(opts, fn {key, value} -> {to_string(key), value} end))
    |> Map.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> new()
    |> Oban.insert()
  end

  # ── Delivery ───────────────────────────────────────────────────────────────

  defp deliver(webhook, args) do
    payload = args["payload"]
    {thread_id, payload} = thread(webhook, args, payload)

    case args["edit_key"] do
      nil -> post(webhook, payload, thread_id, args)
      key -> edit_or_post(webhook, "message:" <> key, payload, thread_id, args)
    end
  end

  # An explicit thread wins; a forum thread opened earlier under the same name
  # comes next; otherwise the post opens it.
  defp thread(_webhook, %{"thread_id" => thread_id}, payload), do: {thread_id, payload}

  defp thread(webhook, %{"thread_name" => name}, payload) do
    case Discord.get_posted(webhook.id, "thread:" <> name) do
      %{thread_id: thread_id} when is_binary(thread_id) -> {thread_id, payload}
      _none -> {nil, Map.put(payload, "thread_name", name)}
    end
  end

  defp thread(_webhook, _args, payload), do: {nil, payload}

  defp post(webhook, payload, thread_id, args) do
    response = Client.post(webhook.url, payload, thread_id: thread_id)

    with {:ok, %Req.Response{status: status, body: %{} = body}} when status in 200..299 <-
           response,
         name when is_binary(name) <- payload["thread_name"] do
      # The message that opened a forum thread lives in it: its channel is
      # the thread.
      Discord.put_posted(webhook.id, "thread:" <> name, %{thread_id: body["channel_id"]})
    end

    # A message in a thread can only be edited through that thread.
    thread_id = thread_id || (payload["thread_name"] && thread_of(response))
    remember_message(response, webhook, args, thread_id)
    response
  end

  defp remember_message(
         {:ok, %Req.Response{status: status, body: %{"id" => message_id}}},
         webhook,
         %{"edit_key" => key},
         thread_id
       )
       when status in 200..299 do
    Discord.put_posted(webhook.id, "message:" <> key, %{
      message_id: message_id,
      thread_id: thread_id
    })
  end

  defp remember_message(_response, _webhook, _args, _thread_id), do: :ok

  defp thread_of({:ok, %Req.Response{body: %{"channel_id" => channel_id}}}), do: channel_id
  defp thread_of(_response), do: nil

  # Somebody may have deleted the message on Discord; then a fresh one is
  # posted and remembered in its place.
  defp edit_or_post(webhook, key, payload, thread_id, args) do
    case Discord.get_posted(webhook.id, key) do
      %{message_id: message_id} = posted when is_binary(message_id) ->
        case Client.edit(webhook.url, message_id, payload,
               thread_id: posted.thread_id || thread_id
             ) do
          {:ok, %Req.Response{status: 404}} ->
            Discord.delete_posted(webhook.id, key)
            post(webhook, payload, thread_id, args)

          response ->
            response
        end

      _none ->
        post(webhook, payload, thread_id, args)
    end
  end

  # ── Outcome ────────────────────────────────────────────────────────────────

  defp outcome({:ok, %Req.Response{status: status}}, job, webhook) when status in 200..299 do
    if webhook, do: Discord.record_success(webhook.id)
    finish(job, :delivered, nil)
    :ok
  end

  defp outcome({:ok, %Req.Response{status: 429} = response}, _job, _webhook) do
    {:snooze, retry_after(response)}
  end

  defp outcome({:ok, %Req.Response{status: status}}, job, webhook) when status >= 500 do
    retry(job, webhook, "Discord answered with HTTP #{status}")
  end

  # Anything else is a deleted webhook or a payload that will never succeed.
  defp outcome({:ok, %Req.Response{status: status} = response}, job, webhook) do
    reason = "Discord rejected the message with HTTP #{status}#{discord_reason(response)}"
    if webhook, do: Discord.record_failure(webhook.id, reason)
    finish(job, :failed, reason)
    {:cancel, reason}
  end

  defp outcome({:error, exception}, job, webhook) do
    retry(job, webhook, Exception.message(exception))
  end

  defp retry(job, webhook, reason) do
    if job.attempt >= job.max_attempts do
      if webhook, do: Discord.record_failure(webhook.id, reason)
      finish(job, :failed, reason)
    end

    {:error, reason}
  end

  defp finish(%Oban.Job{args: args}, status, detail) do
    Discord.record_delivery(args["execution_id"], args["action_index"], status, detail)
  end

  defp discord_reason(%Req.Response{body: %{"message" => message}}) when is_binary(message),
    do: " (#{message})"

  defp discord_reason(_response), do: ""

  # Discord sends the wait both as a header (whole seconds) and in the body
  # (fractional seconds). Rounding up never retries too early.
  defp retry_after(%Req.Response{body: %{"retry_after" => seconds}}) when is_number(seconds),
    do: max(ceil(seconds), 1)

  defp retry_after(%Req.Response{} = response) do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         {seconds, _rest} <- Float.parse(value) do
      max(ceil(seconds), 1)
    else
      _missing -> @default_retry_after
    end
  end
end
