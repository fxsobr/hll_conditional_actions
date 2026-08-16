defmodule HllConditionalActionsWeb.FeedLive do
  @moduledoc """
  Live feed of what CRCON is reporting, across every server.

  Useful for writing rules: it shows the exact events the engine sees, so you
  can confirm a trigger fires before wiring an action to it.

  Events arrive as PubSub messages and are kept in a LiveView stream capped at
  a few hundred entries, so a busy fleet cannot grow the socket without bound.
  """

  use HllConditionalActionsWeb, :live_view

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_live_feed}}

  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Servers

  @limit 300

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    servers = Servers.list_servers_for(socket.assigns[:current_user])

    if connected?(socket), do: Enum.each(servers, &LogStream.subscribe(&1.id))

    {:ok,
     socket
     |> assign(:page_title, gettext("Live feed"))
     |> assign(:servers, Map.new(servers, &{&1.id, &1}))
     |> assign(:paused?, false)
     |> assign(:type_filter, nil)
     |> assign(:server_filter, nil)
     |> assign(:count, 0)
     |> stream(:events, [], limit: @limit)}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_pause", _params, socket) do
    {:noreply, update(socket, :paused?, &(not &1))}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, socket |> stream(:events, [], reset: true) |> assign(:count, 0)}
  end

  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:type_filter, blank_to_nil(params["type"]))
     |> assign(:server_filter, blank_to_nil(params["server_id"]))}
  end

  @impl Phoenix.LiveView
  def handle_info({:crcon_event, event}, socket) do
    if socket.assigns.paused? or not visible?(event, socket) do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> stream_insert(:events, to_row(event, socket), at: 0, limit: @limit)
       |> update(:count, &(&1 + 1))}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp visible?(event, socket) do
    type_ok? =
      is_nil(socket.assigns.type_filter) or
        to_string(event.type) == socket.assigns.type_filter

    server_ok? =
      is_nil(socket.assigns.server_filter) or
        to_string(event.server_id) == socket.assigns.server_filter

    type_ok? and server_ok?
  end

  # The stream needs a stable dom id; the raw log has no id of its own, so
  # derive one from the counter.
  defp to_row(event, socket) do
    server = Map.get(socket.assigns.servers, event.server_id)

    %{
      id: "event-#{socket.assigns.count}",
      type: event.type,
      action: event.action,
      server_name: server && server.name,
      player_name: event.player_name,
      target_player_name: event.target_player_name,
      weapon: event.weapon,
      message: event.chat_message,
      occurred_at: event.occurred_at
    }
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp type_options do
    [
      :player_connected,
      :player_disconnected,
      :player_kill,
      :player_team_kill,
      :player_chat,
      :team_switch,
      :match_start,
      :match_end,
      :admin_action
    ]
    |> Enum.map(&{Labels.event_type(&1), to_string(&1)})
  end

  defp event_tone(:player_team_kill), do: "error"
  defp event_tone(:player_kill), do: "warning"
  defp event_tone(:player_chat), do: "info"
  defp event_tone(:player_connected), do: "success"
  defp event_tone(type) when type in [:match_start, :match_end], do: "primary"
  defp event_tone(_type), do: "ghost"

  defp describe(%{type: :player_chat} = row), do: row.message

  defp describe(%{type: type} = row) when type in [:player_kill, :player_team_kill] do
    "#{row.player_name} → #{row.target_player_name} (#{row.weapon})"
  end

  defp describe(row), do: row.player_name

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      page_title={gettext("Live feed")}
      page_subtitle={gettext("Events arriving from CRCON, as they happen")}
    >
      <:actions>
        <.button
          type="button"
          size="sm"
          variant={if @paused?, do: "soft", else: "ghost"}
          color={if @paused?, do: "warning", else: "gray"}
          icon={if @paused?, do: "hero-play", else: "hero-pause"}
          phx-click="toggle_pause"
          aria-pressed={to_string(@paused?)}
          label={if @paused?, do: gettext("Resume"), else: gettext("Pause")}
        />
        <.button
          type="button"
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-trash"
          phx-click="clear"
          label={gettext("Clear")}
        />
      </:actions>

      <.filter_bar id="feed-filters" on_change="filter">
        <.filter_select
          name="server_id"
          label={gettext("Server")}
          value={@server_filter}
          prompt={gettext("Every server")}
          options={Enum.map(@servers, fn {id, server} -> {server.name, id} end)}
        />
        <.filter_select
          name="type"
          label={gettext("Event")}
          value={@type_filter}
          prompt={gettext("Every event")}
          options={type_options()}
        />

        <p class="ml-auto px-1 text-xs text-muted" aria-live="polite">
          <%= if @paused? do %>
            {gettext("Paused — new events are being dropped.")}
          <% else %>
            {ngettext("%{count} event received", "%{count} events received", @count, count: @count)}
          <% end %>
        </p>
      </.filter_bar>

      <.card padded={false}>
        <div class="max-h-[65vh] overflow-y-auto">
          <table class="table-collapse app-table app-table-pin" role="log">
            <thead class="text-xs uppercase tracking-wide text-muted">
              <tr>
                <th class="w-24">{gettext("Time")}</th>

                <th class="w-32">{gettext("Event")}</th>

                <th class="w-40">{gettext("Server")}</th>

                <th>{gettext("Details")}</th>
              </tr>
            </thead>

            <tbody id="feed" phx-update="stream" class="divide-y divide-base-300">
              <tr :for={{dom_id, row} <- @streams.events} id={dom_id}>
                <td data-cell="lead" class="font-mono text-xs text-muted">
                  <.local_time id={"#{dom_id}-at"} at={row.occurred_at} format="time" />
                </td>

                <td data-label={gettext("Event")}>
                  <.tone_badge tone={event_tone(row.type)}>
                    {Labels.event_type(row.type)}
                  </.tone_badge>
                </td>

                <td data-label={gettext("Server")} class="truncate text-xs text-subtle">
                  {row.server_name}
                </td>

                <td data-label={gettext("Details")} class="max-w-0 truncate text-sm max-sm:max-w-none">
                  {describe(row)}
                </td>
              </tr>
            </tbody>
          </table>

          <p :if={@count == 0} class="py-10 text-center text-sm text-muted">
            {gettext("Waiting for events. Nothing has happened on your servers yet.")}
          </p>
        </div>
      </.card>
    </Layouts.app>
    """
  end
end
