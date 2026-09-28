defmodule HllConditionalActions.Discord.Client do
  @moduledoc """
  The three webhook endpoints the app uses: read the webhook, post a message,
  edit a message.

  A webhook URL already carries its token, so no other authentication is
  involved. Req's own retry is off: `HllConditionalActions.Workers.DeliverWebhook`
  retries through Oban, honouring the wait Discord asks for.
  """

  @receive_timeout :timer.seconds(10)

  @type response :: {:ok, Req.Response.t()} | {:error, Exception.t()}

  @doc "Reads the webhook: its name, channel and server."
  @spec get(String.t()) :: response()
  def get(url), do: request(:get, url)

  @doc """
  Posts a message. `wait=true` makes Discord answer with the message it
  created, whose id an edit needs later.
  """
  @spec post(String.t(), map(), keyword()) :: response()
  def post(url, payload, opts \\ []) do
    request(:post, url, json: payload, params: params(opts, wait: true))
  end

  @doc "Replaces the text of a message the webhook posted earlier."
  @spec edit(String.t(), String.t(), map(), keyword()) :: response()
  def edit(url, message_id, payload, opts \\ []) do
    request(:patch, "#{url}/messages/#{message_id}",
      json: Map.drop(payload, ["username", "avatar_url", "flags", "thread_name"]),
      params: params(opts, [])
    )
  end

  defp params(opts, base) do
    case Keyword.get(opts, :thread_id) do
      nil -> base
      thread_id -> Keyword.put(base, :thread_id, thread_id)
    end
  end

  defp request(method, url, opts \\ []) do
    [method: method, url: url, receive_timeout: @receive_timeout, retry: false]
    |> Keyword.merge(opts)
    |> Keyword.merge(Application.get_env(:hll_conditional_actions, :discord_req_options, []))
    |> Req.request()
  end
end
