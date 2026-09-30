defmodule HllConditionalActionsWeb.RuleLive.Show do
  @moduledoc """
  The 360 view of a rule: what it is, and whether it is working.

  An admin asks a rule the same few questions every time - *what does it
  say, is it healthy, what did it do lately, why did it not fire for this
  player, and who changed it?* Each has its own tab: the overview reads the
  rule as a sentence with its escalation ladder, its recent runs, the
  checklist before it acts for real and its latest change; the executions
  tab lists every evaluation of a window (the runs and the events it let
  pass) and opens any of them; "why didn't it fire?" walks a player's event
  through the rule; the definition edits the rule as an expression and shows
  it as JSON; versions compare any two changes and restore one.

  A rule in simulation gets a readiness banner built only from what its
  simulated runs recorded, so "can this act for real?" is answered on
  arrival. New executions arrive live over PubSub.
  """

  use HllConditionalActionsWeb, :live_view

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_rules}}

  import HllConditionalActionsWeb.RuleComponents
  import HllConditionalActionsWeb.RuleDiff, only: [rule_diff: 1]

  import HllConditionalActionsWeb.RulePause,
    only: [pause_menu_items: 1, pause_note: 1, pause_modal: 1]

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Discord
  alias HllConditionalActions.Engine
  alias HllConditionalActions.Engine.Diagnosis
  alias HllConditionalActions.Engine.Samples
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Audit
  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActions.Rules.Evaluations
  alias HllConditionalActions.Rules.Expression
  alias HllConditionalActions.Rules.Health
  alias HllConditionalActions.Rules.Insights
  alias HllConditionalActions.Rules.Snapshot
  alias HllConditionalActions.Rules.Transfer
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.RuleDiff
  alias HllConditionalActionsWeb.RuleLive.ShowTabs
  alias HllConditionalActionsWeb.RulePause

  @tabs ~w(overview executions why definition changes)
  @outcomes ~w(executed simulated partial failed no_match waiting capped exempt inactive unrecorded)a
  @page 25

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    rule = Rules.get_rule!(id)
    servers = Servers.list_servers_for(socket.assigns[:current_user])

    if connected?(socket), do: Engine.subscribe(rule.server_id)

    {:ok,
     socket
     |> assign(:rule, rule)
     |> assign(:page_title, rule.name)
     |> assign(:servers, servers)
     |> assign(:zone, zone(servers))
     |> assign(:editable?, Rules.editable_by?(rule, socket.assigns[:current_user]))
     |> assign(:tab, "overview")
     |> assign(:pause_open?, false)
     |> assign(:json, nil)
     |> assign(:json_errors, [])
     |> assign(:notify, %{"on" => false, "webhook_id" => nil})
     |> assign(:webhooks, [])
     |> assign(:exec_filters, %{
       "outcome" => "",
       "server_id" => "",
       "player" => "",
       "period" => "today",
       "from" => "",
       "to" => ""
     })
     |> assign(:exec_limit, @page)
     |> assign(:period_auto?, true)
     |> assign(:evaluations, nil)
     |> assign(:window, {nil, nil})
     |> assign(:open_row, nil)
     |> assign(:row_details, %{})
     |> assign(:definition_mode, "expression")
     |> assign(:expression, nil)
     |> assign(:parsed, nil)
     |> assign(:fields_open, false)
     |> assign(:field_chips, [])
     |> assign(:compare, nil)
     |> assign(:only_changes, false)
     |> assign(:replay, nil)
     |> assign(:why_player, nil)
     |> assign(:export_json, nil)
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    tab = tab_param(params["tab"])

    filters =
      socket.assigns.exec_filters
      |> then(fn filters ->
        case params["outcome"] do
          outcome when is_binary(outcome) -> Map.put(filters, "outcome", outcome)
          _none -> filters
        end
      end)
      |> then(fn filters ->
        case params["player"] do
          player when is_binary(player) and player != "" ->
            filters |> Map.put("player", player) |> Map.put("period", "week")

          _none ->
            filters
        end
      end)

    {:noreply,
     socket
     |> assign(:tab, tab)
     |> assign(:exec_filters, filters)
     |> assign(:why_player, if(tab == "why", do: params["player"]))
     |> load_tab()}
  end

  # ── Events: the rule ───────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("toggle", _params, socket) do
    if authorized?(socket) do
      {:ok, rule} = Rules.toggle_rule(socket.assigns.rule, actor: socket.assigns.current_user)
      {:noreply, reload(socket, rule)}
    else
      {:noreply, deny(socket)}
    end
  end

  # Taking a rule out of simulation is a published change like any other, so
  # it lands in the versions. With a draft pending the draft decides.
  def handle_event("go_live", _params, socket) do
    rule = socket.assigns.rule

    if authorized?(socket) and rule.simulation and is_nil(rule.draft) do
      case Rules.publish(rule, %{simulation: false}, actor: socket.assigns.current_user) do
        {:ok, rule} ->
          socket = notify_discord(socket, rule)

          {:noreply,
           socket
           |> put_flash(:info, gettext("The rule now acts on the game."))
           |> reload(rule)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Could not take the rule live."))}
      end
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("notify", params, socket) do
    webhook_id =
      params["webhook_id"] || socket.assigns.notify["webhook_id"] ||
        socket.assigns.webhooks |> List.first() |> then(&(&1 && to_string(&1.id)))

    {:noreply,
     assign(socket, :notify, %{"on" => params["on"] == "true", "webhook_id" => webhook_id})}
  end

  def handle_event("copy_to", %{"server_id" => server_id}, socket) do
    rule = socket.assigns.rule

    target =
      Enum.find(
        Rules.copy_targets(rule, socket.assigns.servers),
        &(to_string(&1.id) == server_id)
      )

    if authorized?(socket) and target do
      case Rules.duplicate_rule(rule, "",
             server_id: target.id,
             actor: socket.assigns.current_user
           ) do
        {:ok, copy} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("Copied to %{server}, switched off until you enable it there.",
               server: target.name
             )
           )
           |> push_navigate(to: ~p"/rules/#{copy}")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Could not duplicate that rule."))}
      end
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("duplicate", _params, socket) do
    if authorized?(socket) do
      case Rules.duplicate_rule(socket.assigns.rule, gettext("(copy)"),
             actor: socket.assigns.current_user
           ) do
        {:ok, rule} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Rule duplicated."))
           |> push_navigate(to: ~p"/rules/#{rule}")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Could not duplicate that rule."))}
      end
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("pause", params, socket) do
    if authorized?(socket) do
      case RulePause.run(socket.assigns.rule, params, socket.assigns.current_user) do
        {:ok, rule, message} ->
          {:noreply,
           socket
           |> assign(:pause_open?, false)
           |> put_flash(:info, message)
           |> reload(rule)}

        {:error, message} ->
          {:noreply, put_flash(socket, :error, message)}
      end
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("open_pause", _params, socket),
    do: {:noreply, assign(socket, :pause_open?, true)}

  def handle_event("close_pause", _params, socket),
    do: {:noreply, assign(socket, :pause_open?, false)}

  def handle_event("delete", _params, socket) do
    if authorized?(socket) do
      {:ok, _rule} = Rules.delete_rule(socket.assigns.rule, actor: socket.assigns.current_user)

      {:noreply,
       socket |> put_flash(:info, gettext("Rule removed.")) |> push_navigate(to: ~p"/rules")}
    else
      {:noreply, deny(socket)}
    end
  end

  # ── Events: drafts and versions ────────────────────────────────────────────

  def handle_event("publish_draft", _params, socket) do
    if authorized?(socket) do
      case Rules.publish_draft(socket.assigns.rule, actor: socket.assigns.current_user) do
        {:ok, rule} ->
          {:noreply, socket |> put_flash(:info, gettext("Draft published.")) |> reload(rule)}

        {:error, _reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("The draft no longer validates. Continue editing to fix it.")
           )}
      end
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("discard_draft", _params, socket) do
    if authorized?(socket) do
      {:ok, rule} = Rules.discard_draft(socket.assigns.rule)
      {:noreply, socket |> put_flash(:info, gettext("Draft discarded.")) |> reload(rule)}
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("restore_version", %{"id" => id}, socket) do
    if authorized?(socket) do
      case Rules.restore_version(socket.assigns.rule, id, actor: socket.assigns.current_user) do
        {:ok, rule} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("That version is now a draft. Review it and publish to make it live.")
           )
           |> reload(rule)}

        {:error, _reason} ->
          {:noreply,
           put_flash(socket, :error, gettext("That version can no longer be restored."))}
      end
    else
      {:noreply, deny(socket)}
    end
  end

  # Two versions are compared at a time; a click on a version newer than the
  # "after" moves the after, anything else becomes the "before".
  def handle_event("pick_version", %{"id" => id}, socket) do
    {before_id, after_id} = current_pair(socket.assigns)
    rows = socket.assigns.version_rows
    picked = Enum.find(rows, &(to_string(&1.version.id) == id))
    after_row = Enum.find(rows, &(&1.version.id == after_id))

    pair =
      cond do
        is_nil(picked) or picked.version.id == after_id -> {before_id, after_id}
        after_row && picked.number > after_row.number -> {after_id, picked.version.id}
        true -> {picked.version.id, after_id}
      end

    {:noreply, socket |> assign(:compare, pair) |> assign_replay()}
  end

  def handle_event("compare_versions", params, socket) do
    rows = socket.assigns.version_rows
    find = fn id -> Enum.find(rows, &(to_string(&1.version.id) == id)) end

    pair =
      case {find.(params["before"]), find.(params["after"])} do
        {%{} = a, %{} = b} when a.number > b.number -> {b.version.id, a.version.id}
        {%{} = a, %{} = b} -> {a.version.id, b.version.id}
        _other -> current_pair(socket.assigns)
      end

    {:noreply,
     socket
     |> assign(:compare, pair)
     |> assign(:only_changes, params["only_changes"] == "true")
     |> assign_replay()}
  end

  def handle_event("compare_with_current", _params, socket) do
    {before_id, _after_id} = current_pair(socket.assigns)
    latest = List.first(socket.assigns.version_rows)

    {:noreply,
     socket |> assign(:compare, {before_id, latest && latest.version.id}) |> assign_replay()}
  end

  # ── Events: the executions tab ─────────────────────────────────────────────

  def handle_event("exec_filter", params, socket) do
    filters =
      Map.merge(
        socket.assigns.exec_filters,
        Map.take(params, ["outcome", "server_id", "player", "period", "from", "to"])
      )

    {:noreply,
     socket
     |> assign(:exec_filters, filters)
     |> assign(:exec_limit, @page)
     |> assign(:period_auto?, false)
     |> load_evaluations()}
  end

  def handle_event("exec_outcome", %{"outcome" => outcome}, socket) do
    outcome = if socket.assigns.exec_filters["outcome"] == outcome, do: "", else: outcome

    {:noreply,
     socket
     |> update(:exec_filters, &Map.put(&1, "outcome", outcome))
     |> load_evaluations()}
  end

  def handle_event("exec_more", _params, socket) do
    {:noreply, update(socket, :exec_limit, &(&1 + @page))}
  end

  def handle_event("select_execution", %{"id" => id}, socket) do
    if socket.assigns.open_row == id do
      {:noreply, assign(socket, :open_row, nil)}
    else
      {:noreply, socket |> assign(:open_row, id) |> load_row_details(id)}
    end
  end

  # ── Events: the definition tab ─────────────────────────────────────────────

  def handle_event("definition_mode", %{"mode" => mode}, socket)
      when mode in ["visual", "expression"] do
    {:noreply, assign(socket, :definition_mode, mode)}
  end

  def handle_event("toggle_fields", _params, socket),
    do: {:noreply, update(socket, :fields_open, &(!&1))}

  def handle_event("expression_change", %{"expression" => text}, socket) do
    {:noreply, socket |> assign(:expression, text) |> assign(:parsed, parse(text, socket))}
  end

  def handle_event("expression_format", _params, socket) do
    case socket.assigns.parsed do
      {:ok, attrs} ->
        rule = socket.assigns.rule

        text =
          Expression.to_text(
            Map.merge(base_snapshot(rule), stringify(attrs)),
            comment(rule)
          )

        {:noreply, socket |> assign(:expression, text) |> assign(:parsed, parse(text, socket))}

      _error ->
        {:noreply, socket}
    end
  end

  def handle_event("expression_apply", _params, socket) do
    with true <- authorized?(socket),
         {:ok, attrs} <- socket.assigns.parsed,
         {:ok, saved, message} <- apply_expression(socket.assigns.rule, attrs, socket) do
      {:noreply, socket |> put_flash(:info, message) |> reload(saved)}
    else
      false ->
        {:noreply, deny(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :parsed, {:error, {{:invalid, changeset_text(changeset)}, 1, 1}})}

      _invalid ->
        {:noreply, socket}
    end
  end

  # ── Events: editing as JSON ────────────────────────────────────────────────

  def handle_event("json_open", _params, socket) do
    if authorized?(socket) do
      {:noreply,
       socket |> assign(:json, rule_json(socket.assigns.rule)) |> assign(:json_errors, [])}
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("json_close", _params, socket) do
    {:noreply, socket |> assign(:json, nil) |> assign(:json_errors, [])}
  end

  def handle_event("json_validate", %{"json" => json}, socket) do
    {:noreply,
     socket
     |> assign(:json, json)
     |> assign(:json_errors, json_errors(socket.assigns.rule, json))}
  end

  def handle_event("json_save", %{"json" => json} = params, socket) do
    with true <- authorized?(socket),
         {:ok, attrs} <- Transfer.decode_rule(json),
         {:ok, saved, message} <- save_json(socket.assigns.rule, attrs, params["intent"], socket) do
      {:noreply,
       socket
       |> assign(:json, nil)
       |> assign(:json_errors, [])
       |> put_flash(:info, message)
       |> reload(saved)}
    else
      false ->
        {:noreply, deny(socket)}

      {:error, message} when is_binary(message) ->
        {:noreply, socket |> assign(:json, json) |> assign(:json_errors, [{nil, message}])}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign(:json, json) |> assign(:json_errors, error_paths(changeset))}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:rule_fired, _execution}, socket),
    do: {:noreply, socket |> load() |> refresh_tab()}

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Loading ────────────────────────────────────────────────────────────────

  defp reload(socket, rule) do
    socket
    |> assign(:rule, Rules.get_rule!(rule.id))
    |> load()
    |> reset_expression()
    |> load_tab()
  end

  defp load(socket) do
    rule = socket.assigns.rule
    stats = Rules.execution_stats(rule_id: rule.id)
    versions = Audit.list_versions(rule.id)
    rows = version_rows(versions)

    socket
    |> assign(:stats, stats)
    |> assign(:state, state(rule, stats.total > 0))
    |> assign(:recent, Rules.list_executions(rule_id: rule.id, limit: 4))
    |> assign(:issues, Health.for_rule(rule, socket.assigns.servers))
    |> assign(:simulation, Insights.simulation(rule))
    |> assign(:step_counts, Insights.step_counts(rule))
    |> assign(:versions, versions)
    |> assign(:version_rows, rows)
    |> assign(:latest_change, latest_change(rows, socket.assigns.servers))
    |> assign(
      :draft_rows,
      rule.draft && RuleDiff.rows(Snapshot.take(rule), rule.draft, socket.assigns.servers)
    )
  end

  # Live runs only refresh what they change: the executions list.
  defp refresh_tab(%{assigns: %{tab: "executions"}} = socket), do: load_evaluations(socket)
  defp refresh_tab(socket), do: socket

  defp load_tab(%{assigns: %{tab: "executions"}} = socket), do: load_evaluations(socket)

  defp load_tab(%{assigns: %{tab: "definition"}} = socket) do
    socket
    |> then(&if(&1.assigns.expression, do: &1, else: reset_expression(&1)))
    |> assign(:field_chips, ShowTabs.top_field_chips())
    |> assign(:export_json, ShowTabs.export_json(socket.assigns.rule))
  end

  defp load_tab(%{assigns: %{tab: "changes"}} = socket), do: assign_replay(socket)

  defp load_tab(%{assigns: %{tab: "overview"}} = socket) do
    if socket.assigns.simulation != nil and socket.assigns.webhooks == [] and
         can_edit?(socket.assigns) do
      assign(socket, :webhooks, Discord.list_webhooks())
    else
      socket
    end
  end

  defp load_tab(socket), do: socket

  defp reset_expression(socket) do
    rule = socket.assigns.rule
    text = Expression.to_text(shown_rule(rule), comment(rule))
    socket |> assign(:expression, text) |> assign(:parsed, parse(text, socket))
  end

  defp load_evaluations(socket) do
    filters = socket.assigns.exec_filters
    {from, to} = window(filters, socket.assigns.zone)

    outcomes =
      case Enum.find(@outcomes, &(to_string(&1) == filters["outcome"])) do
        nil -> []
        :failed -> [:failed, :partial]
        :waiting -> [:waiting, :capped]
        outcome -> [outcome]
      end

    evaluations =
      Evaluations.list(socket.assigns.rule, socket.assigns.servers,
        from: from,
        to: to,
        server_id: blank(filters["server_id"]),
        player: blank(filters["player"]),
        outcomes: outcomes
      )

    # A quiet rule opens on its week rather than on an empty today, until
    # the admin picks a period.
    if evaluations.total == 0 and filters["period"] == "today" and socket.assigns.period_auto? do
      socket
      |> assign(:exec_filters, Map.put(filters, "period", "week"))
      |> assign(:period_auto?, false)
      |> load_evaluations()
    else
      socket
      |> assign(:evaluations, evaluations)
      |> assign(:window, {from, to})
    end
  end

  defp load_row_details(socket, "run-" <> _id = row_id) do
    case Enum.find(socket.assigns.evaluations.rows, &(&1.id == row_id)) do
      %{execution: execution} when not is_nil(execution) ->
        limits =
          socket.assigns.rule
          |> Insights.runs_before(execution.player_id, execution.executed_at)
          |> Enum.map(& &1.executed_at)

        update(socket, :row_details, &Map.put(&1, row_id, %{limits: limits}))

      _other ->
        socket
    end
  end

  defp load_row_details(socket, "event-" <> _id = row_id) do
    case Enum.find(socket.assigns.evaluations.rows, &(&1.id == row_id)) do
      %{event: sample, server: server, at: at} when not is_nil(sample) ->
        context = Samples.to_context(sample, server)
        diagnosis = Diagnosis.diagnose(socket.assigns.rule, context, at: at)
        update(socket, :row_details, &Map.put(&1, row_id, %{diagnosis: diagnosis}))

      _other ->
        socket
    end
  end

  defp load_row_details(socket, _id), do: socket

  # The time window of the executions tab, in the servers' zone.
  defp window(filters, zone) do
    now = DateTime.utc_now()

    case filters["period"] do
      "hour" ->
        {DateTime.add(now, -3600, :second), now}

      "week" ->
        {DateTime.add(now, -7 * 86_400, :second), now}

      "custom" ->
        from = parse_date(filters["from"])
        to = parse_date(filters["to"])

        {(from && start_of(from, zone)) || DateTime.add(now, -7 * 86_400, :second),
         (to && to |> Date.add(1) |> start_of(zone)) || now}

      _today ->
        {now |> local(zone) |> DateTime.to_date() |> start_of(zone), now}
    end
  end

  defp start_of(date, zone) do
    case DateTime.new(date, ~T[00:00:00], zone) do
      {:ok, at} -> DateTime.shift_zone!(at, "Etc/UTC")
      {:ambiguous, at, _later} -> DateTime.shift_zone!(at, "Etc/UTC")
      {:gap, _before, at} -> DateTime.shift_zone!(at, "Etc/UTC")
      _error -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _error -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: String.trim(value)

  # ── Versions ───────────────────────────────────────────────────────────────

  # Newest first, numbered from the oldest, each with the snapshot before it.
  defp version_rows(versions) do
    total = length(versions)
    older = Enum.drop(versions, 1) ++ [nil]

    versions
    |> Enum.zip(older)
    |> Enum.with_index()
    |> Enum.map(fn {{version, previous}, index} ->
      %{version: version, previous: previous && previous.snapshot, number: total - index}
    end)
  end

  # The newest change that touched the definition, with its rows.
  defp latest_change(rows, servers) do
    Enum.find_value(rows, fn row ->
      with now when is_map(now) <- row.version.snapshot,
           before when is_map(before) <- row.previous,
           [_ | _] = diff <- RuleDiff.rows(before, now, servers) do
        row
        |> Map.put(:rows, diff)
        |> Map.put(:lines, RuleDiff.changes(before, now, servers))
      else
        _other -> nil
      end
    end)
  end

  defp current_pair(%{compare: {before_id, after_id}}), do: {before_id, after_id}

  defp current_pair(%{version_rows: [latest, previous | _rest]}),
    do: {previous.version.id, latest.version.id}

  defp current_pair(%{version_rows: [latest]}), do: {nil, latest.version.id}
  defp current_pair(_assigns), do: {nil, nil}

  defp assign_replay(socket) do
    {before_id, after_id} = current_pair(socket.assigns)
    rows = socket.assigns.version_rows
    before = Enum.find(rows, &(&1.version.id == before_id))
    now = Enum.find(rows, &(&1.version.id == after_id))
    rule = socket.assigns.rule

    replay =
      with %{version: %{snapshot: a}} when is_map(a) <- before,
           %{version: %{snapshot: b}} when is_map(b) <- now,
           %{} = before_rule <- Snapshot.to_rule(rule, a),
           %{} = after_rule <- Snapshot.to_rule(rule, b) do
        Evaluations.replay(before_rule, after_rule, socket.assigns.servers)
      else
        _other -> nil
      end

    assign(socket, :replay, replay)
  end

  # ── Definition ─────────────────────────────────────────────────────────────

  # The rule as it reads now: the pending draft over the published rule.
  defp shown_rule(rule), do: Snapshot.to_rule(rule, rule.draft) || rule

  defp base_snapshot(rule), do: rule.draft || Snapshot.take(rule)

  defp comment(rule) do
    shown = shown_rule(rule)

    gettext("When: %{trigger}, on %{scope}",
      trigger: String.downcase(Labels.trigger(shown.trigger_event)),
      scope: String.downcase(scope_text(shown))
    )
  end

  defp parse(text, socket) do
    with {:ok, attrs} <- Expression.parse(text) do
      merged = Map.merge(base_snapshot(socket.assigns.rule), stringify(attrs))
      changeset = Rules.change_rule(socket.assigns.rule, merged)

      if changeset.valid?,
        do: {:ok, attrs},
        else: {:error, {{:invalid, changeset_text(changeset)}, 1, 1}}
    end
  end

  defp stringify(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(value) and not is_boolean(value) and not is_nil(value) ->
        {to_string(key), to_string(value)}

      {key, value} ->
        {to_string(key), value}
    end)
  end

  defp changeset_text(changeset) do
    changeset
    |> error_paths()
    |> Enum.map_join("; ", fn {path, message} -> "#{path}: #{message}" end)
  end

  # ── JSON ───────────────────────────────────────────────────────────────────

  # A live rule keeps the draft/publish split; anything else saves directly.
  defp save_json(rule, attrs, intent, socket) do
    actor = socket.assigns.current_user

    cond do
      not Rules.draft_required?(rule) ->
        with {:ok, saved} <- Rules.update_rule(rule, attrs, actor: actor),
             do: {:ok, saved, gettext("Rule saved.")}

      intent == "publish" ->
        with {:ok, saved} <- Rules.publish(rule, attrs, actor: actor),
             do: {:ok, saved, gettext("Rule published.")}

      true ->
        with {:ok, saved} <- Rules.save_draft(rule, attrs, actor: actor),
             do:
               {:ok, saved, gettext("Draft saved. The engine keeps running the published rule.")}
    end
  end

  # A live rule takes the expression as a draft; anything else saves it.
  defp apply_expression(rule, attrs, socket) do
    merged = Map.merge(base_snapshot(rule), stringify(attrs))
    actor = socket.assigns.current_user

    if Rules.draft_required?(rule) do
      with {:ok, saved} <- Rules.save_draft(rule, merged, actor: actor),
           do:
             {:ok, saved,
              gettext("Applied to the draft. The engine keeps running the published rule.")}
    else
      with {:ok, saved} <- Rules.update_rule(rule, merged, actor: actor),
           do: {:ok, saved, gettext("Rule saved.")}
    end
  end

  # The JSON starts from the draft when there is one, so edits pile onto it.
  defp rule_json(rule) do
    rule
    |> shown_rule()
    |> Transfer.dump_rule()
    |> Map.delete("enabled")
    |> Jason.encode!(pretty: true)
  end

  defp json_errors(rule, json) do
    case Transfer.decode_rule(json) do
      {:ok, attrs} ->
        changeset = Rules.change_rule(rule, attrs)
        if changeset.valid?, do: [], else: error_paths(changeset)

      {:error, message} ->
        [{nil, message}]
    end
  end

  # Changeset errors as `{"actions[1].parameters", message}`, so a mistake in
  # a long document can be found.
  defp error_paths(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&HllConditionalActionsWeb.CoreComponents.translate_error/1)
    |> flatten_errors(nil)
  end

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} -> flatten_errors(value, join_path(prefix, key)) end)
  end

  defp flatten_errors([first | _rest] = messages, path) when is_binary(first) do
    Enum.map(messages, &{path, &1})
  end

  defp flatten_errors(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> flatten_errors(value, "#{path}[#{index}]") end)
  end

  defp flatten_errors(_other, _path), do: []

  defp join_path(nil, key), do: to_string(key)
  defp join_path(prefix, key), do: "#{prefix}.#{key}"

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp tab_param(tab) when tab in @tabs, do: tab
  # The tab is labelled "Versions"; links written that way land on it too.
  defp tab_param("versions"), do: "changes"
  defp tab_param(_other), do: "overview"

  defp can_edit?(assigns),
    do: Accounts.can?(assigns.current_user, :manage_rules) and assigns.editable?

  defp authorized?(socket), do: can_edit?(socket.assigns)

  defp deny(socket) do
    put_flash(socket, :error, gettext("You do not have permission to change rules."))
  end

  # Posts the "now acting for real" notice when the checklist asked for it.
  defp notify_discord(socket, rule) do
    with %{"on" => true, "webhook_id" => id} <- socket.assigns.notify,
         %{} = webhook <- Discord.get_webhook(id) do
      user = socket.assigns.current_user
      name = user && (Map.get(user, :name) || Map.get(user, :username))

      text =
        gettext("%{rule} now acts on the game for real (switched by %{user}).",
          rule: rule.name,
          user: name || gettext("an admin")
        )

      case Discord.send_test(webhook, text) do
        :ok ->
          socket

        {:error, reason} ->
          put_flash(
            socket,
            :error,
            gettext("Discord did not take the notice: %{reason}", reason: reason)
          )
      end
    else
      _off -> socket
    end
  end

  # Can simulation end with nothing left to check? Only from what the
  # simulated runs recorded, after at least three days of them.
  defp ready?(%{runs: runs, failures: 0, days: days}, []) when runs > 0 and days >= 3, do: true
  defp ready?(_simulation, _issues), do: false

  defp go_live?(rule, simulation, issues) do
    rule.enabled and rule.simulation and is_nil(rule.draft) and simulation != nil and
      ready?(simulation, issues)
  end

  defp crumb(rule) do
    gettext("Rules") <>
      " / " <> if(rule.group in [nil, ""], do: gettext("Without a folder"), else: rule.group)
  end

  defp punishes?(rule) do
    punishing = Catalog.actions_in_group(:punishment)
    Enum.any?(rule.actions, &(&1.type in punishing))
  end

  defp checked_servers(rule, servers) do
    Enum.filter(servers, fn server ->
      server.game == rule.game and (is_nil(rule.server_id) or server.id == rule.server_id) and
        server.known_permissions != []
    end)
  end

  defp state_tone(:live), do: "live"
  defp state_tone(:simulating), do: "simulating"
  defp state_tone(:paused), do: "warning"
  defp state_tone(_draft), do: "neutral"

  defp version_number(rows), do: rows |> List.first() |> then(&(&1 && &1.number))

  defp pair_row(rows, id), do: id && Enum.find(rows, &(&1.version.id == id))

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    {before_id, after_id} = current_pair(assigns)

    assigns =
      assigns
      |> assign(:can_edit?, can_edit?(assigns))
      |> assign(:ready?, assigns.simulation != nil and ready?(assigns.simulation, assigns.issues))
      |> assign(:shown, shown_rule(assigns.rule))
      |> assign(:before_row, pair_row(assigns.version_rows, before_id))
      |> assign(
        :after_row,
        pair_row(assigns.version_rows, after_id) || List.first(assigns.version_rows)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@rule.name}
      crumb={crumb(@rule)}
      back={~p"/rules"}
      back_label={gettext("Back to rules")}
      badges={[%{id: "rule-state", label: state_label(@state), tone: state_tone(@state)}]}
      global_search={false}
      scope={false}
      bell={false}
    >
      <:actions>
        <.header_button
          patch={~p"/rules/#{@rule}?tab=why"}
          icon="hero-beaker"
          class="max-sm:hidden"
        >
          {gettext("Test with a player")}
        </.header_button>
        <.header_button
          :if={@can_edit?}
          navigate={~p"/rules/#{@rule}/edit"}
          class="max-sm:hidden"
        >
          {gettext("Edit")}
        </.header_button>
        <.header_button
          :if={@can_edit? and go_live?(@rule, @simulation, @issues)}
          id="rule-go-live"
          type="button"
          primary
          icon="hero-play-solid"
          phx-click="go_live"
          data-confirm={
            gettext(
              "Take this rule out of simulation? From now on its actions reach the game for real."
            )
          }
          class="max-sm:hidden"
        >
          {gettext("Go live for real")}
        </.header_button>
        <.header_button
          :if={@can_edit? and not @rule.enabled}
          id="rule-toggle"
          type="button"
          primary
          icon="hero-power"
          phx-click="toggle"
          class="max-sm:hidden"
        >
          {gettext("Turn on")}
        </.header_button>
        <.rule_menu
          :if={@can_edit?}
          id="rule-show-menu"
          label={gettext("More options")}
          class="size-11 border border-base-300 bg-base-100 text-base-content"
        >
          <.menu_item :if={@rule.enabled} icon="hero-power" phx-click="toggle">
            {gettext("Turn off")}
          </.menu_item>
          <.menu_item :if={not @rule.enabled} icon="hero-power" phx-click="toggle">
            {gettext("Turn on")}
          </.menu_item>
          <.menu_item icon="hero-pencil-square" navigate={~p"/rules/#{@rule}/edit"}>
            {gettext("Edit")}
          </.menu_item>
          <.pause_menu_items rule={@rule} on_custom="open_pause" />
          <.menu_item icon="hero-document-duplicate" phx-click="duplicate">
            {gettext("Duplicate")}
          </.menu_item>
          <%!-- A rule proven on one server is usually wanted on its siblings;
                  the copy arrives switched off there. --%>
          <.menu_item
            :for={server <- Rules.copy_targets(@rule, @servers)}
            id={"rule-copy-to-#{server.id}"}
            icon="hero-arrow-right-circle"
            phx-click="copy_to"
            phx-value-server_id={server.id}
          >
            {gettext("Copy to %{server}", server: server.name)}
          </.menu_item>
          <.menu_item
            tone="error"
            icon="hero-trash"
            phx-click="delete"
            data-confirm={gettext("Remove the rule \"%{name}\"?", name: @rule.name)}
          >
            {gettext("Remove")}
          </.menu_item>
        </.rule_menu>
      </:actions>

      <div class="flex flex-wrap items-center gap-x-2 gap-y-3 sm:-mt-2">
        <span class="sm:hidden"><.state_pill state={@state} /></span>
        <span class="text-xs text-muted sm:hidden">{meta_line(@rule)}</span>
        <.pill_tabs id="rule-tabs" label={gettext("Rule sections")}>
          <:tab patch={~p"/rules/#{@rule}"} active={@tab == "overview"}>
            {gettext("Overview")}
          </:tab>
          <:tab
            patch={~p"/rules/#{@rule}?tab=executions"}
            active={@tab == "executions"}
            count={@stats.total}
          >
            {gettext("Executions")}
          </:tab>
          <:tab patch={~p"/rules/#{@rule}?tab=why"} active={@tab == "why"}>
            {gettext("Why didn't it fire?")}
          </:tab>
          <:tab patch={~p"/rules/#{@rule}?tab=definition"} active={@tab == "definition"}>
            {gettext("Definition")}
          </:tab>
          <:tab
            patch={~p"/rules/#{@rule}?tab=changes"}
            active={@tab == "changes"}
            count={length(@versions)}
          >
            {gettext("Versions")}
          </:tab>
        </.pill_tabs>
        <span class="grow max-sm:hidden"></span>
        <span class="text-[0.8125rem] text-muted max-sm:hidden">{meta_line(@rule)}</span>
      </div>

      <div
        :for={issue <- @issues}
        class={[
          "flex items-start gap-3 rounded-2xl px-4 py-3 ring-1",
          if(issue.tone == "error",
            do: "bg-error/10 text-error ring-error/35",
            else: "bg-warning/10 text-warning ring-warning/35"
          )
        ]}
        role="alert"
      >
        <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0" />
        <div class="min-w-0">
          <p class="text-sm font-semibold">{Labels.health_issue(issue.id)}</p>
          <p class="text-[0.8125rem] text-base-content">{Labels.health_explanation(issue.id)}</p>
        </div>
      </div>

      <.pause_note rule={@rule} id="rule-paused-until" class="text-[0.8125rem]" />

      <.rule_panel
        :if={@rule.draft}
        id="rule-draft"
        title={gettext("Draft pending")}
        subtitle={
          gettext(
            "These edits are not live yet: the engine keeps running the published rule until the draft is published."
          )
        }
        class="ring-1 ring-warning/40"
      >
        <:action>
          <span :if={@rule.draft_user_name || @rule.draft_updated_at} class="text-xs text-muted">
            {@rule.draft_user_name || gettext("the system")}
            <.local_time
              :if={@rule.draft_updated_at}
              id="rule-draft-at"
              at={@rule.draft_updated_at}
            />
          </span>
        </:action>
        <.rule_diff
          id="rule-draft-diff"
          rows={@draft_rows}
          before_label={gettext("Published")}
          after_label={gettext("Draft")}
        />
        <div :if={@can_edit?} class="flex flex-wrap gap-2">
          <.button
            id="rule-draft-publish"
            type="button"
            size="sm"
            color="primary"
            icon="hero-rocket-launch"
            phx-click="publish_draft"
            data-confirm={gettext("Publish this draft? The engine starts using it right away.")}
            label={gettext("Publish")}
          />
          <.button
            id="rule-draft-discard"
            type="button"
            size="sm"
            variant="outline"
            color="gray"
            icon="hero-trash"
            phx-click="discard_draft"
            data-confirm={gettext("Discard this draft?")}
            label={gettext("Discard")}
          />
          <.button
            id="rule-draft-continue"
            link_type="live_redirect"
            to={~p"/rules/#{@rule}/edit"}
            size="sm"
            variant="ghost"
            color="gray"
            icon="hero-pencil-square"
            label={gettext("Continue editing")}
          />
        </div>
      </.rule_panel>

      <%!-- ── Overview ───────────────────────────────────────────────────── --%>
      <.readiness
        :if={@tab == "overview" and @simulation != nil and @rule.enabled}
        rule={@rule}
        simulation={@simulation}
        issues={@issues}
        ready={@ready?}
        zone={@zone}
      />

      <div
        :if={@tab == "overview"}
        class="grid items-start gap-5 xl:grid-cols-[minmax(0,1fr)_27.5rem]"
      >
        <div class="flex min-w-0 flex-col gap-5">
          <section
            id="rule-sentence"
            class="flex flex-col gap-[1.125rem] rounded-3xl bg-base-100 px-[1.125rem] py-4 sm:rounded-[1.75rem] sm:px-7 sm:py-6"
          >
            <div class="flex items-baseline gap-3">
              <h2 class="flex-1 font-display text-[1.0625rem] font-semibold sm:text-xl">
                <span class="max-sm:hidden">{gettext("The rule, in one sentence")}</span>
                <span class="sm:hidden">
                  {if @rule.escalation_window_seconds > 0 and length(@rule.actions) > 1,
                    do: gettext("The ladder"),
                    else: gettext("The rule")}
                </span>
              </h2>
              <.link
                :if={@can_edit?}
                navigate={~p"/rules/#{@rule}/edit"}
                class="text-[0.8125rem] text-primary max-sm:hidden"
              >
                {gettext("Edit the sentence")}
              </.link>
              <span
                :if={@rule.escalation_window_seconds > 0 and length(@rule.actions) > 1}
                class="text-xs text-muted sm:hidden"
              >
                {gettext("resets after %{time}", time: duration_text(@rule.escalation_window_seconds))}
              </span>
            </div>
            <.rule_sentence_chips rule={@rule} class="text-xl leading-[1.7] max-sm:hidden" />

            <div
              :if={@rule.escalation_window_seconds > 0 and length(@rule.actions) > 1}
              class="flex flex-col gap-2"
            >
              <div class="max-sm:hidden">
                <.ladder id="rule-ladder" rule={@rule} counts={@step_counts} />
              </div>
              <div class="sm:hidden">
                <.ladder id="rule-ladder-m" rule={@rule} counts={@step_counts} compact />
              </div>
              <p class="text-xs text-muted max-sm:hidden">
                {if @rule.simulation,
                  do: gettext("Numbers: how many times each step would have run in simulation."),
                  else: gettext("Numbers: how many times each step ran.")}
              </p>
            </div>
            <p
              :if={not (@rule.escalation_window_seconds > 0 and length(@rule.actions) > 1)}
              class="text-[0.8125rem] text-subtle sm:hidden"
            >
              {short_sentence(@rule)}
            </p>
          </section>

          <section
            id="rule-recent"
            class="flex min-w-0 flex-col gap-1.5 rounded-3xl bg-base-100 px-[1.125rem] py-3.5 sm:rounded-[1.75rem] sm:px-7 sm:py-5"
          >
            <div class="flex items-baseline gap-3">
              <h2 class="flex-1 font-display text-[1.0625rem] font-semibold sm:text-xl">
                {gettext("Latest executions")}
              </h2>
              <.link
                :if={@recent != []}
                patch={~p"/rules/#{@rule}?tab=executions"}
                class="text-[0.8125rem] text-primary"
              >
                <span class="max-sm:hidden">{gettext("See all")}</span>
                <span class="sm:hidden">
                  {gettext("See %{count}", count: number(@stats.total))}
                </span>
              </.link>
            </div>

            <p :if={@recent == []} class="py-4 text-center text-[0.8125rem] text-muted">
              {gettext("This rule has not fired yet")}
            </p>

            <ul :if={@recent != []} id="rule-timeline" class="flex flex-col">
              <li
                :for={execution <- @recent}
                class="grid grid-cols-[2.5rem_minmax(0,1fr)_auto] items-center gap-x-2.5 border-b border-base-300 py-[9px] text-sm last:border-b-0 sm:grid-cols-[4.375rem_minmax(0,1fr)_11.875rem_7.5rem_5.75rem] sm:gap-x-3"
              >
                <span class="font-mono text-[0.6875rem] text-muted sm:text-xs">
                  {execution.executed_at |> local(@zone) |> Calendar.strftime("%H:%M")}
                </span>
                <span class="flex min-w-0 flex-col">
                  <strong class="truncate font-semibold">
                    {execution.player_name || gettext("server wide")}
                  </strong>
                  <span class="truncate text-xs text-muted sm:hidden">
                    {summary(execution) || "—"}
                  </span>
                </span>
                <span class="truncate text-subtle max-sm:hidden">{summary(execution) || "—"}</span>
                <span class="truncate text-muted max-sm:hidden">{execution.server.name}</span>
                <span class="justify-self-end">
                  <.result_pill status={execution.status} size="xs" />
                </span>
              </li>
            </ul>
          </section>
        </div>

        <div class="flex min-w-0 flex-col gap-5">
          <.checklist
            :if={@simulation != nil and @rule.enabled}
            rule={@rule}
            simulation={@simulation}
            issues={@issues}
            servers={checked_servers(@rule, @servers)}
            webhooks={@webhooks}
            notify={@notify}
            can_edit={@can_edit?}
          />

          <.rule_panel
            :if={is_nil(@simulation) or not @rule.enabled}
            id="rule-numbers"
            title={gettext("Outcomes")}
          >
            <div class="grid grid-cols-2 gap-2.5">
              <.kpi_tile
                label={gettext("Times fired")}
                value={number(@stats.total)}
                hint={gettext("since the history began")}
              />
              <.kpi_tile
                label={gettext("Last 24 hours")}
                value={number(@stats.last_24h)}
                hint={gettext("how busy it is right now")}
                tone={if @stats.last_24h > 0, do: "primary"}
              />
              <.kpi_tile
                label={gettext("Players reached")}
                value={number(@stats.players)}
                hint={gettext("distinct players")}
              />
              <.kpi_tile
                label={gettext("Failures")}
                value={number(Map.get(@stats.by_status, :failed, 0))}
                hint={failure_hint(@stats)}
                tone={if Map.get(@stats.by_status, :failed, 0) > 0, do: "error"}
              />
            </div>
            <div
              :if={@stats.total > 0}
              class="flex h-2.5 gap-[3px] overflow-hidden rounded"
              role="img"
              aria-label={gettext("Runs by outcome")}
            >
              <span
                :for={{status, count} <- @stats.by_status}
                class={["rounded", result_fill(status)]}
                style={"flex-grow: #{count}"}
              ></span>
            </div>
            <ul :if={@stats.total > 0} class="flex flex-wrap gap-x-3 gap-y-1 text-xs text-subtle">
              <li :for={{status, count} <- @stats.by_status} class="flex items-center gap-1.5">
                <span class={["size-2 rounded-[3px]", result_fill(status)]} aria-hidden="true"></span>
                {outcome_label(status)}
                <span class="font-mono text-base-content">{number(count)}</span>
              </li>
            </ul>
            <dl class="flex flex-col divide-y divide-base-300 border-t border-base-300 text-[0.8125rem]">
              <div class="flex justify-between gap-3 py-2">
                <dt class="text-muted">{gettext("Last fired")}</dt>
                <dd>{when_text(@stats.last_executed_at, @zone)}</dd>
              </div>
              <div class="flex justify-between gap-3 py-2">
                <dt class="text-muted">{gettext("Limits")}</dt>
                <dd class="text-right">{limits_sentence(@rule)}</dd>
              </div>
            </dl>
          </.rule_panel>

          <section
            :if={@latest_change}
            id="rule-latest-change"
            class="flex min-w-0 flex-col gap-3.5 rounded-[1.75rem] bg-accent/8 px-6 py-[1.375rem] ring-1 ring-accent/25 max-sm:hidden"
          >
            <div class="flex items-baseline gap-3">
              <h2 class="flex-1 font-display text-xl font-semibold">
                {gettext("What changed in version %{number}", number: @latest_change.number)}
              </h2>
              <span class="text-xs text-accent/80">
                {when_text(@latest_change.version.inserted_at, @zone)}
              </span>
            </div>
            <p class="text-[0.8125rem] text-subtle">
              {RuleDiff.note(@latest_change.version.user_name, change_lines(@latest_change))}
            </p>
            <div class="grid grid-cols-[minmax(0,1fr)_1.25rem_minmax(0,1fr)] items-stretch gap-2.5">
              <div class="flex flex-col gap-2 rounded-[0.875rem] bg-base-200 px-3.5 py-3 font-mono text-xs text-accent/80">
                <span class="text-[0.6875rem] uppercase tracking-[0.08em]">
                  {gettext("Before · v%{number}", number: @latest_change.number - 1)}
                </span>
                <span
                  :for={{label, before, _after} <- Enum.take(change_lines(@latest_change), 4)}
                  class="break-words text-error"
                >
                  {label}: {before || "—"}
                </span>
              </div>
              <span class="flex items-center justify-center">
                <.icon name="hero-arrow-right" class="size-4 text-accent" />
              </span>
              <div class="flex flex-col gap-2 rounded-[0.875rem] bg-base-200 px-3.5 py-3 font-mono text-xs ring-1 ring-primary/35">
                <span class="text-[0.6875rem] uppercase tracking-[0.08em] text-primary">
                  {gettext("Now · v%{number}", number: @latest_change.number)}
                </span>
                <span
                  :for={{label, _before, after_value} <- Enum.take(change_lines(@latest_change), 4)}
                  class="break-words text-primary"
                >
                  {label}: {after_value || "—"}
                </span>
              </div>
            </div>
            <div class="flex flex-wrap gap-2.5 pt-2">
              <button
                :if={@can_edit? and previous_version_id(@version_rows, @latest_change)}
                type="button"
                phx-click="restore_version"
                phx-value-id={previous_version_id(@version_rows, @latest_change)}
                data-confirm={
                  gettext("Load this version as a draft? Nothing changes until you publish it.")
                }
                class="h-11 cursor-pointer rounded-full border border-accent/30 px-[1.125rem] text-sm font-medium transition-colors hover:bg-accent/10"
              >
                {gettext("Restore v%{number}", number: @latest_change.number - 1)}
              </button>
              <.link
                patch={~p"/rules/#{@rule}?tab=changes"}
                class="flex h-11 items-center rounded-full bg-accent/20 px-[1.125rem] text-sm font-medium transition-colors hover:bg-accent/30"
              >
                {gettext("All versions")}
              </.link>
            </div>
          </section>
        </div>
      </div>

      <%!-- The phone keeps the one move that matters within thumb reach. --%>
      <div
        :if={@tab == "overview" and @can_edit? and go_live?(@rule, @simulation, @issues)}
        class="sticky bottom-20 z-20 -mx-4 border-t border-base-300 bg-base-200 px-4 pt-3 pb-2 sm:hidden"
      >
        <button
          id="rule-go-live-m"
          type="button"
          phx-click="go_live"
          data-confirm={
            gettext(
              "Take this rule out of simulation? From now on its actions reach the game for real."
            )
          }
          class="flex h-14 w-full cursor-pointer items-center justify-center gap-2.5 rounded-full bg-primary text-base font-semibold text-primary-content"
        >
          <.icon name="hero-play-solid" class="size-5" /> {gettext("Go live for real")}
        </button>
      </div>

      <%!-- ── Executions ─────────────────────────────────────────────────── --%>
      <.executions_tab
        :if={@tab == "executions" and @evaluations != nil}
        rule={@rule}
        evaluations={@evaluations}
        filters={@exec_filters}
        limit={@exec_limit}
        open_row={@open_row}
        details={@row_details}
        servers={@servers}
        zone={@zone}
        window={@window}
      />

      <.pause_modal :if={@pause_open?} rule={@rule} on_cancel={JS.push("close_pause")} />

      <%!-- ── Why didn't it fire ─────────────────────────────────────────── --%>
      <.live_component
        :if={@tab == "why"}
        module={HllConditionalActionsWeb.RuleLive.WhyNot}
        id="why-not"
        rule={@rule}
        servers={@servers}
        zone={@zone}
        version={version_number(@version_rows)}
        player={@why_player}
      />

      <%!-- ── Versions ───────────────────────────────────────────────────── --%>
      <div :if={@tab == "changes"}>
        <.empty_state
          :if={@versions == []}
          icon="hero-clock"
          title={gettext("No changes recorded yet")}
          description={
            gettext(
              "Every edit from now on is recorded here with who made it, so a rule that starts banning people can always be traced back."
            )
          }
        />
        <ShowTabs.versions_tab
          :if={@versions != []}
          rows={@version_rows}
          older={@before_row}
          newer={@after_row}
          servers={@servers}
          rule={@rule}
          can_edit={@can_edit?}
          only_changes={@only_changes}
          replay={@replay}
          zone={@zone}
        />
      </div>

      <%!-- ── Definition ─────────────────────────────────────────────────── --%>
      <ShowTabs.definition_tab
        :if={@tab == "definition" and @expression != nil}
        rule={@rule}
        shown={@shown}
        mode={@definition_mode}
        expression={@expression}
        parsed={@parsed}
        can_edit={@can_edit?}
        json={@json}
        json_errors={@json_errors}
        fields_open={@fields_open}
        chips={@field_chips}
        export={@export_json}
        version={version_number(@version_rows)}
        zone={@zone}
      />
    </Layouts.app>
    """
  end

  defp previous_version_id(rows, change) do
    case Enum.find(rows, &(&1.number == change.number - 1)) do
      nil -> nil
      row -> row.version.id
    end
  end

  # The lines the change card shows: the definition lines that moved, or the
  # history's own fields when only something outside them changed.
  defp change_lines(%{lines: [_ | _] = lines}), do: lines

  defp change_lines(%{rows: rows}) do
    Enum.map(rows, fn row ->
      {String.replace(row.label, ~r/\s*\(.*\)\s*$/, ""), Enum.join(row.from, ", "),
       Enum.join(row.to, ", ")}
    end)
  end

  # ── Pieces of this page ────────────────────────────────────────────────────

  attr :rule, :map, required: true
  attr :simulation, :map, required: true
  attr :issues, :list, required: true
  attr :ready, :boolean, required: true
  attr :zone, :string, required: true

  # Whether a simulating rule has shown enough to act for real, said with
  # nothing but its own simulated runs.
  defp readiness(assigns) do
    ~H"""
    <section
      id="rule-readiness"
      class={[
        "flex flex-wrap items-center gap-x-5 gap-y-3 rounded-3xl px-[1.125rem] py-4 sm:rounded-[1.75rem] sm:px-7 sm:py-[1.375rem]",
        if(@ready,
          do: "bg-primary-300 text-primary-950",
          else: "bg-accent/10 ring-1 ring-accent/30"
        )
      ]}
    >
      <div class="flex min-w-0 flex-1 basis-60 items-center gap-3 sm:gap-5">
        <span class={[
          "flex size-[2.375rem] shrink-0 items-center justify-center rounded-full sm:size-13",
          if(@ready, do: "bg-primary-950 text-primary-300", else: "bg-accent/15 text-accent")
        ]}>
          <.icon name={if @ready, do: "hero-check", else: "hero-beaker"} class="size-5 sm:size-6" />
        </span>

        <div class="flex min-w-0 flex-1 flex-col gap-1">
          <h2 class="font-display text-[1.3125rem] font-semibold tracking-[-0.02em] sm:text-[1.75rem]">
            <span :if={@ready} class="sm:hidden">{gettext("Ready to act")}</span>
            <span :if={@ready} class="max-sm:hidden">{gettext("Ready to act for real")}</span>
            <span :if={!@ready}>{gettext("Still simulating")}</span>
          </h2>
          <p class={[
            "text-sm max-sm:hidden",
            if(@ready, do: "opacity-80", else: "text-subtle")
          ]}>
            {readiness_line(@simulation, @issues)}
          </p>
        </div>
      </div>
      <p class={[
        "w-full text-[0.8125rem] sm:hidden",
        if(@ready, do: "opacity-80", else: "text-subtle")
      ]}>
        {readiness_line(@simulation, @issues)}
      </p>

      <dl :if={@simulation.runs > 0} class="grid grid-cols-2 gap-2 max-sm:w-full sm:flex sm:gap-8">
        <div class={[
          "flex flex-col gap-0.5 max-sm:rounded-[0.875rem] max-sm:px-3 max-sm:py-2",
          if(@ready, do: "max-sm:bg-primary-950/8", else: "max-sm:bg-accent/10")
        ]}>
          <dt class={["text-[0.6875rem] sm:text-xs", if(@ready, do: "opacity-80", else: "text-muted")]}>
            {gettext("Simulating since")}
          </dt>
          <dd class="font-display text-[1.0625rem] font-semibold sm:text-[1.375rem]">
            {@simulation.since |> local(@zone) |> DateTime.to_date() |> day_month()}
          </dd>
        </div>
        <div class={[
          "flex flex-col gap-0.5 max-sm:rounded-[0.875rem] max-sm:px-3 max-sm:py-2",
          if(@ready, do: "max-sm:bg-primary-950/8", else: "max-sm:bg-accent/10")
        ]}>
          <dt class={["text-[0.6875rem] sm:text-xs", if(@ready, do: "opacity-80", else: "text-muted")]}>
            {if punishes?(@rule),
              do: gettext("Would have punished"),
              else: gettext("Would have reached")}
          </dt>
          <dd class="font-display text-[1.0625rem] font-semibold sm:text-[1.375rem]">
            {ngettext("1 player", "%{count} players", @simulation.players)}
          </dd>
        </div>
      </dl>
    </section>
    """
  end

  defp readiness_line(%{runs: 0}, _issues),
    do: gettext("No simulated run yet: nothing has matched since it started simulating.")

  defp readiness_line(simulation, issues) do
    [
      ngettext("1 day in simulation", "%{count} days in simulation", simulation.days),
      ngettext("1 run", "%{count} runs", simulation.runs, count: number(simulation.runs)),
      if(simulation.failures == 0,
        do: gettext("no failure on CRCON"),
        else:
          ngettext("1 failure to look at", "%{count} failures to look at", simulation.failures)
      ),
      if(issues == [],
        do: gettext("no health warning"),
        else: ngettext("1 health warning", "%{count} health warnings", length(issues))
      )
    ]
    |> Enum.join(" · ")
  end

  attr :rule, :map, required: true
  attr :simulation, :map, required: true
  attr :issues, :list, required: true
  attr :servers, :list, required: true
  attr :webhooks, :list, required: true
  attr :notify, :map, required: true
  attr :can_edit, :boolean, required: true

  # What to check before a simulating rule acts for real.
  defp checklist(assigns) do
    assigns =
      assigns
      |> assign(:permission_issue, Enum.find(assigns.issues, &(&1.id == :missing_permission)))
      |> assign(
        :exempt,
        HllConditionalActionsWeb.RuleBuilder.exemptions_text(assigns.rule.exemptions)
      )

    ~H"""
    <section
      id="rule-checklist"
      class="flex flex-col gap-3 rounded-[1.75rem] bg-base-100 px-6 py-[1.375rem] max-sm:hidden"
    >
      <h2 class="font-display text-xl font-semibold">{gettext("Before going live")}</h2>
      <ul class="flex flex-col gap-3">
        <.check_item
          ok={@simulation.days >= 3 and @simulation.runs > 0}
          title={gettext("Ran at least 3 days in simulation")}
        >
          {ngettext("1 day", "%{count} days", @simulation.days)}, {ngettext(
            "1 run",
            "%{count} runs",
            @simulation.runs,
            count: number(@simulation.runs)
          )}
          <span :if={@simulation.servers > 1}>
            {ngettext("on 1 server", "on %{count} servers", @simulation.servers)}
          </span>
        </.check_item>
        <.check_item
          ok={is_nil(@permission_issue) and @servers != [] and @simulation.failures == 0}
          title={gettext("The CRCON key can run: %{actions}", actions: action_list(@rule))}
        >
          <%= cond do %>
            <% @permission_issue -> %>
              {gettext("Missing on the key: %{actions}", actions: @permission_issue.detail)}
            <% @servers == [] -> %>
              {gettext("Not checked yet: test the server's connection")}
            <% @simulation.failures > 0 -> %>
              {ngettext(
                "1 run failed on CRCON",
                "%{count} runs failed on CRCON",
                @simulation.failures
              )}
            <% true -> %>
              {ngettext("Checked on 1 server", "Checked on %{count} servers", length(@servers))}
          <% end %>
        </.check_item>
        <.check_item ok={not is_nil(@exempt)} title={gettext("Exemptions reviewed")}>
          {if @exempt,
            do: gettext("%{who} stay out", who: @exempt),
            else: gettext("Nobody is left out: it applies to everyone")}
        </.check_item>
        <li :if={@can_edit and @webhooks != []}>
          <form id="rule-notify" phx-change="notify" class="flex items-start gap-3">
            <input type="hidden" name="on" value="false" />
            <input
              id="rule-notify-on"
              type="checkbox"
              name="on"
              value="true"
              checked={@notify["on"]}
              class="pc-checkbox mt-px size-[1.375rem] shrink-0 rounded-[0.4375rem]"
            />
            <span class="flex min-w-0 flex-col gap-0.5">
              <label for="rule-notify-on" class="text-sm">
                {gettext("Tell Discord when it goes live")}
              </label>
              <select
                name="webhook_id"
                aria-label={gettext("Discord channel")}
                class="w-fit cursor-pointer border-0 bg-transparent p-0 pr-6 text-xs text-muted focus:ring-0"
              >
                <option
                  :for={webhook <- @webhooks}
                  value={webhook.id}
                  selected={to_string(webhook.id) == @notify["webhook_id"]}
                >
                  {gettext("Channel %{name}", name: webhook.name)}
                </option>
              </select>
            </span>
          </form>
        </li>
      </ul>
    </section>
    """
  end

  defp action_list(rule) do
    rule.actions
    |> Enum.map(&String.downcase(Labels.action(&1.type)))
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  attr :ok, :boolean, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp check_item(assigns) do
    ~H"""
    <li class="flex items-start gap-3">
      <span class={[
        "flex size-[1.375rem] shrink-0 items-center justify-center rounded-[0.4375rem]",
        if(@ok, do: "bg-primary-300 text-primary-950", else: "bg-warning/13 text-warning")
      ]}>
        <.icon name={if @ok, do: "hero-check", else: "hero-exclamation-triangle"} class="size-3.5" />
        <span class="sr-only">{if @ok, do: gettext("done"), else: gettext("not yet")}</span>
      </span>
      <span class="flex min-w-0 flex-col gap-0.5">
        <span class="text-sm">{@title}</span>
        <span class="text-xs text-muted">{render_slot(@inner_block)}</span>
      </span>
    </li>
    """
  end

  # ── The executions tab ─────────────────────────────────────────────────────

  attr :rule, :map, required: true
  attr :evaluations, :map, required: true
  attr :filters, :map, required: true
  attr :limit, :integer, required: true
  attr :open_row, :string, default: nil
  attr :details, :map, required: true
  attr :servers, :list, required: true
  attr :zone, :string, required: true
  attr :window, :any, required: true

  defp executions_tab(assigns) do
    scoped =
      Enum.filter(assigns.servers, fn server ->
        server.game == assigns.rule.game and
          (is_nil(assigns.rule.server_id) or server.id == assigns.rule.server_id)
      end)

    total_counted = assigns.evaluations.counts |> Map.values() |> Enum.sum()

    assigns =
      assigns
      |> assign(:scoped, scoped)
      |> assign(:shown, Enum.take(assigns.evaluations.rows, assigns.limit))
      |> assign(:total, length(assigns.evaluations.rows))
      |> assign(:counted, total_counted)

    ~H"""
    <div class="flex flex-col gap-4">
      <form
        id="rule-execution-filters"
        phx-change="exec_filter"
        phx-submit="exec_filter"
        class="flex flex-wrap items-center gap-2.5"
      >
        <.filter_pill name="outcome" label={gettext("Result")}>
          <option value="">{gettext("All")}</option>
          <option
            :for={outcome <- ~w(simulated executed failed no_match waiting exempt)a}
            value={outcome}
            selected={@filters["outcome"] == to_string(outcome)}
          >
            {outcome_label(outcome)}
          </option>
        </.filter_pill>
        <.filter_pill :if={length(@scoped) > 1} name="server_id" label={gettext("Server")}>
          <option value="">{gettext("All %{count}", count: length(@scoped))}</option>
          <option
            :for={server <- @scoped}
            value={server.id}
            selected={@filters["server_id"] == to_string(server.id)}
          >
            {server.name}
          </option>
        </.filter_pill>
        <label class="flex h-11 w-60 max-w-full items-center gap-2 rounded-[0.875rem] border border-base-300 bg-base-100 px-3.5 text-muted">
          <.icon name="hero-magnifying-glass" class="size-4 shrink-0" />
          <span class="sr-only">{gettext("Filter by player")}</span>
          <input
            type="search"
            name="player"
            value={@filters["player"]}
            phx-debounce="300"
            placeholder={gettext("Player or Steam ID")}
            class="w-full border-0 bg-transparent p-0 text-sm text-base-content placeholder:text-muted focus:ring-0"
          />
        </label>
        <.pill_radios
          id="rule-execution-period"
          name="period"
          value={@filters["period"]}
          label={gettext("Period")}
          class="bg-base-100"
          options={[
            {"hour", gettext("1 h")},
            {"today", gettext("Today")},
            {"week", gettext("7 days")},
            {"custom", gettext("Pick dates")}
          ]}
        />
        <span
          :if={@filters["period"] == "custom"}
          class="flex items-center gap-2 text-xs text-muted"
        >
          <input
            type="date"
            name="from"
            value={@filters["from"]}
            class="pc-text-input h-11"
            aria-label={gettext("From")}
          />
          <span>–</span>
          <input
            type="date"
            name="to"
            value={@filters["to"]}
            class="pc-text-input h-11"
            aria-label={gettext("To")}
          />
        </span>
        <span class="grow"></span>
        <a
          id="rule-executions-csv"
          href={csv_path(@rule, @filters, @window)}
          download
          class="flex h-11 items-center gap-1.5 rounded-full px-3.5 text-[0.8125rem] text-subtle transition-colors hover:text-base-content"
        >
          <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Export CSV")}
        </a>
      </form>

      <section
        aria-label={gettext("Executions")}
        class="flex min-w-0 flex-col rounded-[1.75rem] bg-base-100 px-4 py-3.5"
      >
        <div class="flex flex-wrap items-center gap-1.5 px-1.5 pb-3">
          <span class="mr-1 text-[0.8125rem] text-subtle">
            {period_label(@filters["period"])},
            <span class="font-mono text-xs">{number(@counted)}</span>
            {ngettext("evaluation", "evaluations", @counted)}
          </span>
          <button
            :for={{outcome, count} <- chip_counts(@evaluations.counts)}
            id={"rule-outcome-#{outcome}"}
            type="button"
            phx-click="exec_outcome"
            phx-value-outcome={outcome}
            aria-pressed={to_string(@filters["outcome"] == to_string(outcome))}
            class={[
              "h-[1.875rem] cursor-pointer rounded-full px-3 text-xs font-semibold transition",
              chip_tint(outcome),
              @filters["outcome"] == to_string(outcome) && "ring-2 ring-base-content/40"
            ]}
          >
            {outcome_label(outcome)} <span class="font-mono">{number(count)}</span>
          </button>
        </div>

        <div class="hidden grid-cols-[5.25rem_minmax(0,1fr)_7.5rem_minmax(0,1.1fr)_12.5rem_12.5rem_4.5rem_2rem] gap-3 border-y border-base-300 px-3.5 py-2 text-[0.6875rem] uppercase tracking-[0.08em] text-muted xl:grid">
          <span>{gettext("Hour")}</span>
          <span>{gettext("Player")}</span>
          <span>{gettext("Server")}</span>
          <span>{gettext("Event")}</span>
          <span>{gettext("Result")}</span>
          <span>{gettext("Step")}</span>
          <span class="text-right">{gettext("Duration")}</span>
          <span></span>
        </div>

        <p :if={@shown == []} class="px-3 py-10 text-center text-[0.8125rem] text-muted">
          {gettext("Nothing in this window. Try a longer period.")}
        </p>

        <div id="rule-executions" class="flex flex-col">
          <div
            :for={row <- @shown}
            id={"rule-row-#{row.id}"}
            class={[
              if(@open_row == row.id,
                do: "my-1 rounded-[1.125rem] border border-base-300 bg-secondary",
                else: "border-b border-base-300"
              ),
              @open_row != row.id && row.outcome == :failed && "bg-error/5"
            ]}
          >
            <button
              id={row_toggle_id(row)}
              type="button"
              phx-click="select_execution"
              phx-value-id={row.id}
              aria-expanded={to_string(@open_row == row.id)}
              class="grid w-full cursor-pointer grid-cols-[4.5rem_minmax(0,1fr)_auto] items-center gap-x-3 gap-y-1 px-3.5 py-2.5 text-left text-sm xl:grid-cols-[5.25rem_minmax(0,1fr)_7.5rem_minmax(0,1.1fr)_12.5rem_12.5rem_4.5rem_2rem] xl:py-[9px]"
            >
              <span class="font-mono text-xs text-muted">{clock(row.at, @zone)}</span>
              <strong class="truncate font-semibold">
                {row.player_name || gettext("server wide")}
              </strong>
              <span class="truncate text-[0.8125rem] text-subtle max-xl:hidden">
                {row.server && row.server.name}
              </span>
              <span class="truncate text-[0.8125rem] text-subtle max-xl:col-span-2 max-xl:col-start-2 max-xl:row-start-2">
                {event_text(row.event, row_trigger(row, @rule))}
              </span>
              <span class="max-xl:col-start-3 max-xl:row-start-1">
                <.result_pill status={row.outcome} detail={row_detail(row)} class="max-w-[12.5rem]" />
              </span>
              <span class={[
                "truncate text-[0.8125rem] max-xl:hidden",
                is_nil(step_text(row)) && "text-muted"
              ]}>
                {step_text(row) ||
                  if(row.outcome in [:waiting, :capped], do: gettext("did not go up"), else: "—")}
              </span>
              <span class={[
                "text-right font-mono text-xs max-xl:hidden",
                if(row.outcome == :failed, do: "text-error", else: "text-subtle")
              ]}>
                {(row.execution && duration(row.execution)) || "—"}
              </span>
              <.icon
                name={if @open_row == row.id, do: "hero-chevron-up", else: "hero-chevron-down"}
                class="size-4 text-muted max-xl:hidden"
              />
            </button>

            <div :if={@open_row == row.id} class="px-3.5 pt-1 pb-3.5">
              <.execution_trace
                :if={row.execution}
                id={"rule-execution-#{row.execution.id}-trace"}
                execution={row.execution}
                rule={@rule}
                limits={get_in(@details, [row.id, :limits])}
                zone={@zone}
              />
              <div
                :if={is_nil(row.execution) and get_in(@details, [row.id, :diagnosis]) != nil}
                id={"rule-evaluation-#{row.id}-trace"}
                class="rounded-2xl bg-base-100 p-4"
              >
                <HllConditionalActionsWeb.DiagnosisComponents.diagnosis
                  diagnosis={get_in(@details, [row.id, :diagnosis])}
                  player={row.player_name}
                />
              </div>
            </div>
          </div>
        </div>

        <div class="flex flex-wrap items-center gap-3 px-1.5 pt-2.5">
          <span class="text-[0.8125rem] text-muted">
            {gettext("Showing %{shown} of %{total}",
              shown: number(length(@shown)),
              total: number(@total)
            )} · {gettext("executions are kept for %{days} days", days: retention_days())}
          </span>
          <span class="grow"></span>
          <.link
            id="rule-view-all-executions"
            navigate={~p"/executions?#{[rule_id: @rule.id]}"}
            class="text-[0.8125rem] text-subtle hover:text-base-content"
          >
            {gettext("Open in the history")}
          </.link>
          <button
            :if={length(@shown) < @total}
            id="rule-executions-more"
            type="button"
            phx-click="exec_more"
            class="h-10 cursor-pointer rounded-full border border-base-300 bg-secondary px-4 text-[0.8125rem] transition-colors hover:bg-base-200"
          >
            {gettext("Load more")}
          </button>
        </div>
      </section>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp filter_pill(assigns) do
    ~H"""
    <label class="relative flex h-11 items-center gap-2 rounded-[0.875rem] border border-base-300 bg-base-100 pl-3.5 text-sm">
      <span class="text-muted">{@label}</span>
      <select
        name={@name}
        class="h-full cursor-pointer appearance-none border-0 bg-transparent py-0 pr-8 pl-0 text-sm text-base-content focus:ring-0"
      >
        {render_slot(@inner_block)}
      </select>
      <.icon
        name="hero-chevron-down"
        class="pointer-events-none absolute right-3 size-3.5 text-muted"
      />
    </label>
    """
  end

  defp row_trigger(%{execution: %{trigger_event: trigger}}, _rule), do: trigger
  defp row_trigger(_row, rule), do: rule.trigger_event

  defp row_toggle_id(%{execution: %{id: id}}), do: "rule-execution-#{id}-toggle"
  defp row_toggle_id(%{id: id}), do: "rule-evaluation-#{id}-toggle"

  defp row_detail(%{outcome: :failed, detail: error}) when is_binary(error),
    do: String.slice(error, 0, 40)

  defp row_detail(%{outcome: :waiting, detail: seconds}) when is_integer(seconds),
    do: gettext("%{seconds} s to go", seconds: seconds)

  defp row_detail(%{outcome: :exempt, detail: {:vip}}), do: gettext("VIP")

  defp row_detail(%{outcome: :exempt, detail: {:flag, flag}}),
    do: gettext("flag %{flag}", flag: flag)

  defp row_detail(%{outcome: :exempt, detail: {:listed}}), do: gettext("listed")
  defp row_detail(%{outcome: :no_match}), do: gettext("conditions")
  defp row_detail(_row), do: nil

  defp step_text(%{step: step, steps: steps, execution: execution}) when is_integer(step) do
    action =
      case execution && execution.results do
        [first | _rest] -> " · " <> short_action_label(first["type"])
        _none -> ""
      end

    gettext("Offence %{number} of %{total}", number: step, total: steps) <> action
  end

  defp step_text(%{execution: %{results: [_ | _]} = execution}), do: summary(execution)
  defp step_text(_row), do: nil

  @chip_order [
    :simulated,
    :executed,
    :no_match,
    :waiting,
    :capped,
    :exempt,
    :partial,
    :failed,
    :inactive,
    :unrecorded
  ]

  defp chip_counts(counts) do
    for outcome <- @chip_order,
        count = Map.get(counts, outcome, 0),
        count > 0,
        do: {outcome, count}
  end

  defp chip_tint(:simulated), do: "bg-accent/13 text-accent"
  defp chip_tint(:executed), do: "bg-primary/12 text-primary"

  defp chip_tint(outcome) when outcome in [:waiting, :capped, :partial],
    do: "bg-warning/13 text-warning"

  defp chip_tint(:exempt), do: "ring-1 ring-inset ring-base-300 text-subtle"
  defp chip_tint(:failed), do: "bg-error/14 text-error"
  defp chip_tint(_other), do: "bg-secondary text-subtle"

  defp period_label("hour"), do: gettext("Last hour")
  defp period_label("week"), do: gettext("7 days")
  defp period_label("custom"), do: gettext("Chosen dates")
  defp period_label(_today), do: gettext("Today")

  defp retention_days,
    do: Application.get_env(:hll_conditional_actions, :execution_retention_days, 30)

  defp csv_path(rule, filters, {from, to}) do
    query =
      [
        format: "csv",
        rule_id: rule.id,
        status: filters["outcome"] in ~w(executed simulated partial failed) && filters["outcome"],
        server_id: blank(filters["server_id"]),
        player: blank(filters["player"]),
        from: from && DateTime.to_iso8601(from),
        until: to && DateTime.to_iso8601(to)
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, false] end)

    "/rules/export?" <> URI.encode_query(query)
  end

  defp failure_hint(%{total: 0}), do: gettext("nothing recorded yet")

  defp failure_hint(stats) do
    failed = Map.get(stats.by_status, :failed, 0)

    if failed == 0 do
      gettext("every run landed")
    else
      gettext("%{percent}% of all runs", percent: round(failed * 100 / stats.total))
    end
  end

  defp limits_sentence(rule) do
    [
      if(rule.cooldown_seconds > 0,
        do:
          gettext("one run per player every %{time}", time: duration_text(rule.cooldown_seconds))
      ),
      if(rule.max_executions_per_player > 0,
        do: gettext("at most %{count} per player per day", count: rule.max_executions_per_player)
      ),
      if(rule.escalation_window_seconds > 0,
        do:
          gettext("escalating over %{time}", time: duration_text(rule.escalation_window_seconds))
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> gettext("none")
      parts -> Enum.join(parts, " · ")
    end
  end
end
