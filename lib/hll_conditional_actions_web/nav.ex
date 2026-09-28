defmodule HllConditionalActionsWeb.Nav do
  @moduledoc """
  Keeps the navigation in step with the page: `@current_path` for the active
  entry, and `@nav` - the servers the user can switch between and the one
  the page is about.

  ## Scope

  The app has two places to be, the way CRCON has one install per server:

    * **a server** - every page under `/servers/:id/...`: its live feed,
      leaderboard, matches, rules, history, attention and seasons. The
      sidebar opens on that server's card and lists only its pages.
    * **the organisation** - everything else: the fleet overview, the list
      of servers, achievement definitions, users and roles.

  The scope comes from the URL alone, so a link or a reload always lands in
  the same place, and switching server keeps the page you were on.

  Mounted for every LiveView through `HllConditionalActionsWeb.live_view/0`.
  """

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  import Phoenix.Component
  import Phoenix.LiveView

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Attention
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Features
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Tickets

  @server_path ~r{^/servers/(\d+)(?:/|$)}

  @doc false
  def on_mount(:default, _params, _session, socket) do
    user = socket.assigns[:current_user]
    tickets? = Accounts.can?(user, :view_tickets)

    if tickets? and connected?(socket), do: Tickets.subscribe()

    attention? = connected?(socket) and Accounts.can?(user, :view_executions)
    if attention?, do: Attention.subscribe()

    socket =
      socket
      |> assign_new(:current_path, fn -> "/" end)
      |> assign(:nav, %{
        servers: visible_servers(socket),
        server: nil,
        status: nil,
        tickets: if(tickets?, do: Tickets.open_counts(user), else: %{}),
        attention: attention_count(socket),
        features: installed_features(user)
      })
      |> attach_hook(:current_path, :handle_params, &put_current_path/3)
      |> then(fn socket ->
        if attention?,
          do: attach_hook(socket, :attention_bell, :handle_info, &refresh_attention/2),
          else: socket
      end)

    socket =
      if tickets?,
        do: attach_hook(socket, :ticket_counts, :handle_info, &refresh_ticket_counts/2),
        else: socket

    {:cont, socket}
  end

  # Pages about tickets react to the change themselves; for every other page
  # the message stops here, once the badge is up to date.
  @ticket_pages [
    HllConditionalActionsWeb.TicketLive.Index,
    HllConditionalActionsWeb.TicketLive.Show,
    HllConditionalActionsWeb.TicketLive.Metrics,
    HllConditionalActionsWeb.AttentionLive
  ]

  defp refresh_ticket_counts({:ticket_changed, _ticket}, socket) do
    counts = Tickets.open_counts(socket.assigns[:current_user])
    socket = assign(socket, :nav, %{socket.assigns.nav | tickets: counts})

    if socket.view in @ticket_pages, do: {:cont, socket}, else: {:halt, socket}
  end

  # A ticket arriving rings the browsers that turned alerts on (see
  # `HllConditionalActionsWeb.TicketComponents`), for servers the user sees.
  defp refresh_ticket_counts({:ticket_opened, ticket}, socket) do
    user = socket.assigns[:current_user]

    socket =
      if Accounts.can_access_server?(user, ticket.server_id) do
        push_event(socket, "ticket-alert", %{
          title: gettext("New ticket"),
          body: "#{ticket.player_name || ticket.player_id}",
          url: "/tickets/#{ticket.id}"
        })
      else
        socket
      end

    {:halt, socket}
  end

  # Somebody handed a ticket to this user.
  defp refresh_ticket_counts({:ticket_assigned, ticket, user_id, by}, socket) do
    socket =
      if socket.assigns[:current_user] && socket.assigns.current_user.id == user_id do
        text =
          gettext("%{admin} handed you the ticket of %{player}.",
            admin: by,
            player: ticket.player_name || ticket.player_id
          )

        socket
        |> put_flash(:info, text)
        |> push_event("ticket-alert", %{
          title: gettext("Ticket handed to you"),
          body: text,
          url: "/tickets/#{ticket.id}"
        })
      else
        socket
      end

    {:halt, socket}
  end

  defp refresh_ticket_counts(_message, socket), do: {:cont, socket}

  defp put_current_path(_params, url, socket) do
    path = URI.parse(url).path || "/"
    nav = socket.assigns.nav
    server = scoped_server(nav.servers, path)

    {:cont,
     socket
     |> assign(:current_path, path)
     |> assign(:nav, %{nav | server: server, status: server && LogStream.status(server.id)})}
  end

  # The bell keeps itself current without a reload: every signal that the
  # inbox may have changed (a ticket counts too) schedules one recount, a
  # second later, however many signals arrive in between. Its own messages
  # stop here; the ticket one goes on to the ticket hook and the page.
  @recount_after 1_000

  defp refresh_attention({:attention_changed, _nil}, socket),
    do: {:halt, schedule_recount(socket)}

  defp refresh_attention({:ticket_changed, _ticket}, socket),
    do: {:cont, schedule_recount(socket)}

  defp refresh_attention(:recount_attention, socket) do
    socket = assign(socket, :attention_recount_pending?, false)
    {:halt, assign(socket, :nav, %{socket.assigns.nav | attention: attention_count(socket)})}
  end

  defp refresh_attention(_other, socket), do: {:cont, socket}

  defp schedule_recount(socket) do
    if socket.assigns[:attention_recount_pending?] do
      socket
    else
      Process.send_after(self(), :recount_attention, @recount_after)
      assign(socket, :attention_recount_pending?, true)
    end
  end

  # The open items of the Attention inbox, for the bell in the header.
  # Counted once the page is connected, never on the first static render.
  defp attention_count(socket) do
    user = socket.assigns[:current_user]

    if connected?(socket) and Accounts.can?(user, :view_executions) do
      servers = Servers.list_servers_for(user)
      Attention.count(user, servers, Map.new(servers, &{&1.id, LogStream.status(&1.id)}))
    end
  end

  # Marketplace modules per server the user can reach, so the sidebar only
  # lists pages that exist. Not tied to :view_servers - somebody who only
  # answers tickets still needs to know where tickets are installed.
  defp installed_features(nil), do: %{}

  defp installed_features(user) do
    user |> Servers.list_servers_for() |> Enum.map(& &1.id) |> Features.installed_by_server()
  end

  @doc """
  Whether the navigation should offer a module: installed on the server in
  scope, or on any server when the page is about the organisation.

      iex> nav = %{server: nil, features: %{1 => MapSet.new([:tickets]), 2 => MapSet.new()}}
      iex> HllConditionalActionsWeb.Nav.feature?(nav, :tickets)
      true
      iex> HllConditionalActionsWeb.Nav.feature?(%{nav | server: %{id: 2}}, :tickets)
      false
      iex> HllConditionalActionsWeb.Nav.feature?(nav, nil)
      true
      iex> HllConditionalActionsWeb.Nav.feature?(%{server: nil, features: %{}}, :rules)
      true
  """
  @spec feature?(map() | nil, atom() | nil) :: boolean()
  def feature?(_nav, nil), do: true

  def feature?(%{server: %{id: id}, features: features}, feature),
    do: feature in Map.get(features, id, MapSet.new())

  # No server yet: nothing is hidden, matching `HllConditionalActionsWeb.FeatureGuard`.
  def feature?(%{features: features}, _feature) when features == %{}, do: true

  def feature?(%{features: features}, feature),
    do: Enum.any?(features, fn {_id, set} -> feature in set end)

  def feature?(_nav, _feature), do: true

  defp visible_servers(socket) do
    user = socket.assigns[:current_user]

    if Accounts.can?(user, :view_servers), do: Servers.list_servers_for(user), else: []
  end

  @doc """
  The server a path is about, among the ones the user may see.

      iex> servers = [%{id: 3, name: "EU"}]
      iex> HllConditionalActionsWeb.Nav.scoped_server(servers, "/servers/3/leaderboard")
      %{id: 3, name: "EU"}
      iex> HllConditionalActionsWeb.Nav.scoped_server(servers, "/servers/new")
      nil
  """
  @spec scoped_server([map()], String.t()) :: map() | nil
  def scoped_server(servers, path) do
    case Regex.run(@server_path, path) do
      [_path, id] -> Enum.find(servers, &(to_string(&1.id) == id))
      nil -> nil
    end
  end

  @doc """
  Where switching to another server should go: the same page of that server
  when you are on a server page, its overview otherwise. A page about one
  record of the old server (a match) falls back to its list.

      iex> alias HllConditionalActionsWeb.Nav
      iex> Nav.switch_path("/servers/1/leaderboard", 2)
      "/servers/2/leaderboard"
      iex> Nav.switch_path("/servers/1/matches/9918", 2)
      "/servers/2/matches"
      iex> Nav.switch_path("/rules", 2)
      "/servers/2"
  """
  @spec switch_path(String.t(), term()) :: String.t()
  def switch_path(path, server_id) do
    case Regex.run(~r{^/servers/\d+(/[a-z_-]+)?}, path) do
      [_path, section] -> "/servers/#{server_id}#{section}"
      _other -> "/servers/#{server_id}"
    end
  end
end
