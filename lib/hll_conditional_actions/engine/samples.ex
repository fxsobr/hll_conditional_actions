defmodule HllConditionalActions.Engine.Samples do
  @moduledoc """
  The last evaluations the engine saw, kept so a rule can be replayed against
  them before it is trusted.

  Every time the engine builds a context for a trigger it drops a copy here,
  whether or not a rule was listening. The builder then re-evaluates the rule
  *as typed* against those contexts and says how many would have matched -
  "of the last 150 kills, 12 would have fired" - which catches a condition
  that is far stricter or looser than intended long before simulation would.

  Each `{server, trigger}` pair owns a fixed ring of slots in one ETS table,
  so recording is one counter bump and one insert, and memory is bounded no
  matter how busy a server is. Reads come from memory; new samples are
  also flushed to `HllConditionalActions.Engine.SavedEvents` every few
  seconds in batches (never a row per kill), which keeps a week of them on
  disk (capped per trigger, see `SavedEvents`) and warms the rings again
  after a restart.

  Only what the evaluator reads is stored. The roster is cut down to the
  player's own squad, which is all the squad conditions look at, so a sample
  stays small on a full server.
  """

  use GenServer

  require Logger

  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Evaluator
  alias HllConditionalActions.Engine.SavedEvents
  alias HllConditionalActions.Leaderboards
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Servers.Server

  @table __MODULE__

  @doc "How many evaluations are kept per server and trigger."
  @spec capacity() :: pos_integer()
  def capacity, do: 150

  # ── Recording ──────────────────────────────────────────────────────────────

  @doc """
  Keeps a copy of a context. A no-op while the table is not up, so the engine
  never depends on it.
  """
  @spec record(Context.t()) :: :ok
  def record(%Context{server: %Server{id: server_id}, trigger: trigger} = context)
      when not is_nil(server_id) do
    if :ets.whereis(@table) != :undefined do
      sample = to_sample(context)
      put(server_id, trigger, sample)
      if persist?(), do: GenServer.cast(__MODULE__, {:persist, sample})
    end

    :ok
  end

  def record(_context), do: :ok

  defp put(server_id, trigger, sample) do
    counter = {server_id, trigger, :counter}
    seq = :ets.update_counter(@table, counter, {2, 1}, {counter, 0})
    slot = rem(seq, capacity())

    :ets.insert(@table, {{server_id, trigger, slot}, seq, sample})
  end

  # Tests run the engine inside the Ecto sandbox, where a background writer
  # has no connection; they call `SavedEvents` directly instead.
  defp persist?, do: Application.get_env(:hll_conditional_actions, :persist_samples, true)

  @doc """
  The kept samples for a trigger on some servers, newest first.
  """
  @spec list([term()], atom()) :: [map()]
  def list(server_ids, trigger) do
    if :ets.whereis(@table) == :undefined do
      []
    else
      server_ids
      |> Enum.flat_map(fn server_id ->
        :ets.match_object(@table, {{server_id, trigger, :_}, :_, :_})
      end)
      |> Enum.reject(&match?({{_server, _trigger, :counter}, _count}, &1))
      # Two events can share a microsecond; the ring's own counter breaks the tie.
      |> Enum.sort_by(fn {_key, seq, sample} -> {sample.at_us, seq} end, :desc)
      |> Enum.map(fn {_key, _seq, sample} -> sample end)
    end
  end

  @doc """
  A context to show a rule's messages with: the latest real event of the
  trigger on these servers, or - before any was seen - an example player
  on the first server. Nil without a server.
  """
  @spec example_context([Server.t()], atom()) :: Context.t() | nil
  def example_context([], _trigger), do: nil

  def example_context(servers, trigger) do
    by_id = Map.new(servers, &{&1.id, &1})

    case list(Map.keys(by_id), trigger) do
      [sample | _rest] ->
        to_context(sample, Map.fetch!(by_id, sample.server_id))

      [] ->
        player = %{
          "player_id" => "76561198000000000",
          "name" => "Ana",
          "team" => "allies",
          "role" => "rifleman",
          "unit_name" => "able",
          "level" => 42,
          "kills" => 12,
          "deaths" => 4,
          "combat" => 180,
          "support" => 120
        }

        Context.build(hd(servers), trigger, player: player)
    end
  end

  @doc false
  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  # ── Replaying ──────────────────────────────────────────────────────────────

  @doc """
  Evaluates a rule against the samples kept for its trigger on `servers`.

  Limits and escalation are not applied: this answers "would the conditions
  have held", which is the part an admin gets wrong. `compare_to`, when
  given, is evaluated against the same samples, so the result can say how
  many outcomes an edit changes.

  Returns

    * `:total` / `:matched` - samples seen and samples the rule holds for
    * `:conditions` - per condition, how many samples it failed on, which is
      how you find the one condition that is blocking everything
    * `:changed` - samples where `compare_to` decides differently, or `nil`
    * `:examples` - a few recent samples with their outcome, for context
  """
  @spec replay(Rule.t(), [Server.t()], keyword()) :: map()
  def replay(%Rule{} = rule, servers, opts \\ []) do
    by_id = Map.new(servers, &{&1.id, &1})
    compare_to = Keyword.get(opts, :compare_to)

    judged =
      by_id
      |> Map.keys()
      |> list(rule.trigger_event)
      |> Enum.flat_map(fn sample ->
        case Map.fetch(by_id, sample.server_id) do
          {:ok, server} ->
            context = to_context(sample, server)
            explained = Evaluator.explain(rule, context)
            before = compare_to && Evaluator.explain(compare_to, context).result

            [%{sample: sample, server: server, explained: explained, before: before}]

          :error ->
            []
        end
      end)

    %{
      total: length(judged),
      matched: Enum.count(judged, & &1.explained.result),
      conditions: condition_failures(rule, judged),
      changed:
        compare_to &&
          Enum.count(judged, fn judgement -> judgement.before != judgement.explained.result end),
      examples:
        judged
        |> Enum.take(6)
        |> Enum.map(fn judgement ->
          %{
            player_name: judgement.sample.player_name,
            server_name: judgement.server.name,
            at: judgement.sample.at,
            result: judgement.explained.result
          }
        end)
    }
  end

  defp condition_failures(rule, judged) do
    rule.conditions
    |> Enum.with_index()
    |> Enum.map(fn {condition, index} ->
      %{field: condition.field, failed: Enum.count(judged, &failed_at?(&1, index))}
    end)
  end

  defp failed_at?(judgement, index) do
    match?(%{result: false}, Enum.at(judgement.explained.conditions, index))
  end

  # ── Samples ────────────────────────────────────────────────────────────────

  defp to_sample(context) do
    %{
      server_id: context.server.id,
      trigger: context.trigger,
      player_id: context.player_id,
      player_name: context.player_name,
      player: context.player,
      player_profile: context.player_profile,
      gamestate: context.gamestate,
      squad: context |> Context.squad() |> squad_roster(),
      ranks: Leaderboards.ranks(context.roster, context.player_id),
      event: context.event,
      at: DateTime.utc_now(),
      at_us: System.os_time(:microsecond)
    }
  end

  defp squad_roster(players) do
    Map.new(players, fn player -> {Map.get(player, "player_id"), player} end)
  end

  @doc """
  Rebuilds the context a sample was taken from, on a server.
  """
  @spec to_context(map(), Server.t()) :: Context.t()
  def to_context(sample, server) do
    Context.build(server, sample.trigger,
      player_id: sample.player_id,
      player_name: sample.player_name,
      player: sample.player,
      player_profile: sample.player_profile,
      gamestate: sample.gamestate,
      roster: sample.squad,
      event: sample.event,
      extra: %{ranks: Map.get(sample, :ranks, %{})}
    )
  end

  # ── Process ────────────────────────────────────────────────────────────────

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # New samples are written to `SavedEvents` in batches rather than one row
  # per kill: only the newest `SavedEvents.keep/0` of each trigger survive the
  # prune anyway, so the buffer keeps no more than that either.
  #
  # The state is the buffer (`pending`) and, per pair, how many rows were
  # written since it was last cut back to the cap (`unpruned`; `:unknown`
  # before its first write after a start, when nothing is known about it). A
  # pair is pruned when that is unknown or reaches `SavedEvents.prune_slack/0`,
  # rather than on every flush.
  @flush_ms :timer.seconds(10)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    state = %{pending: %{}, unpruned: %{}}

    if persist?() do
      Process.send_after(self(), :flush, @flush_ms)
      {:ok, state, {:continue, :warm}}
    else
      {:ok, state}
    end
  end

  # After a restart the ring starts from what was saved, so the builder's
  # replay has something to judge straight away. Only what fits the ring is
  # read back.
  @impl GenServer
  def handle_continue(:warm, state) do
    Enum.each(SavedEvents.latest_samples(capacity()), fn sample ->
      if sample.trigger, do: put(sample.server_id, sample.trigger, sample)
    end)

    {:noreply, state}
  rescue
    exception ->
      Logger.warning("[samples] could not load saved events: #{Exception.message(exception)}")
      {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:persist, sample}, state) do
    key = {sample.server_id, sample.trigger}

    pending =
      Map.update(state.pending, key, [sample], &Enum.take([sample | &1], SavedEvents.keep()))

    {:noreply, %{state | pending: pending}}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    Process.send_after(self(), :flush, @flush_ms)

    {:noreply, flush(state)}
  end

  @doc false
  # The batch write, split out so a test can drive it with a sandboxed
  # connection instead of the timer.
  @spec flush(map()) :: map()
  def flush(%{pending: pending} = state) when map_size(pending) == 0, do: state

  def flush(%{pending: pending, unpruned: unpruned}) do
    unpruned =
      Enum.reduce(pending, unpruned, fn {key, samples}, acc ->
        Map.update(acc, key, :unknown, &add_unpruned(&1, length(samples)))
      end)

    due =
      for {key, count} <- unpruned,
          count == :unknown or count >= SavedEvents.prune_slack(),
          do: key

    try do
      pending
      |> Map.values()
      |> List.flatten()
      |> Enum.reverse()
      |> SavedEvents.store(prune: due)

      %{pending: %{}, unpruned: Map.merge(unpruned, Map.new(due, &{&1, 0}))}
    rescue
      exception ->
        Logger.warning("[samples] could not save events: #{Exception.message(exception)}")
        %{pending: %{}, unpruned: unpruned}
    end
  end

  defp add_unpruned(:unknown, _count), do: :unknown
  defp add_unpruned(total, count), do: total + count
end
