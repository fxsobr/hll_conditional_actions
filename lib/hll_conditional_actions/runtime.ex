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
  alias HllConditionalActions.Features
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

  # How long a server whose subtree died waits before it is started again.
  # Long enough not to hammer a CRCON that is down, short enough that nobody
  # has to notice.
  @revive_ms :timer.seconds(30)

  @impl GenServer
  def init(_opts) do
    Servers.subscribe()
    Features.subscribe()
    state = %{monitors: %{}}

    if enabled?() do
      {:ok, state, {:continue, :start_servers}}
    else
      Logger.info("[runtime] engine disabled, not connecting to any CRCON server")
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_continue(:start_servers, state) do
    {:noreply, Enum.reduce(Servers.list_enabled_servers(), state, &start_server/2)}
  end

  @impl GenServer
  def handle_info({:server_created, server}, state) do
    state = if enabled?() and server.enabled, do: start_server(server, state), else: state
    {:noreply, state}
  end

  def handle_info({:server_updated, server}, state) do
    state =
      cond do
        not enabled?() ->
          state

        # Connection details changed, or the server was disabled: tear the
        # subtree down and start it again with the new settings.
        server.enabled ->
          restart_server(server, state)

        true ->
          stop_server(server.id, state)
      end

    {:noreply, state}
  end

  # Installing or removing a module changes which processes a server runs.
  def handle_info({:features_changed, server_id}, state) do
    state =
      with true <- enabled?(),
           {:ok, %Server{enabled: true} = server} <- Servers.fetch_server(server_id) do
        restart_server(server, state)
      else
        _off_gone_or_disabled -> state
      end

    {:noreply, state}
  end

  def handle_info({:server_deleted, server}, state) do
    {:noreply, stop_server(server.id, state)}
  end

  # A subtree went down without being stopped: its supervisor gave up after
  # too many crashes in a row. That exit reads as a clean shutdown to the
  # dynamic supervisor, so nothing else would ever bring the server back -
  # the stream would stay "offline" until somebody saved the server. It is
  # started again after a pause, from the database, if it is still enabled.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {server_id, monitors} ->
        Logger.warning(
          "[runtime] server #{server_id} stopped (#{inspect(reason)}), restarting in #{div(@revive_ms, 1000)}s"
        )

        Process.send_after(self(), {:revive, server_id}, @revive_ms)
        {:noreply, %{state | monitors: monitors}}
    end
  end

  def handle_info({:revive, server_id}, state) do
    state =
      case Servers.fetch_server(server_id) do
        {:ok, %Server{enabled: true} = server} ->
          if enabled?(), do: start_server(server, state), else: state

        _gone_or_disabled ->
          state
      end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── Supervision ────────────────────────────────────────────────────────────

  defp start_server(%Server{} = server, state) do
    spec = %{
      id: {:crcon_server, server.id},
      start: {HllConditionalActions.Runtime.ServerSupervisor, :start_link, [server]},
      restart: :transient,
      type: :supervisor
    }

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, pid} ->
        Logger.info("[runtime] started #{server.name} (#{server.game})")
        watch(state, pid, server.id)

      {:error, {:already_started, pid}} ->
        watch(state, pid, server.id)

      {:error, reason} ->
        Logger.error("[runtime] could not start #{server.name}: #{inspect(reason)}")
        Process.send_after(self(), {:revive, server.id}, @revive_ms)
        state
    end
  end

  defp watch(state, pid, server_id) do
    if server_id in Map.values(state.monitors) do
      state
    else
      %{state | monitors: Map.put(state.monitors, Process.monitor(pid), server_id)}
    end
  end

  defp restart_server(%Server{} = server, state) do
    # The runner can adopt new settings in place, but the log stream holds an
    # open socket built from the old base URL and key, so a full restart is the
    # only way to be sure both agree with the database.
    Runner.update_server(server.id, server)

    server.id
    |> stop_server(state)
    |> then(&start_server(server, &1))
  end

  # Stopping on purpose drops the monitor first, so the stop is not mistaken
  # for a crash and revived.
  defp stop_server(server_id, state) do
    monitors =
      state.monitors
      |> Enum.reject(fn {ref, id} -> id == server_id and Process.demonitor(ref, [:flush]) end)
      |> Map.new()

    case Registry.lookup(@registry, {:supervisor, server_id}) do
      [{pid, _value}] ->
        DynamicSupervisor.terminate_child(@supervisor, pid)
        Logger.info("[runtime] stopped server #{server_id}")

      [] ->
        :ok
    end

    %{state | monitors: monitors}
  end
end
