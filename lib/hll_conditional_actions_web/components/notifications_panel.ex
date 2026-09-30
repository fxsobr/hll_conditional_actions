defmodule HllConditionalActionsWeb.NotificationsPanel do
  @moduledoc """
  The bell in the header and the panel it opens: what happened that the
  user should know about, from `HllConditionalActions.Notifications` -
  attention items, new tickets, notes that mention them - split into what
  they have not read ("Agora") and what they have ("Antes").

  Closed, the bell only shows a dot when something is unread; the count
  comes from `HllConditionalActionsWeb.Nav` (`@nav.unread`), which keeps it
  current without a reload. The list itself is read when the panel opens.
  Opening an item marks it read; "Marcar tudo como lido" marks them all.
  """

  use HllConditionalActionsWeb, :live_component

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Attention
  alias HllConditionalActions.Briefing
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Notifications
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.RelativeTime

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, assign(socket, open: false, items: [], filter: "all", last_events: %{})}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    nav = assigns[:nav]

    # A page recounted the attention items on its own (the Attention inbox
    # does after handling one): the unread count was read with the old
    # list, so ask `HllConditionalActionsWeb.Nav` for fresh counts.
    if ((connected?(socket) and nav) && nav[:unread_basis] != nil) and
         nav[:attention] != nav[:unread_basis],
       do: send(self(), :refresh_shell)

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:current_user, assigns.current_user)
     |> assign(:nav, assigns[:nav])
     |> assign(:compact, Map.get(assigns, :compact, false))
     |> assign(:class, Map.get(assigns, :class))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle", _params, %{assigns: %{open: true}} = socket),
    do: {:noreply, assign(socket, :open, false)}

  def handle_event("toggle", _params, socket),
    do: {:noreply, socket |> assign(:open, true) |> load()}

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, :open, false)}

  def handle_event("filter", %{"filter" => filter}, socket) when filter in ~w(all mentions),
    do: {:noreply, assign(socket, :filter, filter)}

  def handle_event("mark_all", _params, socket) do
    keys = for item <- socket.assigns.items, item.unread?, do: item.key
    Notifications.mark_read(socket.assigns.current_user, keys)
    send(self(), :refresh_shell)
    {:noreply, load(socket)}
  end

  def handle_event("visit", %{"key" => key}, socket) do
    case Enum.find(socket.assigns.items, &(&1.key == key)) do
      nil ->
        {:noreply, socket}

      item ->
        Notifications.mark_read(socket.assigns.current_user, [key])
        send(self(), :refresh_shell)
        {:noreply, socket |> assign(:open, false) |> push_navigate(to: path(item))}
    end
  end

  # Asks the server's log stream to connect again now instead of at its
  # next retry. Only reconnects; it sends nothing to the game.
  def handle_event("reconnect", %{"server" => id}, socket) do
    user = socket.assigns.current_user

    with true <- Accounts.can?(user, :manage_servers),
         {server_id, ""} <- Integer.parse(id),
         true <- Accounts.can_access_server?(user, server_id),
         pid when is_pid(pid) <- GenServer.whereis(LogStream.via(server_id)) do
      send(pid, :reconnect)
      {:noreply, put_flash(socket, :info, gettext("Reconnecting the log stream…"))}
    else
      _no -> {:noreply, socket}
    end
  end

  # Grants a paid VIP that failed again, like "Tentar de novo" on the
  # purchases page: the fulfilment job runs once more for that order.
  def handle_event("retry_vip", %{"order" => id}, socket) do
    user = socket.assigns.current_user

    with true <- Accounts.can?(user, :manage_integrations),
         {order_id, ""} <- Integer.parse(id),
         true <- Enum.any?(socket.assigns.items, &vip_order?(&1, order_id)) do
      %{order_id: order_id}
      |> HllConditionalActions.Workers.FulfillVipOrder.new()
      |> Oban.insert()

      {:noreply, put_flash(socket, :info, gettext("Granting the VIP again."))}
    else
      _no -> {:noreply, socket}
    end
  end

  defp vip_order?(%{kind: :vip_failed, subject: %{order: %{id: id}}}, id), do: true
  defp vip_order?(_item, _id), do: false

  defp load(socket) do
    user = socket.assigns.current_user
    servers = Servers.list_servers_for(user)

    attention =
      if Accounts.can?(user, :view_executions) do
        status = Map.new(servers, &{&1.id, LogStream.status(&1.id)})
        Attention.items(user, servers, status).open
      else
        []
      end

    items = Notifications.list(user, servers, attention)

    # "Nenhum evento desde 21:43": when each fallen stream last delivered.
    down = for %{kind: :stream_down, subject: %{server: server}} <- items, do: server.id

    assign(socket, items: items, last_events: Briefing.last_events(down))
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    unread = Enum.count(assigns.items, & &1.unread?)
    count = if assigns.open, do: unread, else: (assigns.nav && assigns.nav[:unread]) || 0

    shown =
      if assigns.filter == "mentions",
        do: Enum.filter(assigns.items, & &1.mention?),
        else: assigns.items

    {fresh, seen} = Enum.split_with(shown, & &1.unread?)

    assigns =
      assign(assigns,
        count: count,
        fresh: fresh,
        seen: seen,
        mentions: Enum.count(assigns.items, &(&1.mention? and &1.unread?)),
        now: DateTime.utc_now()
      )

    ~H"""
    <div
      id={@id}
      class={["relative", @compact && "max-md:hidden", @class]}
      phx-click-away={@open && JS.push("close", target: @myself)}
      phx-window-keydown={@open && JS.push("close", target: @myself)}
      phx-key="Escape"
    >
      <button
        type="button"
        id="attention-bell"
        class="bell-button"
        aria-expanded={to_string(@open)}
        aria-controls="notifications-panel"
        aria-label={ngettext("Notifications, 1 unread", "Notifications, %{count} unread", @count)}
        phx-click="toggle"
        phx-target={@myself}
      >
        <.icon name="hero-bell" class="size-5" />
        <span :if={@count > 0 and not @open} class="attention-bell-badge bell-dot">
          <span class="sr-only">{@count}</span>
        </span>
        <span :if={@count > 0 and @open} class="bell-count">{count_text(@count)}</span>
      </button>

      <section
        :if={@open}
        id="notifications-panel"
        role="dialog"
        aria-labelledby="notifications-title"
        class="notif-panel"
      >
        <div class="flex flex-col gap-3 px-5 pb-3 pt-[1.125rem]">
          <div class="flex items-center gap-2.5">
            <h2 id="notifications-title" class="flex-1 font-display text-xl font-semibold">
              {gettext("Notifications")}
            </h2>
            <button
              :if={@count > 0}
              type="button"
              id="notifications-mark-all"
              class="h-8 rounded-full px-2.5 text-[0.8125rem] font-semibold text-primary hover:bg-primary/10"
              phx-click="mark_all"
              phx-target={@myself}
            >
              {gettext("Mark all as read")}
            </button>
            <.link
              navigate={~p"/settings"}
              class="icon-round size-8 border-0 bg-secondary text-subtle"
              aria-label={gettext("Notification preferences")}
            >
              <.icon name="hero-cog-6-tooth" class="size-4" />
            </.link>
          </div>

          <div role="tablist" aria-label={gettext("Filter notifications")} class="notif-tabs">
            <button
              type="button"
              role="tab"
              aria-selected={to_string(@filter == "all")}
              phx-click="filter"
              phx-value-filter="all"
              phx-target={@myself}
            >
              {gettext("Everything")} <span class="font-mono text-[0.6875rem]">{@count}</span>
            </button>
            <button
              type="button"
              role="tab"
              aria-selected={to_string(@filter == "mentions")}
              phx-click="filter"
              phx-value-filter="mentions"
              phx-target={@myself}
            >
              {gettext("Mentions")}
              <span class="font-mono text-[0.6875rem] text-accent">{@mentions}</span>
            </button>
          </div>
        </div>

        <div class="notif-list">
          <p :if={@fresh != []} class="notif-heading">{gettext("Now")}</p>
          <.item
            :for={item <- @fresh}
            item={item}
            now={@now}
            myself={@myself}
            user={@current_user}
            last_events={@last_events}
          />

          <p :if={@seen != []} class="notif-heading pt-2.5">{gettext("Earlier")}</p>
          <.item
            :for={item <- @seen}
            item={item}
            now={@now}
            myself={@myself}
            user={@current_user}
            last_events={@last_events}
          />

          <div
            :if={@fresh == [] and @seen == []}
            class="flex flex-col items-center gap-2 px-6 py-10 text-center"
          >
            <span class="flex size-11 items-center justify-center rounded-xl bg-primary/12 text-primary">
              <.icon name="hero-check" class="size-5" />
            </span>
            <p class="font-display text-lg font-semibold">
              {if @filter == "mentions",
                do: gettext("Nobody mentioned you"),
                else: gettext("Nothing needs you right now")}
            </p>
            <p class="max-w-xs text-[0.8125rem] text-subtle">
              {gettext("Tickets, failures and new alerts show up here as soon as they arrive.")}
            </p>
          </div>
        </div>

        <div class="mt-1.5 flex items-center justify-between gap-3 border-t border-line-soft px-5 py-3 text-[0.8125rem]">
          <.link navigate={~p"/inbox"} class="font-semibold text-primary hover:underline">
            {gettext("See everything in the Inbox")}
          </.link>
          <span class="text-muted">
            {gettext("Discord and e-mail in")}
            <.link navigate={~p"/settings"} class="text-subtle underline">{gettext("Settings")}</.link>
          </span>
        </div>
      </section>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :now, :any, required: true
  attr :myself, :any, required: true
  attr :user, :map, required: true
  attr :last_events, :map, default: %{}

  defp item(assigns) do
    assigns =
      assign(assigns,
        tone: tone(assigns.item),
        title: title(assigns.item),
        body: body(assigns.item, assigns.last_events)
      )

    ~H"""
    <div
      id={"notification-#{dom_key(@item.key)}"}
      class={[
        "notif-item",
        @item.unread? && "is-unread",
        @item.unread? && @tone == "error" && "is-error"
      ]}
    >
      <button
        type="button"
        class="absolute inset-0 rounded-[1.125rem]"
        aria-label={@title}
        phx-click="visit"
        phx-value-key={@item.key}
        phx-target={@myself}
      ></button>
      <span class={["notif-icon", "notif-icon--#{@tone}", not @item.unread? && "is-read"]}>
        <%= if @item.kind == :mention do %>
          <span class="text-xs font-bold">{initials(@item.subject.message.user)}</span>
        <% else %>
          <.icon name={item_icon(@item)} class="size-[1.0625rem]" />
        <% end %>
      </span>
      <span class="flex min-w-0 flex-1 flex-col gap-[3px]">
        <span class="flex justify-between gap-2">
          <strong class={[
            "text-sm",
            if(@item.unread?, do: "font-semibold", else: "font-medium text-subtle")
          ]}>
            {@title}
          </strong>
          <span
            :if={@item.at}
            class={[
              "whitespace-nowrap font-mono text-[0.6875rem]",
              if(@item.unread? and @tone == "error", do: "text-error", else: "text-muted")
            ]}
          >
            {RelativeTime.short(@item.at, @now)}
          </span>
        </span>
        <span class={[
          "text-[0.8125rem] leading-[1.4]",
          if(@item.unread?, do: "text-subtle", else: "text-muted"),
          @item.kind == :ticket_new && "truncate"
        ]}>
          <%= if @item.kind == :mention do %>
            #{@item.subject.ticket.id} · “<.mentioned
              text={@item.subject.message.body}
              handles={@item.subject.handles}
            />”
          <% else %>
            {@body}
          <% end %>
        </span>
        <span
          :if={@item.unread? && @item.kind == :stream_down}
          class="relative z-10 mt-1.5 flex gap-1.5"
        >
          <button
            :if={Accounts.can?(@user, :manage_servers)}
            type="button"
            class="h-[1.875rem] rounded-full bg-inverse px-3 text-xs font-semibold text-on-inverse"
            phx-click="reconnect"
            phx-value-server={@item.subject.server.id}
            phx-target={@myself}
          >
            {gettext("Reconnect")}
          </button>
          <.link
            navigate={~p"/servers/#{@item.subject.server.id}"}
            class="flex h-[1.875rem] items-center rounded-full border border-line-raised px-3 text-xs"
          >
            {gettext("Open the server")}
          </.link>
        </span>
        <span
          :if={@item.unread? && @item.kind == :vip_failed}
          class="relative z-10 mt-1.5 flex gap-1.5"
        >
          <button
            :if={Accounts.can?(@user, :manage_integrations)}
            type="button"
            class="h-[1.875rem] cursor-pointer rounded-full border border-line-raised bg-secondary px-3 text-xs"
            phx-click="retry_vip"
            phx-value-order={@item.subject.order.id}
            phx-target={@myself}
          >
            {gettext("Try again")}
          </button>
          <.link
            :if={!Accounts.can?(@user, :manage_integrations)}
            navigate={~p"/vip-shop/purchases"}
            class="flex h-[1.875rem] items-center rounded-full border border-line-raised bg-secondary px-3 text-xs"
          >
            {gettext("Open the order")}
          </.link>
        </span>
      </span>
      <span :if={@item.unread?} class="notif-unread" aria-label={gettext("unread")}></span>
    </div>
    """
  end

  attr :text, :string, required: true
  attr :handles, :list, required: true

  # The note with the user's @handle in the engine colour.
  defp mentioned(assigns) do
    pattern = Enum.map_join(assigns.handles, "|", &Regex.escape/1)

    parts =
      case Regex.compile("(@(?:#{pattern}))", "iu") do
        {:ok, regex} -> Regex.split(regex, clip(assigns.text), include_captures: true)
        _error -> [clip(assigns.text)]
      end

    assigns = assign(assigns, :parts, parts)

    ~H"""
    <span :for={part <- @parts} class={String.starts_with?(part, "@") && "text-accent"}>{part}</span>
    """
  end

  defp clip(text) when is_binary(text) do
    if String.length(text) > 140, do: String.slice(text, 0, 140) <> "…", else: text
  end

  defp clip(_text), do: ""

  # ── Wording ────────────────────────────────────────────────────────────────

  defp title(%{kind: :stream_down, subject: %{server: server}}),
    do: gettext("Stream down on %{server}", server: server.name)

  defp title(%{kind: :ticket_waiting, subject: %{ticket: ticket}}),
    do:
      gettext("Ticket #%{id} · %{player} is waiting",
        id: ticket.id,
        player: ticket.player_name || ticket.player_id
      )

  defp title(%{kind: :ticket_new, subject: %{ticket: ticket}}),
    do:
      gettext("New ticket #%{id} · %{player}",
        id: ticket.id,
        player: ticket.player_name || ticket.player_id
      )

  defp title(%{kind: :mention, subject: %{message: message}}),
    do:
      gettext("%{name} mentioned you in a note",
        name: (message.user && (message.user.name || message.user.username)) || "?"
      )

  defp title(%{kind: :vip_failed, subject: %{order: order}}) do
    case failed_servers(order) do
      [server] -> gettext("VIP purchase failed on %{server}", server: server)
      _many -> gettext("VIP purchase failed")
    end
  end

  defp title(%{kind: :failures, subject: %{rule: rule, count: count}}),
    do:
      ngettext("Rule “%{rule}” failed once", "Rule “%{rule}” failed %{count}×", count,
        rule: rule.name
      )

  defp title(%{kind: kind, subject: %{rule: rule, issue: issue}})
       when kind in [:rule_broken, :rule_quiet],
       do: "“#{rule.name}” · #{Labels.health_issue(issue.id)}"

  defp title(%{kind: :review, subject: %{execution: execution}}),
    do: gettext("Review %{player}", player: execution.player_name || execution.player_id)

  defp title(%{kind: :ready_to_go_live, subject: %{rule: rule}}),
    do: gettext("“%{rule}” is ready to act", rule: rule.name)

  defp title(_item), do: gettext("Notification")

  defp body(%{kind: :stream_down, subject: %{server: server}} = item, last_events)
       when is_map_key(last_events, server.id) do
    at = Map.fetch!(last_events, server.id)

    if at == nil,
      do: body(item),
      else:
        gettext("No event since %{time}. This server's rules are blind.",
          time: clock(at, server)
        )
  end

  defp body(item, _last_events), do: body(item)

  defp clock(at, server) do
    at = if is_struct(at, NaiveDateTime), do: DateTime.from_naive!(at, "Etc/UTC"), else: at

    case DateTime.shift_zone(at, server.timezone || "Etc/UTC") do
      {:ok, local} -> Calendar.strftime(local, "%H:%M")
      _error -> Calendar.strftime(at, "%H:%M")
    end
  end

  defp body(%{kind: :stream_down, subject: %{reason: :stopped}}),
    do: gettext("The engine for this server stopped. This server's rules are blind.")

  defp body(%{kind: :stream_down, subject: %{reason: reason}}),
    do:
      gettext("No events are arriving (%{reason}). This server's rules are blind.",
        reason: reason
      )

  defp body(%{kind: :ticket_waiting, subject: %{ticket: ticket}}),
    do: gettext("No answer yet on %{server}.", server: server_name(ticket))

  defp body(%{kind: :ticket_new, subject: %{ticket: ticket, message: message}}) do
    [
      message && "“#{clip(message)}”",
      Labels.ticket_priority(ticket.priority),
      if(ticket.assigned_to_id, do: nil, else: gettext("unowned"))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp body(%{kind: :vip_failed, subject: %{order: order}}) do
    player = order.player_name || order.player_id
    delivered = Enum.count(order.grants, &(&1.status == "granted"))

    case failed_servers(order) do
      [] ->
        gettext("Order #%{id} by %{player} was paid, but its VIP was not delivered.",
          id: order.id,
          player: player
        )

      servers ->
        gettext("Order #%{id} by %{player} was paid, but CRCON of %{servers} did not answer.",
          id: order.id,
          player: player,
          servers: Enum.join(servers, ", ")
        ) <>
          if(delivered > 0,
            do:
              " " <>
                ngettext(
                  "VIP delivered on the other one.",
                  "VIP delivered on the other %{count}.",
                  delivered
                ),
            else: ""
          )
    end
  end

  defp body(%{kind: :failures, subject: %{error: error}}), do: error || gettext("unknown error")

  defp body(%{kind: kind, subject: %{issue: issue}}) when kind in [:rule_broken, :rule_quiet],
    do: Labels.health_explanation(issue)

  defp body(%{kind: :review, subject: %{execution: execution, reason: reason}}),
    do: Enum.join(Enum.reject([execution.rule && execution.rule.name, reason], &is_nil/1), " · ")

  defp body(%{kind: :ready_to_go_live, subject: %{runs: runs}}),
    do: gettext("%{runs} runs in simulation, no failure", runs: runs)

  defp body(_item), do: nil

  defp failed_servers(order),
    do: for(grant <- order.grants, grant.status == "failed", do: grant.server_name)

  defp server_name(%{server: %{name: name}}), do: name
  defp server_name(_ticket), do: "?"

  defp item_icon(%{kind: :stream_down}), do: "hero-exclamation-triangle"

  defp item_icon(%{kind: kind}) when kind in [:ticket_waiting, :ticket_new],
    do: "hero-chat-bubble-left"

  defp item_icon(%{kind: :vip_failed}), do: "hero-shopping-bag"
  defp item_icon(%{kind: kind}) when kind in [:failures, :rule_broken], do: "hero-bolt"
  defp item_icon(%{kind: :rule_quiet}), do: "hero-moon"
  defp item_icon(%{kind: :review}), do: "hero-eye"
  defp item_icon(%{kind: :ready_to_go_live}), do: "hero-sparkles"
  defp item_icon(_item), do: "hero-bell"

  defp tone(%{kind: :stream_down}), do: "error"
  defp tone(%{kind: :rule_broken}), do: "error"
  defp tone(%{kind: kind}) when kind in [:failures, :vip_failed, :ticket_waiting], do: "warning"
  defp tone(%{kind: :review}), do: "axis"
  defp tone(_item), do: "engine"

  defp path(%{kind: :stream_down, subject: %{server: server}}), do: ~p"/servers/#{server.id}"

  defp path(%{kind: kind, subject: %{ticket: ticket}})
       when kind in [:ticket_waiting, :ticket_new, :mention],
       do: ~p"/inbox?#{[ticket: ticket.id]}"

  defp path(%{kind: :vip_failed}), do: ~p"/vip-shop/purchases"

  defp path(%{kind: :review, subject: %{execution: execution}}),
    do: ~p"/players/#{execution.player_id}"

  defp path(%{subject: %{rule: rule}}), do: ~p"/rules/#{rule.id}"
  defp path(_item), do: ~p"/inbox"

  defp count_text(count) when count > 99, do: "99+"
  defp count_text(count), do: count

  defp dom_key(key), do: String.replace(key, ~r/[^a-zA-Z0-9_-]/, "-")

  defp initials(nil), do: "?"
  defp initials(user), do: HllConditionalActionsWeb.Layouts.initials(user)
end
