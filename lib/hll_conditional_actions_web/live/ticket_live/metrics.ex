defmodule HllConditionalActionsWeb.TicketLive.Metrics do
  @moduledoc """
  How the team handles tickets: how many came in, how long players waited for
  a first answer, who answered, at what hours players call, and which players
  call the most.

  Global under `/tickets/metrics`, or one server's under
  `/servers/:server_id/tickets/metrics`. Hours follow the server's time zone,
  or on the global page the zone most of the user's servers use.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_tickets}}

  alias HllConditionalActions.Servers
  alias HllConditionalActions.Tickets

  @periods [1, 7, 30]

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    servers = Servers.list_servers_for(socket.assigns.current_user)
    server = Enum.find(servers, &(to_string(&1.id) == params["server_id"]))

    if params["server_id"] && is_nil(server) do
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to that page."))
       |> push_navigate(to: ~p"/tickets")}
    else
      if connected?(socket), do: Tickets.subscribe()

      {:ok,
       socket
       |> assign(:page_title, gettext("Ticket metrics"))
       |> assign(:server, server)
       |> assign(:timezone, timezone(server, servers))
       |> assign(:days, 7)
       |> load()}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("period", %{"days" => days}, socket) do
    days = Enum.find(@periods, 7, &(to_string(&1) == days))
    {:noreply, socket |> assign(:days, days) |> load()}
  end

  @impl Phoenix.LiveView
  def handle_info({:ticket_changed, _ticket}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    %{server: server, days: days, current_user: user, timezone: timezone} = socket.assigns

    assign(socket,
      metrics:
        Tickets.metrics(user, days: days, server_id: server && server.id, timezone: timezone)
    )
  end

  @doc """
  The time zone the hours are shown in: the server's, or the one most of the
  servers use when looking at all of them.

      iex> alias HllConditionalActionsWeb.TicketLive.Metrics
      iex> servers = [%{timezone: "America/Sao_Paulo"}, %{timezone: "America/Sao_Paulo"}, %{timezone: "Europe/Paris"}]
      iex> Metrics.timezone(nil, servers)
      "America/Sao_Paulo"
      iex> Metrics.timezone(%{timezone: "Europe/Paris"}, servers)
      "Europe/Paris"
      iex> Metrics.timezone(nil, [])
      "Etc/UTC"
  """
  @spec timezone(map() | nil, [map()]) :: String.t()
  def timezone(%{timezone: zone}, _servers) when is_binary(zone) and zone != "", do: zone

  def timezone(_server, servers) do
    servers
    |> Enum.map(& &1.timezone)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
    |> Enum.max_by(fn {_zone, count} -> count end, fn -> {"Etc/UTC", 0} end)
    |> elem(0)
  end

  @doc """
  A duration in seconds, the way an admin says it.

      iex> HllConditionalActionsWeb.TicketLive.Metrics.duration(nil)
      "–"
      iex> HllConditionalActionsWeb.TicketLive.Metrics.duration(42.4)
      "42s"
      iex> HllConditionalActionsWeb.TicketLive.Metrics.duration(150)
      "2m 30s"
      iex> HllConditionalActionsWeb.TicketLive.Metrics.duration(7260)
      "2h 1m"
  """
  @spec duration(number() | nil) :: String.t()
  def duration(nil), do: "–"

  def duration(seconds) do
    seconds = round(seconds)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns = assign(assigns, :peak, Enum.max([1 | assigns.metrics.by_hour]))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      page_subtitle={if @server, do: @server.name, else: gettext("All servers")}
    >
      <:actions>
        <.button
          link_type="live_redirect"
          to={if @server, do: ~p"/servers/#{@server.id}/tickets", else: ~p"/tickets"}
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-arrow-left"
          label={gettext("Tickets")}
        />
      </:actions>

      <form id="metrics-period" phx-change="period" class="w-fit">
        <.segmented
          name="days"
          label={gettext("Period")}
          value={@days}
          options={[
            {gettext("24 hours"), 1},
            {gettext("7 days"), 7},
            {gettext("30 days"), 30}
          ]}
        />
      </form>

      <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4" id="metrics-kpis">
        <.stat
          icon="hero-inbox-arrow-down"
          label={gettext("Opened")}
          value={@metrics.opened}
          hint={gettext("%{closed} closed", closed: @metrics.closed)}
        />
        <.stat
          icon="hero-chat-bubble-left-ellipsis"
          tone={if @metrics.open_now > 0, do: "warning", else: "neutral"}
          label={gettext("Open now")}
          value={@metrics.open_now}
          hint={gettext("not closed yet")}
        />
        <.stat
          icon="hero-clock"
          tone="info"
          label={gettext("Median first answer")}
          value={duration(@metrics.median_response_seconds)}
          hint={gettext("half of the players waited less than this")}
        />
        <.stat
          icon="hero-bolt"
          label={gettext("Average first answer")}
          value={duration(@metrics.average_response_seconds)}
          hint={
            ngettext(
              "over 1 answered ticket",
              "over %{count} answered tickets",
              @metrics.answered
            )
          }
        />
      </div>

      <.card
        title={gettext("Tickets by hour of the day")}
        subtitle={gettext("Time zone: %{zone}", zone: @timezone)}
        icon="hero-chart-bar"
        id="metrics-by-hour"
      >
        <div
          class="flex h-40 items-end gap-0.5 border-b border-base-300"
          role="img"
          aria-label={gettext("Tickets opened per hour of the day")}
        >
          <div
            :for={{count, hour} <- Enum.with_index(@metrics.by_hour)}
            class="group relative flex h-full flex-1 items-end"
            title={ngettext("%{hour}h: 1 ticket", "%{hour}h: %{count} tickets", count, hour: hour)}
          >
            <div
              class="w-full rounded-t bg-primary/70 transition-colors group-hover:bg-primary"
              style={"height: #{if count == 0, do: 0, else: max(3, round(count / @peak * 100))}%"}
            >
            </div>
          </div>
        </div>
        <div class="flex justify-between text-xs text-muted" aria-hidden="true">
          <span>0h</span><span>6h</span><span>12h</span><span>18h</span><span>23h</span>
        </div>
        <table class="sr-only">
          <caption>{gettext("Tickets opened per hour of the day")}</caption>
          <tr :for={{count, hour} <- Enum.with_index(@metrics.by_hour)}>
            <th scope="row">{hour}h</th>
            <td>{count}</td>
          </tr>
        </table>
      </.card>

      <div class="grid gap-4 lg:grid-cols-3">
        <.card title={gettext("By admin")} icon="hero-user-group" id="metrics-by-admin">
          <p :if={@metrics.by_admin == []} class="text-sm text-muted">
            {gettext("No answers in this period.")}
          </p>
          <table :if={@metrics.by_admin != []} class="w-full text-sm">
            <thead>
              <tr class="text-left text-xs text-muted">
                <th class="py-1 font-normal">{gettext("Admin")}</th>
                <th class="py-1 text-right font-normal">{gettext("Answers")}</th>
                <th class="py-1 text-right font-normal">{gettext("Tickets")}</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-300">
              <tr :for={{name, answers, tickets} <- @metrics.by_admin}>
                <td class="truncate py-1.5">{name}</td>
                <td class="py-1.5 text-right tabular-nums">{answers}</td>
                <td class="py-1.5 text-right tabular-nums">{tickets}</td>
              </tr>
            </tbody>
          </table>
        </.card>

        <.card
          :if={is_nil(@server)}
          title={gettext("By server")}
          icon="hero-server-stack"
          id="metrics-by-server"
        >
          <p :if={@metrics.by_server == []} class="text-sm text-muted">
            {gettext("No tickets in this period.")}
          </p>
          <ul class="divide-y divide-base-300 text-sm">
            <li :for={{name, count} <- @metrics.by_server} class="flex justify-between py-1.5">
              <span class="truncate">{name}</span>
              <span class="tabular-nums">{count}</span>
            </li>
          </ul>
        </.card>

        <.card
          title={gettext("Players who call the most")}
          icon="hero-megaphone"
          id="metrics-top-players"
        >
          <p :if={@metrics.top_players == []} class="text-sm text-muted">
            {gettext("No tickets in this period.")}
          </p>
          <ul class="divide-y divide-base-300 text-sm">
            <li
              :for={{player_id, name, count} <- @metrics.top_players}
              class="flex justify-between gap-2 py-1.5"
            >
              <.link navigate={~p"/players/#{player_id}"} class="truncate hover:underline">
                {name || player_id}
              </.link>
              <span class="tabular-nums">{count}</span>
            </li>
          </ul>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
