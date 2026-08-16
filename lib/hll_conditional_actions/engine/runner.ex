defmodule HllConditionalActions.Engine.Runner do
  @moduledoc """
  Drives the rule engine for one CRCON server.

  One runner per server consumes that server's event stream, keeps its rule set
  in memory, and owns the periodic sweep. Because each server has its own
  process, a CRCON instance that is slow or unreachable cannot stall the
  others.

  ## Why a connect is handled late

  When CRCON reports `CONNECTED`, the player is not in `get_detailed_players`
  yet: the game server has not finished admitting them. Evaluating immediately
  means every condition about their level, clan tag, team or stats compares
  against `nil`, so a welcome rule either never fires or fires only for the
  players who happened to already be in the cached snapshot.

  CRCON's own hook sleeps five seconds before processing a connect for exactly
  this reason. Here the event is scheduled instead of slept on, so the runner
  keeps handling other events meanwhile, and the snapshot is force-refreshed
  when it comes back round - reusing a snapshot taken before the player joined
  would defeat the whole point of waiting.

  ## Why the rules are cached

  Reloading rules from Postgres on every kill line would be wasteful, so the
  runner loads them once and refreshes when `HllConditionalActions.Rules`
  broadcasts a change. The same applies to the CRCON snapshot, which is shared
  across all rules evaluated within its freshness window.
  """

  use GenServer, restart: :transient

  alias HllConditionalActions.Crcon.Events
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Engine
  alias HllConditionalActions.Engine.Snapshot
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Rule

  # How often the runner wakes up to see which periodic rules are due. The
  # rules' own intervals are enforced on top of this, so a 10s tick supports
  # the minimum interval the schema allows.
  @tick_ms :timer.seconds(10)

  # How long to wait before acting on a connect; see the moduledoc.
  @default_connect_delay_ms :timer.seconds(5)

  defmodule State do
    @moduledoc false
    defstruct [:server, rules: [], snapshot: nil, periodic_last_run: %{}]
  end

  @doc """
  Starts a runner for a server.
  """
  def start_link(opts) do
    server = Keyword.fetch!(opts, :server)
    GenServer.start_link(__MODULE__, server, name: Keyword.get(opts, :name, via(server.id)))
  end

  @doc """
  Returns the registry key used to find a server's runner.
  """
  def via(server_id) do
    {:via, Registry, {HllConditionalActions.Runtime.Registry, {:runner, server_id}}}
  end

  @doc """
  Replaces the server this runner drives, after its settings changed.
  """
  @spec update_server(term(), struct()) :: :ok
  def update_server(server_id, server) do
    GenServer.cast(via(server_id), {:update_server, server})
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Returns a snapshot of the runner's state, for the UI.
  """
  @spec info(term()) :: %{rules: non_neg_integer(), snapshot_stale?: boolean()} | :offline
  def info(server_id) do
    GenServer.call(via(server_id), :info)
  catch
    :exit, _reason -> :offline
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl GenServer
  def init(server) do
    LogStream.subscribe(server.id)
    Rules.subscribe()
    schedule_tick()

    {:ok, %State{server: server, rules: Rules.list_active_rules_for(server)}}
  end

  @impl GenServer
  def handle_call(:info, _from, state) do
    info = %{
      rules: length(state.rules),
      snapshot_stale?: not Snapshot.fresh?(state.snapshot)
    }

    {:reply, info, state}
  end

  @impl GenServer
  def handle_cast({:update_server, server}, state) do
    {:noreply, %{state | server: server, rules: Rules.list_active_rules_for(server)}}
  end

  @impl GenServer
  def handle_info({:crcon_event, event}, state) do
    {:noreply, handle_event(event, state)}
  end

  def handle_info({:crcon_stream_status, _server_id, _status}, state), do: {:noreply, state}

  # Any rule change may add or remove rules for this server, so reload rather
  # than trying to patch the cached list.
  def handle_info({:rules_changed, _rule}, state) do
    {:noreply, %{state | rules: Rules.list_active_rules_for(state.server)}}
  end

  def handle_info(:tick, state) do
    schedule_tick()
    {:noreply, run_periodic_rules(state)}
  end

  # A connect that waited for the game server to catch up.
  def handle_info({:deferred_event, event}, state) do
    # Force a refresh: the cached snapshot may well predate the connect we
    # just waited out.
    {:noreply, process_player_event(event, state, &refresh_snapshot/1)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── Event handling ─────────────────────────────────────────────────────────

  defp handle_event(%{type: type} = event, state) when type in [:match_start, :match_end] do
    case Engine.rules_for(state.rules, type) do
      [] ->
        state

      _matching ->
        state = refresh_snapshot(state)

        Engine.process_batch_trigger(state.server, state.rules, type,
          snapshot: state.snapshot,
          event: event
        )

        state
    end
  end

  # A connect is worth nothing until the player exists in CRCON's view, so it
  # is deferred rather than evaluated against a snapshot that predates them.
  defp handle_event(%{type: :player_connected} = event, state) do
    if Engine.rules_for(state.rules, :player_connected) == [] do
      state
    else
      Process.send_after(self(), {:deferred_event, event}, connect_delay_ms())
      state
    end
  end

  defp handle_event(event, state) do
    process_player_event(event, state, &ensure_snapshot/1)
  end

  # Shared by the immediate and the deferred path; the caller decides how fresh
  # the snapshot has to be. The snapshot is only prepared once a trigger is
  # known to have rules, so an event nobody listens for costs nothing.
  defp process_player_event(event, state, prepare_snapshot) do
    event
    |> Events.triggers()
    |> Enum.filter(fn {trigger, _player_id, _name} ->
      Engine.rules_for(state.rules, trigger) != []
    end)
    |> case do
      [] ->
        state

      triggers ->
        state = prepare_snapshot.(state)

        Enum.each(triggers, fn {trigger, player_id, player_name} ->
          Engine.process_player_trigger(state.server, state.rules, trigger,
            player_id: player_id,
            player_name: player_name,
            snapshot: state.snapshot,
            event: event
          )
        end)

        state
    end
  end

  # ── Periodic rules ─────────────────────────────────────────────────────────

  defp run_periodic_rules(state) do
    now = System.monotonic_time(:millisecond)

    due =
      state.rules
      |> Engine.rules_for(:periodic)
      |> Enum.filter(&Engine.periodic_due?(&1, state.periodic_last_run[&1.id], now))

    if due == [] do
      state
    else
      # The periodic sweep is the one caller that must not act on cached
      # numbers: its whole point is to react to the current state of the match.
      state = refresh_snapshot(state)

      Enum.each(due, fn rule ->
        Engine.process_batch_trigger(state.server, [rule], :periodic, snapshot: state.snapshot)
      end)

      last_run = Enum.reduce(due, state.periodic_last_run, &Map.put(&2, &1.id, now))
      %{state | periodic_last_run: last_run}
    end
  end

  # ── Snapshot ───────────────────────────────────────────────────────────────

  defp ensure_snapshot(state) do
    %{state | snapshot: Snapshot.fetch(state.server, state.snapshot)}
  end

  defp refresh_snapshot(state) do
    %{state | snapshot: Snapshot.refresh(state.server, state.snapshot)}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp connect_delay_ms do
    Application.get_env(:hll_conditional_actions, :connect_delay_ms, @default_connect_delay_ms)
  end

  @doc false
  @spec sorted_rules([Rule.t()]) :: [Rule.t()]
  def sorted_rules(rules), do: Rule.sort(rules)
end
