defmodule HllConditionalActions.Runtime do
  @moduledoc """
  Supervises the processes that talk to each CRCON server.

  Every enabled server gets its own subtree:

      Runtime.ServerSupervisor (one_for_all, per server)
      ├── Crcon.LogStream   - WebSocket consumer
      └── Engine.Runner     - rule evaluation

  They are supervised `:one_for_all` because the runner subscribes to the
  stream's PubSub topic on start: restarting the stream alone would be fine,
  but restarting the runner without it is not, and pairing them keeps that
  invariant obvious.

  The set of running subtrees follows the database. `HllConditionalActions.Servers`
  broadcasts every create, update and delete, and this process starts, restarts
  or stops the matching subtree.
  """

  use GenServer

  require Logger

  alias HllConditionalActions.Engine.Runner
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Servers.Server

  @registry HllConditionalActions.Runtime.Registry
  @supervisor HllConditionalActions.Runtime.ServerSupervisor

  @doc """
  Starts the runtime manager.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The child specs the application supervisor needs for the runtime to work.
  """
  @spec children() :: [Supervisor.child_spec() | {module(), term()}]
  def children do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @supervisor},
      __MODULE__
    ]
  end

  @doc """
  Whether this node runs the engine.

  A node with `ENGINE_ENABLED=false` serves the UI without connecting to any
  CRCON server, which is what you want for a second web node or while
  debugging against production data.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:hll_conditional_actions, :engine_enabled, true)

  @doc """
  Server ids with a running subtree.
  """
  @spec running_servers() :: [term()]
  def running_servers do
    Registry.select(@registry, [{{{:runner, :"$1"}, :_, :_}, [], [:"$1"]}])
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    Servers.subscribe()

    if enabled?() do
      {:ok, %{}, {:continue, :start_servers}}
    else
      Logger.info("[runtime] engine disabled, not connecting to any CRCON server")
      {:ok, %{}}
    end
  end

  @impl GenServer
  def handle_continue(:start_servers, state) do
    Enum.each(Servers.list_enabled_servers(), &start_server/1)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:server_created, server}, state) do
    if enabled?() and server.enabled, do: start_server(server)
    {:noreply, state}
  end

  def handle_info({:server_updated, server}, state) do
    cond do
      not enabled?() ->
        :ok

      # Connection details changed, or the server was disabled: tear the
      # subtree down and start it again with the new settings.
      server.enabled ->
        restart_server(server)

      true ->
        stop_server(server.id)
    end

    {:noreply, state}
  end

  def handle_info({:server_deleted, server}, state) do
    stop_server(server.id)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── Supervision ────────────────────────────────────────────────────────────

  defp start_server(%Server{} = server) do
    spec = %{
      id: {:crcon_server, server.id},
      start: {HllConditionalActions.Runtime.ServerSupervisor, :start_link, [server]},
      restart: :transient,
      type: :supervisor
    }

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, _pid} ->
        Logger.info("[runtime] started #{server.name} (#{server.game})")
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.error("[runtime] could not start #{server.name}: #{inspect(reason)}")
        :error
    end
  end

  defp restart_server(%Server{} = server) do
    # The runner can adopt new settings in place, but the log stream holds an
    # open socket built from the old base URL and key, so a full restart is the
    # only way to be sure both agree with the database.
    Runner.update_server(server.id, server)
    stop_server(server.id)
    start_server(server)
  end

  defp stop_server(server_id) do
    case Registry.lookup(@registry, {:supervisor, server_id}) do
      [{pid, _value}] ->
        DynamicSupervisor.terminate_child(@supervisor, pid)
        Logger.info("[runtime] stopped server #{server_id}")
        :ok

      [] ->
        :ok
    end
  end
end
