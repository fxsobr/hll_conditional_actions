defmodule HllConditionalActionsWeb.RuleLive.Show do
  @moduledoc """
  The 360 view of a rule: what it is, and what it has actually been doing.

  Modelled on the health product's patient 360 screen — identity header,
  metric strip, tabs, activity timeline — because an admin asks a rule the
  same questions they ask a patient: *who is this, is it healthy, what
  happened recently, and what exactly is it set up to do?*

  Before this screen the only way in was the builder, so "is this rule
  working?" meant opening History and filtering by hand. The metrics answer
  it on arrival, and every metric is a button into the tab that explains it.

  New executions arrive live over PubSub, so the numbers move while an admin
  watches a match.
  """

  use HllConditionalActionsWeb, :live_view

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_rules}}

  import HllConditionalActionsWeb.Overview
  import HllConditionalActionsWeb.RuleBuilder, only: [rule_summary: 1]

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Engine
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Audit
  alias HllConditionalActions.Rules.Health
  alias HllConditionalActions.Servers

  @tabs ~w(overview executions definition changes)

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    rule = Rules.get_rule!(id)

    if connected?(socket), do: Engine.subscribe(rule.server_id)

    {:ok,
     socket
     |> assign(:rule, rule)
     |> assign(:page_title, rule.name)
     |> assign(:servers, Servers.list_servers_for(socket.assigns[:current_user]))
     |> assign(:editable?, Rules.editable_by?(rule, socket.assigns[:current_user]))
     |> assign(:tab, "overview")
     |> assign(:selected_execution, nil)
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    {:noreply, assign(socket, :tab, tab_param(params["tab"]))}
  end

  @impl Phoenix.LiveView
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :tab, tab_param(tab))}
  end

  def handle_event("select_execution", %{"id" => id}, socket) do
    {:noreply,
     update(socket, :selected_execution, fn current ->
       if current == id, do: nil, else: id
     end)}
  end

  def handle_event("toggle", _params, socket) do
    if authorized?(socket) do
      {:ok, rule} = Rules.toggle_rule(socket.assigns.rule, actor: socket.assigns.current_user)

      {:noreply, socket |> assign(:rule, Rules.get_rule!(rule.id)) |> load()}
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

  def handle_event("delete", _params, socket) do
    if authorized?(socket) do
      {:ok, _rule} = Rules.delete_rule(socket.assigns.rule, actor: socket.assigns.current_user)

      {:noreply,
       socket |> put_flash(:info, gettext("Rule removed.")) |> push_navigate(to: ~p"/rules")}
    else
      {:noreply, deny(socket)}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:rule_fired, _execution}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    rule = socket.assigns.rule

    socket
    |> assign(:stats, Rules.execution_stats(rule_id: rule.id))
    |> assign(:executions, Rules.list_executions(rule_id: rule.id, limit: 50))
    |> assign(:issues, Health.for_rule(rule, socket.assigns.servers))
    |> assign(:versions, Audit.list_versions(rule.id))
  end

  defp tab_param(tab) when tab in @tabs, do: tab
  defp tab_param(_other), do: "overview"

  defp authorized?(socket) do
    Accounts.can?(socket.assigns.current_user, :manage_rules) and socket.assigns.editable?
  end

  defp deny(socket) do
    put_flash(socket, :error, gettext("You do not have permission to change rules."))
  end

  # ── What the header and the metric strip say ───────────────────────────────

  defp header_badges(rule, editable?) do
    [
      if rule.enabled do
        %{id: "state", label: gettext("Active"), tone: "success"}
      else
        %{id: "state", label: gettext("Disabled"), tone: "neutral"}
      end
    ] ++
      if(rule.simulation,
        do: [%{id: "sim", label: gettext("Simulation"), tone: "warning", icon: "hero-beaker"}],
        else: []
      ) ++
      if(editable?,
        do: [],
        else: [
          %{id: "ro", label: gettext("Read only"), tone: "neutral", icon: "hero-lock-closed"}
        ]
      )
  end

  defp header_meta(rule) do
    [
      Labels.trigger(rule.trigger_event),
      scope_label(rule),
      Labels.game(rule.game),
      gettext("priority %{value}", value: rule.priority)
    ]
    |> Enum.join(" · ")
  end

  defp scope_label(%{server: %{name: name}}), do: name
  defp scope_label(_rule), do: gettext("Every server")

  defp kpi_list(stats) do
    [
      %{
        id: "total",
        label: gettext("Times fired"),
        value: stats.total,
        hint: gettext("since the history began"),
        icon: "hero-bolt",
        tone: "primary",
        event: "executions"
      },
      %{
        id: "recent",
        label: gettext("Last 24 hours"),
        value: stats.last_24h,
        hint: gettext("how busy it is right now"),
        icon: "hero-clock",
        tone: if(stats.last_24h > 0, do: "success", else: "neutral"),
        event: "executions"
      },
      %{
        id: "players",
        label: gettext("Players reached"),
        value: stats.players,
        hint: gettext("distinct players"),
        icon: "hero-users",
        tone: "info",
        event: "executions"
      },
      %{
        id: "failed",
        label: gettext("Failures"),
        value: Map.get(stats.by_status, :failed, 0),
        hint: failure_hint(stats),
        icon: "hero-exclamation-triangle",
        tone: if(Map.get(stats.by_status, :failed, 0) > 0, do: "error", else: "neutral"),
        event: "executions"
      }
    ]
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

  defp status_tone(:executed), do: "success"
  defp status_tone(:partial), do: "warning"
  defp status_tone(:failed), do: "error"
  defp status_tone(:simulated), do: "info"
  defp status_tone(_status), do: "neutral"

  defp status_icon(:executed), do: "hero-check-circle"
  defp status_icon(:partial), do: "hero-exclamation-circle"
  defp status_icon(:failed), do: "hero-x-circle"
  defp status_icon(:simulated), do: "hero-beaker"
  defp status_icon(_status), do: "hero-minus-circle"

  # "Warned Fulano · Caveiras #1" — enough to recognise a run in the strip.
  defp execution_snippet(execution) do
    [execution.player_name || gettext("server wide"), execution.server.name]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp result_tone("ok"), do: "text-success"
  defp result_tone("skipped"), do: "text-muted"
  defp result_tone("simulated"), do: "text-info"
  defp result_tone(_status), do: "text-error"

  defp action_label(type) do
    Labels.action(String.to_existing_atom(type))
  rescue
    ArgumentError -> type
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      page_title={@rule.name}
      page_subtitle={header_meta(@rule)}
      back={~p"/rules"}
      back_label={gettext("Back to rules")}
      badges={header_badges(@rule, @editable?)}
    >
      <:actions>
        <.button
          :if={Accounts.can?(@current_user, :manage_rules) and @editable?}
          type="button"
          size="sm"
          variant="outline"
          color="gray"
          icon="hero-power"
          phx-click="toggle"
        >
          <span class="hidden sm:inline">
            {if @rule.enabled, do: gettext("Disable"), else: gettext("Enable")}
          </span>
        </.button>
        <.button
          link_type="live_redirect"
          to={~p"/rules/#{@rule}/edit"}
          size="sm"
          color="primary"
          icon="hero-pencil-square"
        >
          <span class="hidden sm:inline">{gettext("Edit")}</span>
        </.button>
        <.row_menu
          :if={Accounts.can?(@current_user, :manage_rules) and @editable?}
          id="rule-show-menu"
        >
          <.menu_item icon="hero-document-duplicate" phx-click="duplicate">
            {gettext("Duplicate")}
          </.menu_item>

          <.menu_item
            tone="error"
            icon="hero-trash"
            phx-click="delete"
            data-confirm={gettext("Remove the rule \"%{name}\"?", name: @rule.name)}
          >
            {gettext("Remove")}
          </.menu_item>
        </.row_menu>
      </:actions>

      <.alert
        :for={issue <- @issues}
        color={if issue.tone == "error", do: "danger", else: "warning"}
        variant="soft"
        with_icon
        heading={Labels.health_issue(issue.id)}
        label={Labels.health_explanation(issue.id)}
      />

      <.kpi_cards cards={kpi_list(@stats)} on_select="select_tab" />

      <.view_tabs
        id="rule-tabs"
        active={@tab}
        on_change="select_tab"
        label={gettext("Rule sections")}
        items={[
          %{id: "overview", label: gettext("Overview")},
          %{id: "executions", label: gettext("History"), count: @stats.total},
          %{id: "definition", label: gettext("Definition")},
          %{id: "changes", label: gettext("Changes"), count: length(@versions)}
        ]}
      />

      <%!-- ── Overview ───────────────────────────────────────────────────── --%>
      <div :if={@tab == "overview"} class="grid items-start gap-4 lg:grid-cols-3">
        <div class="min-w-0 space-y-4 lg:col-span-2">
          <.card title={gettext("Recent activity")} icon="hero-clock">
            <:action>
              <button
                :if={@executions != []}
                type="button"
                phx-click="select_tab"
                phx-value-tab="executions"
                class="cursor-pointer text-label-small text-muted hover:text-primary hover:underline"
              >
                {gettext("See all")}
              </button>
            </:action>

            <p :if={@executions == []} class="py-6 text-center text-body-small text-muted">
              {gettext("This rule has not fired yet")}
            </p>

            <.timeline
              :if={@executions != []}
              id="rule-timeline"
              label={gettext("Recent activity")}
            >
              <.timeline_card
                :for={execution <- Enum.take(@executions, 12)}
                icon={status_icon(execution.status)}
                tone={status_tone(execution.status)}
                kind={Labels.execution_status(execution.status)}
                at={execution.executed_at}
                at_id={"timeline-#{execution.id}"}
                snippet={execution_snippet(execution)}
                selected={@selected_execution == to_string(execution.id)}
                phx-click="select_execution"
                phx-value-id={execution.id}
              />
            </.timeline>
          </.card>

          <.rule_summary rule={@rule} game={@rule.game} servers={@servers} />
        </div>

        <.card title={gettext("Outcomes")} icon="hero-chart-bar">
          <p :if={@stats.total == 0} class="py-6 text-center text-body-small text-muted">
            {gettext("Nothing recorded yet.")}
          </p>

          <ul :if={@stats.total > 0} class="space-y-3">
            <li :for={{status, count} <- @stats.by_status} class="space-y-1">
              <div class="flex items-center justify-between gap-2 text-body-small">
                <span class="flex items-center gap-1.5">
                  <%!-- decorative: the label is right beside it, so the dot
                        must not be announced a second time --%>
                  <span
                    class={["size-2 shrink-0 rounded-full", bar_tone(status_tone(status))]}
                    aria-hidden="true"
                  ></span>
                  {Labels.execution_status(status)}
                </span>

                <span class="tabular-nums text-muted">
                  {count} · {round(count * 100 / @stats.total)}%
                </span>
              </div>

              <div class="h-1.5 overflow-hidden rounded-pill bg-base-200">
                <div
                  class={["h-full rounded-pill", bar_tone(status_tone(status))]}
                  style={"width: #{round(count * 100 / @stats.total)}%"}
                >
                </div>
              </div>
            </li>
          </ul>

          <dl class="divide-y divide-base-300 border-t border-base-300 pt-1 text-body-small">
            <div class="flex justify-between gap-3 py-2">
              <dt class="text-muted">{gettext("Last fired")}</dt>
              <dd>
                <.local_time
                  :if={@stats.last_executed_at}
                  id="rule-last-fired"
                  at={@stats.last_executed_at}
                />
                <span :if={is_nil(@stats.last_executed_at)} class="text-muted">
                  {gettext("never")}
                </span>
              </dd>
            </div>

            <div class="flex justify-between gap-3 py-2">
              <dt class="text-muted">{gettext("Limits")}</dt>
              <dd class="text-right">{limits_sentence(@rule)}</dd>
            </div>
          </dl>
        </.card>
      </div>

      <%!-- ── History ────────────────────────────────────────────────────── --%>
      <div :if={@tab == "executions"}>
        <.empty_state
          :if={@executions == []}
          icon="hero-clock"
          title={gettext("This rule has not fired yet")}
          description={
            gettext(
              "As soon as it matches something on your servers, every run shows up here with what it did."
            )
          }
        />

        <.card :if={@executions != []} padded={false}>
          <table class="table-collapse app-table">
            <thead>
              <tr>
                <th>{gettext("When")}</th>

                <th>{gettext("Player")}</th>

                <th>{gettext("Server")}</th>

                <th>{gettext("Outcome")}</th>

                <th>{gettext("What it did")}</th>
              </tr>
            </thead>

            <tbody class="divide-y divide-base-300">
              <tr :for={execution <- @executions} class="sm:hover:bg-base-200/60">
                <td data-cell="lead" class="whitespace-nowrap text-body-small text-subtle">
                  <.local_time id={"row-#{execution.id}"} at={execution.executed_at} />
                </td>

                <td data-label={gettext("Player")} class="text-body-small">
                  <span :if={execution.player_name}>{execution.player_name}</span>
                  <span :if={is_nil(execution.player_name)} class="text-muted">
                    {gettext("server wide")}
                  </span>
                </td>

                <td data-label={gettext("Server")} class="text-body-small text-subtle">
                  {execution.server.name}
                </td>

                <td data-label={gettext("Outcome")}>
                  <.tone_badge tone={status_tone(execution.status)}>
                    {Labels.execution_status(execution.status)}
                  </.tone_badge>
                </td>

                <td data-label={gettext("What it did")}>
                  <ul class="space-y-0.5">
                    <li
                      :for={result <- execution.results}
                      class="flex flex-wrap gap-x-1.5 text-label-small"
                    >
                      <span class={result_tone(result["status"])}>
                        {action_label(result["type"])}
                      </span>
                      <span class="text-muted">{result["detail"]}</span>
                    </li>
                  </ul>
                </td>
              </tr>
            </tbody>
          </table>
        </.card>
      </div>

      <%!-- ── Changes ───────────────────────────────────────────────────── --%>
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

        <.card :if={@versions != []} padded={false}>
          <ul class="divide-y divide-base-300">
            <li :for={version <- @versions} class="flex flex-wrap items-start gap-x-3 gap-y-1 p-4">
              <div class="min-w-0 flex-1">
                <p class="text-body-small">
                  <span class="font-medium">{version.user_name || gettext("the system")}</span>
                  {Labels.version_action(version.action)}
                  <span class="text-muted">{gettext("this rule")}</span>
                </p>

                <ul :if={version.changes != %{}} class="mt-1 space-y-0.5">
                  <li :for={{field, change} <- version.changes} class="text-label-small text-muted">
                    <span class="text-base-content">{Labels.rule_field(field)}</span>
                    <span class="mx-1 line-through">{present(change["from"])}</span>
                    <.icon name="hero-arrow-right" class="size-3" />
                    <span class="ml-1">{present(change["to"])}</span>
                    <span :if={change["edited"]}>{gettext("(edited)")}</span>
                  </li>
                </ul>
              </div>

              <.local_time
                id={"version-#{version.id}"}
                at={version.inserted_at}
                class="shrink-0 text-label-small text-muted"
              />
            </li>
          </ul>
        </.card>
      </div>

      <%!-- ── Definition ─────────────────────────────────────────────────── --%>
      <div :if={@tab == "definition"} class="grid items-start gap-4 lg:grid-cols-2">
        <.rule_summary rule={@rule} game={@rule.game} servers={@servers} />

        <.card title={gettext("Settings")} icon="hero-adjustments-horizontal">
          <dl class="divide-y divide-base-300 text-body-small">
            <div :for={{label, value} <- settings_rows(@rule)} class="flex justify-between gap-3 py-2">
              <dt class="text-muted">{label}</dt>
              <dd class="text-right">{value}</dd>
            </div>
          </dl>

          <.button
            link_type="live_redirect"
            to={~p"/rules/#{@rule}/edit"}
            size="sm"
            variant="outline"
            color="gray"
            icon="hero-pencil-square"
            class="w-fit"
            label={gettext("Edit this rule")}
          />
        </.card>
      </div>
    </Layouts.app>
    """
  end

  # An empty value reads as nothing at all in a diff, so it is named.
  defp present(nil), do: gettext("(empty)")
  defp present(""), do: gettext("(empty)")
  defp present(value), do: value

  defp bar_tone("success"), do: "bg-success"
  defp bar_tone("warning"), do: "bg-warning"
  defp bar_tone("error"), do: "bg-error"
  defp bar_tone("info"), do: "bg-info"
  defp bar_tone(_neutral), do: "bg-base-300"

  defp limits_sentence(rule) do
    [
      if(rule.cooldown_seconds > 0,
        do: gettext("one run per player every %{count}s", count: rule.cooldown_seconds)
      ),
      if(rule.max_executions_per_player > 0,
        do: gettext("at most %{count} per player per day", count: rule.max_executions_per_player)
      ),
      if(rule.escalation_window_seconds > 0,
        do: gettext("escalating over %{count}s", count: rule.escalation_window_seconds)
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> gettext("none")
      parts -> Enum.join(parts, " · ")
    end
  end

  defp settings_rows(rule) do
    [
      {gettext("Trigger"), Labels.trigger(rule.trigger_event)},
      {gettext("Applies to"), scope_label(rule)},
      {gettext("Game"), Labels.game(rule.game)},
      {gettext("Priority"), rule.priority},
      {gettext("How conditions combine"), Labels.logical_operator(rule.logical_operator)},
      {gettext("Cooldown per player (seconds)"), rule.cooldown_seconds},
      {gettext("Maximum times per player per day"), rule.max_executions_per_player}
    ]
  end
end
