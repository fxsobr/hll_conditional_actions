defmodule HllConditionalActions.Workers.DeliverWebhook do
  @moduledoc """
  Posts a rule's message to a Discord webhook.

  Discord rate limits aggressively and can be briefly unavailable, neither of
  which should hold up an in-game punishment or be silently dropped. Queuing
  the delivery gives it retries with backoff while the rest of the rule runs at
  full speed.
  """

  use Oban.Worker, queue: :actions, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url, "content" => content} = args}) do
    payload = %{
      content: content,
      username: Map.get(args, "username", "HLL Conditional Actions")
    }

    case Req.post(url, json: payload, receive_timeout: :timer.seconds(10)) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      # 429 and 5xx are worth another attempt; anything else is a bad webhook
      # URL or payload that will never succeed.
      {:ok, %Req.Response{status: status}} when status == 429 or status >= 500 ->
        {:error, "Discord answered with HTTP #{status}"}

      {:ok, %Req.Response{status: status}} ->
        {:cancel, "Discord rejected the webhook with HTTP #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  @doc """
  Queues a webhook delivery.
  """
  @spec enqueue(String.t(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(url, content) do
    %{url: url, content: content} |> new() |> Oban.insert()
  end
end
