defmodule HllConditionalActions.Crcon.Client do
  @moduledoc """
  Low level HTTP client for a CRCON (`hll_rcon_tool`) deployment.

  ## Protocol

  CRCON exposes every command under `/api/<endpoint>` and authenticates with an
  API key issued from its admin site:

      Authorization: Bearer <api_key>

  Read endpoints (`get_*`) are `GET` only and take query parameters; commands
  that change state are `POST` only and take a JSON body. Sending the wrong
  verb returns `405`, so `method_for/1` maps every endpoint we use.

  Responses are always `200 OK` with an envelope:

      {"result": ..., "command": "...", "arguments": {...}, "failed": false,
       "error": null, "forwards_results": null, "version": "v11.x"}

  `request/4` unwraps that envelope, so callers get `{:ok, result}` or
  `{:error, %HllConditionalActions.Crcon.Error{}}`.

  ## The `by` parameter

  Commands that record an audit trail (`kick`, `punish`, `temp_ban`, ...) take a
  `by` argument in Python, but CRCON overwrites it with the username that owns
  the API key. Creating a dedicated CRCON user for this app is therefore what
  makes its actions identifiable in the audit log.
  """

  alias HllConditionalActions.Crcon.Error

  @default_receive_timeout :timer.seconds(15)
  @default_retry_count 2

  # Endpoints CRCON only accepts over POST. Everything else defaults to GET,
  # which matches CRCON's own convention that reads are `get_*`.
  @post_endpoints ~w(
    message_player
    message_all_players
    punish
    kick
    temp_ban
    perma_ban
    switch_player_now
    switch_player_on_death
    flag_player
    unflag_player
    watch_player
    unwatch_player
    set_broadcast
    set_welcome_message
    do_message_player
    add_vip
    remove_vip
  )

  @typedoc "Anything carrying the connection details of a CRCON deployment."
  @type connection :: %{
          required(:base_url) => String.t(),
          required(:api_key) => String.t(),
          optional(atom()) => term()
        }

  @doc """
  Calls a CRCON endpoint and unwraps its response envelope.

  ## Options

    * `:method` - override the HTTP verb inferred by `method_for/1`
    * `:receive_timeout` - defaults to 15s
    * `:retry` - passed through to `Req`, defaults to retrying safe failures twice
  """
  @spec request(connection(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def request(conn, endpoint, params \\ %{}, opts \\ []) do
    method = Keyword.get_lazy(opts, :method, fn -> method_for(endpoint) end)

    conn
    |> build(endpoint, opts)
    |> attach_params(method, params)
    |> Req.request(method: method)
    |> handle_response(endpoint)
  end

  @doc """
  Same as `request/4` but raises on failure.
  """
  @spec request!(connection(), String.t(), map(), keyword()) :: term()
  def request!(conn, endpoint, params \\ %{}, opts \\ []) do
    case request(conn, endpoint, params, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Returns the HTTP verb CRCON expects for an endpoint.

      iex> alias HllConditionalActions.Crcon.Client
      iex> {Client.method_for("get_gamestate"), Client.method_for("kick")}
      {:get, :post}
  """
  @spec method_for(String.t()) :: :get | :post
  def method_for(endpoint) when endpoint in @post_endpoints, do: :post
  def method_for("get_" <> _rest), do: :get
  def method_for("describe_" <> _rest), do: :get
  def method_for(_endpoint), do: :post

  @doc """
  Builds the `Req.Request` used to talk to a CRCON deployment.

  Exposed so tests can plug a stub with `Req.Test`.
  """
  @spec build(connection(), String.t(), keyword()) :: Req.Request.t()
  def build(conn, endpoint, opts \\ []) do
    [
      base_url: normalize_base_url(conn.base_url),
      url: "/api/#{endpoint}",
      auth: {:bearer, conn.api_key},
      headers: [{"content-type", "application/json"}, {"accept", "application/json"}],
      receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout),
      retry: Keyword.get(opts, :retry, :safe_transient),
      max_retries: Keyword.get(opts, :max_retries, @default_retry_count),
      # CRCON's payloads are player and config data, so keys stay strings
      # rather than becoming atoms the VM would never reclaim.
      decoders: [json: &Jason.decode(&1, keys: :strings)]
    ]
    |> Req.new()
    |> Req.merge(Application.get_env(:hll_conditional_actions, :crcon_req_options, []))
  end

  defp attach_params(request, :get, params) when map_size(params) == 0, do: request
  defp attach_params(request, :get, params), do: Req.merge(request, params: encode_query(params))
  defp attach_params(request, :post, params), do: Req.merge(request, json: params)

  # CRCON reads GET parameters as raw strings and lists arrive as repeated keys,
  # which `Req` already encodes correctly. Booleans have to be spelled the way
  # Python's `json.loads` fallback expects them.
  defp encode_query(params) do
    Enum.map(params, fn
      {key, true} -> {key, "true"}
      {key, false} -> {key, "false"}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_base_url(base_url) do
    base_url |> to_string() |> String.trim() |> String.trim_trailing("/")
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}, endpoint) do
    unwrap(body, endpoint)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, endpoint)
       when status in [401, 403] do
    {:error,
     Error.new(:unauthorized, "CRCON rejected the API key or the key lacks permission",
       endpoint: endpoint,
       status: status,
       body: body
     )}
  end

  defp handle_response({:ok, %Req.Response{status: 404, body: body}}, endpoint) do
    {:error,
     Error.new(:not_found, "endpoint not available on this CRCON version",
       endpoint: endpoint,
       status: 404,
       body: body
     )}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, endpoint) do
    {:error,
     Error.new(:http_error, "CRCON answered with HTTP #{status}",
       endpoint: endpoint,
       status: status,
       body: body
     )}
  end

  defp handle_response({:error, exception}, endpoint) do
    {:error,
     Error.new(:transport_error, Exception.message(exception),
       endpoint: endpoint,
       body: exception
     )}
  end

  defp unwrap(%{"failed" => false} = body, _endpoint), do: {:ok, Map.get(body, "result")}

  defp unwrap(%{"failed" => true} = body, endpoint) do
    {:error, Error.new(:command_failed, describe_error(body), endpoint: endpoint, body: body)}
  end

  # A handful of endpoints (and reverse proxies serving an error page) answer
  # without the envelope. Surfacing that as its own reason keeps a misconfigured
  # base URL from looking like a command failure.
  defp unwrap(body, endpoint) do
    {:error,
     Error.new(:invalid_response, "unexpected response body from CRCON",
       endpoint: endpoint,
       body: body
     )}
  end

  defp describe_error(%{"error" => error}) when is_binary(error) and error != "", do: error
  defp describe_error(%{"error" => nil}), do: "command failed without an error message"
  defp describe_error(%{"error" => error}), do: inspect(error)
  defp describe_error(_body), do: "command failed without an error message"
end
