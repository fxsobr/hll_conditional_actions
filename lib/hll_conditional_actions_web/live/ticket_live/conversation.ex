defmodule HllConditionalActionsWeb.TicketLive.Conversation do
  @moduledoc """
  One open ticket's state and events, shared by the ticket page
  (`HllConditionalActionsWeb.TicketLive.Show`) and the Caixa
  (`HllConditionalActionsWeb.InboxLive`), which shows the same conversation
  beside its list.

  `open/3` puts the ticket on the socket (its conversation, the reply form,
  the other admins looking at it, the cards of the caller and of the player
  the ticket is about, read from CRCON in the background) and `leave/1`
  takes it off again, so the Caixa can move from one ticket to the next
  without leaving the page. The LiveView forwards the events in `events/0`
  to `handle_event/3`, and the messages to `ticket_changed/2`,
  `presence_changed/2`, `stop_typing/1` and `player_info_loaded/2`.

  Actions on a player (message, punish, kick, a 2-hour ban) open a small
  sheet asking for the text the player reads; everything else about the
  ticket (priority, owner, the reported player, the transcript, earlier
  tickets) lives in the "more options" sheet.

  Every action needs `:manage_tickets`; a user with only `:view_tickets`
  reads the conversation. Acting on a player (the caller or the one
  reported) also needs `:manage_players` and access to the ticket's server.
  Answering the ticket does not.
  """

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Players
  alias HllConditionalActions.Tickets
  alias HllConditionalActions.Tickets.PlayerInfo
  alias HllConditionalActions.Tickets.Settings
  alias HllConditionalActionsWeb.Presence

  @events ~w(reply typing close quick_reply act act_open act_cancel more more_close
             set_reported transfer refresh_player reopen set_priority assign_me unassign)

  # "Typing" wears off a few seconds after the last keystroke.
  @typing_ms 4_000

  # The hours of the one-click ban beside the reported player.
  @quick_ban_hours 2

  @doc "The events a LiveView showing a conversation forwards to `handle_event/3`."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "How long the one-click ban lasts, in hours."
  @spec quick_ban_hours() :: pos_integer()
  def quick_ban_hours, do: @quick_ban_hours

  @doc """
  Shows a ticket: assigns everything the conversation and its side panels
  read, starts following who else is on it, and asks CRCON for the player
  cards. `back` is where to go when the ticket can no longer be read.
  """
  @spec open(Phoenix.LiveView.Socket.t(), map(), keyword()) :: Phoenix.LiveView.Socket.t()
  def open(socket, ticket, opts) do
    user = socket.assigns.current_user
    ticket = if connected?(socket), do: Tickets.infer_reported(ticket), else: ticket

    if connected?(socket) do
      topic = Presence.ticket_topic(ticket.id)
      Phoenix.PubSub.subscribe(HllConditionalActions.PubSub, topic)
      Presence.track(self(), topic, to_string(user.id), %{name: user_name(user), typing: false})
    end

    socket
    |> assign(:others, Presence.others(ticket.id, user.id))
    |> assign(:typing_timer, nil)
    |> assign(:draft_base, nil)
    |> assign(:note_mode, false)
    |> assign(:back, Keyword.fetch!(opts, :back))
    |> assign(:can_manage?, Accounts.can?(user, :manage_tickets))
    |> assign(:can_act?, can_act?(user, ticket))
    |> assign(:settings, Tickets.get_settings(ticket.server_id))
    |> assign(:reply, reply_form(""))
    |> assign(:quick_reply, nil)
    |> assign(:pending_act, nil)
    |> assign(:act_form, act_form(""))
    |> assign(:more_open?, false)
    |> assign(:player_info, nil)
    |> assign(:cited_info, nil)
    |> assign(:assignable, Tickets.assignable_users(ticket))
    |> assign_ticket(ticket)
    |> load_player_info()
  end

  @doc """
  Stops showing the open ticket, if any: the other admins no longer see
  this one on it.
  """
  @spec leave(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def leave(%{assigns: %{ticket: %{id: id}}} = socket) do
    if timer = socket.assigns[:typing_timer], do: Process.cancel_timer(timer)

    if connected?(socket) do
      topic = Presence.ticket_topic(id)
      Presence.untrack(self(), topic, to_string(socket.assigns.current_user.id))
      Phoenix.PubSub.unsubscribe(HllConditionalActions.PubSub, topic)
    end

    socket
    |> assign(:ticket, nil)
    |> assign(:typing_timer, nil)
    |> assign(:others, [])
    |> assign(:pending_act, nil)
    |> assign(:more_open?, false)
  end

  def leave(socket), do: assign(socket, :ticket, nil)

  defp assign_ticket(socket, ticket) do
    user = socket.assigns.current_user

    socket
    |> assign(:ticket, ticket)
    |> assign(:history, Tickets.player_history(user, ticket))
    |> assign(:ticket_count, Tickets.player_ticket_count(user, ticket.player_id))
    |> assign(:transcript, Tickets.transcript(ticket))
  end

  defp reload(socket) do
    case Tickets.fetch_ticket(socket.assigns.current_user, socket.assigns.ticket.id) do
      {:ok, ticket} ->
        reported_changed? = ticket.reported_player_id != socket.assigns.ticket.reported_player_id
        socket = assign_ticket(socket, ticket)
        if reported_changed?, do: load_player_info(socket), else: socket

      :error ->
        push_navigate(socket, to: socket.assigns.back)
    end
  end

  @doc """
  The player a ticket is about, as `{id, name}`: the reported player, or
  for a ticket a rule opened, the ticket's own player. Nil for a call that
  names nobody.
  """
  @spec cited(map()) :: {String.t(), String.t()} | nil
  def cited(%{reported_player_id: id} = ticket) when is_binary(id) and id != "",
    do: {id, ticket.reported_player_name || id}

  def cited(%{source: :rule} = ticket),
    do: {ticket.player_id, ticket.player_name || ticket.player_id}

  def cited(_ticket), do: nil

  # The result carries the ticket id: the Caixa may have moved on to another
  # ticket by the time CRCON answers.
  defp load_player_info(socket) do
    if connected?(socket) do
      ticket = socket.assigns.ticket

      start_async(socket, :player_info, fn -> fetch_player_info(ticket) end)
    else
      socket
    end
  end

  defp fetch_player_info(ticket) do
    info = PlayerInfo.fetch(ticket.server, ticket.player_id)

    cited =
      case cited(ticket) do
        {id, _name} when id != ticket.player_id -> PlayerInfo.fetch(ticket.server, id)
        {_same, _name} -> info
        nil -> nil
      end

    {ticket.id, %{info: info, cited: cited}}
  end

  defp reply_form(body), do: to_form(%{"body" => body}, as: :reply)
  defp act_form(reason), do: to_form(%{"reason" => reason}, as: :act)

  # ── Messages ───────────────────────────────────────────────────────────────

  @doc "The player cards arrived from CRCON (or failed to)."
  @spec player_info_loaded(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def player_info_loaded(%{assigns: %{ticket: %{id: id}}} = socket, {:ok, {id, cards}}) do
    socket
    |> assign(:player_info, cards.info)
    |> assign(:cited_info, cards.cited)
  end

  def player_info_loaded(%{assigns: %{ticket: %{}}} = socket, {:exit, _reason}) do
    socket
    |> assign(:player_info, :error)
    |> assign(:cited_info, :error)
  end

  def player_info_loaded(socket, _stale), do: socket

  @doc """
  A ticket changed somewhere: reread the open one when it is that ticket,
  or another ticket of the same player (the "earlier tickets" list).
  """
  @spec ticket_changed(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def ticket_changed(%{assigns: %{ticket: %{id: id}}} = socket, %{id: id}), do: reload(socket)

  def ticket_changed(%{assigns: %{ticket: %{player_id: player_id}}} = socket, %{
        player_id: player_id
      }),
      do: reload(socket)

  def ticket_changed(socket, _other), do: socket

  @doc "Someone arrived on, left or started typing on a ticket."
  @spec presence_changed(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def presence_changed(%{assigns: %{ticket: %{id: id}}} = socket, topic) do
    if topic == Presence.ticket_topic(id),
      do: assign(socket, :others, Presence.others(id, socket.assigns.current_user.id)),
      else: socket
  end

  def presence_changed(socket, _topic), do: socket

  @doc "The typing indicator wore off."
  @spec stop_typing(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def stop_typing(%{assigns: %{ticket: %{}}} = socket),
    do: socket |> assign(:typing_timer, nil) |> set_typing(false)

  def stop_typing(socket), do: socket

  # ── Events ─────────────────────────────────────────────────────────────────

  @doc "Handles one of `events/0` for the open ticket."
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event(_event, _params, %{assigns: %{ticket: nil}} = socket), do: {:noreply, socket}

  # The reply box sends to the player, or keeps the text as a note.
  def handle_event("reply", %{"reply" => %{"body" => body}, "mode" => "note"}, socket) do
    with_manage(socket, fn socket ->
      case Tickets.add_note(socket.assigns.ticket, socket.assigns.current_user, body) do
        {:ok, _message} ->
          socket
          |> assign(:reply, reply_form(""))
          |> assign(:note_mode, false)
          |> assign(:quick_reply, nil)

        {:error, _reason} ->
          socket
      end
    end)
  end

  # Typing in the answer box: the others see it, and the conversation as it
  # stands now is what the answer is written against.
  def handle_event("typing", %{"reply" => %{"body" => body}} = params, socket) do
    socket =
      socket
      |> assign(:reply, reply_form(body))
      |> assign(:note_mode, params["mode"] == "note")
      |> assign(:draft_base, socket.assigns.draft_base || length(socket.assigns.ticket.messages))
      |> then(fn socket ->
        if String.trim(body) == "", do: assign(socket, :quick_reply, nil), else: socket
      end)
      |> set_typing(String.trim(body) != "")

    {:noreply, socket}
  end

  def handle_event("reply", %{"reply" => %{"body" => body}}, socket) do
    if changed_under_me?(socket) do
      # Show what arrived, keep the draft, and let a second click send it.
      {:noreply,
       socket
       |> assign(:reply, reply_form(body))
       |> assign(:draft_base, length(socket.assigns.ticket.messages))
       |> put_flash(
         :error,
         gettext("New messages arrived while you were typing. Read them, then send again.")
       )}
    else
      send_reply(socket, body)
    end
  end

  def handle_event("close", params, socket) do
    with_manage(socket, fn socket ->
      reason = Enum.find(close_reasons(), "resolved", &(&1 == params["reason"]))
      {:ok, _ticket} = Tickets.close(socket.assigns.ticket, socket.assigns.current_user, reason)
      put_flash(socket, :info, gettext("Ticket closed."))
    end)
  end

  # A quick reply fills the box instead of sending, so it can be adjusted;
  # its placeholders are filled for this ticket.
  def handle_event("quick_reply", %{"index" => index}, socket) do
    item =
      case Integer.parse(to_string(index)) do
        {index, ""} -> Enum.at(Settings.reply_items(socket.assigns.settings), index)
        _other -> nil
      end

    case item do
      nil ->
        {:noreply, socket}

      item ->
        {:noreply,
         socket
         |> assign(:reply, reply_form(fill_reply(item["body"], socket)))
         |> assign(:note_mode, false)
         |> assign(:quick_reply, item)}
    end
  end

  # An action on a player opens its sheet: what the player reads.
  def handle_event("act_open", %{"action" => action} = params, socket) do
    with_act(socket, fn socket ->
      ticket = socket.assigns.ticket

      target =
        case {params["target"], cited(ticket)} do
          {"caller", _cited} -> {ticket.player_id, ticket.player_name || ticket.player_id}
          {_reported, {id, name}} -> {id, name}
          {_reported, nil} -> {ticket.player_id, ticket.player_name || ticket.player_id}
        end

      case Enum.find(Tickets.player_actions(), &(to_string(&1) == action)) do
        nil ->
          socket

        action ->
          socket
          |> assign(:pending_act, %{action: action, target: target})
          |> assign(:act_form, act_form(default_reason(action, ticket)))
      end
    end)
  end

  def handle_event("act_cancel", _params, socket),
    do: {:noreply, socket |> assign(:pending_act, nil) |> assign(:act_form, act_form(""))}

  def handle_event("act", %{"act" => params}, %{assigns: %{pending_act: %{} = pending}} = socket) do
    with_act(socket, fn socket ->
      {target_id, _name} = pending.target

      case Tickets.act(
             socket.assigns.ticket,
             socket.assigns.current_user,
             pending.action,
             params["reason"],
             target_id,
             duration_hours: @quick_ban_hours
           ) do
        {:ok, _message} ->
          socket
          |> put_flash(:info, gettext("Done. It is recorded in the conversation."))
          |> assign(:pending_act, nil)
          |> assign(:act_form, act_form(""))
          |> load_player_info()

        {:error, :empty_reason} ->
          socket
          |> assign(:act_form, act_form(params["reason"] || ""))
          |> put_flash(:error, gettext("Write what the player reads."))

        {:error, :unknown_action} ->
          socket

        {:error, :forbidden} ->
          socket
          |> assign(:pending_act, nil)
          |> put_flash(:error, gettext("You do not have access to that page."))

        {:error, :bad_duration} ->
          put_flash(socket, :error, gettext("The ban lasts between 1 hour and 1 year."))

        {:error, message} ->
          put_flash(socket, :error, gettext("CRCON refused it: %{reason}", reason: message))
      end
    end)
  end

  def handle_event("act", _params, socket), do: {:noreply, socket}

  def handle_event("more", _params, socket), do: {:noreply, assign(socket, :more_open?, true)}

  def handle_event("more_close", _params, socket),
    do: {:noreply, assign(socket, :more_open?, false)}

  # The player the ticket is about: one of the players seen before the call,
  # an ID typed by hand, or nobody.
  def handle_event("set_reported", %{"reported" => params}, socket) do
    with_manage(socket, fn socket ->
      ticket = socket.assigns.ticket
      typed = String.trim(params["player_id"] || "")
      picked = params["pick"] || ""

      {id, name} =
        cond do
          typed != "" -> {typed, typed}
          picked == "" -> {nil, nil}
          true -> {picked, candidate_name(ticket, picked)}
        end

      {:ok, _ticket} = Tickets.set_reported(ticket, id, name)
      put_flash(socket, :info, gettext("Saved."))
    end)
  end

  def handle_event("transfer", %{"user_id" => ""}, socket) do
    with_manage(socket, fn socket ->
      {:ok, _ticket} = Tickets.assign(socket.assigns.ticket, nil, socket.assigns.current_user)
      socket
    end)
  end

  def handle_event("transfer", %{"user_id" => user_id}, socket) do
    with_manage(socket, fn socket ->
      case Enum.find(socket.assigns.assignable, &(to_string(&1.id) == user_id)) do
        nil ->
          socket

        user ->
          {:ok, _ticket} =
            Tickets.assign(socket.assigns.ticket, user, socket.assigns.current_user)

          put_flash(socket, :info, gettext("Ticket handed to %{name}.", name: user_name(user)))
      end
    end)
  end

  def handle_event("refresh_player", _params, socket),
    do:
      {:noreply,
       socket |> assign(:player_info, nil) |> assign(:cited_info, nil) |> load_player_info()}

  def handle_event("reopen", _params, socket) do
    with_manage(socket, fn socket ->
      case Tickets.reopen(socket.assigns.ticket) do
        {:ok, _ticket} ->
          put_flash(socket, :info, gettext("Ticket reopened."))

        {:error, _full} ->
          put_flash(
            socket,
            :error,
            gettext("The player already has another ticket open on this server.")
          )
      end
    end)
  end

  def handle_event("set_priority", %{"priority" => priority}, socket) do
    with_manage(socket, fn socket ->
      {:ok, _ticket} = Tickets.set_priority(socket.assigns.ticket, priority)
      socket
    end)
  end

  def handle_event("assign_me", _params, socket) do
    with_manage(socket, fn socket ->
      {:ok, _ticket} = Tickets.assign(socket.assigns.ticket, socket.assigns.current_user)
      socket
    end)
  end

  def handle_event("unassign", _params, socket) do
    with_manage(socket, fn socket ->
      {:ok, _ticket} = Tickets.assign(socket.assigns.ticket, nil)
      socket
    end)
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp send_reply(socket, body) do
    socket = socket |> assign(:draft_base, nil) |> set_typing(false)
    quick = socket.assigns.quick_reply

    with_manage(socket, fn socket ->
      %{ticket: ticket, current_user: user} = socket.assigns

      ticket
      |> Tickets.reply(user, body, quick_reply: quick && quick["title"])
      |> replied(socket, quick)
    end)
  end

  defp replied({:ok, message}, socket, quick) do
    %{ticket: ticket, current_user: user} = socket.assigns
    if quick && quick["closes"], do: Tickets.close(ticket, user, "resolved")

    socket
    |> assign(:reply, reply_form(""))
    |> assign(:quick_reply, nil)
    |> warn_undelivered(message)
  end

  defp replied({:error, :empty}, socket, _quick), do: socket

  defp replied({:error, :closed}, socket, _quick),
    do: put_flash(socket, :error, gettext("This ticket is closed. Reopen it to answer."))

  defp replied({:error, _changeset}, socket, _quick),
    do: put_flash(socket, :error, gettext("The answer is too long."))

  defp warn_undelivered(socket, %{delivery: :failed}) do
    socket
    |> put_flash(
      :error,
      gettext("Saved, but the player did not receive it. They may have left the server.")
    )
    |> load_player_info()
  end

  defp warn_undelivered(socket, _message), do: socket

  # The placeholders a quick reply can use, filled for the open ticket.
  defp fill_reply(body, socket) do
    %{ticket: ticket, settings: settings, current_user: user} = socket.assigns

    map =
      case HllConditionalActions.Engine.Runner.current_map(ticket.server_id) do
        map when is_binary(map) -> map
        _unknown -> nil
      end

    vars =
      ticket
      |> Tickets.notice_vars(settings, ticket.server)
      |> Map.merge(%{"admin" => user_name(user), "admin_name" => user_name(user)})
      |> then(fn vars -> if map, do: Map.put(vars, "map", map), else: vars end)

    Tickets.fill(body || "", vars)
  end

  defp default_reason(:message, _ticket), do: ""

  defp default_reason(_action, ticket),
    do: gettext("Reported in ticket #%{id}", id: ticket.id)

  # The players the context names, for the "who is it about" picker.
  @doc false
  def candidates(ticket) do
    (ticket.context || [])
    |> Enum.flat_map(fn line ->
      [{line["actor_id"], line["actor"]}, {line["target_id"], line["target"]}]
    end)
    |> Enum.filter(fn {id, name} -> is_binary(id) and id != "" and is_binary(name) end)
    |> Enum.reject(fn {id, _name} -> id == ticket.player_id end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp candidate_name(ticket, id) do
    case List.keyfind(candidates(ticket), id, 0) do
      {^id, name} -> name
      nil -> id
    end
  end

  defp with_manage(socket, fun) do
    if socket.assigns.can_manage? do
      {:noreply, socket |> fun.() |> reload()}
    else
      {:noreply, put_flash(socket, :error, gettext("You do not have access to that page."))}
    end
  end

  # Acting on a player goes through CRCON: it needs the ticket permission
  # (the action is recorded in the conversation) and the player one.
  defp with_act(socket, fun) do
    if socket.assigns.can_manage? and socket.assigns.can_act? do
      with_manage(socket, fun)
    else
      {:noreply,
       socket
       |> assign(:pending_act, nil)
       |> put_flash(:error, gettext("You do not have access to that page."))}
    end
  end

  defp can_act?(user, ticket), do: Players.can_act?(user, ticket.server_id)

  defp set_typing(socket, typing?) do
    if timer = socket.assigns.typing_timer, do: Process.cancel_timer(timer)

    if connected?(socket) do
      user = socket.assigns.current_user

      Presence.update(
        self(),
        Presence.ticket_topic(socket.assigns.ticket.id),
        to_string(user.id),
        %{name: user_name(user), typing: typing?}
      )
    end

    timer = if typing?, do: Process.send_after(self(), :stop_typing, @typing_ms)
    assign(socket, :typing_timer, timer)
  end

  # Someone else wrote on the ticket since this admin started typing.
  defp changed_under_me?(%{assigns: %{draft_base: nil}}), do: false

  defp changed_under_me?(%{assigns: %{draft_base: base, ticket: ticket, current_user: me}}) do
    ticket.messages
    |> Enum.drop(base)
    |> Enum.any?(&(&1.user_id != me.id))
  end

  @doc "Why a ticket can be closed, in the order the menu lists them."
  @spec close_reasons() :: [String.t()]
  def close_reasons, do: ~w(resolved duplicate no_action player_left other)

  defp user_name(user), do: user.name || user.username
end
