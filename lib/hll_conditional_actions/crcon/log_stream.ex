defmodule HllConditionalActions.Crcon.LogStream do
  @moduledoc """
  Streams a CRCON server's structured game logs over WebSocket.

  CRCON exposes `ws://<host>/ws/logs` (see `rconweb/api/log_stream.py`). The
  consumer authenticates with the same `Authorization: Bearer <api_key>` header
  as the REST API, and requires the `can_view_structured_logs` permission plus
  `log_stream.enabled` in the CRCON config.

  ## Protocol

  The client sends one JSON message to start the stream:

      {"last_seen_id": null, "actions": []}

  An empty `actions` list means "send everything". CRCON then pushes batches of
  at most 25 entries, forever:

      {"logs": [{"id": "1699…-0", "log": {…}}], "last_seen_id": "1699…-0",
       "error": null}

  `id` is a Redis stream id. Keeping the last one lets a reconnect resume from
  where the previous connection stopped instead of replaying the whole buffer.

  ## Delivery

  Each log line is normalized by `HllConditionalActions.Crcon.Events` and
  broadcast on the server's PubSub topic, so the rule engine and any LiveView
  can subscribe independently:

      HllConditionalActions.Crcon.LogStream.subscribe(server_id)
      # => receives {:crcon_event, %Events.Event{}}

  Connection state changes are broadcast as `{:crcon_stream_status, server_id,
  status}` so the UI can show whether a server is live.
  """

  use GenServer, restart: :transient

  require Logger

  alias HllConditionalActions.Crcon.Events
  alias HllConditionalActions.PubSub

  # Reconnect backoff, in milliseconds. Capped so a server that is down for a
  # long time is still retried every ~30s.
  @backoff_start 1_000
  @backoff_max 30_000
  @connect_timeout :timer.seconds(10)

  @type status :: :disconnected | :connecting | :connected | {:error, String.t()}

  defmodule State do
    @moduledoc false
    defstruct [
      :server,
      :conn,
      :websocket,
      :request_ref,
      :last_seen_id,
      :upgrade_status,
      status: :disconnected,
      backoff: 1_000,
      upgrade_headers: [],
      actions: []
    ]
  end

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Starts a stream for a server. Registered in `HllConditionalActions.Runtime`'s
  registry under `{:log_stream, server.id}`.
  """
  def start_link(opts) do
    server = Keyword.fetch!(opts, :server)
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, via(server.id)))
  end

  @doc """
  Returns the registry key used to find a server's stream process.
  """
  def via(server_id) do
    {:via, Registry, {HllConditionalActions.Runtime.Registry, {:log_stream, server_id}}}
  end

  @doc """
  Subscribes the calling process to a server's normalized events.
  """
  @spec subscribe(term()) :: :ok | {:error, term()}
  def subscribe(server_id) do
    Phoenix.PubSub.subscribe(PubSub, topic(server_id))
  end

  @doc """
  Unsubscribes the calling process from a server's events.
  """
  @spec unsubscribe(term()) :: :ok
  def unsubscribe(server_id) do
    Phoenix.PubSub.unsubscribe(PubSub, topic(server_id))
  end

  @doc """
  The PubSub topic carrying a server's events and stream status.
  """
  @spec topic(term()) :: String.t()
  def topic(server_id), do: "crcon:#{server_id}:logs"

  @doc """
  Subscribes to the stream status of *every* server.

  A page showing a list cares about "some server changed", not about one
  server's events, and subscribing per server means a server added after the
  page was opened is never heard from — which left the badge saying
  "Connecting" until somebody reloaded. One topic, subscribed once, has no
  such gap.
  """
  @spec subscribe_status() :: :ok | {:error, term()}
  def subscribe_status, do: Phoenix.PubSub.subscribe(PubSub, status_topic())

  @doc """
  The PubSub topic carrying every server's stream status.
  """
  @spec status_topic() :: String.t()
  def status_topic, do: "crcon:status"

  @doc """
  Returns the current connection status of a server's stream.
  """
  @spec status(term()) :: status()
  def status(server_id) do
    GenServer.call(via(server_id), :status)
  catch
    :exit, _reason -> :disconnected
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    state = %State{
      server: Keyword.fetch!(opts, :server),
      actions: Keyword.get(opts, :actions, []),
      backoff: @backoff_start
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    {:noreply, connect(state)}
  end

  @impl GenServer
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl GenServer
  def handle_info(:reconnect, state), do: {:noreply, connect(state)}

  # Frames arrive as raw transport messages; Mint turns them into responses.
  def handle_info(message, %State{conn: conn} = state) when not is_nil(conn) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        {:noreply, Enum.reduce(responses, %{state | conn: conn}, &handle_response/2)}

      {:error, conn, error, _responses} ->
        Logger.warning("[crcon #{name(state)}] stream error: #{inspect(error)}")
        {:noreply, schedule_reconnect(%{state | conn: conn}, Exception.message(error))}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %State{conn: conn}) when not is_nil(conn) do
    Mint.HTTP.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Connection ─────────────────────────────────────────────────────────────

  defp connect(state) do
    state = broadcast_status(state, :connecting)

    with {:ok, uri} <- parse_url(state.server.base_url),
         {:ok, conn} <- http_connect(uri),
         {:ok, conn, ref} <- upgrade(conn, uri, state.server.api_key) do
      %{state | conn: conn, request_ref: ref}
    else
      {:error, %Mint.HTTPError{} = error} ->
        schedule_reconnect(state, Exception.message(error))

      {:error, %Mint.TransportError{} = error} ->
        schedule_reconnect(state, Exception.message(error))

      {:error, _conn, error} ->
        schedule_reconnect(state, Exception.message(error))

      {:error, reason} when is_binary(reason) ->
        schedule_reconnect(state, reason)

      {:error, reason} ->
        schedule_reconnect(state, inspect(reason))
    end
  end

  defp http_connect(uri) do
    Mint.HTTP.connect(scheme_to_transport(uri.scheme), uri.host, uri.port,
      protocols: [:http1],
      transport_opts: transport_opts(uri.scheme, uri.host),
      timeout: @connect_timeout
    )
  end

  defp upgrade(conn, uri, api_key) do
    Mint.WebSocket.upgrade(ws_scheme(uri.scheme), conn, log_path(uri), [
      {"authorization", "Bearer #{api_key}"}
    ])
  end

  # CRCON is commonly deployed behind a reverse proxy on a subpath, so keep any
  # prefix from the configured base URL.
  defp log_path(%URI{path: path}) do
    prefix = path |> to_string() |> String.trim_trailing("/")
    prefix <> "/ws/logs"
  end

  defp scheme_to_transport("https"), do: :https
  defp scheme_to_transport("wss"), do: :https
  defp scheme_to_transport(_scheme), do: :http

  defp ws_scheme("https"), do: :wss
  defp ws_scheme("wss"), do: :wss
  defp ws_scheme(_scheme), do: :ws

  defp transport_opts(scheme, host) when scheme in ["https", "wss"] do
    [
      verify: :verify_peer,
      cacertfile: CAStore.file_path(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp transport_opts(_scheme, _host), do: []

  defp parse_url(base_url) do
    uri = base_url |> to_string() |> String.trim() |> String.trim_trailing("/") |> URI.parse()

    cond do
      is_nil(uri.host) or uri.host == "" ->
        {:error, "invalid CRCON base URL: #{inspect(base_url)}"}

      is_nil(uri.scheme) ->
        {:error, "CRCON base URL is missing a scheme (http:// or https://)"}

      true ->
        {:ok, %{uri | port: uri.port || default_port(uri.scheme)}}
    end
  end

  defp default_port(scheme) when scheme in ["https", "wss"], do: 443
  defp default_port(_scheme), do: 80

  # ── Responses ──────────────────────────────────────────────────────────────

  defp handle_response({:status, ref, status}, %State{request_ref: ref} = state) do
    %{state | upgrade_status: status}
  end

  defp handle_response({:headers, ref, headers}, %State{request_ref: ref} = state) do
    %{state | upgrade_headers: headers}
  end

  defp handle_response({:done, ref}, %State{request_ref: ref} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.upgrade_status, state.upgrade_headers) do
      {:ok, conn, websocket} ->
        # The backoff is deliberately NOT reset here. CRCON accepts the upgrade
        # and only then reports a disabled log stream in its first frame, so
        # resetting on a successful handshake would retry every second forever
        # against a server that will never answer. It is reset once real log
        # data arrives instead.
        %{state | conn: conn, websocket: websocket}
        |> broadcast_status(:connected)
        |> send_start_frame()

      {:error, conn, error} ->
        schedule_reconnect(
          %{state | conn: conn},
          upgrade_error_message(state.upgrade_status, error)
        )
    end
  end

  defp handle_response({:data, ref, data}, %State{request_ref: ref, websocket: ws} = state)
       when not is_nil(ws) do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, websocket, frames} ->
        Enum.reduce(frames, %{state | websocket: websocket}, &handle_frame/2)

      {:error, websocket, error} ->
        Logger.warning("[crcon #{name(state)}] decode error: #{inspect(error)}")
        %{state | websocket: websocket}
    end
  end

  defp handle_response({:error, ref, error}, %State{request_ref: ref} = state) do
    schedule_reconnect(state, Exception.message(error))
  end

  defp handle_response(_response, state), do: state

  # CRCON's own wording for a disabled stream says nothing about where to turn
  # it on, and this is the first thing a new install hits.
  defp explain_stream_error("Log stream is not enabled" <> _rest) do
    "CRCON's log stream is disabled - turn it on in CRCON under " <>
      "Settings -> Others -> Log Stream (set \"enabled\" to true), " <>
      "otherwise no game events reach this server"
  end

  defp explain_stream_error(error), do: error

  # A rejected upgrade is almost always a bad API key or a CRCON that has the
  # log stream disabled, so say that instead of "unexpected status".
  defp upgrade_error_message(status, error) when status in [401, 403] do
    "log stream refused the API key (HTTP #{status}); " <>
      "check the key's can_view_structured_logs permission - #{Exception.message(error)}"
  end

  defp upgrade_error_message(_status, error), do: Exception.message(error)

  # ── Frames ─────────────────────────────────────────────────────────────────

  defp handle_frame({:text, payload}, state) do
    case Jason.decode(payload) do
      {:ok, message} -> handle_message(message, state)
      {:error, error} -> log_and_keep(state, "invalid JSON frame: #{inspect(error)}")
    end
  end

  defp handle_frame({:ping, data}, state), do: send_frame(state, {:pong, data})
  defp handle_frame({:pong, _data}, state), do: state

  defp handle_frame({:close, code, reason}, state) do
    schedule_reconnect(state, "server closed the stream (#{code}: #{reason})")
  end

  defp handle_frame(:close, state), do: schedule_reconnect(state, "server closed the stream")
  defp handle_frame(_frame, state), do: state

  defp handle_message(%{"error" => error}, state) when is_binary(error) and error != "" do
    schedule_reconnect(state, explain_stream_error(error))
  end

  defp handle_message(%{"logs" => logs} = message, state) when is_list(logs) do
    Enum.each(logs, fn
      %{"log" => log} -> broadcast_event(state, log)
      _other -> :ok
    end)

    # Real data means the stream genuinely works, which is the only signal that
    # justifies going back to the fast retry interval.
    %{
      state
      | last_seen_id: message["last_seen_id"] || state.last_seen_id,
        backoff: @backoff_start
    }
  end

  defp handle_message(_message, state), do: state

  defp broadcast_event(state, raw_log) do
    event = Events.from_log(raw_log, state.server)

    :telemetry.execute(
      [:hll_conditional_actions, :log_stream, :event],
      %{count: 1},
      %{server_id: state.server.id, type: event.type}
    )

    Phoenix.PubSub.broadcast(PubSub, topic(state.server.id), {:crcon_event, event})
  end

  # ── Frames out ─────────────────────────────────────────────────────────────

  defp send_start_frame(state) do
    payload = Jason.encode!(%{last_seen_id: state.last_seen_id, actions: state.actions})
    send_frame(state, {:text, payload})
  end

  defp send_frame(%State{websocket: nil} = state, _frame), do: state

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
      %{state | websocket: websocket, conn: conn}
    else
      {:error, %Mint.WebSocket{} = websocket, error} ->
        log_and_keep(%{state | websocket: websocket}, "encode error: #{inspect(error)}")

      {:error, conn, error} ->
        schedule_reconnect(%{state | conn: conn}, Exception.message(error))
    end
  end

  # ── Reconnection ───────────────────────────────────────────────────────────

  defp schedule_reconnect(state, reason) do
    if state.conn, do: Mint.HTTP.close(state.conn)

    Logger.warning(
      "[crcon #{name(state)}] log stream down: #{reason}. Retrying in #{state.backoff}ms"
    )

    Process.send_after(self(), :reconnect, state.backoff)
    broadcast_status(state, {:error, reason})

    %{
      state
      | conn: nil,
        websocket: nil,
        request_ref: nil,
        status: {:error, reason},
        backoff: min(state.backoff * 2, @backoff_max)
    }
  end

  defp log_and_keep(state, message) do
    Logger.warning("[crcon #{name(state)}] #{message}")
    state
  end

  defp broadcast_status(state, status) do
    :telemetry.execute(
      [:hll_conditional_actions, :log_stream, :status],
      %{count: 1},
      %{server_id: state.server.id, status: status_name(status)}
    )

    message = {:crcon_stream_status, state.server.id, status}

    # Twice: to this server's own topic, for whoever is watching just it, and
    # to the shared one, for the pages showing a list.
    Phoenix.PubSub.broadcast(PubSub, topic(state.server.id), message)
    Phoenix.PubSub.broadcast(PubSub, status_topic(), message)

    %{state | status: status}
  end

  defp name(%State{server: server}), do: server.name || server.id

  # Telemetry metadata must stay low cardinality, so the error reason - which
  # can be any message CRCON invents - is collapsed to the tag.
  defp status_name({:error, _reason}), do: :error
  defp status_name(status), do: status
end
