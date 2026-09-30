defmodule HllConditionalActions.Rules.Bench do
  @moduledoc """
  The data behind the builder's test bench ("bancada de testes"): what a rule
  *as typed* would have done with the real events of the last days, and what
  the saved rule actually did with the latest ones.

  ## The replay

  `replay/3` runs a rule over recorded events, oldest first, the way the
  engine would have: exemptions, then the limits, then the conditions, and on
  a match the escalation rung. Nothing is read from or written to the
  execution history - the rule keeps its own *virtual* history as it goes, so
  the cooldown, the per-player cap and the ladder behave as if the rule had
  been live for the whole window. That answers "had this draft been running
  all week, how often would it have fired, on whom, and which rung?".

  `compare/2` lines two replays over the same events up - the draft and the
  published rule - and names the players whose outcome changed.

  ## The recent runs

  `recent_runs/3` takes the latest events of the rule's trigger and says what
  the saved rule did with each: fired or simulated (matched to the execution
  it recorded), failed, held back by a limit, exempt, or not matched.

  ## Events

  The events are the samples the engine keeps for every evaluation
  (`HllConditionalActions.Engine.Samples` in memory, persisted in batches by
  `HllConditionalActions.Engine.SavedEvents`), so a replay only covers what
  those keep: `days/0` (7) days, up to `SavedEvents.keep/0` (2,000) per
  trigger and server. The replay reads at most `replay_limit/0` events, the
  newest - on a busy trigger, or across many servers, that is less than the
  whole week, and the panel says since when it covers. Loading them once
  per trigger and scope and judging a couple of thousand per edit keeps the
  builder responsive.
  """

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  import Ecto.Query

  alias HllConditionalActions.Discord
  alias HllConditionalActions.Discord.Client
  alias HllConditionalActions.Discord.Message
  alias HllConditionalActions.Engine
  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Evaluator
  alias HllConditionalActions.Engine.Samples
  alias HllConditionalActions.Engine.SavedEvents
  alias HllConditionalActions.Engine.Template
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules.Execution
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Servers.Server

  @days 7
  @replay_limit 2_000
  @cap_window_seconds 24 * 60 * 60
  @unlock_days 3

  @type event :: %{sample: map(), server: Server.t(), key: term()}

  @type judgement :: %{
          event: event(),
          outcome: :fires | :exempt | :cooldown | :max_executions | :conditions_not_met,
          step: non_neg_integer() | nil,
          actions: [non_neg_integer()]
        }

  @doc "How many days the replay looks back."
  @spec days() :: pos_integer()
  def days, do: @days

  @doc "At most how many events a replay reads: the newest of the window."
  @spec replay_limit() :: pos_integer()
  def replay_limit, do: @replay_limit

  @doc "How many days a rule simulates before it may go live."
  @spec unlock_days() :: pos_integer()
  def unlock_days, do: @unlock_days

  # ── Events ─────────────────────────────────────────────────────────────────

  @doc """
  The recorded events of a trigger on some servers since `:since` (default:
  `days/0` ago), oldest first.

  Options: `:since`, `:limit` (the newest this many, default
  `replay_limit/0`).
  """
  @spec events([Server.t()], atom(), keyword()) :: [event()]
  def events(servers, trigger, opts \\ [])
  def events([], _trigger, _opts), do: []
  def events(_servers, nil, _opts), do: []

  def events(servers, trigger, opts) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -@days, :day))
    limit = Keyword.get(opts, :limit, @replay_limit)
    by_id = Map.new(servers, &{&1.id, &1})
    ids = Map.keys(by_id)

    memory =
      ids
      |> Samples.list(trigger)
      |> Enum.filter(&recent?(&1, since))

    stored =
      ids
      |> SavedEvents.list(trigger: trigger, from: since, limit: limit)
      |> Enum.map(& &1.sample)

    # The ring and the table overlap: what the table holds is dropped when
    # the ring has it too. Both lists come newest first, ties in recording
    # order; reversed, a stable sort keeps two events of the same instant in
    # the order they happened.
    in_memory = MapSet.new(memory, &sample_key/1)

    (memory ++ Enum.reject(stored, &MapSet.member?(in_memory, sample_key(&1))))
    |> Enum.reverse()
    |> Enum.flat_map(fn sample ->
      case Map.fetch(by_id, sample.server_id) do
        {:ok, server} -> [%{sample: sample, server: server, key: sample_key(sample)}]
        :error -> []
      end
    end)
    |> Enum.sort_by(&sort_key/1)
    |> Enum.take(-limit)
  end

  defp recent?(%{at: %DateTime{} = at}, since), do: DateTime.compare(at, since) != :lt
  defp recent?(_sample, _since), do: false

  defp sample_key(sample),
    do: {sample.server_id, Map.get(sample, :at_us) || sample.at, sample.player_id}

  defp sort_key(%{sample: sample}),
    do: Map.get(sample, :at_us) || DateTime.to_unix(sample.at, :microsecond)

  @doc """
  The context an event was evaluated in, rebuilt on its server.
  """
  @spec context(event(), atom() | nil) :: Context.t()
  def context(%{sample: sample, server: server}, trigger \\ nil) do
    Samples.to_context(%{sample | trigger: trigger || sample.trigger}, server)
  end

  # ── Replay ─────────────────────────────────────────────────────────────────

  @doc """
  Runs `rule` over `events` (oldest first) with a virtual history; see the
  moduledoc. Returns

    * `:events` - how many events were judged
    * `:since` / `:short?` - when the oldest one happened, and whether that
      is well inside the window (nothing was recorded earlier, or the
      trigger is busy enough to hit the cap)
    * `:capped?` - whether there were `replay_limit/0` events or more, so
      the replay read only the newest of them
    * `:fires` - how many times the rule would have fired
    * `:players` / `:vip_players` - distinct players it would have reached,
      and how many of them held VIP at the time
    * `:steps` - per action index, how many times it would have run
    * `:outcomes` - how many events ended in each outcome
    * `:judged` - every event with its outcome, rung and actions, oldest first
  """
  @spec replay(Rule.t(), [event()]) :: map()
  def replay(%Rule{} = rule, events) do
    {judged, _history} =
      Enum.map_reduce(events, %{}, fn event, history ->
        judgement = judge(rule, event, history)
        {judgement, remember(history, judgement)}
      end)

    fired = Enum.filter(judged, &(&1.outcome == :fires))

    players =
      fired
      |> Enum.reject(&is_nil(&1.event.sample.player_id))
      |> Enum.uniq_by(& &1.event.sample.player_id)

    since =
      case judged do
        [first | _rest] -> first.event.sample.at
        [] -> nil
      end

    %{
      events: length(judged),
      # When the kept events start later than the replay window: nothing was
      # recorded before, or a busy trigger reached the cap sooner than a week.
      since: since,
      capped?: length(judged) >= @replay_limit,
      short?:
        not is_nil(since) and
          DateTime.diff(DateTime.utc_now(), since, :second) < (@days - 1) * 86_400,
      fires: length(fired),
      players: length(players),
      vip_players: Enum.count(players, &vip?(&1.event)),
      steps:
        rule.actions
        |> Enum.with_index()
        |> Enum.map(fn {action, index} ->
          %{index: index, action: action, count: Enum.count(fired, &(index in &1.actions))}
        end),
      outcomes: Enum.frequencies_by(judged, & &1.outcome),
      judged: judged
    }
  end

  defp judge(rule, event, history) do
    player_id = event.sample.player_id
    at = event.sample.at
    past = Map.get(history, player_id, [])
    strikes = strikes(rule, past, at)

    context =
      rule
      |> context_for(event)
      |> then(fn context -> %{context | extra: Map.put(context.extra, :strikes, strikes)} end)

    outcome =
      cond do
        Engine.exempt?(rule, context) -> :exempt
        limit = limit(rule, player_id, past, at) -> limit
        not Evaluator.evaluate(rule, context) -> :conditions_not_met
        true -> :fires
      end

    {step, actions} = rung(rule, outcome, player_id, strikes)

    %{
      event: event,
      outcome: outcome,
      step: step,
      actions: actions,
      # The actions themselves, so two versions of a rule can be told apart
      # by what they would run, not only by which rung.
      judged_actions: Enum.map(actions, &action_key(Enum.at(rule.actions, &1)))
    }
  end

  defp context_for(rule, event), do: context(event, rule.trigger_event)

  defp remember(history, %{outcome: :fires, event: %{sample: %{player_id: id, at: at}}})
       when is_binary(id),
       do: Map.update(history, id, [at], &[at | &1])

  defp remember(history, _judgement), do: history

  # Fires of this player inside the escalation window, before this event.
  defp strikes(%Rule{escalation_window_seconds: window}, past, at)
       when is_integer(window) and window > 0 do
    from = DateTime.add(at, -window, :second)
    Enum.count(past, &(DateTime.compare(&1, from) != :lt and DateTime.compare(&1, at) == :lt))
  end

  defp strikes(_rule, _past, _at), do: 0

  defp limit(_rule, nil, _past, _at), do: nil

  defp limit(rule, _player_id, past, at) do
    cooldown_from = DateTime.add(at, -(rule.cooldown_seconds || 0), :second)
    cap_from = DateTime.add(at, -@cap_window_seconds, :second)

    cond do
      (rule.cooldown_seconds || 0) > 0 and
          Enum.any?(past, &(DateTime.compare(&1, cooldown_from) != :lt)) ->
        :cooldown

      (rule.max_executions_per_player || 0) > 0 and
          Enum.count(past, &(DateTime.compare(&1, cap_from) != :lt)) >=
            rule.max_executions_per_player ->
        :max_executions

      true ->
        nil
    end
  end

  defp rung(_rule, outcome, _player_id, _strikes) when outcome != :fires, do: {nil, []}
  defp rung(%Rule{actions: []}, :fires, _player_id, _strikes), do: {nil, []}

  defp rung(%Rule{escalation_window_seconds: window} = rule, :fires, player_id, strikes)
       when is_integer(window) and window > 0 and is_binary(player_id) do
    step = min(strikes, length(rule.actions) - 1)
    {step, [step]}
  end

  defp rung(rule, :fires, _player_id, _strikes),
    do: {nil, Enum.to_list(0..(length(rule.actions) - 1))}

  defp vip?(%{sample: sample}), do: (sample.player || %{})["is_vip"] in [true, "true"]

  @doc """
  Lines up two replays of the same events - usually the draft and the
  published rule - and returns

    * `:delta` - fires in `replay` minus fires in `baseline`
    * `:changes` - one entry per player whose outcome changed, first change
      first: `%{player_id, player_name, vip?, events, step, kind, from, to}`
      where `kind` is `:now_fires`, `:no_longer_fires` or `:action` (fires in
      both, with a different action on that rung), and `from` / `to` are the
      outcomes, or the actions for `:action`
  """
  @spec compare(map(), map()) :: %{delta: integer(), changes: [map()]}
  def compare(replay, baseline) do
    counts = Enum.frequencies_by(replay.judged, & &1.event.sample.player_id)

    changes =
      replay.judged
      |> Enum.zip(baseline.judged)
      |> Enum.flat_map(fn {now, before} -> change(now, before) end)
      |> Enum.reject(&is_nil(&1.player_id))
      |> Enum.uniq_by(& &1.player_id)
      |> Enum.map(&Map.put(&1, :events, Map.get(counts, &1.player_id, 0)))

    %{delta: replay.fires - baseline.fires, changes: changes}
  end

  defp change(%{outcome: same}, %{outcome: same}) when same != :fires, do: []

  defp change(%{outcome: :fires} = now, %{outcome: :fires} = before) do
    now_actions = actions_of(now)
    before_actions = actions_of(before)

    if now_actions == before_actions,
      do: [],
      else: [entry(now, :action, before_actions, now_actions)]
  end

  defp change(%{outcome: :fires} = now, before),
    do: [entry(now, :now_fires, before.outcome, :fires)]

  defp change(now, %{outcome: :fires}),
    do: [entry(now, :no_longer_fires, :fires, now.outcome)]

  defp change(_now, _before), do: []

  defp actions_of(judgement), do: Map.get(judgement, :judged_actions, judgement.actions)

  defp entry(judgement, kind, from, to) do
    sample = judgement.event.sample

    %{
      player_id: sample.player_id,
      player_name: sample.player_name,
      vip?: vip?(judgement.event),
      step: judgement.step,
      kind: kind,
      from: from,
      to: to,
      at: sample.at
    }
  end

  defp action_key(nil), do: nil
  defp action_key(action), do: %{type: action.type, parameters: action.parameters || %{}}

  # ── Recent runs of the saved rule ──────────────────────────────────────────

  @doc """
  The latest `limit` events of a saved rule's trigger on `servers` since it
  was created, oldest first, each with what the rule did:

    * `:simulated`, `:fired`, `:error` - it fired, with the execution
    * `:held` - its conditions held but a limit kept it back
    * `:exempt` - the player is exempt
    * `:miss` - its conditions did not hold
    * `:idle` - it would have fired but recorded nothing (it was off or
      paused then)

  Executions whose event is no longer kept join the list with `event: nil`.
  """
  @spec recent_runs(Rule.t(), [Server.t()], pos_integer()) :: [map()]
  def recent_runs(rule, servers, limit \\ 48)
  def recent_runs(%Rule{id: nil}, _servers, _limit), do: []

  def recent_runs(%Rule{} = rule, servers, limit) do
    since = rule.inserted_at || DateTime.add(DateTime.utc_now(), -@days, :day)
    since = DateTime.from_naive!(to_naive(since), "Etc/UTC")

    events =
      servers
      |> Enum.filter(&Rule.applies_to?(rule, &1))
      |> events(rule.trigger_event, since: since, limit: limit)

    executions = executions_around(rule.id, events)

    {runs, used} =
      Enum.map_reduce(events, MapSet.new(), fn event, used ->
        execution = find_execution(executions, event, used)
        used = if execution, do: MapSet.put(used, execution.id), else: used
        {run(rule, event, execution, executions), used}
      end)

    # Executions whose event is no longer kept (events leave after a week, or
    # sooner on a trigger busy enough to reach the cap) still count: they are what the rule did, with the values
    # its conditions read in their trace.
    recorded =
      rule.id
      |> latest_executions(limit)
      |> Enum.reject(&MapSet.member?(used, &1.id))
      |> Enum.map(&run(rule, nil, &1, []))

    (runs ++ recorded)
    |> Enum.sort_by(&DateTime.to_unix(&1.at, :microsecond))
    |> Enum.take(-limit)
  end

  defp latest_executions(rule_id, limit) do
    Repo.all(
      from e in Execution,
        where: e.rule_id == ^rule_id,
        order_by: [desc: e.executed_at, desc: e.id],
        limit: ^limit
    )
  end

  defp to_naive(%DateTime{} = at), do: DateTime.to_naive(at)
  defp to_naive(%NaiveDateTime{} = at), do: at

  defp executions_around(_rule_id, []), do: []

  defp executions_around(rule_id, events) do
    first = hd(events).sample.at
    last = List.last(events).sample.at
    window = @cap_window_seconds

    Repo.all(
      from e in Execution,
        where:
          e.rule_id == ^rule_id and e.executed_at >= ^DateTime.add(first, -window, :second) and
            e.executed_at <= ^DateTime.add(last, 60, :second),
        order_by: [asc: e.executed_at]
    )
  end

  # The execution an event led to: the first one for the player within a
  # minute after it (a connect is handled a few seconds late on purpose).
  defp find_execution(executions, %{sample: sample}, used) do
    from = DateTime.add(sample.at, -2, :second)
    to = DateTime.add(sample.at, 60, :second)

    Enum.find(executions, fn execution ->
      execution.player_id == sample.player_id and execution.server_id == sample.server_id and
        not MapSet.member?(used, execution.id) and
        DateTime.compare(execution.executed_at, from) != :lt and
        DateTime.compare(execution.executed_at, to) != :gt
    end)
  end

  defp run(_rule, event, %Execution{} = execution, _executions) do
    outcome =
      case execution.status do
        :simulated -> :simulated
        :executed -> :fired
        _failed -> :error
      end

    %{
      event: event,
      outcome: outcome,
      execution: execution,
      step: trace_step(execution),
      at: (event && event.sample.at) || execution.executed_at
    }
  end

  defp run(rule, event, nil, executions) do
    context = context_for(rule, event)
    sample = event.sample

    past =
      executions
      |> Enum.filter(
        &(&1.player_id == sample.player_id and DateTime.compare(&1.executed_at, sample.at) == :lt)
      )
      |> Enum.map(& &1.executed_at)

    outcome =
      cond do
        Engine.exempt?(rule, context) -> :exempt
        not Evaluator.evaluate(rule, context) -> :miss
        limit(rule, sample.player_id, past, sample.at) -> :held
        true -> :idle
      end

    %{event: event, outcome: outcome, execution: nil, step: nil, at: sample.at}
  end

  defp trace_step(%Execution{trace: %{"step" => step}}) when is_integer(step), do: step - 1
  defp trace_step(_execution), do: nil

  @doc """
  The escalation rung a player was on at `at`, zero based: how many times the
  rule fired for them inside its window before then, capped at the last
  action. `nil` for a rule that does not escalate.
  """
  @spec step_at(Rule.t(), String.t() | nil, DateTime.t()) :: non_neg_integer() | nil
  def step_at(%Rule{escalation_window_seconds: window} = rule, player_id, at)
      when is_integer(window) and window > 0 and is_binary(player_id) and not is_nil(rule.id) do
    from = DateTime.add(at, -window, :second)

    count =
      Repo.one(
        from e in Execution,
          where:
            e.rule_id == ^rule.id and e.player_id == ^player_id and e.executed_at >= ^from and
              e.executed_at < ^DateTime.add(at, -2, :second),
          select: count(e.id)
      )

    min(count, max(length(rule.actions) - 1, 0))
  end

  def step_at(%Rule{escalation_window_seconds: window} = rule, _player_id, _at)
      when is_integer(window) and window > 0,
      do: if(rule.actions == [], do: nil, else: 0)

  def step_at(_rule, _player_id, _at), do: nil

  # ── Going live ─────────────────────────────────────────────────────────────

  @doc """
  How many days are left before a rule may go live: `0` for a rule that is
  (or has been) live, otherwise `unlock_days/0` minus the whole days since its
  first simulated run.
  """
  @spec live_in_days(Rule.t(), DateTime.t()) :: non_neg_integer()
  def live_in_days(rule, now \\ DateTime.utc_now())
  def live_in_days(%Rule{id: nil}, _now), do: @unlock_days
  def live_in_days(%Rule{enabled: true, simulation: false}, _now), do: 0

  def live_in_days(%Rule{id: id}, now) do
    ever_live? =
      Repo.exists?(from e in Execution, where: e.rule_id == ^id and e.status == :executed)

    first_simulated =
      Repo.one(
        from e in Execution,
          where: e.rule_id == ^id and e.status == :simulated,
          select: min(e.executed_at)
      )

    cond do
      ever_live? ->
        0

      is_nil(first_simulated) ->
        @unlock_days

      true ->
        elapsed = div(DateTime.diff(now, first_simulated, :second), 86_400)
        max(@unlock_days - elapsed, 0)
    end
  end

  # ── Actions ────────────────────────────────────────────────────────────────

  @doc """
  How each queued (Discord) action of a rule last ended, by action index:
  `%{0 => %{status: "delivered", detail: nil, at: ~U[...]}}`, from the latest
  executions that recorded a delivery.
  """
  @spec last_deliveries(term()) :: %{non_neg_integer() => map()}
  def last_deliveries(nil), do: %{}

  def last_deliveries(rule_id) do
    Repo.all(
      from e in Execution,
        where: e.rule_id == ^rule_id and e.deliveries != ^%{},
        order_by: [desc: e.executed_at],
        limit: 20,
        select: e.deliveries
    )
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn deliveries, acc ->
      Enum.reduce(deliveries, acc, &put_delivery/2)
    end)
  end

  defp put_delivery({index, entry}, acc) do
    case Integer.parse(to_string(index)) do
      {index, ""} -> Map.put(acc, index, delivery(entry))
      _other -> acc
    end
  end

  defp delivery(entry) when is_map(entry) do
    at =
      case DateTime.from_iso8601(to_string(entry["at"])) do
        {:ok, at, _offset} -> at
        _invalid -> nil
      end

    %{status: to_string(entry["status"]), detail: entry["detail"], at: at}
  end

  defp delivery(_entry), do: %{status: "?", detail: nil, at: nil}

  @doc """
  Posts a Discord action as it would look for `context`, marked as a test,
  to its webhook. Nothing is recorded against the rule.
  """
  @spec send_discord_test(map(), Context.t() | nil) :: :ok | {:error, String.t()}
  def send_discord_test(parameters, context) do
    case Discord.get_webhook(parameters["webhook_id"]) do
      nil ->
        {:error, gettext("Choose a webhook first.")}

      webhook ->
        render = fn text -> render_test_text(text, context) end

        payload =
          parameters
          |> Map.put("mode", "send")
          |> Message.build(render)
          |> Map.update("content", test_mark(), &(test_mark() <> " " <> &1))
          |> Map.put("allowed_mentions", %{"parse" => []})

        post_test(webhook, payload)
    end
  end

  defp render_test_text(text, nil), do: text || ""

  defp render_test_text(text, context),
    do: Template.render(text || "", context, escape: &Message.escape_markdown/1)

  defp post_test(webhook, payload) do
    case Client.post(webhook.url, payload) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        Discord.record_success(webhook.id)
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp test_mark, do: "[" <> gettext("test") <> "]"
end
