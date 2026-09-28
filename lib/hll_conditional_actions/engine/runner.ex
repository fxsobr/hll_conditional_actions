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

  require Logger

  alias HllConditionalActions.Crcon.Events
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Engine
  alias HllConditionalActions.Engine.Snapshot
  alias HllConditionalActions.Features
  alias HllConditionalActions.Progression
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
    defstruct [
      :server,
      :progression_at,
      rules: [],
      snapshot: nil,
      periodic_last_run: %{},
      features: MapSet.new()
    ]
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

    features = Features.installed(server.id)
    {:ok, %State{server: server, features: features, rules: active_rules(server, features)}}
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
    {:noreply, %{state | server: server, rules: active_rules(server, state.features)}}
  end

  @impl GenServer
  def handle_info({:crcon_event, event}, state) do
    {:noreply, guarded(state, "event #{event.type}", &handle_event(event, &1))}
  end

  def handle_info({:crcon_stream_status, _server_id, _status}, state), do: {:noreply, state}

  # Any rule change may add or remove rules for this server, so reload rather
  # than trying to patch the cached list.
  def handle_info({:rules_changed, _rule}, state) do
    {:noreply, %{state | rules: active_rules(state.server, state.features)}}
  end

  def handle_info(:tick, state) do
    schedule_tick()
    {:noreply, guarded(state, "tick", &(&1 |> watch_vehicles() |> run_periodic_rules()))}
  end

  # A connect that waited for the game server to catch up.
  def handle_info({:deferred_event, event}, state) do
    # Force a refresh: the cached snapshot may well predate the connect we
    # just waited out.
    {:noreply,
     guarded(state, "event #{event.type}", fn state ->
       process_player_event(event, state, &refresh_snapshot/1)
     end)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # One bad event - a CRCON answer shaped differently, a bug in a rule's
  # evaluation - is logged and skipped, and the runner keeps its state. Left
  # to crash, the same event pattern repeating would exhaust the server's
  # restart budget and take its log stream down with it.
  defp guarded(state, what, fun) do
    case fun.(state) do
      %State{} = next ->
        next

      other ->
        Logger.error(
          "[engine] #{state.server.name}: #{what} returned #{inspect(other)}, state kept"
        )

        state
    end
  rescue
    exception ->
      Logger.error("""
      [engine] #{state.server.name}: #{what} failed, skipped: #{Exception.message(exception)}
      #{Exception.format_stacktrace(__STACKTRACE__)}
      """)

      state
  end

  # ── Event handling ─────────────────────────────────────────────────────────

  # The end of a match is also when achievements and seasons are counted,
  # rules or not. It is read from a fresh snapshot, the match's final
  # numbers, and only once per match: CRCON can repeat the line.
  defp handle_event(%{type: :match_end} = event, state) do
    state = record_progression(state)
    run_match_rules(event, state)
  end

  defp handle_event(%{type: :match_start} = event, state), do: run_match_rules(event, state)

  # A connect is worth nothing until the player exists in CRCON's view, so it
  # is deferred rather than evaluated against a snapshot that predates them.
  defp handle_event(%{type: :player_connected} = event, state) do
    if Engine.rules_for(state.rules, :player_connected) == [] do
      sample_unheard(event, state)
      state
    else
      Process.send_after(self(), {:deferred_event, event}, connect_delay_ms())
      state
    end
  end

  defp handle_event(event, state) do
    process_player_event(event, state, &ensure_snapshot/1)
  end

  defp run_match_rules(%{type: type} = event, state) do
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

  # Shared by the immediate and the deferred path; the caller decides how fresh
  # the snapshot has to be. The snapshot is only prepared once a trigger is
  # known to have rules, so an event nobody listens for costs nothing.
  defp process_player_event(event, state, prepare_snapshot) do
    sample_unheard(event, state)

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

  @progression_gap_ms :timer.minutes(10)

  # A server without the rules module runs none, whatever is written for it.
  defp active_rules(server, features) do
    if MapSet.member?(features, :rules), do: Rules.list_active_rules_for(server), else: []
  end

  defp record_progression(state) do
    if MapSet.member?(state.features, :progression),
      do: do_record_progression(state),
      else: state
  end

  defp do_record_progression(state) do
    now = System.monotonic_time(:millisecond)

    if state.progression_at && now - state.progression_at < @progression_gap_ms do
      state
    else
      state = refresh_snapshot(state)

      if state.snapshot && not state.snapshot.stale? do
        Progression.record_match(state.server, state.snapshot.players,
          gamestate: state.snapshot.gamestate
        )
      end

      %{state | progression_at: now}
    end
  end

  # Triggers nobody listens for still leave a sample for the builder's replay,
  # built from whatever snapshot is already cached - never a CRCON call, so an
  # unheard event keeps costing nothing.
  defp sample_unheard(event, state) do
    event
    |> Events.triggers()
    |> Enum.each(fn {trigger, player_id, player_name} ->
      if Engine.rules_for(state.rules, trigger) == [] do
        Engine.record_sample(state.server, trigger,
          player_id: player_id,
          player_name: player_name,
          snapshot: state.snapshot,
          event: event
        )
      end
    end)
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
    replace_snapshot(state, Snapshot.fetch(state.server, state.snapshot))
  end

  defp refresh_snapshot(state) do
    replace_snapshot(state, Snapshot.refresh(state.server, state.snapshot))
  end

  # Every new snapshot is compared with the last one: HLL writes no log line
  # when a vehicle is destroyed, so a player's `vehicles_destroyed` counter
  # going up between two reads is the only trace the event leaves.
  defp replace_snapshot(state, snapshot) do
    if snapshot != state.snapshot and Engine.rules_for(state.rules, :vehicle_destroyed) != [] do
      state.snapshot
      |> vehicle_destroyers(snapshot)
      |> Enum.each(fn {player_id, player} ->
        Engine.process_player_trigger(state.server, state.rules, :vehicle_destroyed,
          player_id: player_id,
          player_name: player["name"],
          snapshot: snapshot
        )
      end)
    end

    publish_map(state.server.id, snapshot)
    %{state | snapshot: snapshot}
  end

  # The map being played, for pages that only need that - the sidebar's
  # server picture - without a CRCON call of their own. Kept in a
  # persistent term, written only when the map changes (every hour or so).
  defp publish_map(server_id, %{gamestate: %{"current_map" => map}}) when is_map(map) do
    key = {__MODULE__, :map, server_id}
    if :persistent_term.get(key, nil) != map, do: :persistent_term.put(key, map)
  end

  defp publish_map(_server_id, _snapshot), do: :ok

  @doc """
  The map a server is playing, as CRCON describes it (`current_map` of the
  game state), or nil before its engine has read it.
  """
  @spec current_map(term()) :: map() | nil
  def current_map(server_id), do: :persistent_term.get({__MODULE__, :map, server_id}, nil)

  # Players whose counter rose. A player missing from the old snapshot, or a
  # counter that went down (a new match), is not a destruction.
  defp vehicle_destroyers(%Snapshot{stale?: false} = old, %Snapshot{stale?: false} = new) do
    Enum.filter(new.players, fn {player_id, player} ->
      case Map.get(old.players, player_id) do
        %{"vehicles_destroyed" => before} when is_integer(before) ->
          is_integer(player["vehicles_destroyed"]) and player["vehicles_destroyed"] > before

        _unknown ->
          false
      end
    end)
  end

  defp vehicle_destroyers(_old, _new), do: []

  # With a rule listening for destroyed vehicles, the snapshot is refreshed
  # on every tick, so the window between two reads stays around ten seconds.
  defp watch_vehicles(state) do
    if Engine.rules_for(state.rules, :vehicle_destroyed) == [],
      do: state,
      else: refresh_snapshot(state)
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp connect_delay_ms do
    Application.get_env(:hll_conditional_actions, :connect_delay_ms, @default_connect_delay_ms)
  end

  @doc false
  @spec sorted_rules([Rule.t()]) :: [Rule.t()]
  def sorted_rules(rules), do: Rule.sort(rules)
end
