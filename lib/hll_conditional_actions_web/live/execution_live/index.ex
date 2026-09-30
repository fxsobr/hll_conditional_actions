defmodule HllConditionalActionsWeb.ExecutionLive.Index do
  @moduledoc """
  The audit log: every time a rule fired, for whom, and what each of its
  actions did - a dense table whose rows open into the trace of what each
  condition read, what each action returned and what went to Discord.

  New executions arrive live over PubSub, so an admin watching this page sees a
  rule take effect the moment it does — but only on the first page. Reloading
  page four because something happened on page one would move the row somebody
  is reading out from under their cursor, so past the first page the list holds
  still until they ask for it. Rows that arrived while the page was open are
  marked new, and the header counts them.
  """

  use HllConditionalActionsWeb, :live_view

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_executions}}

  import HllConditionalActionsWeb.RuleComponents

  alias HllConditionalActions.Engine
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Insights
  alias HllConditionalActions.Servers

  # Enough that a quiet server needs no paging at all, small enough that the
  # page stays quick on a busy one.
  @per_page 50

  @periods ~w(24h 7d 30d all custom)

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    servers = Servers.list_servers_for(socket.assigns[:current_user])
    scope = Enum.find(servers, &(to_string(&1.id) == params["server_id"]))

    if connected?(socket), do: Enum.each(servers, &Engine.subscribe(&1.id))

    {:ok,
     socket
     |> assign(:page_title, gettext("History"))
     |> assign(:servers, servers)
     |> assign(:zone, zone(servers))
     |> assign(:scope, scope)
     |> assign(:rules, Rules.list_rules_for(socket.assigns[:current_user]))
     |> assign(:expanded, MapSet.new())
     |> assign(:limits, %{})
     |> assign(:opened_at, DateTime.utc_now())
     |> assign(:fresh, MapSet.new())
     |> assign(:page, 1)
     |> assign(:per_page, @per_page)}
  end

  # The filters live in the URL, so a filtered view can be linked to (the
  # rule page's "open in the history", a player's name) and survives a reload.
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
    if MapSet.member?(socket.assigns.expanded, id) do
      {:noreply, update(socket, :expanded, &MapSet.delete(&1, id))}
    else
      {:noreply, socket |> update(:expanded, &MapSet.put(&1, id)) |> load_limits(id)}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:rule_fired, execution}, %{assigns: %{page: 1}} = socket) do
    fresh =
      case execution do
        %{id: id} -> MapSet.put(socket.assigns.fresh, id)
        _other -> socket.assigns.fresh
      end

    {:noreply, socket |> assign(:fresh, fresh) |> load()}
  end

  def handle_info({:rule_fired, _execution}, socket), do: {:noreply, socket}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp filters_from(params, scope) do
    period = if params["period"] in @periods, do: params["period"], else: nil
    from = cast_date(params["from"])
    to = cast_date(params["to"])

    %{
      # Under a server the filter is the server itself, not a choice.
      server_id: if(scope, do: to_string(scope.id), else: cast_id(params["server_id"])),
      rule_id: cast_id(params["rule_id"]),
      status: cast_status(params["status"]),
      player: blank_to_nil(params["player"]),
      period: period || if(from || to, do: "custom", else: "30d"),
      from: from,
      to: to
    }
  end

  defp filter_path(scope, filters) do
    query =
      filters
      |> Enum.reject(fn {key, value} ->
        is_nil(value) or (scope != nil and key == :server_id) or
          (key == :period and value == "30d") or
          (key in [:from, :to] and Map.get(filters, :period) != "custom")
      end)
      |> Enum.map(fn {key, value} -> {key, to_string(value)} end)
      |> Enum.sort()

    base = if scope, do: ~p"/servers/#{scope.id}/history", else: ~p"/executions"

    if query == [], do: base, else: base <> "?" <> URI.encode_query(query)
  end

  # What the context understands: a period becomes a start, dates become
  # the start and the end of that day (UTC).
  defp query_filters(filters) do
    now = DateTime.utc_now()

    {from, until} =
      case filters.period do
        "24h" ->
          {DateTime.add(now, -86_400, :second), nil}

        "7d" ->
          {DateTime.add(now, -7 * 86_400, :second), nil}

        "30d" ->
          {DateTime.add(now, -30 * 86_400, :second), nil}

        "custom" ->
          {filters.from && DateTime.new!(filters.from, ~T[00:00:00]),
           filters.to && DateTime.new!(filters.to, ~T[23:59:59.999999])}

        _all ->
          {nil, nil}
      end

    [
      server_id: filters.server_id,
      rule_id: filters.rule_id,
      status: filters.status,
      player: filters.player,
      from: from,
      until: until
    ]
  end

  defp filtered?(filters, scope) do
    Enum.any?(filters, fn {key, value} ->
      value != nil and not (scope != nil and key == :server_id) and
        not (key == :period and value == "30d")
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
    |> assign(:summary, Insights.overview(user, 30))
    |> assign(:total, total)
    |> assign(:page, page)
  end

  defp load_limits(socket, id) do
    case Enum.find(socket.assigns.executions, &(to_string(&1.id) == id)) do
      %{rule: %{} = rule} = execution ->
        limits =
          rule
          |> Insights.runs_before(execution.player_id, execution.executed_at)
          |> Enum.map(& &1.executed_at)

        update(socket, :limits, &Map.put(&1, id, limits))

      _other ->
        socket
    end
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

  defp expanded?(expanded, execution), do: MapSet.member?(expanded, to_string(execution.id))

  defp period_options do
    [
      {gettext("Last 24 hours"), "24h"},
      {gettext("Last 7 days"), "7d"},
      {gettext("Last 30 days"), "30d"},
      {gettext("Everything kept"), "all"},
      {gettext("Pick dates"), "custom"}
    ]
  end

  defp csv_path(filters) do
    query =
      filters
      |> query_filters()
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map(fn
        {key, %DateTime{} = at} -> {key, DateTime.to_iso8601(at)}
        {key, value} -> {key, to_string(value)}
      end)

    "/rules/export?" <> URI.encode_query([format: "csv"] ++ query)
  end

  defp success_text(nil), do: "–"

  defp success_text(rate) do
    rate |> :erlang.float_to_binary(decimals: 1) |> String.replace(".", ",") |> Kernel.<>("%")
  end

  @outcomes [:executed, :simulated, :partial, :failed]

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assigns
      |> assign(:delta, Insights.delta(assigns.summary.fired, assigns.summary.previous))
      |> assign(:outcomes, @outcomes)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Rules")}
    >
      <:actions>
        <%!-- Only the first page takes new runs as they happen; past it the
              list holds still under whoever is reading. --%>
        <span
          id="execution-live-status"
          role="status"
          class="flex h-12 items-center gap-2.5 rounded-full border border-base-300 bg-base-100 px-[1.125rem] text-[0.8125rem] text-subtle"
        >
          <span
            class={[
              "size-2 rounded-full",
              if(@page == 1, do: "bg-primary", else: "bg-base-300")
            ]}
            aria-hidden="true"
          ></span>
          <span :if={@page == 1} class="font-semibold text-primary">{gettext("Page 1 live")}</span>
          <span :if={@page != 1}>{gettext("Holding still while you read")}</span>
          <span :if={@page == 1} class="font-mono text-xs text-muted max-sm:hidden">
            +{MapSet.size(@fresh)} {gettext("since")} {clock(@opened_at, @zone)}
          </span>
        </span>
        <.header_button
          id="execution-csv"
          href={csv_path(@filters)}
          download
          icon="hero-arrow-down-tray"
          class="max-sm:hidden"
        >
          {gettext("Export CSV")}
        </.header_button>
      </:actions>

      <div
        id="execution-kpis"
        class="grid grid-cols-2 gap-3 sm:gap-5 xl:grid-cols-[1fr_1fr_1fr_1.75fr]"
      >
        <section class="flex min-h-[6.5rem] flex-col gap-0.5 rounded-[1.375rem] bg-base-100 px-[1.375rem] py-4">
          <span class="text-[0.8125rem] text-subtle">{gettext("Runs · 30 days")}</span>
          <strong class="font-display text-[2rem] font-semibold leading-[1.15] tabular-nums">
            {number(@summary.fired)}
          </strong>
          <span
            :if={@delta}
            class={["text-xs", if(@delta >= 0, do: "text-primary", else: "text-warning")]}
          >
            {gettext("%{delta}% on the 30 days before",
              delta: if(@delta > 0, do: "+#{@delta}", else: @delta)
            )}
          </span>
          <span :if={is_nil(@delta)} class="text-xs text-muted">
            {gettext("every recorded execution")}
          </span>
        </section>
        <section class="flex min-h-[6.5rem] flex-col gap-0.5 rounded-[1.375rem] bg-base-100 px-[1.375rem] py-4">
          <span class="text-[0.8125rem] text-subtle">{gettext("Success")}</span>
          <strong class="font-display text-[2rem] font-semibold leading-[1.15] tabular-nums">
            {success_text(@summary.success_rate)}
          </strong>
          <span :if={@summary.top_failing} class="truncate text-xs text-warning">
            {gettext("%{count} of the %{total} failures: %{rule}",
              count: number(@summary.top_failing.count),
              total: number(@summary.failed),
              rule: @summary.top_failing.name
            )}
          </span>
          <span :if={is_nil(@summary.top_failing)} class="text-xs text-muted">
            {gettext("no failure in 30 days")}
          </span>
        </section>
        <section class="flex min-h-[6.5rem] flex-col gap-0.5 rounded-[1.375rem] bg-base-100 px-[1.375rem] py-4">
          <span class="text-[0.8125rem] text-subtle">{gettext("Players reached")}</span>
          <strong class="font-display text-[2rem] font-semibold leading-[1.15] tabular-nums">
            {number(@summary.players)}
          </strong>
          <span class="text-xs text-muted">
            {ngettext("on 1 server", "on %{count} servers", @summary.servers)}
          </span>
        </section>
        <section
          aria-label={gettext("Executions by result")}
          class="col-span-2 flex flex-col justify-center gap-3 rounded-[1.375rem] bg-base-100 px-[1.375rem] py-4 xl:col-span-1"
        >
          <span class="text-[0.8125rem] text-subtle">{gettext("By result")}</span>
          <div :if={@summary.fired > 0} class="flex h-3 gap-[3px]" aria-hidden="true">
            <span
              :for={status <- @outcomes}
              :if={Map.get(@summary.by_status, status, 0) > 0}
              class={["rounded", result_fill(status)]}
              style={"flex-grow: #{Map.get(@summary.by_status, status, 0)}"}
            ></span>
          </div>
          <div :if={@summary.fired == 0} class="h-3 rounded bg-secondary" aria-hidden="true"></div>
          <ul class="flex flex-wrap gap-x-3 gap-y-1 text-xs text-subtle">
            <li :for={status <- @outcomes} class="flex items-center gap-1.5">
              <span class={["size-[9px] rounded-[3px]", result_fill(status)]} aria-hidden="true"></span>
              {outcome_label(status)}
              <span class="font-mono text-base-content">
                {number(Map.get(@summary.by_status, status, 0))}
              </span>
            </li>
          </ul>
        </section>
      </div>

      <section
        aria-label={gettext("Executions")}
        class="flex min-w-0 flex-col rounded-[1.75rem] bg-base-100 px-3 pt-3 pb-3 sm:px-5 sm:pt-[1.125rem] sm:pb-4"
      >
        <form
          id="execution-filters"
          phx-change="filter"
          class="mb-3 flex flex-wrap items-center gap-2"
        >
          <.select_pill name="rule_id" label={gettext("Rule")}>
            <option value="">{gettext("All")}</option>
            <option
              :for={rule <- @rules}
              value={rule.id}
              selected={@filters.rule_id == to_string(rule.id)}
            >
              {rule.name}
            </option>
          </.select_pill>
          <.select_pill :if={is_nil(@scope)} name="server_id" label={gettext("Server")}>
            <option value="">{gettext("All")}</option>
            <option
              :for={server <- @servers}
              value={server.id}
              selected={@filters.server_id == to_string(server.id)}
            >
              {server.name}
            </option>
          </.select_pill>
          <.select_pill name="status" label={gettext("Result")}>
            <option value="">{gettext("All")}</option>
            <option
              :for={status <- @outcomes}
              value={status}
              selected={@filters.status == status}
            >
              {outcome_label(status)}
            </option>
          </.select_pill>
          <label class="flex h-10 w-[14.375rem] max-w-full items-center gap-2 rounded-full border border-base-300 bg-secondary px-3.5 text-muted">
            <.icon name="hero-magnifying-glass" class="size-4 shrink-0" />
            <span class="sr-only">{gettext("Player name or ID")}</span>
            <input
              type="search"
              name="player"
              value={@filters.player}
              phx-debounce="300"
              placeholder={gettext("Player or Steam ID")}
              class="w-full border-0 bg-transparent p-0 text-[0.8125rem] text-base-content placeholder:text-muted focus:ring-0"
            />
          </label>
          <label class="relative flex h-10 items-center gap-2 rounded-full border border-base-300 bg-secondary pl-3.5 text-[0.8125rem]">
            <.icon name="hero-calendar" class="size-4 text-muted" />
            <span class="sr-only">{gettext("Period")}</span>
            <select
              name="period"
              class="h-full cursor-pointer appearance-none border-0 bg-transparent py-0 pr-8 pl-0 text-[0.8125rem] font-medium text-base-content focus:ring-0"
            >
              {Phoenix.HTML.Form.options_for_select(period_options(), @filters.period)}
            </select>
            <.icon
              name="hero-chevron-down"
              class="pointer-events-none absolute right-3 size-3.5 text-muted"
            />
          </label>
          <span :if={@filters.period == "custom"} class="flex items-center gap-1.5 text-xs text-muted">
            <input
              type="date"
              name="from"
              value={@filters.from}
              class="pc-text-input h-10"
              aria-label={gettext("From")}
            />
            <span>–</span>
            <input
              type="date"
              name="to"
              value={@filters.to}
              class="pc-text-input h-10"
              aria-label={gettext("To")}
            />
          </span>
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
          <span class="grow"></span>
          <span :if={@total > 0} class="text-[0.8125rem] text-muted">
            <span class="font-mono text-base-content">{number(@total)}</span>
            {ngettext("execution, newest first", "executions, newest first", @total)}
          </span>
        </form>

        <.empty_state
          :if={@executions == []}
          card={false}
          icon="hero-clock"
          title={gettext("No rule executions recorded yet.")}
          description={
            gettext("Every time a rule fires it is recorded here, with what each of its actions did.")
          }
        />

        <div
          :if={@executions != []}
          class="hidden grid-cols-[8rem_minmax(0,1.25fr)_7.25rem_minmax(0,1fr)_minmax(0,1.05fr)_7rem_4.375rem_1.25rem] gap-3.5 border-b border-base-300 px-3.5 py-2 text-xs text-muted lg:grid"
        >
          <span>{gettext("When")}</span>
          <span>{gettext("Rule")}</span>
          <span>{gettext("Server")}</span>
          <span>{gettext("Player")}</span>
          <span>{gettext("Trigger")}</span>
          <span>{gettext("Result")}</span>
          <span class="text-right">{gettext("Duration")}</span>
          <span></span>
        </div>

        <div :if={@executions != []} id="execution-rows" class="flex flex-col">
          <div
            :for={execution <- @executions}
            id={"execution-#{execution.id}"}
            class={[
              if(expanded?(@expanded, execution),
                do: [
                  "my-1 overflow-hidden rounded-[1.25rem] border",
                  if(execution.status in [:failed, :partial],
                    do: "border-error/35",
                    else: "border-base-300"
                  )
                ],
                else: "border-b border-base-300"
              ),
              MapSet.member?(@fresh, execution.id) && !expanded?(@expanded, execution) &&
                "bg-primary/4"
            ]}
          >
            <button
              id={"execution-#{execution.id}-toggle"}
              type="button"
              phx-click="toggle_details"
              phx-value-id={execution.id}
              aria-expanded={to_string(expanded?(@expanded, execution))}
              class={[
                "grid w-full cursor-pointer grid-cols-[minmax(0,1fr)_auto] items-center gap-x-3.5 gap-y-1 px-3.5 py-2.5 text-left text-[0.8125rem] transition-colors hover:bg-secondary/50 lg:grid-cols-[8rem_minmax(0,1.25fr)_7.25rem_minmax(0,1fr)_minmax(0,1.05fr)_7rem_4.375rem_1.25rem]",
                expanded?(@expanded, execution) && "border-b border-base-300",
                (expanded?(@expanded, execution) and execution.status in [:failed, :partial]) &&
                  "bg-error/6"
              ]}
            >
              <span class="font-mono text-xs text-subtle max-lg:col-span-2">
                {stamp(execution.executed_at, @zone)}
              </span>
              <span class="flex min-w-0 items-center gap-2 font-semibold">
                <span
                  :if={MapSet.member?(@fresh, execution.id)}
                  class="shrink-0 rounded-full bg-primary px-1.5 py-0.5 text-[0.625rem] font-bold text-primary-content"
                >
                  {gettext("NEW")}
                </span>
                <span class="truncate">{execution.rule.name}</span>
              </span>
              <span class="truncate text-subtle max-lg:hidden">{execution.server.name}</span>
              <span class="truncate max-lg:col-start-1">
                <%= if execution.player_id do %>
                  {execution.player_name || execution.player_id}
                  <.link
                    navigate={~p"/players/#{execution.player_id}"}
                    class="sr-only"
                    tabindex="-1"
                  >
                    {gettext("Player profile")}
                  </.link>
                <% else %>
                  <span class="text-muted">{gettext("server wide")}</span>
                <% end %>
              </span>
              <span class="truncate text-subtle max-lg:hidden">
                {trigger_label(execution.trigger_event)}
              </span>
              <span class="max-lg:col-start-2 max-lg:row-start-2 max-lg:justify-self-end">
                <.result_pill status={execution.status} dot />
              </span>
              <span class="text-right font-mono text-xs text-subtle max-lg:hidden">
                {duration(execution) || "—"}
              </span>
              <.icon
                name={
                  if expanded?(@expanded, execution),
                    do: "hero-chevron-down",
                    else: "hero-chevron-right"
                }
                class="size-4 text-muted max-lg:hidden"
              />
            </button>

            <.execution_trace
              :if={expanded?(@expanded, execution)}
              id={"execution-#{execution.id}-trace"}
              execution={execution}
              limits={Map.get(@limits, to_string(execution.id))}
              zone={@zone}
              variant={:history}
            />
          </div>
        </div>

        <.pager page={@page} per_page={@per_page} total={@total} />
      </section>
    </Layouts.app>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp select_pill(assigns) do
    ~H"""
    <label class="relative flex h-10 items-center gap-2 rounded-full border border-base-300 bg-secondary pl-3.5 text-[0.8125rem]">
      <span class="text-muted">{@label}</span>
      <select
        name={@name}
        class="h-full max-w-40 cursor-pointer appearance-none truncate border-0 bg-transparent py-0 pr-8 pl-0 text-[0.8125rem] font-medium text-base-content focus:ring-0"
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

  attr :page, :integer, required: true
  attr :per_page, :integer, required: true
  attr :total, :integer, required: true

  # The pages as the board draws them: round buttons, the current one filled,
  # an ellipsis before the last.
  defp pager(assigns) do
    pages = max(ceil(assigns.total / assigns.per_page), 1)

    assigns =
      assigns
      |> assign(:pages, pages)
      |> assign(:first, (assigns.page - 1) * assigns.per_page + 1)
      |> assign(:last, min(assigns.page * assigns.per_page, assigns.total))
      |> assign(:window, page_window(assigns.page, pages))

    ~H"""
    <nav
      :if={@total > 0}
      aria-label={gettext("Pages")}
      class="flex flex-wrap items-center gap-1.5 px-1 pt-4"
    >
      <span class="flex-1 text-[0.8125rem] text-muted">
        <span class="font-mono text-base-content">{@first}–{@last}</span>
        {gettext("of %{total}", total: number(@total))} · {gettext("only page 1 takes new executions")}
      </span>
      <div :if={@pages > 1} class="flex items-center gap-1.5">
        <button
          type="button"
          phx-click="page"
          phx-value-page={@page - 1}
          disabled={@page == 1}
          aria-label={gettext("Previous page")}
          class="flex size-9 cursor-pointer items-center justify-center rounded-full border border-base-300 bg-secondary transition-colors hover:bg-base-200 disabled:cursor-default disabled:bg-transparent disabled:text-muted"
        >
          <.icon name="hero-chevron-left" class="size-4" />
        </button>
        <%= for item <- @window do %>
          <span :if={item == :gap} class="px-0.5 text-xs text-muted">…</span>
          <button
            :if={item != :gap}
            type="button"
            phx-click="page"
            phx-value-page={item}
            aria-current={item == @page && "page"}
            aria-label={gettext("Page %{number}", number: item)}
            class={[
              "h-9 min-w-9 cursor-pointer rounded-full px-2 font-mono text-xs transition-colors",
              if(item == @page,
                do: "bg-base-content font-semibold text-base-100",
                else: "text-subtle hover:bg-secondary"
              )
            ]}
          >
            {item}
          </button>
        <% end %>
        <button
          type="button"
          phx-click="page"
          phx-value-page={@page + 1}
          disabled={@page == @pages}
          aria-label={gettext("Next page")}
          class="flex size-9 cursor-pointer items-center justify-center rounded-full border border-base-300 bg-secondary transition-colors hover:bg-base-200 disabled:cursor-default disabled:bg-transparent disabled:text-muted"
        >
          <.icon name="hero-chevron-right" class="size-4" />
        </button>
      </div>
    </nav>
    """
  end

  # 1, 2, 3 … 250 around the current page.
  defp page_window(_page, pages) when pages <= 6, do: Enum.to_list(1..pages)

  defp page_window(page, pages) do
    middle = Enum.to_list(max(page - 1, 1)..min(page + 1, pages))
    head = if 1 in middle, do: [], else: [1]
    tail = if pages in middle, do: [], else: [pages]
    head = if head != [] and hd(middle) > 2, do: head ++ [:gap], else: head
    tail = if tail != [] and List.last(middle) < pages - 1, do: [:gap] ++ tail, else: tail
    head ++ middle ++ tail
  end
end
