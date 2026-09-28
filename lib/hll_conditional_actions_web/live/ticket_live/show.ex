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
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_tickets}}

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Tickets
  alias HllConditionalActions.Tickets.PlayerInfo
  alias HllConditionalActionsWeb.Presence
  alias HllConditionalActionsWeb.TicketComponents

  @impl Phoenix.LiveView
  def mount(%{"id" => id} = params, _session, socket) do
    user = socket.assigns.current_user

    case Tickets.fetch_ticket(user, id) do
      {:ok, ticket} ->
        if connected?(socket) do
          Tickets.subscribe()
          topic = Presence.ticket_topic(ticket.id)
          Phoenix.PubSub.subscribe(HllConditionalActions.PubSub, topic)

          Presence.track(self(), topic, to_string(user.id), %{
            name: user_name(user),
            typing: false
          })
        end

        {:ok,
         socket
         |> assign(:page_title, ticket.player_name || ticket.player_id)
         |> assign(:others, Presence.others(ticket.id, user.id))
         |> assign(:typing_timer, nil)
         |> assign(:draft_base, nil)
         |> assign(:back, back_path(params))
         |> assign(:can_manage?, Accounts.can?(user, :manage_tickets))
         |> assign(:settings, Tickets.get_settings(ticket.server_id))
         |> assign(:reply, reply_form(""))
         |> assign(:action_form, action_form())
         |> assign(:player_info, nil)
         |> assign(:assignable, Tickets.assignable_users(ticket))
         |> assign_ticket(ticket)
         |> load_player_info()}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Ticket not found."))
         |> push_navigate(to: back_path(params))}
    end
  end

  defp back_path(%{"server_id" => server_id}), do: ~p"/servers/#{server_id}/tickets"
  defp back_path(_params), do: ~p"/tickets"

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
      {:ok, ticket} -> assign_ticket(socket, ticket)
      :error -> push_navigate(socket, to: socket.assigns.back)
    end
  end

  defp load_player_info(socket) do
    if connected?(socket) do
      ticket = socket.assigns.ticket

      start_async(socket, :player_info, fn ->
        PlayerInfo.fetch(ticket.server, ticket.player_id)
      end)
    else
      socket
    end
  end

  defp reply_form(body), do: to_form(%{"body" => body}, as: :reply)

  defp action_form,
    do:
      to_form(
        %{
          "action" => "punish",
          "reason" => "",
          "target" => "",
          "hours" => "2",
          "custom_hours" => ""
        },
        as: :act
      )

  @impl Phoenix.LiveView
  def handle_async(:player_info, {:ok, info}, socket),
    do: {:noreply, assign(socket, :player_info, info)}

  def handle_async(:player_info, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :player_info, :error)}

  @impl Phoenix.LiveView
  # The reply box has two buttons: send to the player, or keep as a note.
  def handle_event("reply", %{"reply" => %{"body" => body}, "mode" => "note"}, socket) do
    with_manage(socket, fn socket ->
      case Tickets.add_note(socket.assigns.ticket, socket.assigns.current_user, body) do
        {:ok, _message} -> assign(socket, :reply, reply_form(""))
        {:error, _reason} -> socket
      end
    end)
  end

  # Typing in the answer box: the others see it, and the conversation as it
  # stands now is what the answer is written against.
  def handle_event("typing", %{"reply" => %{"body" => body}}, socket) do
    socket =
      socket
      |> assign(:reply, reply_form(body))
      |> assign(:draft_base, socket.assigns.draft_base || length(socket.assigns.ticket.messages))
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

  # A quick reply fills the box instead of sending, so it can be adjusted.
  def handle_event("quick_reply", %{"index" => index}, socket) do
    text = Enum.at(socket.assigns.settings.quick_replies, String.to_integer(index), "")
    {:noreply, assign(socket, :reply, reply_form(text))}
  end

  def handle_event("act", %{"act" => params}, socket) do
    with_manage(socket, fn socket ->
      action = Enum.find(Tickets.player_actions(), &(to_string(&1) == params["action"]))

      case Tickets.act(
             socket.assigns.ticket,
             socket.assigns.current_user,
             action,
             params["reason"],
             params["target"],
             duration_hours: ban_hours(params)
           ) do
        {:ok, _message} ->
          socket
          |> put_flash(:info, gettext("Done. It is recorded in the conversation."))
          |> assign(:action_form, action_form())
          |> load_player_info()

        {:error, :empty_reason} ->
          put_flash(socket, :error, gettext("Write a reason: the player sees it."))

        {:error, :unknown_action} ->
          socket

        {:error, :bad_duration} ->
          put_flash(socket, :error, gettext("The ban lasts between 1 hour and 1 year."))

        {:error, message} ->
          put_flash(socket, :error, gettext("CRCON refused it: %{reason}", reason: message))
      end
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
    do: {:noreply, socket |> assign(:player_info, nil) |> load_player_info()}

  def handle_event("reopen", _params, socket) do
    with_manage(socket, fn socket ->
      case Tickets.reopen(socket.assigns.ticket) do
        {:ok, _ticket} ->
          put_flash(socket, :info, gettext("Ticket reopened."))

        {:error, _changeset} ->
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

  defp send_reply(socket, body) do
    socket = socket |> assign(:draft_base, nil) |> set_typing(false)

    with_manage(socket, fn socket ->
      case Tickets.reply(socket.assigns.ticket, socket.assigns.current_user, body) do
        {:ok, %{delivery: :failed}} ->
          socket
          |> put_flash(
            :error,
            gettext("Saved, but the player did not receive it. They may have left the server.")
          )
          |> assign(:reply, reply_form(""))
          |> load_player_info()

        {:ok, _message} ->
          assign(socket, :reply, reply_form(""))

        {:error, :empty} ->
          socket

        {:error, :closed} ->
          put_flash(socket, :error, gettext("This ticket is closed. Reopen it to answer."))

        {:error, _changeset} ->
          put_flash(socket, :error, gettext("The answer is too long."))
      end
    end)
  end

  defp with_manage(socket, fun) do
    if socket.assigns.can_manage? do
      {:noreply, socket |> fun.() |> reload()}
    else
      {:noreply, put_flash(socket, :error, gettext("You do not have access to that page."))}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:ticket_changed, %{id: id}}, %{assigns: %{ticket: %{id: id}}} = socket),
    do: {:noreply, reload(socket)}

  # Another ticket of the same player changes the "earlier tickets" list.
  def handle_info({:ticket_changed, %{player_id: player_id}}, socket) do
    if player_id == socket.assigns.ticket.player_id,
      do: {:noreply, reload(socket)},
      else: {:noreply, socket}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    others = Presence.others(socket.assigns.ticket.id, socket.assigns.current_user.id)
    {:noreply, assign(socket, :others, others)}
  end

  def handle_info(:stop_typing, socket),
    do: {:noreply, socket |> assign(:typing_timer, nil) |> set_typing(false)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # "Typing" wears off a few seconds after the last keystroke.
  @typing_ms 4_000

  defp set_typing(socket, typing?) do
    if timer = socket.assigns.typing_timer, do: Process.cancel_timer(timer)

    if connected?(socket) do
      user = socket.assigns.current_user

      Presence.update(
        self(),
        Presence.ticket_topic(socket.assigns.ticket.id),
        to_string(user.id),
        %{
          name: user_name(user),
          typing: typing?
        }
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

  defp close_reasons, do: ~w(resolved duplicate no_action player_left other)

  defp user_name(nil), do: nil
  defp user_name(user), do: user.name || user.username

  defp author_label(%{author: :player}, ticket), do: ticket.player_name || ticket.player_id

  defp author_label(%{author: :admin, user: user}, _ticket),
    do: user_name(user) || gettext("Admin")

  defp author_label(%{author: :note, user: user}, _ticket),
    do: gettext("Internal note · %{name}", name: user_name(user) || gettext("Admin"))

  defp author_label(%{author: :system, user: %{} = user}, _ticket), do: user_name(user)
  defp author_label(%{author: :system}, _ticket), do: gettext("Automatic message")

  defp action_options do
    [
      {gettext("Punish (kill in place)"), "punish"},
      {gettext("Kick"), "kick"},
      {gettext("Temporary ban"), "temp_ban"},
      {gettext("Add to the watchlist"), "watch"}
    ]
  end

  # A typed number of hours wins over the preset.
  defp ban_hours(params) do
    [params["custom_hours"], params["hours"]]
    |> Enum.find_value(2, fn value ->
      case Integer.parse(String.trim(value || "")) do
        {hours, ""} -> hours
        _other -> nil
      end
    end)
  end

  defp ban_options do
    [
      {gettext("1 hour"), "1"},
      {gettext("2 hours"), "2"},
      {gettext("6 hours"), "6"},
      {gettext("24 hours"), "24"},
      {gettext("7 days"), "168"},
      {gettext("30 days"), "720"}
    ]
  end

  defp parse_at(text) do
    case DateTime.from_iso8601(text || "") do
      {:ok, at, _offset} -> at
      _error -> nil
    end
  end

  defp context_icon("chat"), do: "hero-chat-bubble-bottom-center-text"
  defp context_icon("team_kill"), do: "hero-exclamation-triangle"
  defp context_icon(_kind), do: "hero-bolt"

  defp playtime(nil), do: "–"
  defp playtime(seconds), do: "#{div(seconds, 3600)}h"

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
    >
      <:actions>
        <.button
          link_type="live_redirect"
          to={@back}
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-arrow-left"
          label={gettext("All tickets")}
        />
      </:actions>

      <div class="grid gap-4 lg:grid-cols-3">
        <div class="space-y-4 lg:col-span-2">
          <.card
            title={gettext("Conversation")}
            icon="hero-chat-bubble-left-right"
            id="ticket-conversation"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <.tone_badge :if={@ticket.category} tone="primary" icon="hero-tag">
                {@ticket.category}
              </.tone_badge>
              <TicketComponents.export_buttons
                id="ticket-export"
                text={@transcript}
                filename={"ticket-#{@ticket.id}.txt"}
              />
            </div>

            <p :if={@ticket.source == :rule} class="text-xs text-muted" id="ticket-rule-source">
              <.icon name="hero-bolt" class="size-3" />
              {gettext("Opened by the rule %{rule}.",
                rule: (@ticket.rule && @ticket.rule.name) || gettext("(removed)")
              )}
            </p>

            <ol class="space-y-3" id="ticket-messages">
              <li
                :for={message <- @ticket.messages}
                id={"message-#{message.id}"}
                data-author={message.author}
                class={[
                  "flex flex-col gap-1",
                  message.author != :player && "items-end"
                ]}
              >
                <div class="flex items-center gap-2 text-xs text-muted">
                  <span class="font-medium text-base-content">
                    {author_label(message, @ticket)}
                  </span>
                  <.local_time id={"message-#{message.id}-at"} at={message.inserted_at} />
                </div>
                <p class={[
                  "max-w-[85%] whitespace-pre-wrap break-words rounded-box px-3 py-2 text-sm",
                  message.author == :player && "bg-base-200",
                  message.author == :admin && "bg-primary/10",
                  message.author == :system && "bg-base-200/50 italic text-muted",
                  message.author == :note &&
                    "border border-dashed border-warning/60 bg-warning/10 text-base-content"
                ]}>
                  {message.body}
                </p>
                <span
                  :if={message.delivery == :failed}
                  class="text-xs text-error"
                  title={message.delivery_error}
                >
                  <.icon name="hero-exclamation-triangle" class="size-3" />
                  {gettext("Not delivered")}
                </span>
              </li>
            </ol>

            <div
              :if={@can_manage? and @ticket.status != :closed}
              class="mt-2 space-y-2 border-t border-base-300 pt-3"
            >
              <div
                :if={@player_info not in [nil, :error] and @player_info.online == false}
                id="player-offline-warning"
              >
                <.alert
                  color="warning"
                  variant="soft"
                  with_icon
                  label={
                    gettext(
                      "The player is not on the server right now: an answer will not reach them."
                    )
                  }
                />
              </div>

              <div
                :if={@settings.quick_replies != []}
                class="flex flex-wrap gap-1.5"
                id="quick-replies"
              >
                <button
                  :for={{text, index} <- Enum.with_index(@settings.quick_replies)}
                  type="button"
                  phx-click="quick_reply"
                  phx-value-index={index}
                  title={text}
                  class="max-w-64 cursor-pointer truncate rounded-full border border-base-300 px-2.5 py-1 text-xs text-subtle transition-colors hover:border-primary/50 hover:text-primary"
                >
                  {text}
                </button>
              </div>

              <div :if={@others != []} id="ticket-presence" class="flex flex-wrap gap-1.5">
                <span
                  :for={other <- @others}
                  data-typing={to_string(other.typing?)}
                  class={[
                    "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs",
                    if(other.typing?,
                      do: "bg-error/10 font-medium text-error",
                      else: "bg-warning/10 text-warning"
                    )
                  ]}
                >
                  <span class={[
                    "size-1.5 rounded-full",
                    if(other.typing?, do: "animate-pulse bg-error", else: "bg-warning")
                  ]}></span>
                  {if other.typing?,
                    do: gettext("%{name} is typing an answer", name: other.name),
                    else: gettext("%{name} is viewing", name: other.name)}
                </span>
              </div>

              <.form
                for={@reply}
                id="reply-form"
                phx-submit="reply"
                phx-change="typing"
                class="space-y-2"
              >
                <.input
                  field={@reply[:body]}
                  type="textarea"
                  label={gettext("Answer")}
                  placeholder={gettext("Sent to the player as a private message in game")}
                  rows="3"
                  maxlength="250"
                />
                <div class="flex flex-wrap justify-end gap-2">
                  <.button
                    type="submit"
                    name="mode"
                    value="note"
                    size="sm"
                    variant="outline"
                    color="gray"
                    icon="hero-lock-closed"
                    title={gettext("Only admins see it; nothing is sent to the player")}
                    label={gettext("Save as internal note")}
                  />
                  <.button
                    type="submit"
                    name="mode"
                    value="reply"
                    size="sm"
                    color="primary"
                    icon="hero-paper-airplane"
                    phx-disable-with={gettext("Sending...")}
                    label={gettext("Send to the player")}
                  />
                </div>
              </.form>
            </div>

            <p :if={@ticket.status == :closed} class="text-sm text-muted" id="ticket-closed-note">
              {gettext("This ticket is closed.")}
              <span :if={@ticket.close_reason}>
                {gettext("Reason: %{reason}.", reason: Labels.close_reason(@ticket.close_reason))}
              </span>
            </p>
          </.card>

          <.card
            :if={@ticket.context != []}
            title={gettext("Before the call")}
            subtitle={gettext("Chat and fights in the minutes before the ticket opened")}
            icon="hero-clock"
            id="ticket-context"
          >
            <ol class="space-y-1.5 text-sm">
              <li
                :for={{line, index} <- Enum.with_index(@ticket.context)}
                id={"context-#{index}"}
                data-kind={line["kind"]}
                class={[
                  "flex items-start gap-2",
                  line["kind"] == "team_kill" && "text-error"
                ]}
              >
                <.icon name={context_icon(line["kind"])} class="mt-0.5 size-4 shrink-0 text-muted" />
                <.local_time
                  id={"context-#{index}-at"}
                  at={parse_at(line["at"])}
                  format="time"
                  class="shrink-0 text-xs tabular-nums text-muted"
                />
                <span class="break-words">{line["text"]}</span>
              </li>
            </ol>
          </.card>

          <.card
            :if={@can_manage?}
            title={gettext("Act on a player")}
            icon="hero-shield-exclamation"
            id="ticket-actions"
          >
            <.form for={@action_form} id="act-form" phx-submit="act" class="space-y-3">
              <div class="grid gap-3 sm:grid-cols-2">
                <.input
                  field={@action_form[:action]}
                  type="select"
                  options={action_options()}
                  label={gettext("Action")}
                />
                <.input
                  field={@action_form[:target]}
                  type="text"
                  label={gettext("Player ID")}
                  placeholder={@ticket.player_id}
                  help_text={
                    gettext(
                      "Blank acts on the player of the ticket. Paste another ID to act on the one being reported."
                    )
                  }
                />
              </div>
              <div class="grid gap-3 sm:grid-cols-2">
                <.input
                  field={@action_form[:hours]}
                  type="select"
                  options={ban_options()}
                  label={gettext("Ban duration")}
                  help_text={gettext("Only for a temporary ban.")}
                />
                <.input
                  field={@action_form[:custom_hours]}
                  type="number"
                  min="1"
                  max="8760"
                  label={gettext("Or type the hours")}
                  placeholder="48"
                />
              </div>
              <.input
                field={@action_form[:reason]}
                type="text"
                label={gettext("Reason")}
                placeholder={gettext("Shown to the player")}
                maxlength="200"
              />
              <div class="flex justify-end">
                <.button
                  type="submit"
                  size="sm"
                  color="danger"
                  variant="outline"
                  data-confirm={gettext("Run this action on the player now?")}
                  phx-disable-with={gettext("Sending...")}
                  label={gettext("Run")}
                />
              </div>
            </.form>
          </.card>
        </div>

        <div class="space-y-4">
          <.card title={gettext("Player")} icon="hero-user" id="ticket-player">
            <:action>
              <button
                type="button"
                phx-click="refresh_player"
                class="cursor-pointer text-muted hover:text-base-content"
                title={gettext("Refresh")}
              >
                <.icon name="hero-arrow-path" class="size-4" />
              </button>
            </:action>

            <div class="flex items-center justify-between gap-2">
              <div class="min-w-0">
                <.link
                  navigate={~p"/players/#{@ticket.player_id}"}
                  class="block truncate font-medium hover:underline"
                >
                  {@ticket.player_name || @ticket.player_id}
                </.link>
                <span class="block truncate text-xs text-muted">{@ticket.player_id}</span>
              </div>
              <span id="player-online">
                <.tone_badge :if={@player_info == nil} tone="neutral">
                  {gettext("Checking...")}
                </.tone_badge>
                <.tone_badge :if={@player_info == :error} tone="neutral">
                  {gettext("Unknown")}
                </.tone_badge>
                <.tone_badge
                  :if={@player_info not in [nil, :error] and @player_info.online == true}
                  tone="success"
                >
                  {gettext("Online")}
                </.tone_badge>
                <.tone_badge
                  :if={@player_info not in [nil, :error] and @player_info.online == false}
                  tone="error"
                >
                  {gettext("Left the server")}
                </.tone_badge>
                <.tone_badge
                  :if={@player_info not in [nil, :error] and @player_info.online == :unknown}
                  tone="neutral"
                >
                  {gettext("Unknown")}
                </.tone_badge>
              </span>
            </div>

            <dl
              :if={@player_info not in [nil, :error]}
              class="grid grid-cols-2 gap-3 border-t border-base-300 pt-3 text-sm"
              id="player-card"
            >
              <div>
                <dt class="text-xs text-muted">{gettext("Level")}</dt>
                <dd>{@player_info.level || "–"}</dd>
              </div>
              <div>
                <dt class="text-xs text-muted">{gettext("Clan")}</dt>
                <dd>{@player_info.clan_tag || "–"}</dd>
              </div>
              <div>
                <dt class="text-xs text-muted">{gettext("Playtime")}</dt>
                <dd>{playtime(@player_info.playtime_seconds)}</dd>
              </div>
              <div>
                <dt class="text-xs text-muted">{gettext("Sessions")}</dt>
                <dd>{@player_info.sessions || "–"}</dd>
              </div>
              <div class="col-span-2 flex flex-wrap gap-1">
                <.tone_badge :if={@player_info.vip?} tone="primary">VIP</.tone_badge>
                <.tone_badge :if={@player_info.watched?} tone="warning" icon="hero-eye">
                  {gettext("Watchlist")}
                </.tone_badge>
                <.tone_badge :if={@player_info.blacklisted?} tone="error">
                  {gettext("Blacklisted")}
                </.tone_badge>
                <.tone_badge :for={flag <- @player_info.flags} tone="neutral">{flag}</.tone_badge>
              </div>
              <div class="col-span-2">
                <dt class="text-xs text-muted">{gettext("Past penalties")}</dt>
                <dd :if={@player_info.penalties == %{}}>{gettext("None")}</dd>
                <dd :if={@player_info.penalties != %{}} class="flex flex-wrap gap-1">
                  <.tone_badge
                    :for={{type, count} <- Enum.sort(@player_info.penalties)}
                    tone="error"
                  >
                    {type} × {count}
                  </.tone_badge>
                </dd>
              </div>
              <div :if={length(@player_info.names) > 1} class="col-span-2">
                <dt class="text-xs text-muted">{gettext("Also known as")}</dt>
                <dd class="truncate">{Enum.join(@player_info.names, ", ")}</dd>
              </div>
              <div class="col-span-2">
                <dt class="text-xs text-muted">{gettext("Tickets opened")}</dt>
                <dd>{@ticket_count}</dd>
              </div>
            </dl>
          </.card>

          <.card title={gettext("Ticket")} icon="hero-ticket" id="ticket-details">
            <dl class="grid grid-cols-2 gap-3 text-sm">
              <div>
                <dt class="text-xs text-muted">{gettext("Status")}</dt>
                <dd>
                  <.tone_badge tone={Labels.ticket_status_tone(@ticket.status)}>
                    {Labels.ticket_status(@ticket.status)}
                  </.tone_badge>
                </dd>
              </div>
              <div>
                <dt class="text-xs text-muted">{gettext("Priority")}</dt>
                <dd :if={!@can_manage? or @ticket.status == :closed}>
                  <.tone_badge tone={Labels.ticket_priority_tone(@ticket.priority)}>
                    {Labels.ticket_priority(@ticket.priority)}
                  </.tone_badge>
                </dd>
                <dd :if={@can_manage? and @ticket.status != :closed}>
                  <form id="priority-form" phx-change="set_priority">
                    <select
                      name="priority"
                      class="pc-text-input w-full"
                      aria-label={gettext("Priority")}
                    >
                      <option
                        :for={{label, value} <- Labels.ticket_priority_options()}
                        value={value}
                        selected={value == to_string(@ticket.priority)}
                      >
                        {label}
                      </option>
                    </select>
                  </form>
                </dd>
              </div>
              <div class="col-span-2">
                <dt class="text-xs text-muted">{gettext("Assigned to")}</dt>
                <dd :if={!@can_manage? or @ticket.status == :closed}>
                  {user_name(@ticket.assigned_to) || "–"}
                </dd>
                <dd :if={@can_manage? and @ticket.status != :closed}>
                  <form id="transfer-form" phx-change="transfer">
                    <select
                      name="user_id"
                      class="pc-text-input w-full"
                      aria-label={gettext("Hand the ticket to")}
                    >
                      <option value="">{gettext("Nobody")}</option>
                      <option
                        :for={user <- @assignable}
                        value={user.id}
                        selected={user.id == @ticket.assigned_to_id}
                      >
                        {user_name(user)}
                      </option>
                    </select>
                  </form>
                </dd>
              </div>
              <div>
                <dt class="text-xs text-muted">{gettext("Opened")}</dt>
                <dd><.local_time id="ticket-opened" at={@ticket.inserted_at} /></dd>
              </div>
            </dl>

            <div :if={@can_manage?} class="flex flex-wrap gap-2 border-t border-base-300 pt-3">
              <.button
                :if={@ticket.status != :closed and @ticket.assigned_to_id != @current_user.id}
                type="button"
                size="xs"
                variant="outline"
                color="gray"
                phx-click="assign_me"
                label={gettext("Assign to me")}
              />
              <.button
                :if={@ticket.status != :closed and @ticket.assigned_to_id}
                type="button"
                size="xs"
                variant="ghost"
                color="gray"
                phx-click="unassign"
                label={gettext("Unassign")}
              />
              <form
                :if={@ticket.status != :closed}
                id="close-form"
                phx-submit="close"
                class="flex w-full items-center gap-2"
              >
                <select
                  name="reason"
                  class="pc-text-input min-w-0 flex-1 py-1 text-sm"
                  aria-label={gettext("Why it is closed")}
                >
                  <option :for={reason <- close_reasons()} value={reason}>
                    {Labels.close_reason(reason)}
                  </option>
                </select>
                <.button
                  type="submit"
                  size="xs"
                  color="primary"
                  data-confirm={gettext("Close this ticket? The player is told it was closed.")}
                  label={gettext("Close ticket")}
                />
              </form>
              <.button
                :if={@ticket.status == :closed}
                type="button"
                size="xs"
                variant="outline"
                color="gray"
                phx-click="reopen"
                label={gettext("Reopen")}
              />
            </div>
          </.card>

          <.card
            :if={@history != []}
            title={gettext("Earlier tickets")}
            icon="hero-clock"
            id="ticket-history"
          >
            <ul class="divide-y divide-base-300 text-sm">
              <li :for={earlier <- @history} class="flex items-center justify-between gap-2 py-2">
                <.link navigate={~p"/tickets/#{earlier.id}"} class="truncate hover:underline">
                  {earlier.server.name}
                </.link>
                <.local_time
                  id={"earlier-#{earlier.id}"}
                  at={earlier.inserted_at}
                  class="text-xs text-muted"
                />
              </li>
            </ul>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
