defmodule HllConditionalActionsWeb.ServerLive.Show do
  @moduledoc """
  A server's cockpit - *Ao vivo*: what is happening on the server right
  now, on one screen.

    1. **The match, live** - the map's picture as the backdrop, the map, the
       mode and when the match started, the score in the teams' colours with
       the five sectors under it, time left, both teams' head count against
       the server's cap, the queue and the VIPs playing.
    2. **The feed** - the server's log as it happens, with the rule that
       acted on a line (or the ticket a line opened) as a pill on that line,
       and the rules' own lines where no log line started them. Chips narrow
       it to kills, chat, or only where rules acted; the pause freezes it
       without losing what arrives meanwhile.
    3. **The match's best and the rules in this match** - the leader of the
       kills, support and defense, and how many times each rule acted since
       the match started.

  On a phone what needs the admin comes first, under the hero.

  The feed opens on the last lines of CRCON's log (`get_recent_logs`) with
  the executions they triggered, so it is never blank; see
  `HllConditionalActions.LiveFeed`. It shows only when the live feed module
  is installed on the server and the admin may see it; otherwise the panel
  lists the rules' latest executions. The CRCON calls run off the LiveView
  process and refresh on a timer, so a slow server shows skeletons, never a
  frozen page.
  """

  use HllConditionalActionsWeb, :live_view

  import HllConditionalActionsWeb.LiveComponents

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_servers}}

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Attention
  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Engine
  alias HllConditionalActions.Engine.Snapshot
  alias HllConditionalActions.Features
  alias HllConditionalActions.Leaderboards
  alias HllConditionalActions.LiveFeed
  alias HllConditionalActions.LiveMatch
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Tickets
  alias HllConditionalActionsWeb.LiveFeedRows

  @live_ms :timer.seconds(15)
  @shown 60
  @kept 150
  @seed_lines 80
  @best_categories [:kills, :support, :defense]

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    server = Servers.get_server!(id)
    user = socket.assigns.current_user

    if Accounts.can_access_server?(user, server) do
      feed? = Accounts.can?(user, :view_live_feed) and Features.installed?(server.id, :live_feed)

      if connected?(socket) do
        LogStream.subscribe(server.id)
        Engine.subscribe(server.id)
        :timer.send_interval(@live_ms, :refresh_live)
      end

      {:ok,
       socket
       |> assign(:server, server)
       |> assign(:page_title, gettext("Live"))
       |> assign(:stream_status, LogStream.status(server.id))
       |> assign(:snapshot, nil)
       |> assign(:live_error?, false)
       |> assign(:match, %{started_at: nil, max_players: nil})
       |> assign(:log_started_at, nil)
       |> assign(:feed?, feed?)
       |> assign(:paused?, false)
       |> assign(:filter, "all")
       |> assign(:buffer, LiveFeedRows.new(@kept))
       |> assign(:seq, 0)
       |> assign(:seeded?, false)
       |> assign(:recount?, false)
       |> assign(:ticket_commands, ticket_commands(user, server))
       |> assign(:messaging?, false)
       |> assign(:message_form, to_form(%{"text" => ""}, as: :message))
       |> assign(:can_message?, Accounts.can?(user, :manage_servers))
       |> stream_configure(:feed, dom_id: & &1.id)
       |> stream(:feed, [])
       |> load()
       |> seed_feed()
       |> fetch_live()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to that page."))
       |> push_navigate(to: ~p"/servers")}
    end
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("toggle_feed", _params, socket) do
    socket = update(socket, :paused?, &(not &1))
    {:noreply, if(socket.assigns.paused?, do: socket, else: restream(socket))}
  end

  def handle_event("feed_filter", %{"filter" => filter}, socket) do
    {:noreply, socket |> assign(:filter, LiveFeedRows.parse_filter(filter)) |> restream()}
  end

  def handle_event("open_message", _params, socket) do
    {:noreply, assign(socket, :messaging?, socket.assigns.can_message?)}
  end

  def handle_event("close_message", _params, socket) do
    {:noreply, assign(socket, :messaging?, false)}
  end

  def handle_event("send_message", %{"message" => %{"text" => text}}, socket) do
    text = String.trim(text || "")

    cond do
      not socket.assigns.can_message? ->
        {:noreply, socket}

      text == "" ->
        {:noreply,
         assign(
           socket,
           :message_form,
           to_form(%{"text" => ""},
             as: :message,
             errors: [
               text: {gettext("Write the message first."), []}
             ]
           )
         )}

      true ->
        server = socket.assigns.server

        {:noreply,
         socket
         |> assign(:messaging?, false)
         |> assign(:message_form, to_form(%{"text" => ""}, as: :message))
         |> start_async(:message, fn -> Crcon.message_all_players(server, text) end)}
    end
  end

  def handle_event("claim_ticket", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with true <- Accounts.can?(user, :manage_tickets),
         {:ok, ticket} <- Tickets.fetch_ticket(user, id),
         {:ok, _ticket} <- Tickets.assign(ticket, user, user) do
      {:noreply, push_navigate(socket, to: ~p"/tickets/#{ticket.id}")}
    else
      _denied -> {:noreply, push_navigate(socket, to: ~p"/tickets/#{id}")}
    end
  end

  # ── Messages ───────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_info({:crcon_stream_status, _server_id, status}, socket) do
    {:noreply, socket |> assign(:stream_status, status) |> load()}
  end

  def handle_info({:crcon_event, event}, %{assigns: %{feed?: true}} = socket) do
    seq = socket.assigns.seq + 1
    key = LiveFeed.event_key(event)

    row =
      event
      |> event_row(LiveFeedRows.row_id(key, "live-#{seq}"),
        roster: socket.assigns.snapshot && socket.assigns.snapshot.players
      )
      |> LiveFeedRows.with_session(socket.assigns.buffer.rows)

    socket =
      socket
      |> assign(:seq, seq)
      |> update(:buffer, &LiveFeedRows.add(&1, row))
      |> show_new(row)
      |> watch_ticket(event, row)

    socket =
      if event.type == :match_start,
        do: socket |> assign(:log_started_at, event.occurred_at) |> load_counts(),
        else: socket

    {:noreply, socket}
  end

  def handle_info({:rule_fired, execution}, socket) do
    socket = ensure_rule(socket, execution.rule_id)
    rule = Enum.find(socket.assigns.rules, &(&1.id == execution.rule_id))
    annotation = LiveFeed.annotation(execution, rule)

    socket =
      case LiveFeedRows.annotate(
             socket.assigns.buffer,
             LiveFeed.execution_event_key(execution),
             annotation
           ) do
        {:ok, row, buffer} ->
          socket |> assign(:buffer, buffer) |> show_changed(row)

        :error ->
          row = execution_row(execution, rule)

          socket
          |> update(:buffer, &LiveFeedRows.add(&1, row))
          |> show_new(row)
      end

    {:noreply, schedule_recount(socket)}
  end

  def handle_info(:recount, socket) do
    {:noreply, socket |> assign(:recount?, false) |> load_counts()}
  end

  # A chat line that looked like a ticket command: the ticket, if it opened,
  # goes on the line.
  def handle_info({:check_ticket, row_id}, socket) do
    buffer = socket.assigns.buffer

    with %{ticket: nil} = row <- Enum.find(buffer.rows, &(&1.id == row_id)),
         %{} = ticket <-
           socket.assigns.server.id |> LiveFeed.tickets_for([row]) |> Map.get(row.key) do
      row = %{row | ticket: ticket}

      {:noreply,
       socket |> assign(:buffer, LiveFeedRows.replace(buffer, row)) |> show_changed(row)}
    else
      _nothing -> {:noreply, socket}
    end
  end

  def handle_info(:refresh_live, socket), do: {:noreply, socket |> load() |> fetch_live()}
  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Async ──────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_async(:live, {:ok, {%Snapshot{stale?: false} = snapshot, match}}, socket) do
    socket =
      socket
      |> assign(snapshot: snapshot, live_error?: false)
      |> assign_match(match)
      |> enrich_rows()

    {:noreply, load_counts(socket)}
  end

  # A failed read keeps the last good one on screen, if there is one.
  def handle_async(:live, {:ok, {_stale, match}}, socket) do
    {:noreply,
     socket
     |> assign(:live_error?, is_nil(socket.assigns.snapshot))
     |> assign_match(match)}
  end

  def handle_async(:live, _failed, socket) do
    {:noreply, assign(socket, :live_error?, is_nil(socket.assigns.snapshot))}
  end

  def handle_async(:seed, {:ok, seed}, socket) do
    roster = socket.assigns.snapshot && socket.assigns.snapshot.players
    seeded = LiveFeedRows.seed(seed.events, seed.executions, seed.tickets, roster: roster)
    seeded_ids = MapSet.new(seeded, & &1.id)

    # Lines that arrived while the log was being read stay on top.
    live = Enum.reject(socket.assigns.buffer.rows, &MapSet.member?(seeded_ids, &1.id))

    {:noreply,
     socket
     |> assign(:buffer, LiveFeedRows.reset(socket.assigns.buffer, live ++ seeded))
     |> assign(:seeded?, true)
     |> assign(:log_started_at, LiveMatch.started_at_from(seed.events))
     |> load_counts()
     |> restream()}
  end

  def handle_async(:seed, _failed, socket), do: {:noreply, assign(socket, :seeded?, true)}

  def handle_async(:message, {:ok, {:ok, _result}}, socket) do
    {:noreply, put_flash(socket, :info, gettext("Message sent to every player."))}
  end

  def handle_async(:message, _failed, socket) do
    {:noreply, put_flash(socket, :error, gettext("CRCON did not take the message. Try again."))}
  end

  defp fetch_live(socket) do
    server = socket.assigns.server

    start_async(socket, :live, fn ->
      match =
        case LiveMatch.info(server) do
          {:ok, info} -> info
          {:error, _error} -> nil
        end

      {Snapshot.refresh(server), match}
    end)
  end

  defp assign_match(socket, nil), do: socket
  defp assign_match(socket, match), do: assign(socket, :match, match)

  # The feed opens on the last lines of the log and what the rules did on
  # them; without the live feed module, on the rules' latest executions.
  defp seed_feed(socket) do
    if connected?(socket) do
      %{server: server, feed?: feed?} = socket.assigns

      start_async(socket, :seed, fn -> seed_rows(server, feed?) end)
    else
      socket
    end
  end

  defp seed_rows(server, feed?) do
    events =
      with true <- feed?,
           {:ok, events} <- LiveFeed.recent_events(server, @seed_lines) do
        events
      else
        _none -> []
      end

    since = events |> List.last() |> then(&(&1 && &1.occurred_at))

    executions =
      if since,
        do: LiveFeed.executions(server.id, since: since, limit: @seed_lines),
        else: LiveFeed.executions(server.id, limit: 20)

    %{
      events: events,
      executions: executions,
      tickets: LiveFeed.tickets_for(server.id, events)
    }
  end

  # ── The feed's rows ────────────────────────────────────────────────────────

  defp restream(socket) do
    rows =
      socket.assigns.buffer
      |> LiveFeedRows.visible(socket.assigns.filter)
      |> Enum.take(@shown)

    stream(socket, :feed, rows, reset: true)
  end

  defp show_new(%{assigns: %{paused?: true}} = socket, _row), do: socket

  defp show_new(socket, row) do
    if LiveFeedRows.matches?(row, socket.assigns.filter),
      do: stream_insert(socket, :feed, row, at: 0, limit: @shown),
      else: socket
  end

  # A row that changed in place (a rule or a ticket joined it). Under the
  # "where rules acted" filter it may have just become visible, so the list
  # is redrawn in order.
  defp show_changed(%{assigns: %{paused?: true}} = socket, _row), do: socket
  defp show_changed(%{assigns: %{filter: "acted"}} = socket, _row), do: restream(socket)

  defp show_changed(socket, row) do
    if LiveFeedRows.shown?(socket.assigns.buffer, socket.assigns.filter, row.id, @shown),
      do: stream_insert(socket, :feed, row),
      else: socket
  end

  # A joining player is not in the roster yet when the line arrives; the
  # next snapshot gives their level and session.
  defp enrich_rows(socket) do
    roster = socket.assigns.snapshot.players
    since = DateTime.add(DateTime.utc_now(), -300, :second)

    socket.assigns.buffer.rows
    |> Enum.filter(fn row ->
      row.kind == :event and row.type == :player_connected and row.details == %{} and
        DateTime.compare(row.occurred_at, since) == :gt
    end)
    |> Enum.reduce(socket, fn row, socket ->
      case details(row, roster) do
        details when details == %{} ->
          socket

        details ->
          row = %{row | details: details}

          socket
          |> update(:buffer, &LiveFeedRows.replace(&1, row))
          |> show_changed(row)
      end
    end)
  end

  defp watch_ticket(%{assigns: %{ticket_commands: []}} = socket, _event, _row), do: socket

  defp watch_ticket(socket, %{type: :player_chat} = event, row) do
    case Tickets.match_command(event.chat_message, socket.assigns.ticket_commands) do
      {:ok, _text} ->
        Process.send_after(self(), {:check_ticket, row.id}, 2_500)
        socket

      :nomatch ->
        socket
    end
  end

  defp watch_ticket(socket, _event, _row), do: socket

  defp ticket_commands(user, server) do
    with true <- Accounts.can?(user, :view_tickets),
         %{enabled: true, commands: commands} when is_list(commands) <-
           Tickets.get_settings(server.id) do
      commands
    else
      _off -> []
    end
  end

  # ── Loading ────────────────────────────────────────────────────────────────

  defp load(socket) do
    %{server: server, current_user: user, stream_status: status} = socket.assigns

    socket
    |> assign(:rules, Rules.list_rules_applying_to(server))
    |> assign(:attention, Attention.items(user, [server], %{server.id => status}).open)
    |> load_counts()
  end

  # What the rules did since the match started.
  defp load_counts(socket) do
    started_at = started_at(socket.assigns)

    socket
    |> assign(:started_at, started_at)
    |> assign(:counts, LiveMatch.rule_counts(socket.assigns.server.id, started_at))
  end

  # When the match started: CRCON's public info, then its game state, then
  # the log's last match start line.
  defp started_at(assigns) do
    assigns.match.started_at ||
      LiveMatch.started_at_from_gamestate(assigns.snapshot && assigns.snapshot.gamestate) ||
      assigns.log_started_at
  end

  # A sweep at the end of a match fires a rule once per player: the counts
  # are read again once the burst is over, not once per execution.
  defp schedule_recount(%{assigns: %{recount?: true}} = socket), do: socket

  defp schedule_recount(socket) do
    Process.send_after(self(), :recount, 1_000)
    assign(socket, :recount?, true)
  end

  defp ensure_rule(socket, rule_id) do
    if Enum.any?(socket.assigns.rules, &(&1.id == rule_id)),
      do: socket,
      else: assign(socket, :rules, Rules.list_rules_applying_to(socket.assigns.server))
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assign(assigns,
        roster: assigns.snapshot && assigns.snapshot.players,
        base: "/servers/#{assigns.server.id}",
        stats?: Accounts.can?(assigns.current_user, :view_stats),
        rule_rows: rule_rows(assigns.rules, assigns.counts)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Live")}
    >
      <:actions>
        <button
          :if={@can_message?}
          id="cockpit-message"
          type="button"
          phx-click="open_message"
          aria-label={gettext("Message everyone")}
          class="flex size-12 cursor-pointer items-center justify-center gap-2 rounded-full border border-base-300 bg-white text-sm font-medium transition-colors hover:bg-base-100 xl:w-auto xl:pl-4 xl:pr-5 dark:bg-secondary dark:hover:bg-base-300"
        >
          <.icon name="hero-chat-bubble-left" class="size-[1.125rem]" />
          <span class="hidden xl:inline">{gettext("Message everyone")}</span>
        </button>
      </:actions>

      <div class="flex flex-col gap-3.5 md:gap-4 xl:gap-5">
        <.live_hero
          id="cockpit-live"
          server={@server}
          gamestate={@snapshot && @snapshot.gamestate}
          roster={@roster}
          stream_status={@stream_status}
          started_at={@started_at}
          max_players={@match.max_players}
          loading?={is_nil(@snapshot) and not @live_error?}
          error?={@live_error?}
        />

        <.attention_panel attention={@attention} base={@base} current_user={@current_user} />

        <div class="grid gap-3.5 md:gap-4 xl:grid-cols-[minmax(0,1fr)_25rem] xl:gap-5">
          <.feed_panel
            streams={@streams}
            feed?={@feed?}
            paused?={@paused?}
            filter={@filter}
            seeded?={@seeded?}
            base={@base}
            stats?={@stats?}
          />

          <div class="flex min-w-0 flex-col gap-3.5 md:gap-4 xl:gap-5">
            <.live_panel
              id="cockpit-best"
              title={gettext("Best of the match")}
              title_id="cockpit-top-title"
            >
              <:aside>
                <span class="hidden text-[0.8125rem] text-muted md:inline xl:hidden">
                  {gettext("Rules acted")}
                  <strong class="font-semibold text-primary">{@counts.total}</strong>
                  {ngettext("time", "times", @counts.total)}
                </span>
                <.panel_link :if={@stats?} navigate={@base <> "/leaderboard"}>
                  {gettext("Scoreboard")}
                </.panel_link>
              </:aside>
              <div
                :if={is_nil(@roster)}
                class="grid gap-3 md:grid-cols-3 md:gap-2.5 xl:grid-cols-1 xl:gap-3"
              >
                <.skeleton_block :for={_ <- 1..3} class="h-10 w-full rounded-xl" />
              </div>
              <p :if={@roster == %{}} class="py-6 text-center text-sm text-muted">
                {gettext("Nobody is playing right now.")}
              </p>
              <div
                :if={@roster not in [nil, %{}]}
                class="grid gap-3 md:grid-cols-3 md:gap-2.5 xl:grid-cols-1 xl:gap-3"
              >
                <.best_row
                  :for={category <- best_categories()}
                  id={"cockpit-board-#{category}"}
                  category={category}
                  leader={@roster |> Leaderboards.top_players(category, 1) |> List.first()}
                />
              </div>
            </.live_panel>

            <.live_panel id="cockpit-rules" class="hidden grow xl:flex">
              <div class="flex items-baseline">
                <h2 class="flex-1 font-display text-xl font-semibold">
                  {gettext("Rules in this match")}
                </h2>
                <span class="font-display text-xl font-semibold text-primary tabular-nums">
                  {@counts.total}
                </span>
              </div>
              <ul :if={@rule_rows != []} class="flex flex-col gap-3" id="cockpit-rule-counts">
                <li :for={row <- @rule_rows}>
                  <.link
                    navigate={~p"/rules/#{row.id}"}
                    class="flex items-center gap-2.5 rounded-[0.875rem] bg-secondary px-3 py-2.5 transition-colors hover:bg-base-300"
                  >
                    <span class={["size-2 shrink-0 rounded-full", match_rule_dot(row.state)]}></span>
                    <span class="min-w-0 flex-1 truncate text-sm">{row.name}</span>
                    <span
                      :if={row.state != :live}
                      class={["text-[0.6875rem] font-semibold", match_rule_text(row.state)]}
                    >
                      {match_rule_label(row.state)}
                    </span>
                    <span class="font-mono text-[0.8125rem] text-subtle tabular-nums">
                      {row.count}
                    </span>
                  </.link>
                </li>
              </ul>
              <p :if={@rule_rows == []} class="py-3 text-sm text-muted">
                {if @started_at,
                  do: gettext("No rule acted in this match yet."),
                  else: gettext("CRCON has not said when this match started yet.")}
              </p>
            </.live_panel>
          </div>
        </div>
      </div>

      <.modal
        :if={@messaging?}
        id="broadcast-modal"
        title={gettext("Message everyone")}
        subtitle={gettext("Every player on %{server} sees it on their screen.", server: @server.name)}
        on_cancel={JS.push("close_message")}
      >
        <.form
          for={@message_form}
          id="broadcast-form"
          phx-submit="send_message"
          class="flex flex-col gap-4"
        >
          <.input
            field={@message_form[:text]}
            type="textarea"
            label={gettext("Message")}
            rows="4"
            maxlength="300"
          />
          <div class="flex justify-end gap-2">
            <.button type="button" variant="ghost" color="gray" phx-click="close_message">
              {gettext("Cancel")}
            </.button>
            <.button type="submit" color="primary" icon="hero-paper-airplane">
              {gettext("Send to everyone")}
            </.button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end

  # ── The feed panel ─────────────────────────────────────────────────────────

  attr :streams, :any, required: true
  attr :feed?, :boolean, required: true
  attr :paused?, :boolean, required: true
  attr :filter, :string, required: true
  attr :seeded?, :boolean, required: true
  attr :base, :string, required: true
  attr :stats?, :boolean, required: true

  defp feed_panel(assigns) do
    ~H"""
    <.live_panel id="cockpit-feed" wide gap="gap-0.5 md:gap-2.5 xl:gap-3.5">
      <div class="mb-1.5 flex items-baseline md:hidden">
        <h2 class="flex-1 font-display text-lg font-semibold">
          {if @feed?, do: gettext("Feed"), else: gettext("Latest activity")}
        </h2>
        <span class="text-xs text-muted">
          {if @paused?, do: gettext("paused"), else: gettext("live")}
        </span>
      </div>

      <div class="hidden items-center gap-2 md:flex">
        <h2 class="sr-only">
          {if @feed?, do: gettext("Live feed"), else: gettext("Latest activity")}
        </h2>
        <.match_views
          id="cockpit-views"
          base={@base}
          current={:feed}
          stats?={@stats?}
          class="bg-secondary"
        />
        <span class="grow"></span>
        <.feed_filters
          :if={@feed?}
          id="cockpit-feed-filters"
          filter={@filter}
          paused?={@paused?}
          pause_event="toggle_feed"
          filter_event="feed_filter"
        />
      </div>

      <div
        id="cockpit-feed-rows"
        phx-update="stream"
        role="log"
        aria-label={gettext("Live feed")}
        class="live-feed live-feed-short flex flex-col md:max-h-[36rem] md:overflow-y-auto xl:max-h-[32.5rem]"
      >
        <p id="cockpit-feed-empty" class="hidden py-10 text-center text-sm text-muted only:block">
          <%= cond do %>
            <% not @seeded? -> %>
              {gettext("Reading the server's log…")}
            <% @filter != "all" -> %>
              {gettext("Nothing like this in the feed yet.")}
            <% @feed? -> %>
              {gettext("Waiting for events. Nothing has happened on this server yet.")}
            <% true -> %>
              {gettext("No rule fired here yet.")}
          <% end %>
        </p>
        <.feed_row :for={{dom_id, row} <- @streams.feed} id={dom_id} row={row} />
      </div>
      <.link
        :if={@feed?}
        id="cockpit-feed-more"
        navigate={@base <> "/feed"}
        class="pt-2.5 text-center text-[0.8125rem] text-primary md:hidden"
      >
        {gettext("See the whole feed")}
      </.link>
    </.live_panel>
    """
  end

  # ── Side panels ────────────────────────────────────────────────────────────

  attr :attention, :list, required: true
  attr :base, :string, required: true
  attr :current_user, :map, required: true

  # What needs the admin, first on a phone; the bell and the inbox carry it
  # on wider screens.
  defp attention_panel(assigns) do
    ~H"""
    <.live_panel :if={@attention != []} id="cockpit-attention" gap="gap-1" class="md:hidden">
      <div class="mb-1 flex items-baseline">
        <h2 class="flex-1 font-display text-lg font-semibold">{gettext("Needs you")}</h2>
        <span class="text-xs text-muted">{length(@attention)}</span>
      </div>
      <ul class="flex flex-col">
        <li
          :for={item <- Enum.take(@attention, 3)}
          data-severity={item.severity}
          class="flex min-h-13 items-center gap-3"
        >
          <.link navigate={attention_path(item, @base)} class="flex min-w-0 flex-1 items-center gap-3">
            <span class={[
              "flex size-9 shrink-0 items-center justify-center rounded-xl",
              attention_tint(item)
            ]}>
              <.icon name={attention_icon(item)} class="size-[1.125rem]" />
            </span>
            <span class="flex min-w-0 flex-1 flex-col gap-px">
              <strong class="truncate text-sm font-semibold">{attention_title(item)}</strong>
              <span :if={attention_detail(item)} class="truncate text-xs text-muted">
                {attention_detail(item)}
              </span>
            </span>
          </.link>
          <button
            :if={item.kind == :ticket_waiting and Accounts.can?(@current_user, :manage_tickets)}
            type="button"
            phx-click="claim_ticket"
            phx-value-id={item.subject.ticket.id}
            class="flex h-8 shrink-0 cursor-pointer items-center rounded-full bg-primary px-3 text-xs font-bold text-primary-content transition-opacity hover:opacity-90"
          >
            {gettext("Take it")}
          </button>
          <.icon
            :if={item.kind != :ticket_waiting}
            name="hero-chevron-right"
            class="size-4 shrink-0 text-muted"
          />
        </li>
      </ul>
    </.live_panel>
    """
  end

  attr :id, :string, required: true
  attr :category, :atom, required: true
  attr :leader, :map, default: nil

  # The leader of one category of the match: initials on the team's tint,
  # the category under the name, the number on the right. A card of its own
  # on a tablet, a plain row elsewhere.
  defp best_row(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex items-center gap-3 md:rounded-[1.125rem] md:bg-secondary md:px-3.5 md:py-3 xl:rounded-none xl:bg-transparent xl:p-0"
    >
      <.initials_tile name={(@leader && @leader.name) || "–"} team={@leader && @leader.team} />
      <span class="flex min-w-0 flex-1 flex-col">
        <strong class="truncate text-sm font-semibold">{(@leader && @leader.name) || "–"}</strong>
        <span class="truncate text-xs text-muted">{Labels.leaderboard_category(@category)}</span>
      </span>
      <span :if={@leader} class="font-display text-xl font-semibold tabular-nums">
        {format_number(@leader.value)}
      </span>
    </div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp best_categories, do: @best_categories

  # The rules that acted in this match, most active first: live, simulating,
  # or failing when some of this match's runs failed.
  defp rule_rows(rules, %{rules: counts}) do
    by_id = Map.new(rules, &{&1.id, &1})

    counts
    |> Enum.map(fn {rule_id, %{count: count, failed: failed}} ->
      rule = Map.get(by_id, rule_id)

      %{
        id: rule_id,
        name: (rule && rule.name) || gettext("Deleted rule"),
        count: count,
        state:
          cond do
            failed > 0 -> :failing
            rule && rule.simulation -> :simulating
            true -> :live
          end
      }
    end)
    |> Enum.sort_by(&{-&1.count, &1.name})
    |> Enum.take(6)
  end

  defp match_rule_dot(:failing), do: "bg-warning"
  defp match_rule_dot(:simulating), do: "border-[1.5px] border-dashed border-accent"
  defp match_rule_dot(_live), do: "bg-primary"

  defp match_rule_text(:failing), do: "text-warning"
  defp match_rule_text(_simulating), do: "text-accent"

  defp match_rule_label(:failing), do: gettext("failing")
  defp match_rule_label(_simulating), do: gettext("simulating")

  defp attention_path(%{kind: :ticket_waiting, subject: %{ticket: ticket}}, _base),
    do: "/tickets/#{ticket.id}"

  defp attention_path(%{kind: :vip_failed}, _base), do: "/vip-shop/purchases"

  defp attention_path(%{kind: :review, subject: %{execution: execution}}, _base),
    do: "/players/#{execution.player_id}"

  defp attention_path(%{subject: %{rule: %{id: id}}}, _base), do: "/rules/#{id}"
  defp attention_path(_item, base), do: base <> "/attention"

  defp attention_icon(%{kind: :ticket_waiting}), do: "hero-chat-bubble-left"
  defp attention_icon(%{kind: :stream_down}), do: "hero-signal-slash"
  defp attention_icon(%{kind: :vip_failed}), do: "hero-shopping-bag"
  defp attention_icon(%{kind: :review}), do: "hero-eye"
  defp attention_icon(%{subject: %{rule: _rule}}), do: "hero-bolt"
  defp attention_icon(%{severity: :error}), do: "hero-exclamation-circle"
  defp attention_icon(%{severity: :warning}), do: "hero-exclamation-triangle"
  defp attention_icon(_item), do: "hero-information-circle"

  defp attention_tint(%{kind: :ticket_waiting}), do: "bg-accent/13 text-accent"
  defp attention_tint(%{severity: :error}), do: "bg-error/14 text-error"
  defp attention_tint(%{severity: :warning}), do: "bg-warning/13 text-warning"
  defp attention_tint(_item), do: "bg-info/14 text-info"

  defp attention_title(%{kind: :stream_down}), do: gettext("The log stream is down")

  defp attention_title(%{kind: :review, subject: %{execution: e}}),
    do: gettext("Review %{player}", player: e.player_name || e.player_id)

  defp attention_title(%{kind: :ticket_waiting, subject: %{ticket: ticket}}),
    do: gettext("Ticket from %{player}", player: ticket.player_name || ticket.player_id)

  defp attention_title(%{kind: :vip_failed, subject: %{order: order}}),
    do:
      gettext("Paid VIP not granted for %{player}", player: order.player_name || order.player_id)

  defp attention_title(%{kind: :failures, subject: %{rule: rule}}),
    do: gettext("%{rule} failed", rule: rule.name)

  defp attention_title(%{kind: :ready_to_go_live, subject: %{rule: rule}}),
    do: gettext("%{rule} is ready to go live", rule: rule.name)

  defp attention_title(%{subject: %{rule: rule, issue: issue}}),
    do: "#{rule.name} · #{Labels.health_issue(issue.id)}"

  defp attention_title(_item), do: gettext("Needs attention")

  defp attention_detail(%{kind: :ticket_waiting, subject: %{ticket: ticket}} = item) do
    waiting =
      item.at &&
        gettext("waiting for %{time}", time: waited(DateTime.diff(DateTime.utc_now(), item.at)))

    [waiting, ticket.category] |> Enum.reject(&is_nil/1) |> Enum.join(" · ") |> blank()
  end

  defp attention_detail(%{kind: :failures, subject: %{count: count} = subject}) do
    [ngettext("1 time", "%{count} times", count), subject[:error]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp attention_detail(_item), do: nil

  defp waited(seconds) when seconds < 3600,
    do: gettext("%{minutes} min", minutes: max(div(seconds, 60), 1))

  defp waited(seconds), do: gettext("%{hours} h", hours: div(seconds, 3600))

  defp blank(""), do: nil
  defp blank(text), do: text
end
