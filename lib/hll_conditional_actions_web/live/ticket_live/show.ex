defmodule HllConditionalActionsWeb.TicketLive.Show do
  @moduledoc """
  One ticket: the conversation with the player, the reply box with the
  server's quick replies, the player's card (online or not, level, VIP,
  penalties) and the controls to assign, flag, punish and close.

  Reachable as `/tickets/:id` and `/servers/:server_id/tickets/:id`; either
  way the user must be allowed on the ticket's server. The page follows the
  ticket live, so a player's new line shows up while the admin reads. The
  player card is read from CRCON in the background, and again after each
  action, so a slow CRCON never holds the conversation back.

  The state and the events live in
  `HllConditionalActionsWeb.TicketLive.Conversation`, shared with the Caixa
  (`HllConditionalActionsWeb.InboxLive`), which shows the same conversation
  beside its list.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_tickets}}

  alias HllConditionalActions.Tickets
  alias HllConditionalActionsWeb.TicketComponents
  alias HllConditionalActionsWeb.TicketLive.Conversation

  @impl Phoenix.LiveView
  def mount(%{"id" => id} = params, _session, socket) do
    case Tickets.fetch_ticket(socket.assigns.current_user, id) do
      # Ticket changes arrive through `HllConditionalActionsWeb.Nav`, which
      # subscribes every user who may read tickets.
      {:ok, ticket} ->
        {:ok,
         socket
         |> assign(:page_title, ticket.player_name || ticket.player_id)
         |> assign(:server_scope, params["server_id"])
         |> Conversation.open(ticket, back: back_path(params))}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Ticket not found."))
         |> push_navigate(to: back_path(params))}
    end
  end

  defp back_path(%{"server_id" => server_id}), do: ~p"/servers/#{server_id}/tickets"
  defp back_path(_params), do: ~p"/tickets"

  @impl Phoenix.LiveView
  def handle_async(:player_info, result, socket),
    do: {:noreply, Conversation.player_info_loaded(socket, result)}

  @impl Phoenix.LiveView
  def handle_event(event, params, socket), do: Conversation.handle_event(event, params, socket)

  @impl Phoenix.LiveView
  def handle_info({:ticket_changed, ticket}, socket),
    do: {:noreply, Conversation.ticket_changed(socket, ticket)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic}, socket),
    do: {:noreply, Conversation.presence_changed(socket, topic)}

  def handle_info(:stop_typing, socket), do: {:noreply, Conversation.stop_typing(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp history_path(nil), do: fn earlier -> ~p"/tickets/#{earlier.id}" end

  defp history_path(server_id),
    do: fn earlier -> ~p"/servers/#{server_id}/tickets/#{earlier.id}" end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      page_subtitle={@ticket.server.name}
      back={@back}
      back_label={gettext("All tickets")}
    >
      <:actions>
        <.link
          navigate={~p"/inbox?#{[ticket: @ticket.id]}"}
          class="inline-flex h-9 items-center gap-1.5 rounded-full px-3 text-sm text-subtle transition-colors hover:bg-base-100 hover:text-base-content"
        >
          <.icon name="hero-inbox" class="size-4" /> {gettext("Open in the inbox")}
        </.link>
      </:actions>

      <TicketComponents.frame
        id="ticket-grid"
        class="grid grid-cols-[minmax(0,1fr)] gap-5 md:mt-4 min-[85rem]:grid-cols-[minmax(0,1fr)_20rem]"
      >
        <TicketComponents.conversation
          ticket={@ticket}
          reply={@reply}
          settings={@settings}
          others={@others}
          can_manage?={@can_manage?}
          can_act?={@can_act?}
          player_info={@player_info}
          cited_info={@cited_info}
          ticket_count={@ticket_count}
          note_mode={@note_mode}
          current_user={@current_user}
        />
        <TicketComponents.ticket_aside
          ticket={@ticket}
          player_info={@player_info}
          cited_info={@cited_info}
          ticket_count={@ticket_count}
          can_manage?={@can_manage?}
          can_act?={@can_act?}
          class="max-[85rem]:hidden"
        />
      </TicketComponents.frame>
      <TicketComponents.ticket_sheets
        ticket={@ticket}
        pending_act={@pending_act}
        act_form={@act_form}
        more_open?={@more_open?}
        can_manage?={@can_manage?}
        assignable={@assignable}
        history={@history}
        transcript={@transcript}
        history_path={history_path(@server_scope)}
      />
    </Layouts.app>
    """
  end
end
