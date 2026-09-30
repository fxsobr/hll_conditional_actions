defmodule HllConditionalActionsWeb.FeedLive do
  @moduledoc """
  The live feed on a page of its own: every line CRCON reports, for one
  server (`/servers/:server_id/feed`) or across every server the admin can
  see (`/feed`).

  Useful for writing rules: it shows the exact events the engine sees, with
  the rule that acted on a line as a pill on that line, so you can confirm a
  trigger fires before wiring an action to it. It is the cockpit's feed
  panel at full height - the same rows (`LiveComponents.feed_row/1`), the
  same chips (everything, kills, chat, only where rules acted) and pause -
  and opens on the last lines of each server's log.

  Rows live in a bounded buffer (`HllConditionalActionsWeb.LiveFeedRows`)
  and a LiveView stream capped at a few hundred entries, so a busy fleet
  cannot grow the socket without bound.
  """

  use HllConditionalActionsWeb, :live_view

  import HllConditionalActionsWeb.LiveComponents

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_live_feed}}

  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Engine
  alias HllConditionalActions.LiveFeed
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.LiveFeedRows

  @limit 300
  @seed_lines 60

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    servers = Servers.list_servers_for(socket.assigns[:current_user])
    scope = Enum.find(servers, &(to_string(&1.id) == params["server_id"]))
    watched = if scope, do: [scope], else: servers

    if connected?(socket) do
      Enum.each(watched, fn server ->
        LogStream.subscribe(server.id)
        Engine.subscribe(server.id)
      end)
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("Live feed"))
     |> assign(:servers, Map.new(servers, &{&1.id, &1}))
     |> assign(:scope, scope)
     |> assign(:server_filter, nil)
     |> assign(:paused?, false)
     |> assign(:filter, "all")
     |> assign(:buffer, LiveFeedRows.new(@limit))
     |> assign(:count, 0)
     |> assign(:rule_cache, %{})
     |> assign(:seeded?, not connected?(socket) or watched == [])
     |> stream_configure(:events, dom_id: & &1.id)
     |> stream(:events, [])
     |> seed(watched)}
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("toggle_pause", _params, socket) do
    socket = update(socket, :paused?, &(not &1))
    {:noreply, if(socket.assigns.paused?, do: socket, else: restream(socket))}
  end

  def handle_event("feed_filter", %{"filter" => filter}, socket) do
    {:noreply, socket |> assign(:filter, LiveFeedRows.parse_filter(filter)) |> restream()}
  end

  def handle_event("filter_server", params, socket) do
    {:noreply,
     socket
     |> assign(:server_filter, blank_to_nil(params["server_id"]))
     |> restream()}
  end

  def handle_event("clear", _params, socket) do
    {:noreply,
     socket
     |> assign(:buffer, LiveFeedRows.new(@limit))
     |> assign(:count, 0)
     |> stream(:events, [], reset: true)}
  end

  # ── Messages ───────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_info({:crcon_event, event}, socket) do
    key = LiveFeed.event_key(event)
    count = socket.assigns.count + 1
    server = Map.get(socket.assigns.servers, event.server_id)

    row =
      event_row(event, LiveFeedRows.row_id(key, "live-#{count}"),
        server_name: server && server.name
      )
      |> Map.put(:server_id, event.server_id)
      |> LiveFeedRows.with_session(socket.assigns.buffer.rows)

    {:noreply,
     socket
     |> assign(:count, count)
     |> update(:buffer, &LiveFeedRows.add(&1, row))
     |> show_new(row)}
  end

  def handle_info({:rule_fired, execution}, socket) do
    {rule, socket} = rule_for(socket, execution.rule_id)
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
          row = execution |> execution_row(rule) |> Map.put(:server_id, execution.server_id)
          socket |> update(:buffer, &LiveFeedRows.add(&1, row)) |> show_new(row)
      end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # The rules the feed has named, read once each: a sweep at the end of a
  # match brings one execution per player.
  defp rule_for(socket, rule_id) do
    case Map.fetch(socket.assigns.rule_cache, rule_id) do
      {:ok, rule} ->
        {rule, socket}

      :error ->
        rule = HllConditionalActions.Repo.get(HllConditionalActions.Rules.Rule, rule_id)
        {rule, update(socket, :rule_cache, &Map.put(&1, rule_id, rule))}
    end
  end

  @impl Phoenix.LiveView
  def handle_async(:seed, {:ok, rows}, socket) do
    ids = MapSet.new(rows, & &1.id)
    live = Enum.reject(socket.assigns.buffer.rows, &MapSet.member?(ids, &1.id))

    {:noreply,
     socket
     |> assign(:buffer, LiveFeedRows.reset(socket.assigns.buffer, live ++ rows))
     |> assign(:seeded?, true)
     |> restream()}
  end

  def handle_async(:seed, _failed, socket), do: {:noreply, assign(socket, :seeded?, true)}

  # The last lines of each server's log, with what the rules did on them.
  defp seed(socket, servers) do
    if connected?(socket) and servers != [] do
      names = Map.new(servers, &{&1.id, &1.name})

      start_async(socket, :seed, fn -> seed_all(servers, names) end)
    else
      socket
    end
  end

  defp seed_all(servers, names) do
    servers
    |> Task.async_stream(&seed_rows(&1, names),
      max_concurrency: 4,
      timeout: :timer.seconds(20),
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, rows} -> rows
      _failed -> []
    end)
    |> Enum.sort_by(&DateTime.to_unix(&1.occurred_at, :microsecond), :desc)
  end

  defp seed_rows(server, names) do
    events =
      case LiveFeed.recent_events(server, @seed_lines) do
        {:ok, events} -> events
        {:error, _error} -> []
      end

    since = events |> List.last() |> then(&(&1 && &1.occurred_at))

    executions =
      if since,
        do: LiveFeed.executions(server.id, since: since, limit: @seed_lines),
        else: []

    events
    |> LiveFeedRows.seed(executions, LiveFeed.tickets_for(server.id, events), server_names: names)
    |> Enum.map(&Map.put(&1, :server_id, server.id))
  end

  # ── Rows ───────────────────────────────────────────────────────────────────

  defp restream(socket) do
    rows =
      socket.assigns.buffer
      |> LiveFeedRows.visible(socket.assigns.filter)
      |> Enum.filter(&on_server?(&1, socket))

    stream(socket, :events, rows, reset: true)
  end

  defp show_new(%{assigns: %{paused?: true}} = socket, _row), do: socket

  defp show_new(socket, row) do
    if LiveFeedRows.matches?(row, socket.assigns.filter) and on_server?(row, socket),
      do: stream_insert(socket, :events, row, at: 0, limit: @limit),
      else: socket
  end

  defp show_changed(%{assigns: %{paused?: true}} = socket, _row), do: socket
  defp show_changed(%{assigns: %{filter: "acted"}} = socket, _row), do: restream(socket)

  defp show_changed(socket, row) do
    if on_server?(row, socket) and
         LiveFeedRows.shown?(socket.assigns.buffer, socket.assigns.filter, row.id, @limit),
       do: stream_insert(socket, :events, row),
       else: socket
  end

  defp on_server?(_row, %{assigns: %{server_filter: nil}}), do: true
  defp on_server?(row, socket), do: to_string(row[:server_id]) == socket.assigns.server_filter

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Live feed")}
      page_subtitle={gettext("Events arriving from CRCON, as they happen")}
    >
      <:actions>
        <.button
          id="feed-clear"
          type="button"
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-trash"
          phx-click="clear"
          label={gettext("Clear")}
        />
      </:actions>

      <.live_panel id="feed-panel" wide gap="gap-2.5 xl:gap-3.5">
        <div class="flex flex-wrap items-center gap-2">
          <form :if={is_nil(@scope)} id="feed-server" phx-change="filter_server">
            <label>
              <span class="sr-only">{gettext("Server")}</span>
              <select
                name="server_id"
                class="h-9 rounded-full border border-base-300 bg-white px-3 pr-8 text-xs dark:bg-secondary"
              >
                <option value="">{gettext("Every server")}</option>
                <option
                  :for={{id, server} <- @servers}
                  value={id}
                  selected={to_string(id) == @server_filter}
                >
                  {server.name}
                </option>
              </select>
            </label>
          </form>
          <span class="grow"></span>
          <span :if={@paused?} class="text-xs text-warning" aria-live="polite">
            {gettext("Paused: new lines wait until you resume.")}
          </span>
          <.feed_filters
            id="feed-filters"
            filter={@filter}
            paused?={@paused?}
            pause_event="toggle_pause"
            filter_event="feed_filter"
          />
        </div>

        <div
          id="feed"
          phx-update="stream"
          role="log"
          aria-label={gettext("Live feed")}
          class="live-feed flex max-h-[70vh] flex-col overflow-y-auto"
        >
          <p id="feed-empty" class="hidden py-10 text-center text-sm text-muted only:block">
            <%= cond do %>
              <% not @seeded? -> %>
                {gettext("Reading the servers' logs…")}
              <% @filter != "all" -> %>
                {gettext("Nothing like this in the feed yet.")}
              <% true -> %>
                {gettext("Waiting for events. Nothing has happened on your servers yet.")}
            <% end %>
          </p>
          <.feed_row
            :for={{dom_id, row} <- @streams.events}
            id={dom_id}
            row={row}
            show_server={is_nil(@scope)}
          />
        </div>
      </.live_panel>
    </Layouts.app>
    """
  end
end
