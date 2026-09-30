defmodule HllConditionalActionsWeb.DashboardLive do
  @moduledoc """
  The Briefing: the organisation's front page. One question - *what needs
  me?* - answered in three rows:

    1. *How is it going?* - a greeting with the week in one sentence, and
       the tiles: rules running, players online, success rate, open
       attention items and tickets
    2. *Anything to decide?* - a rule that simulated long enough to go live,
       with what it would have done; and the fires per day, with the
       period's totals against the period before
    3. *What needs me, and are the servers alive?* - the top of the
       attention inbox, and one card per server with its match right now

  A new server - one with nothing installed yet - turns the page into its
  first steps (`HllConditionalActions.Onboarding`) until it is set up or the
  admin skips them for the session.

  The period lives in the URL (`?period=30`), so a view can be shared. The
  page refreshes itself every ten seconds, follows the streams live and
  reads each server's match from CRCON in the background
  (`HllConditionalActions.Briefing.LiveStatus`).
  """

  use HllConditionalActionsWeb, :live_view

  import HllConditionalActionsWeb.BriefingComponents

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Attention
  alias HllConditionalActions.Briefing
  alias HllConditionalActions.Briefing.LiveStatus
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Features
  alias HllConditionalActions.Onboarding
  alias HllConditionalActions.Reports
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Runtime
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.Nav

  @refresh_ms :timer.seconds(10)
  @default_period 30
  @metrics ~w(fired players failed duration)
  @attention_rows 4
  @weekdays ~w(monday tuesday wednesday thursday friday saturday sunday)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Servers.subscribe()
      # One subscription for every server's status, including the ones added
      # while this page is open.
      LogStream.subscribe_status()

      :timer.send_interval(@refresh_ms, :refresh)
    end

    {:ok,
     assign(socket,
       page_title: gettext("Briefing"),
       period: @default_period,
       metric: "fired",
       series: "all",
       skipped?: false,
       setup: nil,
       live: %{},
       live_loading?: false,
       picked: default_modules(),
       events_server: nil,
       events: %{count: 0, first_at: nil, recent: [], rate: 0},
       arrivals: []
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    {:noreply,
     socket
     |> assign(:period, parse_period(params["period"]))
     |> assign(:skipped?, socket.assigns.skipped? or params["onboarding"] == "skip")
     |> assign(:setup, params["setup"])
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("chart_metric", %{"metric" => metric}, socket) when metric in @metrics do
    {:noreply, assign(socket, :metric, metric)}
  end

  def handle_event("chart_series", %{"series" => series}, socket) do
    if series in Briefing.series() do
      {:noreply, socket |> assign(:series, series) |> load()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("skip_onboarding", _params, socket) do
    {:noreply, socket |> assign(:skipped?, true) |> load()}
  end

  def handle_event("pick_modules", params, socket) do
    {:noreply, assign(socket, :picked, parse_modules(params))}
  end

  def handle_event("install_modules", params, socket) do
    install(socket, parse_modules(params))
  end

  def handle_event("copy_modules", %{"from" => from}, socket) do
    case Enum.find(socket.assigns.servers, &(to_string(&1.id) == from)) do
      nil -> {:noreply, socket}
      source -> install(socket, Features.installed(source.id))
    end
  end

  def handle_event("grant_team", _params, socket) do
    %{current_user: user, onboarding_server: server} = socket.assigns

    if server && Accounts.can?(user, :manage_users) do
      team = Briefing.team_without(user, server)
      :ok = Briefing.grant_server(team, server)

      {:noreply,
       socket
       |> put_flash(:info, gettext("They can see %{server} now.", server: server.name))
       |> load()}
    else
      {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_info({:crcon_stream_status, server_id, status}, socket) do
    {:noreply,
     socket
     |> update(:stream_status, &Map.put(&1, server_id, status))
     |> load()}
  end

  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  def handle_info({event, _server}, socket)
      when event in [:server_created, :server_updated, :server_deleted] do
    {:noreply, load(socket)}
  end

  def handle_info({:crcon_event, %{server_id: server_id} = event}, socket) do
    if socket.assigns.events_server == server_id do
      {:noreply, record_event(socket, event)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_async(:live, {:ok, live}, socket) do
    {:noreply, assign(socket, live: live, live_loading?: false)}
  end

  def handle_async(:live, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :live_loading?, false)}
  end

  defp parse_period(value) do
    case Integer.parse(value || "") do
      {days, ""} -> if days in Reports.periods(), do: days, else: @default_period
      _other -> @default_period
    end
  end

  defp parse_modules(params) do
    params
    |> Map.get("modules", [])
    |> List.wrap()
    |> Enum.map(&Features.parse/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # ── Loading ────────────────────────────────────────────────────────────────

  # Every authenticated user lands here, so this page has no permission of its
  # own. That makes what it *loads* the only gate: a role without
  # `:view_servers` must not learn the names of the servers from the Briefing
  # when `/servers` would refuse to show them, and one without
  # `:view_executions` sees no activity numbers.
  defp load(socket) do
    user = socket.assigns.current_user
    servers = visible_servers(user)
    stream_status = Map.new(servers, &{&1.id, LogStream.status(&1.id)})
    rules = if Accounts.can?(user, :view_rules), do: Rules.list_rules_for(user), else: []

    socket =
      socket
      |> assign(servers: servers, stream_status: stream_status, rules: rules)
      |> assign_onboarding()

    if socket.assigns.onboarding?,
      do: load_onboarding(socket),
      else: load_briefing(socket)
  end

  # The first steps take the page while the install is new (no rule acts
  # for real yet), or while a server that just joined is being set up.
  # `?setup=<id>` opens them for one server on purpose, done or not.
  defp assign_onboarding(socket) do
    %{current_user: user, servers: servers, stream_status: stream_status, rules: rules} =
      socket.assigns

    chosen = chosen_server(socket)
    new_server = chosen || new_server(user, servers, rules)
    steps = Onboarding.steps(user, servers, stream_status, server: new_server)
    first_run? = new_server != nil or not Onboarding.established?(rules)
    wanted? = chosen != nil or (first_run? and Onboarding.show?(user, steps))

    assign(socket,
      steps: steps,
      onboarding?: wanted? and not socket.assigns.skipped?,
      onboarding_server: new_server || single(servers),
      new_server?: new_server != nil
    )
  end

  defp chosen_server(%{assigns: %{setup: nil}}), do: nil

  defp chosen_server(%{assigns: %{setup: id, servers: servers, current_user: user}}) do
    if Accounts.can?(user, :manage_servers),
      do: Enum.find(servers, &(to_string(&1.id) == id))
  end

  defp new_server(user, servers, rules) do
    if Accounts.can?(user, :manage_servers) do
      installed = Features.installed_by_server(Enum.map(servers, & &1.id))
      Onboarding.new_server(servers, installed, rules)
    end
  end

  defp single([server]), do: server
  defp single(_servers), do: nil

  defp load_briefing(socket) do
    %{current_user: user, servers: servers, rules: rules} = socket.assigns
    executions? = Accounts.can?(user, :view_executions)

    activity =
      if executions?,
        do: Briefing.activity(user, socket.assigns.period, socket.assigns.series)

    week =
      cond do
        not executions? -> nil
        socket.assigns.period == 7 and socket.assigns.series == "all" -> activity
        true -> Briefing.activity(user, 7)
      end

    socket
    |> assign(
      activity: activity,
      week: week,
      rule_summary: rule_summary(user, rules),
      tickets: ticket_counts(socket),
      last_events: Briefing.last_events(Enum.map(servers, & &1.id))
    )
    |> assign_attention()
    |> fetch_live(servers)
  end

  # The open items of the attention inbox; the first rule ready to leave
  # simulation is lifted out of the list into its own panel.
  defp assign_attention(socket) do
    user = socket.assigns.current_user

    if Accounts.can?(user, :view_executions) do
      %{open: open} = Attention.items(user, socket.assigns.servers, socket.assigns.stream_status)
      suggestion = Enum.find(open, &(&1.kind == :ready_to_go_live))
      needs_you = if suggestion, do: List.delete(open, suggestion), else: open
      shown = Enum.take(needs_you, @attention_rows)

      ticket_ids = for %{kind: :ticket_waiting, subject: %{ticket: t}} <- shown, do: t.id

      assign(socket,
        attention: open,
        suggestion: suggestion,
        digest: suggestion && Briefing.simulation_digest(user, suggestion.subject.rule),
        needs_you: shown,
        quotes: Briefing.ticket_quotes(ticket_ids)
      )
    else
      assign(socket, attention: nil, suggestion: nil, digest: nil, needs_you: [], quotes: %{})
    end
  end

  defp load_onboarding(socket) do
    %{current_user: user, onboarding_server: server, servers: servers, rules: rules} =
      socket.assigns

    installed = Features.installed_by_server(Enum.map(servers, & &1.id))

    others =
      for other <- servers, server == nil or other.id != server.id do
        %{
          server: other,
          modules: installed |> Map.get(other.id, MapSet.new()) |> MapSet.to_list()
        }
      end

    socket
    |> assign(
      others: others,
      team: if(server, do: Briefing.team_without(user, server), else: []),
      server_rules: if(server, do: Enum.filter(rules, &(&1.server_id == server.id)), else: [])
    )
    |> follow_events(server)
    |> fetch_live(List.wrap(server))
  end

  # The events card of the first steps follows one server's stream live,
  # starting from what is already on record.
  defp follow_events(socket, nil), do: socket

  defp follow_events(%{assigns: %{events_server: id}} = socket, %{id: id}), do: socket

  defp follow_events(socket, server) do
    if connected?(socket) do
      if old = socket.assigns.events_server, do: LogStream.unsubscribe(old)
      LogStream.subscribe(server.id)
    end

    stats = Briefing.event_stats(server.id)

    assign(socket,
      events_server: server.id,
      arrivals: [],
      events: %{
        count: stats.count,
        first_at: stats.first_at,
        rate: 0,
        recent: Briefing.recent_events(server.id, 3)
      }
    )
  end

  defp record_event(socket, event) do
    now = System.monotonic_time(:second)
    arrivals = [now | Enum.filter(socket.assigns.arrivals, &(now - &1 < 60))]
    at = Map.get(event, :occurred_at) || DateTime.utc_now()

    update(socket, :events, fn events ->
      %{
        events
        | count: events.count + 1,
          first_at: events.first_at || at,
          rate: length(arrivals),
          recent: Enum.take([%{at: at, event: event} | events.recent], 3)
      }
    end)
    |> assign(:arrivals, arrivals)
  end

  # Players, score and time left come from CRCON, off the LiveView process.
  defp fetch_live(socket, []), do: socket

  defp fetch_live(socket, servers) do
    if connected?(socket) and not socket.assigns.live_loading? do
      socket
      |> assign(:live_loading?, true)
      |> start_async(:live, fn -> LiveStatus.fetch(servers) end)
    else
      socket
    end
  end

  defp install(socket, features) do
    %{current_user: user, onboarding_server: server} = socket.assigns

    if server && Accounts.can?(user, :manage_servers) && MapSet.size(features) > 0 do
      Enum.each(features, &Features.install(server.id, &1, user.email))

      nav =
        case socket.assigns[:nav] do
          %{features: installed} = nav ->
            %{nav | features: Map.put(installed, server.id, Features.installed(server.id))}

          nav ->
            nav
        end

      {:noreply,
       socket
       |> assign(:nav, nav)
       |> put_flash(
         :info,
         ngettext(
           "1 module installed on %{server}.",
           "%{count} modules installed on %{server}.",
           MapSet.size(features),
           server: server.name
         )
       )
       |> load()}
    else
      {:noreply, socket}
    end
  end

  defp visible_servers(user) do
    if Accounts.can?(user, :view_servers), do: Servers.list_servers_for(user), else: []
  end

  defp rule_summary(user, rules) do
    if Accounts.can?(user, :view_rules) do
      enabled = Enum.filter(rules, & &1.enabled)
      %{enabled: length(enabled), simulating: Enum.count(enabled, & &1.simulation)}
    end
  end

  # Tickets only where the module is installed.
  defp ticket_counts(socket) do
    user = socket.assigns.current_user

    if Accounts.can?(user, :view_tickets) and Nav.feature?(socket.assigns[:nav], :tickets),
      do: Briefing.ticket_counts(user)
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(%{onboarding?: true} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("First steps")}
      eyebrow={
        if @new_server?,
          do: gettext("Briefing of a new server"),
          else: gettext("Briefing of a new install")
      }
    >
      <:actions>
        <.link
          id="onboarding-skip"
          patch={~p"/?onboarding=skip"}
          class="flex h-11 items-center rounded-full border border-base-300 bg-base-100 px-5 text-sm font-medium transition-colors hover:border-base-content/25 md:h-12"
        >
          {gettext("Skip for now")}
        </.link>
      </:actions>

      <.onboarding
        steps={@steps}
        server={@onboarding_server}
        others={@others}
        picked={@picked}
        events={@events}
        live={live_of(@live, @onboarding_server)}
        rules={@server_rules}
        team={@team}
        has_servers={@servers != []}
      />
    </Layouts.app>
    """
  end

  def render(assigns) do
    cards = server_cards(assigns)
    players = LiveStatus.players_online(assigns.live)

    tiles = kpi_tiles(assigns, players)

    assigns =
      assign(assigns,
        cards: cards,
        players: players,
        tiles: tiles,
        areas: areas(assigns, cards, tiles)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      greeting={header_greeting(@current_user, @servers)}
      greeting_eyebrow={header_date(@servers)}
    >
      <:actions>
        <.button
          :if={Accounts.can?(@current_user, :manage_rules) and @servers != []}
          link_type="live_redirect"
          to={~p"/rules/new"}
          size="sm"
          color="primary"
          icon="hero-plus"
          class="max-md:hidden"
          aria-label={gettext("New rule")}
        >
          <span class="hidden xl:inline">{gettext("New rule")}</span>
        </.button>
      </:actions>

      <%!-- "No servers yet" would be a lie to somebody whose role simply does
            not let them see the ones that exist. --%>
      <.empty_state
        :if={@servers == [] and Accounts.can?(@current_user, :view_servers)}
        icon="hero-server-stack"
        title={gettext("No servers yet")}
        description={
          gettext("An administrator has not connected a CRCON instance yet. Check back later.")
        }
      />

      <div
        :if={@servers != [] or not Accounts.can?(@current_user, :view_servers)}
        id="briefing"
        class="briefing-grid"
        style={@areas}
      >
        <div data-area="greet" class="hidden min-w-0 xl:block">
          <.greeting name={first_name(@current_user)}>
            <%= if @week do %>
              {ngettext(
                "Your rules acted once this week",
                "Your rules acted %{fires} times this week",
                @week.totals.fired,
                fires: format_number(@week.totals.fired)
              )}<span :if={is_integer(change(@week.totals.fired, @week.previous.fired))}>,</span>
              <.week_change change={change(@week.totals.fired, @week.previous.fired)} />
            <% else %>
              {gettext("Your servers, and what the rules are doing on them")}
            <% end %>
          </.greeting>
        </div>

        <div :if={@tiles != []} data-area="kpis" class="hidden min-w-0 md:block">
          <.kpi_row tiles={@tiles} />
        </div>

        <div :if={@cards != []} data-area="chips" class="min-w-0 md:hidden">
          <.server_chips cards={@cards} />
        </div>

        <div :if={@week} data-area="week" class="min-w-0 md:hidden">
          <.week_card
            week={@week}
            rules={@rule_summary && @rule_summary.enabled}
            players={@players && format_number(elem(@players, 0))}
            success={percent(@week.totals.success_rate)}
          />
        </div>

        <div :if={@activity && @suggestion} data-area="suggest" class="flex min-w-0">
          <.suggestion rule={@suggestion.subject.rule} digest={@digest} />
        </div>

        <div :if={@activity} data-area="chart" class="hidden min-w-0 md:flex">
          <.fires_panel
            activity={@activity}
            metric={@metric}
            series={@series}
            period={@period}
          />
        </div>

        <div :if={@attention} data-area="needs" class="flex min-w-0">
          <.briefing_panel
            id="briefing-attention"
            title={gettext("Needs you")}
            aria-label={gettext("Needs you")}
            class="flex-1"
          >
            <:action>
              <.panel_link id="briefing-open-inbox" navigate={~p"/inbox"}>
                {gettext("Open the inbox")}
              </.panel_link>
            </:action>

            <div :if={@needs_you != []} class="flex flex-col gap-0.5 md:gap-1 xl:-mx-0.5 xl:gap-1.5">
              <.attention_row
                :for={{item, index} <- Enum.with_index(@needs_you)}
                item={item}
                extra={%{last_events: @last_events, quotes: @quotes}}
                class={index >= 3 && "max-md:hidden xl:hidden"}
              />
            </div>

            <.needs_you_empty :if={@needs_you == []} feed_path={feed_path(@servers)} />
          </.briefing_panel>
        </div>

        <div :if={@cards != []} data-area="servers" class="hidden min-w-0 md:flex">
          <.briefing_panel
            id="briefing-servers"
            title={gettext("Servers now")}
            aria-label={gettext("Servers now")}
            class="flex-1"
          >
            <:action>
              <.panel_link id="briefing-all-servers" navigate={~p"/servers"}>
                {gettext("See them all")}
              </.panel_link>
            </:action>

            <div class="grid flex-1 grid-cols-3 gap-3">
              <.server_card :for={card <- Enum.take(@cards, 3)} card={card} />
            </div>
          </.briefing_panel>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Fires ──────────────────────────────────────────────────────────────────

  attr :activity, :map, required: true
  attr :metric, :string, required: true
  attr :series, :string, required: true
  attr :period, :integer, required: true

  defp fires_panel(assigns) do
    totals = assigns.activity.totals
    previous = assigns.activity.previous

    assigns =
      assign(assigns,
        totals: totals,
        changes: %{
          fired: change(totals.fired, previous.fired),
          players: change(totals.players, previous.players),
          failed: change(totals.failed, previous.failed)
        }
      )

    ~H"""
    <section
      id="overview-activity"
      aria-label={gettext("Rule fires")}
      class="flex min-w-0 flex-1 flex-col gap-2.5 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-5 shadow-[var(--shadow-card)] xl:min-h-[25rem] xl:gap-3.5 xl:px-[1.625rem] xl:py-[1.125rem]"
    >
      <header class="flex flex-wrap items-center gap-2">
        <h2 class="flex-1 font-display text-[1.25rem] font-semibold whitespace-nowrap xl:text-[1.375rem]">
          {gettext("Rule fires")}
        </h2>
        <div id="chart-series" role="group" aria-label={gettext("Which fires")} class="flex gap-2">
          <button
            :for={
              {key, label} <- [
                {"all", gettext("All")},
                {"live", gettext("Live")},
                {"simulated", gettext("Simulation")}
              ]
            }
            id={"chart-series-#{key}"}
            type="button"
            phx-click="chart_series"
            phx-value-series={key}
            aria-pressed={to_string(@series == key)}
            class={[
              "h-9 cursor-pointer rounded-full border px-3.5 text-[0.8125rem] transition-colors",
              if(@series == key,
                do:
                  "border-base-content bg-base-content font-semibold text-base-100 dark:border-primary/45 dark:bg-primary/10 dark:text-primary",
                else: "border-base-300 bg-white hover:border-base-content/25 dark:bg-secondary"
              )
            ]}
          >
            {label}
          </button>
        </div>

        <details id="overview-period" class="briefing-period relative">
          <summary
            aria-label={gettext("Period")}
            class="flex h-9 cursor-pointer list-none items-center gap-1.5 rounded-full border border-base-300 bg-white px-3.5 text-[0.8125rem] transition-colors hover:border-base-content/25 dark:bg-secondary"
          >
            <.icon name="hero-calendar" class="size-3.5" />
            {gettext("%{count} days", count: @period)}
          </summary>
          <nav class="absolute right-0 z-20 mt-2 flex min-w-32 flex-col rounded-2xl border border-base-300 bg-base-100 p-1.5 shadow-[var(--shadow-card-large)]">
            <.link
              :for={days <- Reports.periods()}
              id={"overview-period-#{days}"}
              patch={~p"/?period=#{days}"}
              aria-current={days == @period && "true"}
              class={[
                "rounded-xl px-3 py-2 text-[0.8125rem] transition-colors hover:bg-secondary",
                days == @period && "font-semibold text-primary"
              ]}
            >
              {gettext("%{count} days", count: days)}
            </.link>
          </nav>
        </details>
      </header>

      <div class="hidden grid-cols-4 gap-2.5 xl:grid">
        <.metric_tile
          id="chart-metric-fired"
          metric="fired"
          selected={@metric}
          label={gettext("Fires")}
          value={format_number(@totals.fired)}
          change={@changes.fired}
        />
        <.metric_tile
          id="chart-metric-players"
          metric="players"
          selected={@metric}
          label={gettext("Reached")}
          value={format_number(@totals.players)}
          change={@changes.players}
        />
        <.metric_tile
          id="chart-metric-failed"
          metric="failed"
          selected={@metric}
          label={gettext("Failures")}
          value={format_number(@totals.failed)}
          change={@changes.failed}
          lower_is_better
        />
        <.metric_tile
          id="chart-metric-duration"
          metric="duration"
          selected={@metric}
          label={gettext("Average time")}
          value={duration(@totals.duration_ms)}
        />
      </div>

      <p class="flex flex-wrap items-baseline gap-x-[1.125rem] gap-y-1 text-[0.8125rem] text-subtle xl:hidden">
        <span>
          <strong class="font-display text-lg font-semibold text-base-content">
            {format_number(@totals.fired)}
          </strong>
          {ngettext("fire", "fires", @totals.fired)}
          <.change_note change={@changes.fired} />
        </span>
        <span>
          <strong class="font-display text-lg font-semibold text-base-content">
            {format_number(@totals.players)}
          </strong>
          {ngettext("player", "players", @totals.players)}
        </span>
        <span>
          <strong class="font-display text-lg font-semibold text-base-content">
            {format_number(@totals.failed)}
          </strong>
          {ngettext("failure", "failures", @totals.failed)}
          <.change_note change={@changes.failed} lower_is_better />
        </span>
        <span>
          <strong class="font-display text-lg font-semibold text-base-content">
            {duration(@totals.duration_ms)}
          </strong>
          {gettext("on average")}
        </span>
      </p>

      <.fires_chart
        :if={@totals.fired > 0}
        id="overview-chart"
        points={chart_points(@activity.daily, @metric, @series)}
        tone={chart_tone(@metric, @series)}
        label={chart_label(@metric, @series, @period)}
      />
      <.quiet_period :if={@totals.fired == 0} period={@period} />
    </section>
    """
  end

  defp chart_points(daily, metric, series) do
    Enum.map(daily, fn day ->
      {value, tip, extra} = point(day, metric, series)
      %{date: day.date, value: value, tip: tip, extra: extra}
    end)
  end

  defp point(day, "players", _series),
    do: {day.players, ngettext("1 player", "%{count} players", day.players), nil}

  defp point(day, "failed", _series),
    do: {day.failed, ngettext("1 failure", "%{count} failures", day.failed), nil}

  defp point(day, "duration", _series),
    do: {day.duration_ms || 0, duration(day.duration_ms), nil}

  defp point(day, _fired, "simulated"),
    do: {day.fired, ngettext("1 fire", "%{count} fires", day.fired), nil}

  defp point(day, _fired, _series),
    do:
      {day.fired, ngettext("1 fire", "%{count} fires", day.fired),
       ngettext("1 failure", "%{count} failures", day.failed)}

  defp chart_tone("failed", _series), do: "error"
  defp chart_tone(_metric, "simulated"), do: "accent"
  defp chart_tone(_metric, _series), do: "primary"

  defp chart_label("failed", _series, period),
    do: gettext("Failed runs per day, last %{count} days", count: period)

  defp chart_label("players", _series, period),
    do: gettext("Players reached per day, last %{count} days", count: period)

  defp chart_label("duration", _series, period),
    do: gettext("Average run time per day, last %{count} days", count: period)

  defp chart_label(_fired, "simulated", period),
    do: gettext("Simulated fires per day, last %{count} days", count: period)

  defp chart_label(_fired, "live", period),
    do: gettext("Live fires per day, last %{count} days", count: period)

  defp chart_label(_fired, _all, period),
    do: gettext("Rules fired per day, last %{count} days", count: period)

  # ── Tiles ──────────────────────────────────────────────────────────────────

  # The summary row, from what this page already loads: each tile only for a
  # role that may see what it counts.
  defp kpi_tiles(assigns, players) do
    [
      rules_tile(assigns.rule_summary),
      players_tile(assigns.servers, assigns.live, players),
      success_tile(assigns.week),
      attention_tile(assigns.attention),
      tickets_tile(assigns.tickets)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp rules_tile(nil), do: nil

  defp rules_tile(summary) do
    %{
      id: "rules",
      label: gettext("Active rules"),
      icon: "hero-bolt",
      value: format_number(summary.enabled),
      hint: ngettext("%{count} in simulation", "%{count} in simulation", summary.simulating),
      tone: nil,
      to: ~p"/rules"
    }
  end

  defp players_tile([], _live, _players), do: nil

  defp players_tile(_servers, live, players) do
    {value, hint} =
      case players do
        {count, servers} ->
          {format_number(count), ngettext("on 1 server", "on %{count} servers", servers)}

        nil when live == %{} ->
          {"–", gettext("reading the servers…")}

        nil ->
          {"–", gettext("no server answering")}
      end

    %{
      id: "players",
      label: gettext("Playing now"),
      icon: "hero-user",
      value: value,
      hint: hint,
      tone: nil,
      to: ~p"/players"
    }
  end

  defp success_tile(nil), do: nil

  defp success_tile(week) do
    rate = week.totals.success_rate

    points =
      rate && week.previous.success_rate && Float.round(rate - week.previous.success_rate, 1)

    {hint, hint_tone} =
      cond do
        is_number(points) and points != 0 ->
          {gettext("%{arrow} %{points} pt this week",
             arrow: if(points > 0, do: "↑", else: "↓"),
             points: format_decimal(abs(points))
           ), if(points > 0, do: "primary", else: "error")}

        is_number(points) ->
          {gettext("same as last week"), nil}

        true ->
          {ngettext("1 failed this week", "%{count} failed this week", week.totals.failed), nil}
      end

    %{
      id: "success",
      label: gettext("Success"),
      icon: "hero-check",
      value: percent(rate),
      hint: hint,
      hint_tone: hint_tone,
      tone: nil,
      to: ~p"/executions"
    }
  end

  defp attention_tile(nil), do: nil

  defp attention_tile(open) do
    urgent = Enum.count(open, &(&1.severity == :error))

    %{
      id: "attention",
      label: gettext("Attention"),
      icon: "hero-exclamation-triangle",
      value: format_number(length(open)),
      hint: ngettext("1 urgent", "%{count} urgent", urgent),
      tone: if(open != [], do: "warning"),
      to: ~p"/inbox"
    }
  end

  defp tickets_tile(nil), do: nil

  defp tickets_tile(%{active: active, unassigned: unassigned}) do
    %{
      id: "tickets",
      label: gettext("Tickets"),
      icon: "hero-chat-bubble-left",
      value: format_number(active),
      hint: ngettext("1 unassigned", "%{count} unassigned", unassigned),
      tone: if(active > 0, do: "engine"),
      to: ~p"/tickets"
    }
  end

  # ── Servers now ────────────────────────────────────────────────────────────

  defp server_cards(assigns) do
    Enum.map(assigns.servers, fn server ->
      status = assigns.stream_status[server.id]
      live = assigns.live[server.id]
      seeding = Briefing.seeding_threshold(assigns.rules, server.id)

      state =
        cond do
          not server.enabled -> :disabled
          stream_problem?(status) -> :no_stream
          is_nil(live) -> :loading
          live == :error -> :unreachable
          seeding && live.players <= seeding -> :seeding
          true -> :match
        end

      %{
        server: server,
        status: status,
        state: state,
        live: if(is_map(live), do: live),
        seeding: seeding,
        last_event: assigns.last_events[server.id]
      }
    end)
  end

  # The same rule as the attention inbox: an error, or no stream at all on
  # an enabled server while the engine runs.
  defp stream_problem?({:error, _reason}), do: true
  defp stream_problem?(:disconnected), do: Runtime.enabled?()
  defp stream_problem?(_status), do: false

  defp live_of(_live, nil), do: nil

  defp live_of(live, server) do
    case live[server.id] do
      %{} = status -> status
      _missing -> nil
    end
  end

  defp feed_path([server | _rest]), do: ~p"/servers/#{server}/feed"
  defp feed_path(_servers), do: nil

  # ── Layout ─────────────────────────────────────────────────────────────────

  # The grid's areas for the phone, the tablet and the desktop, so a block
  # the viewer may not see leaves no hole: its neighbour takes the row.
  defp areas(assigns, cards, tiles) do
    has = %{
      kpis: tiles != [],
      chips: cards != [],
      week: assigns.week != nil,
      suggest: assigns.activity != nil and assigns.suggestion != nil,
      chart: assigns.activity != nil,
      needs: assigns.attention != nil,
      servers: cards != []
    }

    # Below the desktop the greeting is the header's (`Layouts.app`'s `greeting`).
    phone = for(area <- [:chips, :week, :suggest, :needs], has[area], do: [to_string(area)])

    tablet =
      if(has.kpis, do: [["kpis", "kpis"]], else: []) ++
        pair(has, :suggest, :needs) ++
        if(has.chart, do: [["chart", "chart"]], else: []) ++
        if(has.servers, do: [["servers", "servers"]], else: [])

    desktop =
      [if(has.kpis, do: ["greet", "kpis"], else: ["greet", "greet"])] ++
        pair(has, :suggest, :chart) ++ pair(has, :needs, :servers)

    "--areas-sm: #{template(phone)}; --areas-md: #{template(tablet)}; --areas-xl: #{template(desktop)}"
  end

  defp pair(has, left, right) do
    case {has[left], has[right]} do
      {true, true} -> [[to_string(left), to_string(right)]]
      {true, false} -> [[to_string(left), to_string(left)]]
      {false, true} -> [[to_string(right), to_string(right)]]
      {false, false} -> []
    end
  end

  defp template(rows), do: Enum.map_join(rows, " ", &~s("#{Enum.join(&1, " ")}"))

  # ── Helpers ────────────────────────────────────────────────────────────────

  # The header's greeting on phones and tablets. The server does not know the
  # viewer's clock, so it reads the time where the servers are (the first
  # one's time zone); the desktop greeting corrects itself in the browser.
  defp header_greeting(user, servers) do
    name = first_name(user)

    case local_now(servers).hour do
      hour when hour >= 5 and hour < 12 -> gettext("Good morning, %{name}", name: name)
      hour when hour >= 12 and hour < 18 -> gettext("Good afternoon, %{name}", name: name)
      _night -> gettext("Good evening, %{name}", name: name)
    end
  end

  defp header_date(servers) do
    now = local_now(servers)

    gettext("%{weekday}, %{month} %{day}",
      weekday: Labels.day_of_week(Enum.at(@weekdays, Date.day_of_week(now) - 1)),
      month: month_name(now.month),
      day: now.day
    )
  end

  defp local_now(servers) do
    zone =
      case servers do
        [%{timezone: zone} | _rest] when is_binary(zone) -> zone
        _none -> "Etc/UTC"
      end

    case DateTime.now(zone) do
      {:ok, now} -> now
      _error -> DateTime.utc_now()
    end
  end

  defp month_name(1), do: gettext("january")
  defp month_name(2), do: gettext("february")
  defp month_name(3), do: gettext("march")
  defp month_name(4), do: gettext("april")
  defp month_name(5), do: gettext("may")
  defp month_name(6), do: gettext("june")
  defp month_name(7), do: gettext("july")
  defp month_name(8), do: gettext("august")
  defp month_name(9), do: gettext("september")
  defp month_name(10), do: gettext("october")
  defp month_name(11), do: gettext("november")
  defp month_name(12), do: gettext("december")

  defp first_name(user) do
    (Map.get(user, :name) || Map.get(user, :username) || "")
    |> String.split()
    |> List.first("")
  end

  defp percent(nil), do: "–"
  defp percent(value), do: "#{format_decimal(value)}%"

  defp duration(nil), do: "–"
  defp duration(ms) when ms >= 1000, do: "#{format_decimal(Float.round(ms / 1000, 1))} s"
  defp duration(ms), do: "#{ms} ms"

  defp change(current, previous), do: Reports.change(current, previous)
end
