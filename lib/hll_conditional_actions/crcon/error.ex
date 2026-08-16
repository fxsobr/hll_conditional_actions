defmodule HllConditionalActions.Crcon.Error do
  @moduledoc """
  A failed CRCON call.

  CRCON always answers `200 OK` with an envelope, so a failure is usually
  `%{"failed" => true, "error" => "..."}` rather than an HTTP status. The
  `reason` field distinguishes the failure modes callers care about:

    * `:command_failed` - CRCON ran the command and it failed
    * `:unauthorized` - the API key is missing, wrong, or lacks the permission
    * `:not_found` - the endpoint does not exist on that CRCON version
    * `:http_error` - any other non-2xx response
    * `:transport_error` - the request never reached CRCON
    * `:invalid_response` - the body was not the expected envelope
  """

  @type reason ::
          :command_failed
          | :unauthorized
          | :not_found
          | :http_error
          | :transport_error
          | :invalid_response

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          endpoint: String.t() | nil,
          status: pos_integer() | nil,
          body: term()
        }

  defexception [:reason, :message, :endpoint, :status, :body]

  @impl Exception
  def message(%__MODULE__{endpoint: nil, message: message}), do: message
  def message(%__MODULE__{endpoint: endpoint, message: message}), do: "#{endpoint}: #{message}"

  @doc """
  Builds an error struct.
  """
  @spec new(reason(), String.t(), keyword()) :: t()
  def new(reason, message, opts \\ []) do
    %__MODULE__{
      reason: reason,
      message: message,
      endpoint: opts[:endpoint],
      status: opts[:status],
      body: opts[:body]
    }
  end
end
