defmodule HllConditionalActionsWeb.ServerLive.Show do
  @moduledoc """
  A server's home: everything about it on one screen, most urgent first.

  It is laid out for the question an admin opens it with - *is my server
  fine, and what is going on?* - and reads top to bottom:

    1. **The match, live** - map, score with the five sectors drawn as a bar,
       time left, both teams' head count and the stream's health.
    2. **Who is playing well** - the top three of the match's key categories
       and the best squad of each type.
    3. **What the automation did** - rules running, what fired, what needs
       attention.
    4. **What already happened** - the last matches and the running season.

  Every block is a summary that opens its full page (leaderboard, matches,
  rules, history, attention, seasons): nothing is hidden behind tabs, and
  nothing is shown twice.

  The CRCON calls - the live snapshot and the match history - run off the
  LiveView process and refresh on timers, so a slow server shows skeletons,
  never a frozen page.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_servers}}

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Attention
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Engine
  alias HllConditionalActions.Engine.Snapshot
  alias HllConditionalActions.Leaderboards
  alias HllConditionalActions.Matches
  alias HllConditionalActions.Progression
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.MapArt

  @live_ms :timer.seconds(15)
  @history_ms :timer.minutes(2)

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    server = Servers.get_server!(id)

    if Accounts.can_access_server?(socket.assigns.current_user, server) do
      if connected?(socket) do
        LogStream.subscribe(server.id)
        Engine.subscribe(server.id)
        :timer.send_interval(@live_ms, :refresh_live)
        :timer.send_interval(@history_ms, :refresh_history)
      end

      {:ok,
       socket
       |> assign(:server, server)
       |> assign(:page_title, server.name)
       |> assign(:stream_status, LogStream.status(server.id))
       |> assign(:snapshot, nil)
       |> assign(:live_error?, false)
       |> assign(:matches, nil)
       |> load()
       |> fetch_live()
       |> fetch_history()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to that page."))
       |> push_navigate(to: ~p"/servers")}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:crcon_stream_status, _server_id, status}, socket) do
    {:noreply, socket |> assign(:stream_status, status) |> load()}
  end

  def handle_info({:rule_fired, _execution}, socket), do: {:noreply, load(socket)}
  def handle_info(:refresh_live, socket), do: {:noreply, socket |> load() |> fetch_live()}
  def handle_info(:refresh_history, socket), do: {:noreply, fetch_history(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_async(:live, {:ok, %Snapshot{stale?: false} = snapshot}, socket) do
    {:noreply, assign(socket, snapshot: snapshot, live_error?: false)}
  end

  # A failed read keeps the last good one on screen, if there is one.
  def handle_async(:live, _failed, socket) do
    {:noreply, assign(socket, :live_error?, is_nil(socket.assigns.snapshot))}
  end

  def handle_async(:history, {:ok, {:ok, %{matches: matches}}}, socket),
    do: {:noreply, assign(socket, :matches, matches)}

  def handle_async(:history, _failed, socket), do: {:noreply, assign(socket, :matches, [])}

  defp fetch_live(socket) do
    server = socket.assigns.server
    start_async(socket, :live, fn -> Snapshot.refresh(server) end)
  end

  defp fetch_history(socket) do
    server = socket.assigns.server

    if Accounts.can?(socket.assigns.current_user, :view_stats),
      do: start_async(socket, :history, fn -> Matches.list(server, limit: 5) end),
      else: assign(socket, :matches, [])
  end

  defp load(socket) do
    %{server: server, current_user: user, stream_status: status} = socket.assigns
    rules = Rules.list_rules_applying_to(server)

    socket
    |> assign(:rules, rules)
    |> assign(:executions, Rules.list_executions(server_id: server.id, limit: 6))
    |> assign(:stats, Rules.execution_stats(server_id: server.id))
    |> assign(:attention, Attention.items(user, [server], %{server.id => status}).open)
    |> assign(:season, Progression.active_season(server.id))
    |> then(fn socket ->
      season = socket.assigns.season
      assign(socket, :season_top, season && Progression.standings(season, limit: 3))
    end)
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assign(assigns,
        gamestate: assigns.snapshot && assigns.snapshot.gamestate,
        roster: assigns.snapshot && assigns.snapshot.players,
        base: "/servers/#{assigns.server.id}"
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@server.name}
      page_subtitle={Labels.game(@server.game) <> " · " <> @server.base_url}
    >
      <:actions>
        <.button
          :if={Accounts.can?(@current_user, :manage_rules)}
          link_type="live_redirect"
          to={~p"/rules/new?#{[server_id: @server.id]}"}
          size="sm"
          color="primary"
          icon="hero-plus"
        >
          <span class="hidden sm:inline">{gettext("New rule")}</span>
        </.button>
      </:actions>

      <%!-- 1. The match, live ─────────────────────────────────────────── --%>
      <.live_hero
        server={@server}
        gamestate={@gamestate}
        roster={@roster}
        stream_status={@stream_status}
        loading?={is_nil(@snapshot) and not @live_error?}
        error?={@live_error?}
      />

      <%!-- 2. Who is playing well ─────────────────────────────────────── --%>
      <section class="grid gap-4 xl:grid-cols-3" aria-labelledby="cockpit-top-title">
        <div class="overview-card xl:col-span-2">
          <.block_head
            id="cockpit-top-title"
            icon="hero-trophy"
            title={gettext("This match's best")}
            to={@base <> "/leaderboard"}
            link={gettext("Full leaderboard")}
          />
          <div :if={is_nil(@roster)} class="grid gap-3 sm:grid-cols-3">
            <.skeleton_block :for={_ <- 1..3} class="h-36 rounded-box" />
          </div>
          <p :if={@roster == %{}} class="py-8 text-center text-sm text-muted">
            {gettext("Nobody is playing right now.")}
          </p>
          <div :if={@roster not in [nil, %{}]} class="grid gap-3 sm:grid-cols-3">
            <.rank_board
              :for={category <- [:kills, :teamplay, :offdef]}
              id={"cockpit-board-#{category}"}
              title={Labels.leaderboard_category(category)}
              rows={
                for row <- Leaderboards.top_players(@roster, category, 3),
                    do: %{name: row.name, team: row.team, value: format(row.value), note: nil}
              }
            />
          </div>
        </div>

        <div class="overview-card">
          <.block_head
            icon="hero-user-group"
            title={gettext("Best squads")}
            to={@base <> "/leaderboard"}
            link={gettext("See all")}
          />
          <div :if={is_nil(@roster)} class="space-y-2">
            <.skeleton_block :for={_ <- 1..4} class="h-12 rounded-field" />
          </div>
          <ul :if={@roster} class="space-y-2" id="cockpit-squads">
            <li
              :for={{type, squad} <- best_squads(@roster)}
              class="flex items-center gap-3 rounded-field bg-base-200/60 px-3 py-2"
            >
              <span class="flex size-8 shrink-0 items-center justify-center rounded-field bg-base-100 text-subtle">
                <.icon name={squad_icon(type)} class="size-4" />
              </span>
              <span class="min-w-0 flex-1">
                <span class="block text-xs text-muted">{Labels.squad_type(type)}</span>
                <span class="block truncate text-sm font-medium">
                  {if squad, do: String.capitalize(squad.name), else: "–"}
                  <span
                    :if={squad}
                    class={["ml-1 inline-block size-1.5 rounded-full", team_dot(squad.team)]}
                  ></span>
                </span>
              </span>
              <span :if={squad} class="font-mono text-xs tabular-nums">{squad.score}</span>
            </li>
          </ul>
        </div>
      </section>

      <%!-- 3. What the automation did ─────────────────────────────────── --%>
      <section class="grid gap-4 lg:grid-cols-3" aria-label={gettext("Automation")}>
        <div class="overview-card">
          <.block_head
            icon="hero-bolt"
            title={gettext("Rules")}
            to={@base <> "/rules"}
            link={gettext("Manage")}
          />
          <div class="grid grid-cols-3 gap-2 text-center">
            <.mini_stat
              value={Enum.count(@rules, &(&1.enabled and not &1.simulation))}
              label={gettext("Live")}
              tone="success"
            />
            <.mini_stat
              value={Enum.count(@rules, &(&1.enabled and &1.simulation))}
              label={gettext("Simulating")}
              tone="warning"
            />
            <.mini_stat value={@stats.last_24h} label={gettext("Fired 24h")} tone="primary" />
          </div>
          <ul class="mt-3 divide-y divide-base-300">
            <li :for={rule <- Enum.take(@rules, 4)} class="flex items-center gap-2 py-2">
              <span class="flex size-7 shrink-0 items-center justify-center rounded-selector bg-primary/10 text-primary">
                <.icon name={Icons.trigger(rule.trigger_event)} class="size-3.5" />
              </span>
              <.link
                navigate={~p"/rules/#{rule.id}"}
                class="min-w-0 flex-1 truncate text-sm hover:underline"
              >
                {rule.name}
              </.link>
              <.rule_state rule={rule} />
            </li>
          </ul>
          <p :if={@rules == []} class="py-3 text-center text-sm text-muted">
            {gettext("No rule runs here yet.")}
          </p>
        </div>

        <div class="overview-card">
          <.block_head
            icon="hero-clock"
            title={gettext("Latest activity")}
            to={@base <> "/history"}
            link={gettext("History")}
          />
          <p :if={@executions == []} class="py-8 text-center text-sm text-muted">
            {gettext("No rule fired here yet.")}
          </p>
          <ol :if={@executions != []} class="cockpit-timeline">
            <li :for={execution <- @executions} class="cockpit-timeline-item">
              <.status_dot
                tone={execution_tone(execution.status)}
                label={Labels.execution_status(execution.status)}
              />
              <div class="min-w-0 flex-1">
                <p class="truncate text-sm font-medium leading-tight">{execution.rule.name}</p>
                <p class="truncate text-xs text-muted">
                  {execution.player_name || gettext("server wide")}
                </p>
              </div>
              <.local_time
                id={"cockpit-execution-#{execution.id}"}
                at={execution.executed_at}
                class="shrink-0 text-xs text-muted"
              />
            </li>
          </ol>
        </div>

        <div class="overview-card">
          <.block_head
            icon="hero-bell-alert"
            title={gettext("Attention")}
            to={@base <> "/attention"}
            link={gettext("Open")}
          />
          <div :if={@attention == []} class="flex flex-col items-center gap-2 py-6 text-center">
            <span class="flex size-10 items-center justify-center rounded-full bg-success/15 text-success">
              <.icon name="hero-check" class="size-5" />
            </span>
            <p class="text-sm font-medium">{gettext("All clear")}</p>
            <p class="text-xs text-muted">{gettext("Nothing on this server needs you.")}</p>
          </div>
          <ul :if={@attention != []} class="space-y-2" id="cockpit-attention">
            <li
              :for={item <- Enum.take(@attention, 4)}
              class="attention-item !p-2.5"
              data-severity={item.severity}
            >
              <p class="min-w-0 flex-1 text-sm">{attention_title(item)}</p>
            </li>
            <li :if={length(@attention) > 4} class="text-xs text-muted">
              {ngettext("and 1 more", "and %{count} more", length(@attention) - 4)}
            </li>
          </ul>
        </div>
      </section>

      <%!-- 4. What already happened ───────────────────────────────────── --%>
      <section class="grid gap-4 xl:grid-cols-3" aria-label={gettext("History")}>
        <div :if={Accounts.can?(@current_user, :view_stats)} class="overview-card xl:col-span-2">
          <.block_head
            icon="hero-flag"
            title={gettext("Latest matches")}
            to={@base <> "/matches"}
            link={gettext("All matches")}
          />
          <div :if={is_nil(@matches)} class="space-y-2">
            <.skeleton_block :for={_ <- 1..4} class="h-12 rounded-field" />
          </div>
          <p :if={@matches == []} class="py-6 text-center text-sm text-muted">
            {gettext("No match recorded yet.")}
          </p>
          <ul :if={@matches not in [nil, []]} class="divide-y divide-base-300" id="cockpit-matches">
            <li :for={match <- @matches}>
              <.link
                navigate={~p"/servers/#{@server}/matches/#{match.id}"}
                class="flex items-center gap-3 py-2.5 transition-colors hover:text-primary"
              >
                <span class={["h-8 w-1 shrink-0 rounded-pill", winner_bar(match.winner)]}></span>
                <span class="min-w-0 flex-1">
                  <span class="block truncate text-sm font-medium">{match.map}</span>
                  <span class="block truncate text-xs text-muted">
                    {time_ago(match.ended_at)} · {duration(match.duration_seconds)}
                  </span>
                </span>
                <span class="rounded-field bg-base-200 px-2 py-0.5 font-mono text-xs font-semibold tabular-nums">
                  {match.allied || "–"} : {match.axis || "–"}
                </span>
              </.link>
            </li>
          </ul>
        </div>

        <div :if={Accounts.can?(@current_user, :view_progression)} class="overview-card">
          <.block_head
            icon="hero-calendar-days"
            title={gettext("Season")}
            to={@base <> "/seasons"}
            link={gettext("Seasons")}
          />
          <%= if @season do %>
            <p class="font-medium">{@season.name}</p>
            <p class="text-xs text-muted">
              {Labels.season_measure(@season)} · {HllConditionalActionsWeb.SeasonLive.Index.days_left(
                @season,
                DateTime.utc_now()
              )}
            </p>
            <div class="mt-2 h-1.5 overflow-hidden rounded-pill bg-base-200">
              <div
                class="h-full rounded-pill bg-primary"
                style={"width: #{HllConditionalActionsWeb.SeasonLive.Index.elapsed(@season, DateTime.utc_now())}%"}
              >
              </div>
            </div>
            <ol class="mt-3 space-y-1.5">
              <li
                :for={{score, rank} <- Enum.with_index(@season_top, 1)}
                class="flex items-center gap-2 text-sm"
              >
                <span class={["leaderboard-medal", "leaderboard-medal-#{rank}"]}>{rank}</span>
                <span class="min-w-0 flex-1 truncate">{score.player_name}</span>
                <span class="font-mono text-xs tabular-nums">{score.score}</span>
              </li>
              <li :if={@season_top == []} class="text-xs text-muted">
                {gettext("Nobody has scored yet: the first match to end starts it.")}
              </li>
            </ol>
          <% else %>
            <div class="flex flex-col items-center gap-2 py-4 text-center">
              <p class="text-sm text-subtle">
                {gettext("No season running. Reward the best players of the next few weeks.")}
              </p>
              <.button
                :if={Accounts.can?(@current_user, :manage_progression)}
                link_type="live_redirect"
                to={~p"/seasons/new"}
                size="sm"
                variant="outline"
                color="gray"
                icon="hero-plus"
                label={gettext("Start a season")}
              />
            </div>
          <% end %>
        </div>
      </section>

      <%!-- The server itself, last: rarely needed, always one click away. --%>
      <section class="overview-card" aria-label={gettext("Server details")}>
        <.block_head
          icon="hero-server-stack"
          title={gettext("Server details")}
          to={if Accounts.can?(@current_user, :manage_servers), do: ~p"/servers/#{@server}/edit"}
          link={gettext("Edit")}
        />
        <dl class="grid gap-x-6 gap-y-3 text-sm sm:grid-cols-2 xl:grid-cols-4">
          <div>
            <dt class="text-xs text-muted">{gettext("Address")}</dt>
            <dd class="truncate">{@server.base_url}</dd>
          </div>
          <div>
            <dt class="text-xs text-muted">{gettext("Game")}</dt>
            <dd>{Labels.game(@server.game)}</dd>
          </div>
          <div>
            <dt class="text-xs text-muted">{gettext("Time zone")}</dt>
            <dd>{@server.timezone || "UTC"}</dd>
          </div>
          <div>
            <dt class="text-xs text-muted">{gettext("Log stream")}</dt>
            <dd class="flex items-center gap-1.5">
              <.status_dot
                tone={stream_tone(@stream_status)}
                label={Labels.stream_status(@stream_status)}
              />
              {Labels.stream_status(@stream_status)}
            </dd>
          </div>
        </dl>
        <p
          :if={@server.notes not in [nil, ""]}
          class="mt-3 border-t border-base-300 pt-3 text-sm text-subtle"
        >
          {@server.notes}
        </p>
      </section>
    </Layouts.app>
    """
  end

  # ── The live hero ──────────────────────────────────────────────────────────

  attr :server, :map, required: true
  attr :gamestate, :map, default: nil
  attr :roster, :map, default: nil
  attr :stream_status, :any, default: nil
  attr :loading?, :boolean, default: false
  attr :error?, :boolean, default: false

  # The match as a scoreboard: the map as the backdrop, the score in the
  # middle with the five sectors drawn under it, each team's head count on
  # its side. Allies on the left, the way the game draws them.
  defp live_hero(assigns) do
    gs = assigns.gamestate || %{}

    assigns =
      assign(assigns,
        map: hero_map(gs),
        mode: gs["game_mode"],
        allied: gs["allied_score"],
        axis: gs["axis_score"],
        allied_players: gs["num_allied_players"] || 0,
        axis_players: gs["num_axis_players"] || 0,
        time_left: gs["raw_time_remaining"],
        art: hero_art(gs, assigns.server)
      )

    ~H"""
    <section id="cockpit-live" class="cockpit-hero" style={"--hero-art: url('#{@art}')"}>
      <div class="cockpit-hero-scrim"></div>

      <div class="relative flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <p class="flex items-center gap-2 text-xs font-medium tracking-wide text-white/70 uppercase">
            <span class={["size-2 rounded-full", live_dot(@stream_status)]}></span>
            {gettext("Live match")} · {Labels.stream_status(@stream_status)}
          </p>
          <h2 class="mt-1 truncate text-3xl font-semibold tracking-tight text-white sm:text-4xl">
            <%= cond do %>
              <% @loading? -> %>
                <span class="inline-block h-9 w-56 animate-pulse rounded-field bg-white/15"></span>
              <% @error? -> %>
                {gettext("CRCON is not answering")}
              <% true -> %>
                {@map || gettext("Unknown map")}
            <% end %>
          </h2>
          <p :if={not @loading? and not @error?} class="mt-1 text-sm text-white/75">
            {mode_label(@mode)}
            <span :if={@time_left}>· {gettext("%{time} left", time: @time_left)}</span>
          </p>
        </div>

        <span class="rounded-pill bg-white/10 px-3 py-1 text-xs text-white/85 backdrop-blur">
          {ngettext("1 player", "%{count} players", @allied_players + @axis_players)}
        </span>
      </div>

      <div
        :if={not @loading? and not @error?}
        class="relative mt-6 grid items-end gap-4 sm:grid-cols-[1fr_auto_1fr]"
      >
        <div class="text-white">
          <p class="text-xs tracking-wide text-white/70 uppercase">{gettext("Allies")}</p>
          <p class="text-2xl font-semibold tabular-nums">
            {ngettext("1 player", "%{count} players", @allied_players)}
          </p>
        </div>

        <div class="flex flex-col items-center gap-2">
          <p class="font-mono text-5xl font-bold tracking-tight text-white tabular-nums">
            {@allied || 0}<span class="px-2 text-white/40">:</span>{@axis || 0}
          </p>
          <div class="cockpit-sectors" aria-label={gettext("Sectors held")}>
            <span
              :for={index <- 1..5}
              class={[
                "cockpit-sector",
                if(index <= (@allied || 0), do: "is-allies", else: "is-axis")
              ]}
            ></span>
          </div>
        </div>

        <div class="text-white sm:text-right">
          <p class="text-xs tracking-wide text-white/70 uppercase">{gettext("Axis")}</p>
          <p class="text-2xl font-semibold tabular-nums">
            {ngettext("1 player", "%{count} players", @axis_players)}
          </p>
        </div>
      </div>

      <div
        :if={not @loading? and not @error? and @allied_players + @axis_players > 0}
        class="relative mt-4 flex h-1.5 overflow-hidden rounded-pill bg-white/15"
        aria-hidden="true"
      >
        <span
          class="bg-info"
          style={"width: #{share(@allied_players, @allied_players + @axis_players)}%"}
        ></span>
        <span
          class="bg-error"
          style={"width: #{share(@axis_players, @allied_players + @axis_players)}%"}
        ></span>
      </div>
    </section>
    """
  end

  # ── Small pieces ───────────────────────────────────────────────────────────

  attr :id, :string, default: nil
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :to, :string, default: nil
  attr :link, :string, default: nil

  defp block_head(assigns) do
    ~H"""
    <header class="overview-card-head">
      <h2 id={@id} class="overview-card-title">
        <.icon name={@icon} class="size-4" />{@title}
      </h2>
      <.link
        :if={@to}
        navigate={@to}
        class="flex items-center gap-1 text-xs text-muted transition-colors hover:text-primary"
      >
        {@link}<.icon name="hero-arrow-right" class="size-3" />
      </.link>
    </header>
    """
  end

  attr :value, :any, required: true
  attr :label, :string, required: true
  attr :tone, :string, default: "primary"

  defp mini_stat(assigns) do
    ~H"""
    <div class="rounded-field bg-base-200/60 px-2 py-2.5">
      <p class={["text-xl font-semibold tabular-nums", mini_tone(@tone)]}>{@value}</p>
      <p class="truncate text-[0.6875rem] text-muted">{@label}</p>
    </div>
    """
  end

  defp mini_tone("success"), do: "text-success"
  defp mini_tone("warning"), do: "text-warning"
  defp mini_tone(_primary), do: "text-primary"

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp hero_map(gamestate) do
    case gamestate["current_map"] do
      %{"map" => %{"pretty_name" => name}} -> name
      %{"pretty_name" => name} -> name
      _other -> nil
    end
  end

  # The picture of the map being played - with its time of day - and the
  # server's own art until the game state arrives.
  defp hero_art(%{"current_map" => map}, server) when is_map(map),
    do: MapArt.url(server.game, map)

  defp hero_art(_gamestate, server), do: server_art(server)

  defp best_squads(roster) do
    squads = Leaderboards.squads(roster)
    Enum.map(Leaderboards.squad_types(), &{&1, squads |> Map.get(&1, []) |> List.first()})
  end

  defp squad_icon(:infantry), do: "hero-user-group"
  defp squad_icon(:armor), do: "hero-truck"
  defp squad_icon(:recon), do: "hero-eye"
  defp squad_icon(:artillery), do: "hero-fire"

  defp attention_title(%{kind: :stream_down}), do: gettext("The log stream is down")

  defp attention_title(%{kind: :review, subject: %{execution: e}}),
    do: gettext("Review %{player}", player: e.player_name || e.player_id)

  defp attention_title(%{kind: :ticket_waiting, subject: %{ticket: ticket}}),
    do:
      gettext("%{player} is waiting for an admin",
        player: ticket.player_name || ticket.player_id
      )

  defp attention_title(%{subject: %{rule: rule}} = item),
    do: "#{rule.name} · #{attention_kind(item)}"

  defp attention_title(_item), do: gettext("Needs attention")

  defp attention_kind(%{kind: :failures}), do: gettext("failing")
  defp attention_kind(%{kind: :ready_to_go_live}), do: gettext("ready to go live")
  defp attention_kind(%{subject: %{issue: issue}}), do: Labels.health_issue(issue.id)
  defp attention_kind(_item), do: ""

  defp mode_label(nil), do: gettext("Unknown mode")

  defp mode_label(mode) do
    case to_string(mode) do
      "warfare" -> gettext("Warfare")
      "offensive" -> gettext("Offensive")
      "skirmish" -> gettext("Skirmish")
      other -> String.capitalize(other)
    end
  end

  defp time_ago(nil), do: "–"

  defp time_ago(at) do
    minutes = div(DateTime.diff(DateTime.utc_now(), at), 60)

    cond do
      minutes < 60 -> ngettext("1 minute ago", "%{count} minutes ago", max(minutes, 1))
      minutes < 1440 -> ngettext("1 hour ago", "%{count} hours ago", div(minutes, 60))
      true -> ngettext("1 day ago", "%{count} days ago", div(minutes, 1440))
    end
  end

  defp duration(nil), do: "–"
  defp duration(seconds), do: gettext("%{minutes} min", minutes: div(seconds, 60))

  defp share(_part, 0), do: 0
  defp share(part, total), do: Float.round(part * 100 / total, 1)

  defp winner_bar(:allies), do: "bg-info"
  defp winner_bar(:axis), do: "bg-error"
  defp winner_bar(_draw), do: "bg-base-300"

  defp team_dot("allies"), do: "bg-info"
  defp team_dot("axis"), do: "bg-error"
  defp team_dot(_team), do: "bg-base-300"

  defp live_dot(:connected), do: "bg-success animate-pulse"
  defp live_dot(:connecting), do: "bg-warning"
  defp live_dot({:error, _reason}), do: "bg-error"
  defp live_dot(_status), do: "bg-white/40"

  defp stream_tone(:connected), do: "success"
  defp stream_tone(:connecting), do: "warning"
  defp stream_tone({:error, _reason}), do: "error"
  defp stream_tone(_status), do: "neutral"

  defp execution_tone(:executed), do: "success"
  defp execution_tone(:partial), do: "warning"
  defp execution_tone(:failed), do: "error"
  defp execution_tone(:simulated), do: "info"
  defp execution_tone(_status), do: "neutral"

  defp format(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format(value), do: to_string(value)
end
