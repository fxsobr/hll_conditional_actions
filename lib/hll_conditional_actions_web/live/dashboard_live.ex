defmodule HllConditionalActionsWeb.DashboardLive do
  @moduledoc """
  The overview: what the rules did over a period, and the state of the fleet.

  Read top to bottom it answers, in order, the questions an admin opens the
  tool with:

    1. *Is it set up?* - a checklist until the install is trusted to act on
       its own (`HllConditionalActions.Onboarding`)
    2. *Is it working?* - fired, success rate, players reached and run time,
       each against the period before
    3. *When and on what?* - a daily chart and the split by trigger
    4. *Which rules?* - the busiest rules with their failure rate
    5. *Are the servers alive?* - one card per server with its stream

  The period lives in the URL (`?period=30`), so a view can be shared.
  """

  use HllConditionalActionsWeb, :live_view

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Engine.Runner
  alias HllConditionalActions.Onboarding
  alias HllConditionalActions.Reports
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Recipes
  alias HllConditionalActions.Servers

  @refresh_ms :timer.seconds(10)
  @default_period 30

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Servers.subscribe()
      # One subscription for every server's status, including the ones added
      # while this page is open. Subscribing per server, as this used to, left
      # a new server stuck on "Connecting" until a reload.
      LogStream.subscribe_status()

      :timer.send_interval(@refresh_ms, :refresh)
    end

    {:ok, assign(socket, page_title: gettext("Overview"), period: @default_period)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    {:noreply, socket |> assign(:period, parse_period(params["period"])) |> load()}
  end

  @impl Phoenix.LiveView
  def handle_info({:crcon_stream_status, server_id, status}, socket) do
    {:noreply,
     socket
     |> update(:stream_status, &Map.put(&1, server_id, status))
     |> assign_onboarding()}
  end

  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  def handle_info({event, _server}, socket)
      when event in [:server_created, :server_updated, :server_deleted] do
    {:noreply, load(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp parse_period(value) do
    case Integer.parse(value || "") do
      {days, ""} -> if days in Reports.periods(), do: days, else: @default_period
      _other -> @default_period
    end
  end

  # Every authenticated user lands here, so this page has no permission of its
  # own. That makes what it *loads* the only gate: a role without
  # `:view_servers` must not learn the names of the servers from the dashboard
  # when `/servers` would refuse to show them, and one without
  # `:view_executions` sees no activity numbers.
  defp load(socket) do
    servers = visible_servers(socket)
    user = socket.assigns[:current_user]

    socket
    |> assign(:servers, servers)
    |> assign(:stream_status, Map.new(servers, &{&1.id, LogStream.status(&1.id)}))
    |> assign(:runner_info, Map.new(servers, &{&1.id, Runner.info(&1.id)}))
    |> assign(:activity?, Accounts.can?(user, :view_executions))
    |> assign(:report, report(user, socket.assigns.period))
    |> assign(:recent, recent_executions(user))
    |> assign_onboarding()
  end

  defp assign_onboarding(socket) do
    user = socket.assigns.current_user
    steps = Onboarding.steps(user, socket.assigns.servers, socket.assigns.stream_status)

    socket
    |> assign(:steps, steps)
    |> assign(:onboarding?, Onboarding.show?(user, steps))
  end

  defp visible_servers(socket) do
    if Accounts.can?(socket.assigns[:current_user], :view_servers) do
      Servers.list_servers_for(socket.assigns[:current_user])
    else
      []
    end
  end

  defp report(user, period) do
    if Accounts.can?(user, :view_executions), do: Reports.overview(user, period)
  end

  defp recent_executions(user) do
    if Accounts.can?(user, :view_executions) do
      Rules.list_executions_for(user, limit: 6)
    else
      []
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      page_subtitle={subtitle(@report, @servers)}
    >
      <:actions>
        <nav
          :if={@report}
          id="overview-period"
          aria-label={gettext("Period")}
          class="flex items-center gap-0.5 rounded-pill border border-base-300 bg-base-100 p-0.5"
        >
          <.link
            :for={days <- Reports.periods()}
            patch={~p"/?period=#{days}"}
            class={[
              "rounded-pill px-3 py-1 text-xs font-medium whitespace-nowrap transition-colors",
              if(days == @period,
                do: "bg-primary text-primary-content",
                else: "text-muted hover:text-base-content"
              )
            ]}
            aria-current={days == @period && "true"}
          >
            {gettext("%{count} days", count: days)}
          </.link>
        </nav>
        <.button
          :if={Accounts.can?(@current_user, :manage_rules) and @servers != []}
          link_type="live_redirect"
          to={~p"/rules/new"}
          size="sm"
          color="primary"
          icon="hero-plus"
        >
          <span class="hidden sm:inline">{gettext("New rule")}</span>
        </.button>
      </:actions>

      <.onboarding :if={@onboarding?} steps={@steps} />

      <%!-- "No servers yet" would be a lie to somebody whose role simply does
            not let them see the ones that exist; and the checklist above
            already says it to anyone who can add one. --%>
      <.empty_state
        :if={@servers == [] and not @onboarding? and Accounts.can?(@current_user, :view_servers)}
        icon="hero-server-stack"
        title={gettext("No servers yet")}
        description={
          gettext("An administrator has not connected a CRCON instance yet. Check back later.")
        }
      />

      <div :if={@report && @servers != []} class="space-y-4">
        <div id="overview-kpis" class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <.kpi
            icon="hero-bolt"
            label={gettext("Rules fired")}
            value={format_number(@report.totals.fired)}
            change={Reports.change(@report.totals.fired, @report.previous.fired)}
            hint={
              ngettext("%{count} in simulation", "%{count} in simulation", @report.totals.simulated)
            }
            to={~p"/executions"}
          />
          <.kpi
            icon="hero-check-badge"
            label={gettext("Success rate")}
            value={percent(@report.totals.success_rate)}
            change={points(@report.totals.success_rate, @report.previous.success_rate)}
            change_unit={gettext("pts")}
            hint={ngettext("1 failed", "%{count} failed", @report.totals.failed)}
            to={~p"/executions"}
          />
          <.kpi
            icon="hero-users"
            label={gettext("Players reached")}
            value={format_number(@report.totals.players)}
            change={Reports.change(@report.totals.players, @report.previous.players)}
            hint={gettext("different players a rule acted on")}
          />
          <.kpi
            icon="hero-clock"
            label={gettext("Average run time")}
            value={duration(@report.totals.duration_ms)}
            change={Reports.change(@report.totals.duration_ms, @report.previous.duration_ms)}
            lower_is_better
            hint={gettext("from trigger to last action")}
          />
        </div>

        <div class="grid gap-4 xl:grid-cols-3">
          <section class="overview-card xl:col-span-2" aria-labelledby="overview-chart-title">
            <header class="overview-card-head">
              <h2 id="overview-chart-title" class="overview-card-title">
                <.icon name="hero-chart-bar" class="size-4" />
                {gettext("Activity · last %{count} days", count: @period)}
              </h2>
              <div class="flex items-center gap-3 text-xs text-subtle">
                <span class="flex items-center gap-1.5">
                  <span class="size-2 rounded-full bg-primary"></span>{gettext("Fired")}
                </span>
                <span class="flex items-center gap-1.5">
                  <span class="size-2 rounded-full bg-error"></span>{gettext("Failed")}
                </span>
              </div>
            </header>

            <.activity_chart :if={@report.totals.fired > 0} daily={@report.daily} />
            <.quiet_period :if={@report.totals.fired == 0} period={@period} />
          </section>

          <section class="overview-card" aria-labelledby="overview-trigger-title">
            <header class="overview-card-head">
              <h2 id="overview-trigger-title" class="overview-card-title">
                <.icon name="hero-bolt" class="size-4" />{gettext("By trigger")}
              </h2>
            </header>

            <p :if={@report.by_trigger == []} class="py-6 text-center text-sm text-muted">
              {gettext("Nothing fired in this period.")}
            </p>

            <ul :if={@report.by_trigger != []} class="space-y-3.5">
              <li :for={
                {{trigger, count}, index} <- Enum.with_index(Enum.take(@report.by_trigger, 6))
              }>
                <div class="flex items-center gap-2 text-sm">
                  <span class={["size-2 shrink-0 rounded-full", bar_tone(index)]}></span>
                  <span class="min-w-0 flex-1 truncate">{trigger_label(trigger)}</span>
                  <span class="font-medium tabular-nums">{format_number(count)}</span>
                  <span class="w-9 text-right text-xs text-muted tabular-nums">
                    {share(count, @report.totals.fired)}%
                  </span>
                </div>
                <div class="mt-1.5 h-1.5 overflow-hidden rounded-pill bg-base-200">
                  <div
                    class={["h-full rounded-pill", bar_tone(index)]}
                    style={"width: #{share(count, @report.totals.fired)}%"}
                  >
                  </div>
                </div>
              </li>
            </ul>
          </section>
        </div>

        <section
          :if={@report.rules != []}
          id="overview-rules"
          class="overview-card"
          aria-labelledby="overview-rules-title"
        >
          <header class="overview-card-head">
            <h2 id="overview-rules-title" class="overview-card-title">
              <.icon name="hero-trophy" class="size-4" />
              {gettext("Busiest rules · last %{count} days", count: @period)}
            </h2>
            <.link navigate={~p"/rules"} class="text-xs text-muted hover:text-primary hover:underline">
              {gettext("All rules")}
            </.link>
          </header>

          <div class="-mx-4 overflow-x-auto sm:-mx-5">
            <table class="w-full min-w-[40rem] text-sm">
              <thead class="text-left text-xs tracking-wide text-muted uppercase">
                <tr class="border-b border-base-300">
                  <th class="px-4 py-2 font-medium sm:px-5">{gettext("Rule")}</th>
                  <th class="px-2 py-2 text-right font-medium">{gettext("Fired")}</th>
                  <th class="px-2 py-2 text-right font-medium">{gettext("Success")}</th>
                  <th class="px-2 py-2 text-right font-medium">{gettext("Players")}</th>
                  <th class="px-2 py-2 font-medium">{gettext("State")}</th>
                  <th class="px-4 py-2 text-right font-medium sm:px-5">{gettext("Last fired")}</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-300">
                <tr :for={rule <- @report.rules} class="transition-colors hover:bg-base-200/50">
                  <td class="px-4 py-2.5 sm:px-5">
                    <.link navigate={~p"/rules/#{rule.id}"} class="flex items-center gap-2.5">
                      <span class="flex size-8 shrink-0 items-center justify-center rounded-field bg-primary/10 text-primary">
                        <.icon name={Icons.trigger(rule.trigger)} class="size-4" />
                      </span>
                      <span class="min-w-0">
                        <span class="block truncate font-medium hover:underline">{rule.name}</span>
                        <span class="block truncate text-xs text-muted">
                          {Labels.trigger(rule.trigger)}
                        </span>
                      </span>
                    </.link>
                  </td>
                  <td class="px-2 py-2.5 text-right font-mono tabular-nums">
                    {format_number(rule.fired)}
                  </td>
                  <td class={[
                    "px-2 py-2.5 text-right font-mono tabular-nums",
                    success_tone(rule)
                  ]}>
                    {rule_success(rule)}
                  </td>
                  <td class="px-2 py-2.5 text-right font-mono tabular-nums">
                    {format_number(rule.players)}
                  </td>
                  <td class="px-2 py-2.5"><.rule_state rule={rule} /></td>
                  <td class="px-4 py-2.5 text-right text-xs whitespace-nowrap text-muted sm:px-5">
                    <.local_time id={"overview-rule-#{rule.id}-at"} at={rule.last_at} />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>

      <div :if={@servers != []} class="mt-4 grid gap-4 xl:grid-cols-3">
        <section
          class={["overview-card", if(@recent == [], do: "xl:col-span-3", else: "xl:col-span-2")]}
          aria-labelledby="overview-servers-title"
        >
          <header class="overview-card-head">
            <h2 id="overview-servers-title" class="overview-card-title">
              <.icon name="hero-server-stack" class="size-4" />{gettext("Servers")}
            </h2>
            <span class="text-xs text-muted">
              {stream_hint(@stream_status, @servers)}
            </span>
          </header>

          <div class="grid gap-3 sm:grid-cols-2">
            <.link
              :for={server <- @servers}
              navigate={~p"/servers/#{server}"}
              class="group flex items-center gap-3 rounded-box border border-base-300 p-2.5 transition-colors hover:border-primary/40 hover:bg-base-200/40"
            >
              <img
                src={server_art(server)}
                alt=""
                class="size-12 shrink-0 rounded-field object-cover"
                loading="lazy"
              />
              <span class="min-w-0 flex-1">
                <span class="block truncate font-medium">{server.name}</span>
                <span class="block truncate text-xs text-muted">
                  {Labels.game(server.game)} · {rule_count(@runner_info[server.id])}
                </span>
              </span>
              <.stream_badge status={@stream_status[server.id]} enabled={server.enabled} />
            </.link>
          </div>
        </section>

        <section :if={@recent != []} class="overview-card" aria-labelledby="overview-recent-title">
          <header class="overview-card-head">
            <h2 id="overview-recent-title" class="overview-card-title">
              <.icon name="hero-clock" class="size-4" />{gettext("Latest rule activity")}
            </h2>
            <.link
              navigate={~p"/executions"}
              class="text-xs text-muted hover:text-primary hover:underline"
            >
              {gettext("See all")}
            </.link>
          </header>

          <ul class="-my-1 divide-y divide-base-300">
            <li :for={execution <- @recent} class="flex items-start gap-2.5 py-2.5">
              <.status_dot
                tone={execution_tone(execution.status)}
                label={Labels.execution_status(execution.status)}
                class="mt-1.5"
              />
              <div class="min-w-0 flex-1">
                <p class="truncate text-sm font-medium leading-tight">{execution.rule.name}</p>
                <p class="truncate text-xs text-muted">
                  {execution.player_name || gettext("server wide")} · {execution.server.name}
                </p>
              </div>
              <.local_time
                id={"recent-#{execution.id}-at"}
                at={execution.executed_at}
                class="shrink-0 text-xs text-muted"
              />
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # ── Onboarding ─────────────────────────────────────────────────────────────

  attr :steps, :list, required: true

  # A vertical stepper. Every step is visible so the road ahead is clear, but
  # only the ones whose prerequisites exist carry anything to press; a locked
  # step says what it is waiting for instead.
  defp onboarding(assigns) do
    done = Enum.count(assigns.steps, &(&1.state == :done))

    assigns =
      assign(assigns,
        done: done,
        total: length(assigns.steps),
        focus: Onboarding.focus(assigns.steps)
      )

    ~H"""
    <section
      id="onboarding"
      class="onboarding mb-4"
      data-collapsed="false"
      data-keep-attrs="data-collapsed"
      x-data
      x-init="try { if (localStorage.getItem('onboarding-collapsed') === '1') $el.dataset.collapsed = 'true' } catch (_e) {}"
      aria-labelledby="onboarding-title"
    >
      <div class="onboarding-hero">
        <div class="min-w-0 flex-1">
          <p class="text-xs font-medium tracking-wide text-primary uppercase">
            {gettext("Getting started")}
          </p>
          <h2 id="onboarding-title" class="mt-1 text-xl font-semibold">
            {hero_title(@focus, @done)}
          </h2>
          <p class="mt-1 max-w-2xl text-sm text-subtle">
            {gettext(
              "A rule needs a server to run on, and earns trust in simulation before it acts. The steps unlock in that order."
            )}
          </p>

          <div class="mt-3 flex items-center gap-3">
            <div class="h-2 w-full max-w-xs overflow-hidden rounded-pill bg-base-300">
              <div
                class="h-full rounded-pill bg-primary transition-all"
                style={"width: #{round(@done * 100 / max(@total, 1))}%"}
              >
              </div>
            </div>
            <span class="text-xs text-muted tabular-nums">{@done}/{@total}</span>
          </div>
        </div>

        <button
          type="button"
          class="onboarding-toggle"
          x-on:click="const c = $root.dataset.collapsed !== 'true'; $root.dataset.collapsed = c; try { localStorage.setItem('onboarding-collapsed', c ? '1' : '0') } catch (_e) {}"
        >
          <span class="onboarding-when-open">{gettext("Hide steps")}</span>
          <span class="onboarding-when-collapsed">{gettext("Show steps")}</span>
          <.icon name="hero-chevron-up" class="onboarding-chevron size-4" />
        </button>
      </div>

      <ol class="onboarding-steps">
        <li
          :for={{step, index} <- Enum.with_index(@steps, 1)}
          id={"onboarding-step-#{step.id}"}
          class="onboarding-step"
          data-state={step.state}
        >
          <span class="onboarding-marker" aria-hidden="true">
            <%= case step.state do %>
              <% :done -> %>
                <.icon name="hero-check" class="size-4" />
              <% :locked -> %>
                <.icon name="hero-lock-closed" class="size-3.5" />
              <% :waiting -> %>
                <span class="onboarding-pulse"></span>
              <% :blocked -> %>
                <.icon name="hero-exclamation-triangle" class="size-4" />
              <% _numbered -> %>
                {index}
            <% end %>
          </span>

          <div class="min-w-0 flex-1 pb-1">
            <div class="flex flex-wrap items-center gap-2">
              <p class="font-medium">{step_title(step.id)}</p>
              <span class="onboarding-state">{state_label(step)}</span>
            </div>

            <p :if={step.state != :done} class="mt-0.5 text-sm text-subtle">
              {step_hint(step)}
            </p>

            <p :if={step.state == :locked} class="mt-1 flex items-center gap-1.5 text-xs text-muted">
              <.icon name="hero-lock-closed" class="size-3.5" />
              {gettext("Unlocks after: %{step}", step: step_title(step.requires))}
            </p>

            <p
              :if={step.state == :blocked}
              class="mt-2 rounded-field bg-error/10 px-3 py-2 font-mono text-xs break-words text-error"
            >
              {stream_problem(step.context.error)}
            </p>

            <div
              :if={step.state in [:current, :waiting, :blocked, :available]}
              class="mt-3 flex flex-wrap items-center gap-2"
            >
              <.step_actions step={step} primary={step.state in [:current, :blocked]} />
            </div>
          </div>
        </li>
      </ol>
    </section>
    """
  end

  attr :step, :map, required: true
  attr :primary, :boolean, default: false

  defp step_actions(%{step: %{id: :server}} = assigns) do
    ~H"""
    <.button
      link_type="live_redirect"
      to={~p"/servers/new?from=onboarding"}
      size="sm"
      color={if @primary, do: "primary", else: "gray"}
      variant={if @primary, do: "solid", else: "outline"}
      icon="hero-plus"
      label={gettext("Connect a server")}
    />
    <span class="text-xs text-muted">
      {gettext("You will need its address and an API key from CRCON.")}
    </span>
    """
  end

  defp step_actions(%{step: %{id: :stream}} = assigns) do
    ~H"""
    <.button
      :if={@step.context[:server]}
      link_type="live_redirect"
      to={
        if @step.state == :blocked,
          do: ~p"/servers/#{@step.context.server}/edit",
          else: ~p"/servers/#{@step.context.server}"
      }
      size="sm"
      color={if @primary, do: "primary", else: "gray"}
      variant={if @primary, do: "solid", else: "outline"}
      icon={if @step.state == :blocked, do: "hero-wrench-screwdriver", else: "hero-signal"}
      label={
        if @step.state == :blocked,
          do: gettext("Review the server"),
          else: gettext("Open %{name}", name: @step.context.server.name)
      }
    />
    """
  end

  defp step_actions(%{step: %{id: :modules}} = assigns) do
    ~H"""
    <.button
      :if={@step.context[:server]}
      link_type="live_redirect"
      to={~p"/servers/#{@step.context.server}/marketplace"}
      size="sm"
      color={if @primary, do: "primary", else: "gray"}
      variant={if @primary, do: "solid", else: "outline"}
      icon="hero-squares-plus"
      label={gettext("Open the marketplace")}
    />
    <span class="text-xs text-muted">
      {gettext("Rules, tickets, achievements, leaderboards: install only what you need.")}
    </span>
    """
  end

  # Rules are a module too: without it, the recipes would open a page that
  # is not installed, so the step points at the marketplace instead.
  defp step_actions(
         %{step: %{id: :rule, context: %{rules_installed?: false, server: server}}} = assigns
       )
       when not is_nil(server) do
    ~H"""
    <.button
      link_type="live_redirect"
      to={~p"/servers/#{@step.context.server}/marketplace"}
      size="sm"
      color={if @primary, do: "primary", else: "gray"}
      variant={if @primary, do: "solid", else: "outline"}
      icon="hero-bolt"
      label={gettext("Install Conditional rules")}
    />
    """
  end

  defp step_actions(%{step: %{id: :rule}} = assigns) do
    assigns =
      assign(assigns, :server_id, assigns.step.context.server && assigns.step.context.server.id)

    ~H"""
    <.link
      :for={recipe <- Enum.take(Recipes.all(), 3)}
      navigate={new_rule_path(recipe: recipe.id, server_id: @server_id)}
      class="onboarding-recipe"
    >
      <.recipe_art id={recipe.id} class="size-6 text-primary" />{Labels.recipe_name(recipe.id)}
    </.link>
    <.link navigate={new_rule_path(server_id: @server_id)} class="onboarding-recipe">
      <.icon name="hero-document-plus" class="size-4 text-muted" />{gettext("Blank rule")}
    </.link>
    <p class="basis-full text-xs text-muted">
      {gettext("Recipes start in simulation: they record what they would do, and touch nothing.")}
    </p>
    """
  end

  defp step_actions(%{step: %{id: :simulation}} = assigns) do
    ~H"""
    <%= if rule = @step.context[:rule] do %>
      <.button
        link_type="live_redirect"
        to={~p"/rules/#{rule.id}/edit"}
        size="sm"
        color="gray"
        variant="outline"
        icon="hero-arrow-path"
        label={gettext("Replay it on recent events")}
      />
      <.link
        navigate={~p"/rules/#{rule.id}"}
        class="text-xs text-muted hover:text-primary hover:underline"
      >
        {gettext("Open %{name}", name: rule.name)}
      </.link>
    <% end %>
    """
  end

  defp step_actions(%{step: %{id: :live}} = assigns) do
    ~H"""
    <.button
      link_type="live_redirect"
      to={if @step.context[:rule], do: ~p"/rules/#{@step.context.rule.id}", else: ~p"/rules"}
      size="sm"
      color={if @primary, do: "primary", else: "gray"}
      variant={if @primary, do: "solid", else: "outline"}
      icon="hero-play"
      label={
        if @step.context[:rule],
          do: gettext("Review %{name}", name: @step.context.rule.name),
          else: gettext("Open your rules")
      }
    />
    """
  end

  defp step_actions(%{step: %{id: :two_factor}} = assigns) do
    ~H"""
    <.button
      link_type="live_redirect"
      to={~p"/account"}
      size="sm"
      color={if @primary, do: "primary", else: "gray"}
      variant={if @primary, do: "solid", else: "outline"}
      icon="hero-shield-check"
      label={gettext("Set up two factor")}
    />
    """
  end

  # The builder, pointed at the server the rule is for when there is one. A
  # role that cannot see servers gets the builder's own default instead.
  defp new_rule_path(params) do
    ~p"/rules/new?#{Enum.reject(params, fn {_key, value} -> is_nil(value) end)}"
  end

  defp stream_problem(:stopped),
    do:
      gettext(
        "The engine for this server stopped. It starts again on its own within a minute; if it does not, save the server again."
      )

  defp stream_problem(reason), do: reason

  defp hero_title(nil, _done), do: gettext("Almost there")
  defp hero_title(_focus, 0), do: gettext("Welcome! Start by connecting your server")
  defp hero_title(%{id: :stream, state: :blocked}, _done), do: gettext("The server needs a look")
  defp hero_title(%{id: :stream}, _done), do: gettext("Waiting for the game's events")
  defp hero_title(%{id: :modules}, _done), do: gettext("Pick what your server needs")
  defp hero_title(%{id: :rule}, _done), do: gettext("Now, your first rule")
  defp hero_title(%{id: :simulation}, _done), do: gettext("Your rule is watching in simulation")
  defp hero_title(%{id: :live}, _done), do: gettext("Ready to let it act")
  defp hero_title(_focus, _done), do: gettext("Keep going")

  defp state_label(%{state: :done}), do: gettext("Done")
  defp state_label(%{state: :waiting}), do: gettext("Waiting")
  defp state_label(%{state: :blocked}), do: gettext("Needs attention")
  defp state_label(%{state: :locked}), do: gettext("Locked")
  defp state_label(%{id: :two_factor}), do: gettext("Recommended")
  defp state_label(%{state: :current}), do: gettext("Next")
  defp state_label(_step), do: gettext("Available")

  defp step_title(:server), do: gettext("Connect a CRCON server")
  defp step_title(:stream), do: gettext("Receive the game's events")
  defp step_title(:modules), do: gettext("Install modules from the marketplace")
  defp step_title(:rule), do: gettext("Create your first rule")
  defp step_title(:simulation), do: gettext("See what it would have done")
  defp step_title(:live), do: gettext("Let it act for real")
  defp step_title(:two_factor), do: gettext("Protect your account")

  defp step_hint(%{id: :server}),
    do:
      gettext(
        "The connection is tested before saving, and the key is stored encrypted. Every other step builds on this one."
      )

  defp step_hint(%{id: :stream, state: :blocked}),
    do: gettext("The live log stream could not connect. This is what CRCON answered:")

  defp step_hint(%{id: :stream, state: :waiting, context: %{server: server}})
       when not is_nil(server),
       do:
         gettext(
           "Connecting to the live log stream of %{name}. Kills, chat and connections reach the engine once it is up - you can already create a rule meanwhile.",
           name: server.name
         )

  defp step_hint(%{id: :stream}),
    do:
      gettext("Once the live log stream connects, kills, chat and connections reach the engine.")

  defp step_hint(%{id: :modules}),
    do:
      gettext(
        "A new server starts with nothing installed. Each module adds its pages and its work; removing one later keeps its data."
      )

  defp step_hint(%{id: :rule, context: %{rules_installed?: false}}),
    do:
      gettext(
        "Rules are a module as well: install Conditional rules from the marketplace to write the first one."
      )

  defp step_hint(%{id: :rule}),
    do:
      gettext(
        "When something happens, if it matches, do this. Pick a recipe to start with everything filled in for your server."
      )

  defp step_hint(%{id: :simulation, state: :waiting, context: %{rule: rule}})
       when not is_nil(rule),
       do:
         gettext(
           "\"%{name}\" records what it would do without touching the game. Its first result shows up here as soon as it matches someone - or replay it on recent events right now.",
           name: rule.name
         )

  defp step_hint(%{id: :simulation}),
    do:
      gettext(
        "A rule in simulation records what it would have done, so you can read it before it acts."
      )

  defp step_hint(%{id: :live}),
    do:
      gettext(
        "Happy with what it recorded? Open the rule, turn simulation off, and it starts acting."
      )

  defp step_hint(%{id: :two_factor}),
    do: gettext("This tool can kick and ban. A second factor keeps that power with you.")

  # ── KPI tiles ──────────────────────────────────────────────────────────────

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :change, :integer, default: nil
  attr :change_unit, :string, default: "%"
  attr :lower_is_better, :boolean, default: false
  attr :hint, :string, default: nil
  attr :to, :string, default: nil

  defp kpi(assigns) do
    ~H"""
    <div class="overview-card flex flex-col gap-3">
      <p class="overview-card-title border-b border-base-300 pb-3">
        <.icon name={@icon} class="size-4" />{@label}
      </p>
      <div class="flex items-end justify-between gap-2">
        <p class="text-3xl font-semibold tracking-tight tabular-nums">{@value}</p>
        <.link
          :if={@to}
          navigate={@to}
          class="flex size-8 items-center justify-center rounded-field border border-base-300 text-muted transition-colors hover:border-primary/40 hover:text-primary"
          aria-label={gettext("Open %{name}", name: @label)}
        >
          <.icon name="hero-arrow-up-right" class="size-4" />
        </.link>
      </div>
      <p class="flex flex-wrap items-center gap-2 text-xs text-muted">
        <span
          :if={@change}
          class={[
            "rounded-pill px-2 py-0.5 font-medium",
            change_tone(@change, @lower_is_better)
          ]}
        >
          {change_label(@change, @change_unit)}
        </span>
        <span :if={is_nil(@change)} class="rounded-pill bg-base-200 px-2 py-0.5">
          {gettext("no earlier data")}
        </span>
        <span class="truncate">{@hint}</span>
      </p>
    </div>
    """
  end

  defp change_tone(0, _lower_is_better), do: "bg-base-200 text-subtle"

  defp change_tone(change, lower_is_better) do
    if change > 0 != lower_is_better,
      do: "bg-primary/10 text-primary",
      else: "bg-error/10 text-error"
  end

  defp change_label(change, unit) when change > 0,
    do: gettext("%{change} vs before", change: "+#{change}#{unit}")

  defp change_label(change, unit), do: gettext("%{change} vs before", change: "#{change}#{unit}")

  defp points(nil, _previous), do: nil
  defp points(_current, nil), do: nil
  defp points(current, previous), do: current - previous

  # ── Chart ──────────────────────────────────────────────────────────────────

  @chart_width 640
  @chart_height 220
  @chart_pad_left 36
  @chart_pad_bottom 26
  @chart_pad_top 10

  attr :daily, :list, required: true

  # Drawn on the server as a plain SVG: two smoothed lines over a light grid,
  # with the day under the cursor readable from each point's <title>.
  defp activity_chart(assigns) do
    max = assigns.daily |> Enum.map(& &1.fired) |> Enum.max(fn -> 0 end) |> nice_max()

    assigns =
      assign(assigns,
        max: max,
        width: @chart_width,
        height: @chart_height,
        left: @chart_pad_left,
        bottom: @chart_height - @chart_pad_bottom,
        ticks: Enum.map(0..3, &round(max * &1 / 3)),
        fired: points_for(assigns.daily, :fired, max),
        failed: points_for(assigns.daily, :failed, max),
        labels: x_labels(assigns.daily)
      )

    ~H"""
    <svg
      id="overview-chart"
      viewBox={"0 0 #{@width} #{@height}"}
      class="overview-chart"
      role="img"
      aria-label={gettext("Rules fired per day")}
    >
      <g :for={tick <- @ticks}>
        <line
          x1={@left}
          x2={@width}
          y1={y_for(tick, @max)}
          y2={y_for(tick, @max)}
          class="overview-chart-grid"
        />
        <text x={@left - 8} y={y_for(tick, @max) + 4} text-anchor="end" class="overview-chart-axis">
          {format_number(tick)}
        </text>
      </g>

      <path d={area_path(@fired, @bottom)} class="overview-chart-area" />
      <path d={smooth_path(@fired)} class="overview-chart-line" />
      <path d={smooth_path(@failed)} class="overview-chart-line overview-chart-line-failed" />

      <circle :for={{x, y, day} <- @fired} cx={x} cy={y} r="7" class="overview-chart-hit">
        <title>
          {Calendar.strftime(day.date, "%d/%m")} · {gettext("%{fired} fired, %{failed} failed",
            fired: day.fired,
            failed: day.failed
          )}
        </title>
      </circle>

      <text
        :for={{x, label} <- @labels}
        x={x}
        y={@height - 6}
        text-anchor="middle"
        class="overview-chart-axis"
      >
        {label}
      </text>
    </svg>
    """
  end

  defp nice_max(0), do: 4

  defp nice_max(value) do
    magnitude = :math.pow(10, floor(:math.log10(value)))

    step =
      Enum.find([1, 2, 2.5, 5, 10], fn factor -> factor * magnitude * 3 >= value end) * magnitude

    max(round(step * 3), 3)
  end

  defp x_for(index, count) do
    span = @chart_width - @chart_pad_left - 8
    @chart_pad_left + 4 + span * index / max(count - 1, 1)
  end

  defp y_for(value, max) do
    span = @chart_height - @chart_pad_bottom - @chart_pad_top
    Float.round(@chart_height - @chart_pad_bottom - span * value / max, 1)
  end

  defp points_for(daily, key, max) do
    count = length(daily)

    daily
    |> Enum.with_index()
    |> Enum.map(fn {day, index} ->
      {Float.round(x_for(index, count) * 1.0, 1), y_for(Map.fetch!(day, key), max), day}
    end)
  end

  # Catmull-Rom through the points, as cubic Béziers.
  defp smooth_path([]), do: ""

  defp smooth_path([{x, y, _day} | _rest] = points) do
    coords = Enum.map(points, fn {px, py, _day} -> {px, py} end)
    padded = [hd(coords)] ++ coords ++ [List.last(coords)]

    segments =
      padded
      |> Enum.chunk_every(4, 1, :discard)
      |> Enum.map(fn [{x0, y0}, {x1, y1}, {x2, y2}, {x3, y3}] ->
        # Control points are held between the two ends of the segment, so a
        # spike never swings the line below zero or above its own peak.
        c1 = {x1 + (x2 - x0) / 6, clamp(y1 + (y2 - y0) / 6, y1, y2)}
        c2 = {x2 - (x3 - x1) / 6, clamp(y2 - (y3 - y1) / 6, y1, y2)}
        "C#{pt(c1)} #{pt(c2)} #{pt({x2, y2})}"
      end)

    "M#{pt({x, y})} " <> Enum.join(segments, " ")
  end

  defp clamp(value, a, b), do: value |> max(min(a, b)) |> min(max(a, b))

  defp area_path([], _bottom), do: ""

  defp area_path(points, bottom) do
    {first_x, _y, _day} = hd(points)
    {last_x, _ly, _lday} = List.last(points)
    smooth_path(points) <> " L#{pt({last_x, bottom})} L#{pt({first_x, bottom})} Z"
  end

  defp pt({x, y}), do: "#{Float.round(x * 1.0, 1)},#{Float.round(y * 1.0, 1)}"

  # About six dates under the axis, whatever the period.
  defp x_labels(daily) do
    count = length(daily)
    every = max(div(count, 6), 1)

    daily
    |> Enum.with_index()
    |> Enum.filter(fn {_day, index} -> rem(index, every) == 0 end)
    |> Enum.map(fn {day, index} ->
      {Float.round(x_for(index, count) * 1.0, 1), Calendar.strftime(day.date, "%d/%m")}
    end)
  end

  attr :period, :integer, required: true

  defp quiet_period(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-2 py-12 text-center">
      <span class="flex size-10 items-center justify-center rounded-full bg-base-200 text-muted">
        <.icon name="hero-moon" class="size-5" />
      </span>
      <p class="font-medium">{gettext("No rule fired in the last %{count} days", count: @period)}</p>
      <p class="max-w-sm text-sm text-muted">
        {gettext(
          "Either nothing matched, or no rule is enabled yet. Try a recipe, or replay a rule against recent events from the builder."
        )}
      </p>
    </div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp subtitle(nil, _servers), do: gettext("Your servers, and what the rules are doing on them")

  defp subtitle(report, servers) do
    gettext("%{from} – %{to} · %{servers}",
      from: Calendar.strftime(report.since, "%d/%m/%Y"),
      to: Calendar.strftime(report.until, "%d/%m/%Y"),
      servers: ngettext("1 server", "%{count} servers", length(servers))
    )
  end

  defp format_number(nil), do: "–"

  defp format_number(number) when is_integer(number) and number >= 1000 do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(".")
    |> String.reverse()
  end

  defp format_number(number), do: to_string(number)

  defp percent(nil), do: "–"
  defp percent(value), do: "#{value}%"

  defp duration(nil), do: "–"
  defp duration(ms) when ms >= 1000, do: "#{Float.round(ms / 1000, 1)} s"
  defp duration(ms), do: "#{ms} ms"

  defp share(_count, 0), do: 0
  defp share(count, total), do: round(count * 100 / total)

  defp rule_success(%{fired: fired, simulated: simulated, failed: failed}) do
    case fired - simulated do
      0 -> "–"
      live -> "#{round((live - failed) * 100 / live)}%"
    end
  end

  # Red only when a rule fails often enough to need a look.
  defp success_tone(%{failed: 0}), do: nil

  defp success_tone(%{fired: fired, simulated: simulated, failed: failed}) do
    live = fired - simulated
    if live > 0 and failed * 10 > live, do: "text-error", else: "text-warning"
  end

  defp bar_tone(0), do: "bg-primary"
  defp bar_tone(1), do: "bg-primary/60"
  defp bar_tone(2), do: "bg-info"
  defp bar_tone(3), do: "bg-warning"
  defp bar_tone(_index), do: "bg-base-content/25"

  defp trigger_label(trigger) do
    Labels.trigger(String.to_existing_atom(trigger))
  rescue
    _unknown -> trigger
  end

  # The tone a finished execution reads in, shared with the history page.
  defp execution_tone(:executed), do: "success"
  defp execution_tone(:partial), do: "warning"
  defp execution_tone(:failed), do: "error"
  defp execution_tone(:simulated), do: "info"
  defp execution_tone(_status), do: "neutral"

  defp count_status(stream_status, servers, wanted) do
    Enum.count(servers, &(&1.enabled and stream_status[&1.id] == wanted))
  end

  defp count_enabled(servers), do: Enum.count(servers, & &1.enabled)

  defp stream_hint(stream_status, servers) do
    enabled = count_enabled(servers)
    connected = count_status(stream_status, servers, :connected)

    if connected == enabled do
      gettext("all enabled servers streaming")
    else
      ngettext("1 not connected", "%{count} not connected", enabled - connected)
    end
  end

  attr :status, :any, default: nil
  attr :enabled, :boolean, default: true

  defp stream_badge(assigns) do
    ~H"""
    <.tone_badge :if={not @enabled} tone="ghost">{gettext("Disabled")}</.tone_badge>
    <.tone_badge :if={@enabled} tone={stream_badge_tone(@status)}>
      <span :if={@status == :connected} class="size-1.5 rounded-full bg-current"></span> {Labels.stream_status(
        @status
      )}
    </.tone_badge>
    """
  end

  defp stream_badge_tone(:connected), do: "success"
  defp stream_badge_tone(:connecting), do: "warning"
  defp stream_badge_tone({:error, _reason}), do: "error"
  defp stream_badge_tone(_status), do: "ghost"

  defp rule_count(%{rules: count}),
    do: ngettext("%{count} active rule", "%{count} active rules", count, count: count)

  defp rule_count(_info), do: gettext("engine offline")
end
