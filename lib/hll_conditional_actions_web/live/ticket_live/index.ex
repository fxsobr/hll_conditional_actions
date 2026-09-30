defmodule HllConditionalActionsWeb.TicketLive.Index do
  @moduledoc """
  The ticket inbox: every call for an admin on the servers the user may see,
  or one server's under `/servers/:server_id/tickets`.

  Built the way help desks split a queue: views with their counts
  (unassigned, mine, waiting on an admin, waiting on the player, closed),
  a colour that ages with the wait on each row, and "Claim" right on the
  row. Higher priorities come first, then the most recent activity. The
  list updates live.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_tickets}}

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Tickets
  alias HllConditionalActionsWeb.TicketComponents

  # Rows age against each server's alert time; a server without one uses this.
  @default_attention_minutes 5
  @refresh_ms :timer.seconds(30)

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    user = socket.assigns.current_user
    servers = Servers.list_servers_for(user)
    server = Enum.find(servers, &(to_string(&1.id) == params["server_id"]))

    if params["server_id"] && is_nil(server) do
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to that page."))
       |> push_navigate(to: ~p"/tickets")}
    else
      # Ticket changes arrive through `HllConditionalActionsWeb.Nav`, which
      # subscribes every user who may read tickets.
      if connected?(socket) do
        # Ages move on even when nothing happens.
        :timer.send_interval(@refresh_ms, :refresh)
      end

      settings = Map.new(servers, &{&1.id, Tickets.get_settings(&1.id)})

      {:ok,
       socket
       |> assign(:page_title, gettext("Tickets"))
       |> assign(:servers, servers)
       |> assign(:server, server)
       |> assign(:can_manage?, Accounts.can?(user, :manage_tickets))
       |> assign(:settings_by_server, settings)
       |> assign(:configured?, Enum.any?(Map.values(settings), & &1.enabled))
       |> assign(:filters, %{
         "view" => "active",
         "server_id" => "",
         "q" => "",
         "category" => ""
       })
       |> load()}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("filter", params, socket) do
    filters =
      Map.merge(
        socket.assigns.filters,
        Map.take(params, ["server_id", "q", "category"])
      )

    {:noreply, socket |> assign(:filters, filters) |> load()}
  end

  def handle_event("view", %{"view" => view}, socket) do
    {:noreply,
     socket |> assign(:filters, Map.put(socket.assigns.filters, "view", view)) |> load()}
  end

  def handle_event("claim", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with true <- socket.assigns.can_manage?,
         {:ok, ticket} <- Tickets.fetch_ticket(user, id) do
      {:ok, _ticket} = Tickets.assign(ticket, user)
      {:noreply, load(socket)}
    else
      _denied ->
        {:noreply, put_flash(socket, :error, gettext("You do not have access to that page."))}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:ticket_changed, _ticket}, socket), do: {:noreply, load(socket)}
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    %{filters: filters, server: server, current_user: user} = socket.assigns
    server_id = server_id(server, filters)

    tickets =
      Tickets.list_tickets(user,
        server_id: server_id,
        view: view(filters["view"], user),
        query: filters["q"],
        category: filters["category"]
      )

    socket
    |> assign(:tickets_empty?, tickets == [])
    |> stream(:tickets, tickets, reset: true, dom_id: &"ticket-#{&1.id}")
    |> assign(:counts, Tickets.view_counts(user, server_id))
    |> assign(:categories, Tickets.categories(user))
    |> assign(:player_counts, Tickets.counts_by_player(user, Enum.map(tickets, & &1.player_id)))
    |> assign(:now, DateTime.utc_now())
  end

  defp server_id(%{id: id}, _filters), do: id
  defp server_id(nil, %{"server_id" => id}) when id not in [nil, ""], do: String.to_integer(id)
  defp server_id(nil, _filters), do: nil

  defp view("mine", user), do: {:mine, user.id}
  defp view(name, _user), do: Enum.find(Tickets.views(), :active, &(to_string(&1) == name))

  defp view_label(:unassigned), do: gettext("Unassigned")
  defp view_label(:mine), do: gettext("Mine")
  defp view_label(:waiting_admin), do: gettext("Waiting for an admin")
  defp view_label(:waiting_player), do: gettext("Waiting for the player")
  defp view_label(:active), do: gettext("All open")
  defp view_label(:closed), do: gettext("Closed")

  defp view_icon(:unassigned), do: "hero-inbox"
  defp view_icon(:mine), do: "hero-user"
  defp view_icon(:waiting_admin), do: "hero-exclamation-circle"
  defp view_icon(:waiting_player), do: "hero-chat-bubble-left-ellipsis"
  defp view_icon(:active), do: "hero-inbox-stack"
  defp view_icon(:closed), do: "hero-archive-box"

  @doc """
  How long a ticket has been waiting on an admin, as a tone: fresh, getting
  old (past half the server's alert time) or overdue. Tickets that are not
  waiting on an admin do not age.

      iex> alias HllConditionalActionsWeb.TicketLive.Index
      iex> now = ~U[2026-09-26 20:00:00Z]
      iex> ticket = %{status: :open, last_activity_at: ~U[2026-09-26 19:58:00Z]}
      iex> Index.age_tone(ticket, 10, now)
      :fresh
      iex> Index.age_tone(%{ticket | last_activity_at: ~U[2026-09-26 19:54:00Z]}, 10, now)
      :aging
      iex> Index.age_tone(%{ticket | last_activity_at: ~U[2026-09-26 19:40:00Z]}, 10, now)
      :overdue
      iex> Index.age_tone(%{ticket | status: :answered}, 10, now)
      :idle
  """
  @spec age_tone(map(), non_neg_integer(), DateTime.t()) :: :fresh | :aging | :overdue | :idle
  def age_tone(%{status: :open, last_activity_at: at}, minutes, now) when minutes > 0 do
    waited = DateTime.diff(now, at, :second)

    cond do
      waited >= minutes * 60 -> :overdue
      waited >= minutes * 30 -> :aging
      true -> :fresh
    end
  end

  def age_tone(%{status: :open}, _minutes, _now), do: :fresh
  def age_tone(_ticket, _minutes, _now), do: :idle

  defp attention(settings_by_server, server_id) do
    case settings_by_server[server_id] do
      %{attention_minutes: minutes} when is_integer(minutes) and minutes > 0 -> minutes
      _other -> @default_attention_minutes
    end
  end

  defp age_class(:overdue), do: "bg-error"
  defp age_class(:aging), do: "bg-warning"
  defp age_class(:fresh), do: "bg-primary"
  defp age_class(:idle), do: "bg-base-300"

  defp age_title(:overdue), do: gettext("Waiting too long")
  defp age_title(:aging), do: gettext("Waiting for a while")
  defp age_title(:fresh), do: gettext("Just arrived")
  defp age_title(:idle), do: gettext("Not waiting on an admin")

  defp ticket_path(nil, ticket), do: ~p"/tickets/#{ticket.id}"
  defp ticket_path(server, ticket), do: ~p"/servers/#{server.id}/tickets/#{ticket.id}"

  defp user_name(user), do: user.name || user.username

  defp last_line(ticket) do
    ticket.messages
    |> Enum.filter(&(&1.author in [:player, :admin]))
    |> List.last()
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
      page_subtitle={gettext("Players who called an admin from the game chat")}
    >
      <:actions>
        <TicketComponents.alert_toggle id="ticket-alert-toggle" />
      </:actions>

      <TicketComponents.config_tabs server={@server} current={:tickets} can_manage?={@can_manage?} />

      <div
        :if={!@configured? and @can_manage?}
        id="tickets-setup"
        class="flex flex-wrap items-center gap-4 rounded-[1.75rem] border border-primary/30 bg-primary/8 p-5 sm:p-6"
      >
        <.icon_tile icon="hero-sparkles" tone="primary" size="lg" />
        <div class="min-w-0 flex-1">
          <p class="font-display text-lg font-semibold">
            {gettext("Let players call an admin from the game")}
          </p>
          <p class="text-sm text-subtle">
            {gettext(
              "The wizard sets up the command, the messages and the office hours in a few steps."
            )}
          </p>
        </div>
        <.button
          link_type="live_redirect"
          to={if @server, do: ~p"/servers/#{@server.id}/tickets/setup", else: ~p"/tickets/setup"}
          color="primary"
          icon="hero-arrow-right"
          label={gettext("Start the wizard")}
        />
      </div>

      <p
        :if={@server && @configured? && !@settings_by_server[@server.id].enabled}
        id="tickets-off"
        class="flex items-center gap-2 rounded-2xl bg-warning/13 px-4 py-3 text-sm text-warning"
      >
        <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
        {gettext("Tickets are off on this server: players' commands are ignored.")}
      </p>

      <section class="flex flex-col gap-4 rounded-[1.75rem] bg-base-100 p-4 sm:p-5">
        <nav
          id="ticket-views"
          aria-label={gettext("Views")}
          class="-mx-1 flex gap-1.5 overflow-x-auto px-1 pb-1"
        >
          <button
            :for={view <- Tickets.views()}
            type="button"
            phx-click="view"
            phx-value-view={view}
            aria-current={@filters["view"] == to_string(view) && "page"}
            data-view={view}
            class={[
              "inline-flex h-9 shrink-0 cursor-pointer items-center gap-2 rounded-full border px-3.5 text-[0.8125rem] transition-colors",
              if(@filters["view"] == to_string(view),
                do: "border-base-content bg-base-content font-semibold text-base-100",
                else: "border-base-300 bg-secondary text-subtle hover:text-base-content"
              )
            ]}
          >
            <.icon name={view_icon(view)} class="size-4" />
            {view_label(view)}
            <span class={[
              "rounded-full px-1.5 font-mono text-xs tabular-nums leading-5",
              if(view in [:unassigned, :waiting_admin] and @counts[view] > 0,
                do: "bg-warning font-semibold text-warning-content",
                else: "opacity-70"
              )
            ]}>
              {@counts[view]}
            </span>
          </button>
        </nav>

        <.filter_bar id="ticket-filters" on_change="filter">
          <.search_input
            name="q"
            label={gettext("Search")}
            value={@filters["q"]}
            placeholder={gettext("Player name or ID")}
            class="max-sm:w-full sm:w-56"
          />
          <.filter_select
            :if={@categories != []}
            name="category"
            label={gettext("Category")}
            value={@filters["category"]}
            prompt={gettext("All categories")}
            options={Enum.map(@categories, &{&1, &1})}
          />
          <.filter_select
            :if={is_nil(@server) and length(@servers) > 1}
            name="server_id"
            label={gettext("Server")}
            value={@filters["server_id"]}
            prompt={gettext("All servers")}
            options={Enum.map(@servers, &{&1.name, &1.id})}
          />
        </.filter_bar>

        <.empty_state
          :if={@tickets_empty?}
          card={false}
          icon="hero-chat-bubble-left-right"
          title={gettext("No tickets")}
          description={
            gettext(
              "When a player types a ticket command in the game chat, the ticket shows up here."
            )
          }
        />

        <ul id="tickets" phx-update="stream" class="flex flex-col gap-1">
          <li
            :for={{dom_id, ticket} <- @streams.tickets}
            id={dom_id}
            data-age={age_tone(ticket, attention(@settings_by_server, ticket.server_id), @now)}
            class="group relative flex items-center gap-3 rounded-[1.125rem] p-3 transition-colors hover:bg-secondary"
          >
            <span class="relative">
              <TicketComponents.avatar_tile name={ticket.player_name || ticket.player_id} />
              <span
                class={[
                  "absolute -right-0.5 -top-0.5 size-2.5 rounded-full ring-2 ring-base-100",
                  age_class(age_tone(ticket, attention(@settings_by_server, ticket.server_id), @now))
                ]}
                title={
                  age_title(age_tone(ticket, attention(@settings_by_server, ticket.server_id), @now))
                }
              ></span>
            </span>

            <div class="flex min-w-0 flex-1 flex-wrap items-center gap-x-4 gap-y-2">
              <div class="min-w-0 flex-1 basis-64">
                <div class="flex flex-wrap items-center gap-1.5">
                  <.link
                    navigate={ticket_path(@server, ticket)}
                    class="truncate text-sm font-semibold after:absolute after:inset-0 hover:underline"
                  >
                    <span class="font-mono text-xs font-normal text-muted">#{ticket.id}</span>
                    · {ticket.player_name || ticket.player_id}
                  </.link>
                  <.pill
                    :if={ticket.priority != :normal}
                    tone={Labels.ticket_priority_tone(ticket.priority)}
                    dot={false}
                    class="h-5 px-2 text-[0.6875rem]"
                  >
                    {Labels.ticket_priority(ticket.priority)}
                  </.pill>
                  <.pill
                    :if={ticket.category}
                    tone="engine"
                    dot={false}
                    class="h-5 px-2 text-[0.6875rem]"
                  >
                    {ticket.category}
                  </.pill>
                  <.pill
                    :if={ticket.source == :rule}
                    tone="engine"
                    dot={false}
                    class="h-5 px-2 text-[0.6875rem]"
                  >
                    <.icon name="hero-bolt" class="size-3" /> {gettext("Rule")}
                  </.pill>
                  <span
                    :if={Map.get(@player_counts, ticket.player_id, 0) > 1}
                    class="text-xs text-muted"
                    title={gettext("Tickets this player opened")}
                  >
                    · {ngettext(
                      "1 ticket",
                      "%{count} tickets",
                      Map.get(@player_counts, ticket.player_id, 0)
                    )}
                  </span>
                </div>
                <p :if={last_line(ticket)} class="mt-0.5 truncate text-[0.8125rem] text-muted">
                  <span :if={last_line(ticket).author == :admin} class="text-subtle">
                    {gettext("Admin:")}
                  </span>
                  {last_line(ticket).body}
                </p>
              </div>

              <div class="flex shrink-0 flex-wrap items-center gap-3 text-sm">
                <span :if={is_nil(@server)} class="hidden text-xs text-muted md:inline">
                  {ticket.server.name}
                </span>
                <.pill
                  tone={TicketComponents.status_pill(ticket.status)}
                  class="h-6 px-2.5 text-[0.6875rem]"
                >
                  {Labels.ticket_status(ticket.status)}
                </.pill>
                <span class="w-20 text-right font-mono text-[0.6875rem] text-muted">
                  <.local_time id={"ticket-#{ticket.id}-activity"} at={ticket.last_activity_at} />
                </span>
                <span
                  :if={ticket.assigned_to}
                  class="relative z-10 flex items-center gap-1 text-xs text-muted"
                  title={gettext("Assigned to")}
                >
                  <.icon name="hero-user-circle" class="size-4" />
                  <span class="max-w-24 truncate">{user_name(ticket.assigned_to)}</span>
                </span>
                <.button
                  :if={@can_manage? and is_nil(ticket.assigned_to) and ticket.status != :closed}
                  type="button"
                  size="xs"
                  color="primary"
                  variant="outline"
                  phx-click="claim"
                  phx-value-id={ticket.id}
                  class="relative z-10"
                  label={gettext("Claim")}
                />
              </div>
            </div>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
