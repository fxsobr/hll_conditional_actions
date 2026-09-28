defmodule HllConditionalActionsWeb.ExecutionLive.Index do
  @moduledoc """
  The audit log: every time a rule fired, for whom, and what each of its
  actions did.

  New executions arrive live over PubSub, so an admin watching this page sees a
  rule take effect the moment it does — but only on the first page. Reloading
  page four because something happened on page one would move the row somebody
  is reading out from under their cursor, so past the first page the list holds
  still until they ask for it.
  """

  use HllConditionalActionsWeb, :live_view

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_executions}}

  alias HllConditionalActions.Engine
  alias HllConditionalActions.Reports
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Servers

  # Enough that a quiet server needs no paging at all, small enough that the
  # page stays quick on a busy one.
  @per_page 50

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    servers = Servers.list_servers_for(socket.assigns[:current_user])
    scope = Enum.find(servers, &(to_string(&1.id) == params["server_id"]))

    if connected?(socket), do: Enum.each(servers, &Engine.subscribe(&1.id))

    {:ok,
     socket
     |> assign(:page_title, gettext("History"))
     |> assign(:servers, servers)
     |> assign(:scope, scope)
     |> assign(:rules, Rules.list_rules_for(socket.assigns[:current_user]))
     |> assign(:expanded, MapSet.new())
     |> assign(:page, 1)
     |> assign(:per_page, @per_page)}
  end

  # The filters live in the URL, so a filtered view can be linked to (the
  # rule page's "View all", a player's name) and survives a reload.
  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    # Narrowing the filters while on page 6 would otherwise land on a page
    # that no longer exists.
    {:noreply,
     socket
     |> assign(:filters, filters_from(params, socket.assigns.scope))
     |> assign(:page, 1)
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("filter", params, socket) do
    filters = filters_from(params, socket.assigns.scope)
    {:noreply, push_patch(socket, to: filter_path(socket.assigns.scope, filters))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: filter_path(socket.assigns.scope, %{}))}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply, socket |> assign(:page, cast_page(page)) |> load()}
  end

  def handle_event("toggle_details", %{"id" => id}, socket) do
    {:noreply,
     update(socket, :expanded, fn expanded ->
       if MapSet.member?(expanded, id) do
         MapSet.delete(expanded, id)
       else
         MapSet.put(expanded, id)
       end
     end)}
  end

  @impl Phoenix.LiveView
  def handle_info({:rule_fired, _execution}, %{assigns: %{page: 1}} = socket) do
    {:noreply, load(socket)}
  end

  def handle_info({:rule_fired, _execution}, socket), do: {:noreply, socket}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp filters_from(params, scope) do
    %{
      # Under a server the filter is the server itself, not a choice.
      server_id: if(scope, do: to_string(scope.id), else: cast_id(params["server_id"])),
      rule_id: cast_id(params["rule_id"]),
      status: cast_status(params["status"]),
      player: blank_to_nil(params["player"]),
      from: cast_date(params["from"]),
      to: cast_date(params["to"])
    }
  end

  defp filter_path(scope, filters) do
    query =
      filters
      |> Enum.reject(fn {key, value} -> is_nil(value) or (scope != nil and key == :server_id) end)
      |> Enum.map(fn {key, value} -> {key, to_string(value)} end)
      |> Enum.sort()

    base = if scope, do: ~p"/servers/#{scope.id}/history", else: ~p"/executions"

    if query == [], do: base, else: base <> "?" <> URI.encode_query(query)
  end

  # What the context understands: dates become the start and the end of
  # that day (UTC).
  defp query_filters(filters) do
    [
      server_id: filters.server_id,
      rule_id: filters.rule_id,
      status: filters.status,
      player: filters.player,
      from: filters.from && DateTime.new!(filters.from, ~T[00:00:00]),
      until: filters.to && DateTime.new!(filters.to, ~T[23:59:59.999999])
    ]
  end

  defp filtered?(filters, scope) do
    Enum.any?(filters, fn {key, value} ->
      value != nil and not (scope != nil and key == :server_id)
    end)
  end

  defp load(socket) do
    user = socket.assigns[:current_user]
    filters = query_filters(socket.assigns.filters)
    total = Rules.count_executions_for(user, filters)

    # A page emptied by rows expiring or by a narrower filter would otherwise
    # show nothing at all; walk back to the last page that has rows.
    page = min(socket.assigns.page, max(ceil(total / @per_page), 1))

    executions =
      Rules.list_executions_for(
        user,
        filters ++ [limit: @per_page, offset: (page - 1) * @per_page]
      )

    socket
    |> assign(:executions, executions)
    |> assign(:summary, Reports.overview(user, 30).totals)
    |> assign(:total, total)
    |> assign(:page, page)
  end

  defp cast_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {number, _rest} when number > 0 -> number
      _other -> 1
    end
  end

  defp cast_page(_page), do: 1

  defp cast_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> to_string(id)
      _other -> nil
    end
  end

  defp cast_id(_value), do: nil

  defp cast_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp cast_date(_value), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: String.trim(value)

  defp cast_status(status) when status in ~w(executed partial failed simulated) do
    String.to_existing_atom(status)
  end

  defp cast_status(_status), do: nil

  defp status_tone(:executed), do: "success"
  defp status_tone(:partial), do: "warning"
  defp status_tone(:failed), do: "error"
  defp status_tone(:simulated), do: "info"
  defp status_tone(_status), do: "ghost"

  # The stored trigger is a string; show the same translated label the rule
  # builder uses, falling back to the raw value for anything unknown.
  defp trigger_label(trigger) when is_atom(trigger), do: Labels.trigger(trigger)

  defp trigger_label(trigger) when is_binary(trigger) do
    Labels.trigger(String.to_existing_atom(trigger))
  rescue
    ArgumentError -> trigger
    FunctionClauseError -> trigger
  end

  defp action_label(type) do
    Labels.action(String.to_existing_atom(type))
  rescue
    ArgumentError -> type
  end

  # ── Trace ──────────────────────────────────────────────────────────────────

  # One execution, node by node: what triggered it, how each condition read,
  # which rung of the ladder it was on, and what each action did.
  attr :execution, :map, required: true

  defp execution_trace(assigns) do
    trace = assigns.execution.trace || %{}

    assigns =
      assigns
      |> assign(:conditions, Map.get(trace, "conditions", []))
      |> assign(:logical_operator, Map.get(trace, "logical_operator"))
      |> assign(:step, Map.get(trace, "step"))
      |> assign(:steps, Map.get(trace, "steps"))
      |> assign(:duration_ms, Map.get(trace, "duration_ms"))

    ~H"""
    <div id={"execution-#{@execution.id}-trace"} class="py-2">
      <ol class="execution-trace">
        <.trace_step
          state="ok"
          icon="hero-bolt"
          title={trigger_label(@execution.trigger_event)}
          detail={gettext("Trigger received")}
        />
        <.trace_step
          :if={@conditions == []}
          state="unknown"
          icon="hero-arrows-pointing-out"
          title={gettext("Conditions")}
          detail={gettext("Not recorded for executions older than this version.")}
        />
        <.trace_step
          :for={condition <- @conditions}
          :if={condition["field"] != "always_true"}
          state={if condition["result"], do: "ok", else: "no"}
          icon="hero-arrows-pointing-out"
          title={condition_title(condition)}
          detail={condition_detail(condition)}
          aside={if condition["result"], do: gettext("Yes"), else: gettext("No")}
        />
        <.trace_step
          :if={@step}
          state="ok"
          icon="hero-bars-arrow-up"
          title={gettext("Escalation")}
          detail={gettext("Offence %{number} of %{total}", number: @step, total: @steps)}
        />
        <.trace_step
          :for={{result, index} <- Enum.with_index(@execution.results)}
          state={delivery_state(result, delivery(@execution, index))}
          icon={action_icon(result["type"])}
          title={action_label(result["type"])}
          detail={delivery_detail(result, delivery(@execution, index))}
          aside={delivery_label(result, delivery(@execution, index))}
        />
        <.trace_step
          :if={@execution.results == []}
          state="unknown"
          icon="hero-play"
          title={gettext("Actions")}
          detail={gettext("No action ran.")}
        />
      </ol>

      <p :if={@duration_ms} class="mt-2 pl-9 text-xs text-muted">
        {gettext("Took %{ms} ms", ms: @duration_ms)}
      </p>
    </div>
    """
  end

  attr :state, :string, required: true, values: ~w(ok no error skipped simulated unknown)
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :detail, :string, default: nil
  attr :aside, :string, default: nil

  defp trace_step(assigns) do
    ~H"""
    <li class="execution-trace-step" data-state={@state}>
      <span class="execution-trace-dot">
        <.icon name={state_icon(@state)} class="size-3.5" />
      </span>

      <span class="flex size-7 shrink-0 items-center justify-center rounded-field bg-base-100 text-subtle">
        <.icon name={@icon} class="size-4" />
      </span>

      <span class="min-w-0 flex-1">
        <span class="block text-sm font-medium">{@title}</span>
        <span :if={@detail} class="block text-xs break-words text-muted">{@detail}</span>
      </span>

      <span
        :if={@aside}
        class="shrink-0 rounded-pill border border-base-300 bg-base-100 px-2 py-0.5 text-xs text-subtle"
      >
        {@aside}
      </span>
    </li>
    """
  end

  # Queued actions (Discord) say "ok" once queued; what happened to the
  # delivery itself is written later, under the action's index.
  defp delivery(execution, index), do: Map.get(execution.deliveries || %{}, to_string(index))

  defp delivery_state(_result, %{"status" => "failed"}), do: "error"
  defp delivery_state(result, _delivery), do: result_state(result["status"])

  defp delivery_detail(result, %{"status" => "failed", "detail" => reason})
       when is_binary(reason),
       do: Enum.join(Enum.reject([result["detail"], reason], &is_nil/1), " - ")

  defp delivery_detail(result, _delivery), do: result["detail"]

  defp delivery_label(_result, %{"status" => "delivered"}), do: gettext("Delivered")
  defp delivery_label(_result, %{"status" => "failed"}), do: gettext("Not delivered")

  defp delivery_label(%{"type" => "send_discord_webhook", "status" => "ok"}, nil),
    do: gettext("Queued")

  defp delivery_label(_result, _delivery), do: nil

  defp state_icon("ok"), do: "hero-check"
  defp state_icon("simulated"), do: "hero-beaker"
  defp state_icon("no"), do: "hero-minus"
  defp state_icon("skipped"), do: "hero-minus"
  defp state_icon("error"), do: "hero-x-mark"
  defp state_icon(_state), do: "hero-question-mark-circle"

  defp result_state("ok"), do: "ok"
  defp result_state("simulated"), do: "simulated"
  defp result_state("skipped"), do: "skipped"
  defp result_state(_status), do: "error"

  defp condition_title(condition) do
    to_existing(condition["field"], &Labels.field/1)
  end

  # "read 12, needed: is greater than 10"
  defp condition_detail(condition) do
    actual =
      case condition["actual"] do
        nil -> gettext("nothing")
        "" -> gettext("nothing")
        value -> to_string(value)
      end

    operator = to_existing(condition["operator"], &Labels.operator/1)

    gettext("read %{actual}, needed: %{operator} %{expected}",
      actual: actual,
      operator: operator,
      expected: condition["expected"] || ""
    )
  end

  defp trigger_icon(trigger) do
    Icons.trigger(String.to_existing_atom(trigger))
  rescue
    _unknown -> "hero-bolt"
  end

  defp action_icon(type) do
    Icons.action(String.to_existing_atom(type))
  rescue
    _unknown -> "hero-play"
  end

  defp to_existing(nil, _label), do: ""

  defp to_existing(value, label) do
    label.(String.to_existing_atom(value))
  rescue
    _unknown -> value
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("History")}
      page_subtitle={gettext("Every time a rule fired, and what it did")}
    >
      <div id="execution-kpis" class="grid grid-cols-2 gap-3 sm:gap-4 xl:grid-cols-4">
        <.stat
          icon="hero-bolt"
          label={gettext("Fired · 30 days")}
          value={@summary.fired}
          hint={gettext("every recorded execution")}
        />
        <.stat
          icon="hero-check-badge"
          tone="success"
          label={gettext("Success rate")}
          value={if @summary.success_rate, do: "#{@summary.success_rate}%", else: "–"}
          hint={ngettext("1 failed", "%{count} failed", @summary.failed)}
        />
        <.stat
          icon="hero-beaker"
          tone="info"
          label={gettext("Simulated")}
          value={@summary.simulated}
          hint={gettext("recorded without touching the game")}
        />
        <.stat
          icon="hero-users"
          label={gettext("Players reached")}
          value={@summary.players}
          hint={gettext("different players a rule acted on")}
        />
      </div>

      <.filter_bar id="execution-filters" on_change="filter">
        <.filter_select
          :if={is_nil(@scope)}
          name="server_id"
          label={gettext("Server")}
          value={@filters.server_id}
          prompt={gettext("Every server")}
          options={Enum.map(@servers, &{&1.name, &1.id})}
        />
        <.filter_select
          name="status"
          label={gettext("Outcome")}
          value={@filters.status}
          prompt={gettext("Any outcome")}
          options={
            Enum.map(
              ~w(executed partial failed simulated)a,
              &{Labels.execution_status(&1), to_string(&1)}
            )
          }
        />
        <.filter_select
          name="rule_id"
          label={gettext("Rule")}
          value={@filters.rule_id}
          prompt={gettext("Every rule")}
          options={Enum.map(@rules, &{&1.name, to_string(&1.id)})}
        />
        <.search_input
          name="player"
          label={gettext("Player name or ID")}
          value={@filters.player}
          class="max-sm:grow sm:w-52"
        />
        <label class="flex items-center gap-1.5 text-label-small text-muted">
          <span>{gettext("From")}</span>
          <input type="date" name="from" value={@filters.from} class="pc-text-input" />
        </label>
        <label class="flex items-center gap-1.5 text-label-small text-muted">
          <span>{gettext("To")}</span>
          <input type="date" name="to" value={@filters.to} class="pc-text-input" />
        </label>

        <:clear>
          <.button
            :if={filtered?(@filters, @scope)}
            id="execution-filters-clear"
            type="button"
            size="sm"
            variant="ghost"
            color="gray"
            icon="hero-x-mark"
            phx-click="clear_filters"
            label={gettext("Clear")}
          />
        </:clear>
      </.filter_bar>

      <.empty_state
        :if={@executions == []}
        icon="hero-clock"
        title={gettext("No rule executions recorded yet.")}
        description={
          gettext("Every time a rule fires it is recorded here, with what each of its actions did.")
        }
      />
      <.card :if={@executions != []} padded={false}>
        <table class="table-collapse app-table">
          <thead class="text-xs uppercase tracking-wide text-muted">
            <tr>
              <th>{gettext("When")}</th>

              <th>{gettext("Rule")}</th>

              <th>{gettext("Player")}</th>

              <th>{gettext("Server")}</th>

              <th>{gettext("Outcome")}</th>

              <th class="w-0 text-right">
                <span class="sr-only">{gettext("Actions")}</span>
              </th>
            </tr>
          </thead>

          <tbody class="divide-y divide-base-300">
            <%= for execution <- @executions do %>
              <tr class="sm:hover:bg-base-200/60">
                <td data-cell="lead" class="whitespace-nowrap text-sm text-subtle">
                  <.local_time id={"execution-#{execution.id}-at"} at={execution.executed_at} />
                </td>

                <td data-label={gettext("Rule")}>
                  <div class="flex items-center gap-2.5">
                    <span class="flex size-8 shrink-0 items-center justify-center rounded-field bg-primary/10 text-primary max-sm:hidden">
                      <.icon name={trigger_icon(execution.trigger_event)} class="size-4" />
                    </span>

                    <div class="min-w-0">
                      <.link
                        navigate={~p"/rules/#{execution.rule_id}"}
                        class="text-sm font-medium hover:underline"
                      >
                        {execution.rule.name}
                      </.link>

                      <p class="text-xs text-muted max-sm:hidden">
                        {trigger_label(execution.trigger_event)}
                      </p>
                    </div>
                  </div>
                </td>

                <td data-label={gettext("Player")} class="text-sm">
                  <span :if={execution.player_id} class="inline-flex items-center gap-1.5">
                    <.link
                      patch={filter_path(@scope, Map.put(@filters, :player, execution.player_id))}
                      class="font-medium hover:text-primary hover:underline"
                      title={gettext("Only this player")}
                    >
                      {execution.player_name || execution.player_id}
                    </.link>
                    <.link
                      navigate={~p"/players/#{execution.player_id}"}
                      class="text-muted hover:text-primary"
                      title={gettext("Player profile")}
                    >
                      <.icon name="hero-user-circle" class="size-4" />
                      <span class="sr-only">{gettext("Player profile")}</span>
                    </.link>
                  </span>

                  <span :if={is_nil(execution.player_id)} class="text-muted">
                    {gettext("server wide")}
                  </span>
                </td>

                <td data-label={gettext("Server")} class="text-sm text-subtle">
                  {execution.server.name}
                </td>

                <td data-label={gettext("Outcome")}>
                  <.tone_badge tone={status_tone(execution.status)}>
                    {Labels.execution_status(execution.status)}
                  </.tone_badge>
                </td>

                <td data-cell="actions" class="text-right">
                  <.button
                    id={"execution-#{execution.id}-toggle"}
                    type="button"
                    size="xs"
                    variant="ghost"
                    color="gray"
                    icon={
                      if MapSet.member?(@expanded, to_string(execution.id)),
                        do: "hero-chevron-up",
                        else: "hero-chevron-down"
                    }
                    icon_placement="right"
                    phx-click="toggle_details"
                    phx-value-id={execution.id}
                    aria-expanded={to_string(MapSet.member?(@expanded, to_string(execution.id)))}
                    label={gettext("Details")}
                  />
                </td>
              </tr>

              <tr :if={MapSet.member?(@expanded, to_string(execution.id))} class="bg-base-200/60">
                <td colspan="6">
                  <.execution_trace execution={execution} />
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
        <.pagination page={@page} per_page={@per_page} total={@total} on_page="page" />
      </.card>
    </Layouts.app>
    """
  end
end
