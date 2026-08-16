defmodule HllConditionalActions.FakeCrcon.Socket do
  @moduledoc """
  The WebSocket side of `HllConditionalActions.FakeCrcon`.

  It waits for the client's start frame (`{"last_seen_id": ..., "actions": []}`)
  and then answers according to the mode it was started with.
  """

  @behaviour WebSock

  @impl WebSock
  def init(mode), do: {:ok, mode}

  @impl WebSock
  def handle_in({_payload, [opcode: :text]}, :disabled) do
    # Exactly what CRCON's LogStreamConsumer sends when the feature is off in
    # its config: an error, then a disconnect.
    body =
      Jason.encode!(%{
        "error" => "Log stream is not enabled in your config",
        "last_seen_id" => nil,
        "logs" => []
      })

    {:push, {:text, body}, :disabled}
  end

  def handle_in({_payload, [opcode: :text]}, {:logs, entries} = mode) do
    body =
      Jason.encode!(%{
        "error" => nil,
        "last_seen_id" => "1700000000000-0",
        "logs" => Enum.map(entries, &%{"id" => "1700000000000-0", "log" => &1})
      })

    {:push, {:text, body}, mode}
  end

  def handle_in(_message, mode), do: {:ok, mode}

  @impl WebSock
  def handle_info(_message, mode), do: {:ok, mode}

  @impl WebSock
  def terminate(_reason, _mode), do: :ok
end
