defmodule HllConditionalActionsWeb.InboxLive do
  @moduledoc """
  The Caixa: everything waiting on a human, in one list, most urgent first.

  The list mixes the Attention items (`HllConditionalActions.Attention`:
  broken streams and rules, failures, players to review, rules ready to go
  live, VIP not granted) and the open tickets of the servers where the
  tickets module is installed, when the user may read tickets. A ticket
  that waited too long is the ticket's own row, marked urgent, rather than
  a second Attention row.

  Chips narrow the list (urgent, tickets, rules, players, suggestions, and
  the resolved tickets); the owner tabs split it into everything, what is
  assigned to me, and what nobody owns yet. Picking a row opens it on the
  right, kept in the URL (`?ticket=ID` or `?item=KEY`) so it survives a
  reload: a ticket shows its conversation and, on the widest screens, the
  cards of who called and who it is about
  (`HllConditionalActionsWeb.TicketLive.Conversation`); an Attention item
  shows what it is about, where to deal with it and, when it can be, the
  button that marks it as handled.

  Ticket changes arrive through `HllConditionalActionsWeb.Nav`, which lists
  this page among the ticket pages and so lets `{:ticket_changed, _}` reach
  it; the page does not subscribe on its own, so each change arrives once.
  A burst of changes rebuilds the list once. Like the Attention page, it
  also refreshes on its own.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_executions}}

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Attention
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Engine
  alias HllConditionalActions.Features
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Tickets
  alias HllConditionalActions.Tickets.Stats
  alias HllConditionalActionsWeb.AttentionLive
  alias HllConditionalActionsWeb.TicketComponents
  alias HllConditionalActionsWeb.TicketLive.Conversation
  alias HllConditionalActionsWeb.TicketLive.Index, as: TicketIndex
  alias HllConditionalActionsWeb.TicketLive.Metrics, as: TicketMetrics

  @refresh_ms :timer.seconds(30)
  # How often the list asks CRCON who is on the servers, for the players to
  # review who came back.
  @online_every :timer.seconds(60)
  # Changes closer together than this rebuild the list once.
  @reload_after 250
  # A server without its own alert time ages tickets against this.
  @default_attention_minutes 5
  @chips ~w(urgent tickets rules players suggestions resolved)
  @owners ~w(all mine unowned)

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    user = socket.assigns.current_user
    servers = Servers.list_servers_for(user)

    ticket_server_ids =
      if Accounts.can?(user, :view_tickets), do: ticket_servers(servers), else: []

    if connected?(socket) do
      LogStream.subscribe_status()
      Enum.each(servers, &Engine.subscribe(&1.id))
      :timer.send_interval(@refresh_ms, :refresh)
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("Inbox"))
     |> assign(:servers, servers)
     |> assign(:timezone, TicketMetrics.timezone(nil, servers))
     |> assign(:ticket_server_ids, ticket_server_ids)
     |> assign(:tickets?, ticket_server_ids != [])
     |> assign(:settings_by_server, Map.new(ticket_server_ids, &{&1, Tickets.get_settings(&1)}))
     |> assign_configure_path(user)
     |> assign(:can_resolve?, Accounts.can?(user, :manage_rules))
     |> assign(:chip, nil)
     # The owner tab from the address already, so the first render lists the
     # same rows as the connected one.
     |> assign(:owner, Enum.find(@owners, "all", &(&1 == params["owner"])))
     |> assign(:query, "")
     |> assign(:selected, nil)
     |> assign(:ticket, nil)
     |> assign(:reload_pending?, false)
     |> assign(:online, MapSet.new())
     |> assign(:online_checked_at, nil)
     |> load()}
  end

  # Where "Configurar tickets" leads: the settings once tickets run on some
  # server, the setup wizard before that. Only for who may change them.
  defp assign_configure_path(socket, user) do
    path =
      cond do
        not socket.assigns.tickets? or not Accounts.can?(user, :manage_tickets) ->
          nil

        Enum.any?(Map.values(socket.assigns.settings_by_server), & &1.enabled) ->
          ~p"/tickets/settings"

        true ->
          ~p"/tickets/setup"
      end

    assign(socket, :configure_path, path)
  end

  # The servers the user sees with the tickets module installed.
  defp ticket_servers([]), do: []

  defp ticket_servers(servers) do
    servers
    |> Enum.map(& &1.id)
    |> Features.installed_by_server()
    |> Enum.filter(fn {_id, installed} -> :tickets in installed end)
    |> Enum.map(fn {id, _installed} -> id end)
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    owner = Enum.find(@owners, "all", &(&1 == params["owner"]))

    {:noreply,
     socket
     |> assign(:owner, owner)
     |> select(selection(params))
     |> stream_entries()}
  end

  defp selection(%{"ticket" => id}) do
    case Integer.parse(id) do
      {id, ""} -> {:ticket, id}
      _other -> nil
    end
  end

  defp selection(%{"item" => key}) when is_binary(key) and key != "", do: {:item, key}
  defp selection(_params), do: nil

  defp select(%{assigns: %{selected: same}} = socket, same), do: socket

  defp select(socket, {:ticket, id}) do
    socket = Conversation.leave(socket)

    with true <- socket.assigns.tickets?,
         {:ok, ticket} <- Tickets.fetch_ticket(socket.assigns.current_user, id),
         true <- ticket.server_id in socket.assigns.ticket_server_ids do
      socket
      |> assign(:selected, {:ticket, id})
      |> Conversation.open(ticket, back: ~p"/inbox")
    else
      _missing ->
        socket
        |> assign(:selected, nil)
        |> put_flash(:error, gettext("Ticket not found."))
    end
  end

  defp select(socket, selection) do
    socket |> Conversation.leave() |> assign(:selected, selection)
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @conversation_events Conversation.events()
  @quiet_events ~w(typing quick_reply refresh_player act_open act_cancel more more_close)

  @impl Phoenix.LiveView
  # What the admin does on the ticket shows on its row at once, without
  # waiting for the change to come back through PubSub.
  def handle_event(event, params, socket) when event in @conversation_events do
    {:noreply, socket} = Conversation.handle_event(event, params, socket)
    {:noreply, if(event in @quiet_events, do: socket, else: load(socket))}
  end

  def handle_event("owner", %{"owner" => owner}, socket) do
    owner = Enum.find(@owners, "all", &(&1 == owner))
    {:noreply, socket |> assign(:owner, owner) |> stream_entries()}
  end

  def handle_event("chip", %{"chip" => chip}, socket) do
    chip = Enum.find(@chips, &(&1 == chip))
    # The same chip again goes back to everything.
    chip = if chip == socket.assigns.chip, do: nil, else: chip
    {:noreply, socket |> assign(:chip, chip) |> load()}
  end

  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, socket |> assign(:query, String.trim(query)) |> stream_entries()}
  end

  def handle_event("resolve", %{"key" => key}, socket) do
    if socket.assigns.can_resolve? do
      Attention.resolve(key, socket.assigns.current_user)

      socket =
        socket
        |> put_flash(:info, gettext("Marked as handled."))
        |> load()

      socket =
        if socket.assigns.selected == {:item, key},
          do: push_patch(socket, to: inbox_path(socket.assigns.owner)),
          else: socket

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, gettext("You do not have access to that page."))}
    end
  end

  @impl Phoenix.LiveView
  def handle_async(:player_info, result, socket),
    do: {:noreply, Conversation.player_info_loaded(socket, result)}

  def handle_async(:online, {:ok, online}, socket),
    do: {:noreply, socket |> assign(:online, online) |> stream_entries()}

  def handle_async(:online, {:exit, _reason}, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_info({:ticket_changed, ticket}, socket),
    do: {:noreply, socket |> Conversation.ticket_changed(ticket) |> schedule_reload()}

  def handle_info(:reload_inbox, socket) do
    socket = if socket.assigns[:reload_dirty?], do: load(socket), else: socket
    {:noreply, socket |> assign(:reload_pending?, false) |> assign(:reload_dirty?, false)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic}, socket),
    do: {:noreply, Conversation.presence_changed(socket, topic)}

  def handle_info(:stop_typing, socket), do: {:noreply, Conversation.stop_typing(socket)}

  def handle_info({:crcon_stream_status, _server_id, _status}, socket),
    do: {:noreply, schedule_reload(socket)}

  def handle_info({:rule_fired, _execution}, socket), do: {:noreply, schedule_reload(socket)}
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  # The first change rebuilds the list at once; more changes within the
  # next moment wait for the end of it and rebuild it once.
  defp schedule_reload(%{assigns: %{reload_pending?: true}} = socket),
    do: assign(socket, :reload_dirty?, true)

  defp schedule_reload(socket) do
    Process.send_after(self(), :reload_inbox, @reload_after)

    socket
    |> assign(:reload_pending?, true)
    |> assign(:reload_dirty?, false)
    |> load()
  end

  # ── The list ───────────────────────────────────────────────────────────────

  defp load(socket) do
    %{current_user: user, servers: servers} = socket.assigns
    now = DateTime.utc_now()
    stream_status = Map.new(servers, &{&1.id, LogStream.status(&1.id)})
    %{open: open, handled: handled} = Attention.items(user, servers, stream_status)

    tickets = list_tickets(socket, :active)
    shown = MapSet.new(tickets, & &1.id)

    # A ticket waiting too long is its own row, marked urgent.
    {waiting, items} =
      Enum.split_with(open, &(&1.kind == :ticket_waiting and &1.subject.ticket.id in shown))

    overdue = MapSet.new(waiting, & &1.subject.ticket.id)

    entries =
      (Enum.map(items, &item_entry/1) ++
         Enum.map(tickets, &ticket_entry(&1, socket, overdue, now)))
      |> Enum.sort_by(&{&1.rank, sort_time(&1.at)})

    resolved =
      if socket.assigns.chip == "resolved",
        do: Enum.map(list_tickets(socket, :closed), &ticket_entry(&1, socket, overdue, now)),
        else: []

    socket
    |> assign(:entries, entries)
    |> assign(:resolved, resolved)
    |> assign(:handled, handled)
    |> assign(:now, now)
    |> assign(:today, today(socket))
    |> stream_entries()
    |> refresh_bell()
    |> check_online(items)
  end

  # A player a rule put on the watchlist who is on a server again shows as
  # "back". CRCON is asked in the background, at most once a minute, and
  # only about the servers with such players.
  defp check_online(socket, items) do
    reviews = Enum.filter(items, &(&1.kind == :review))
    checked = socket.assigns.online_checked_at
    now = System.monotonic_time(:millisecond)

    cond do
      not connected?(socket) or reviews == [] ->
        socket

      checked && now - checked < @online_every ->
        socket

      true ->
        server_ids = reviews |> Enum.map(& &1.subject.execution.server_id) |> Enum.uniq()
        servers = Enum.filter(socket.assigns.servers, &(&1.id in server_ids))

        socket
        |> assign(:online_checked_at, now)
        |> start_async(:online, fn -> online_players(servers) end)
    end
  end

  defp online_players(servers) do
    for server <- servers,
        {:ok, %{"players" => %{} = players}} <- [
          HllConditionalActions.Crcon.get_detailed_players(server)
        ],
        player_id <- Map.keys(players),
        into: MapSet.new(),
        do: {server.id, player_id}
  end

  defp today(%{assigns: %{tickets?: false}}), do: nil

  defp today(socket) do
    %{current_user: user, ticket_server_ids: ids, timezone: timezone} = socket.assigns
    Stats.today(user, ids, timezone)
  end

  defp list_tickets(%{assigns: %{tickets?: false}}, _view), do: []

  defp list_tickets(socket, view) do
    ids = socket.assigns.ticket_server_ids

    socket.assigns.current_user
    |> Tickets.list_tickets(view: view, limit: if(view == :closed, do: 50, else: 200))
    |> Enum.filter(&(&1.server_id in ids))
  end

  # Filters the entries and streams what shows; the counts on the tabs and
  # chips come from the same pass.
  defp stream_entries(socket) do
    %{entries: entries, owner: owner, chip: chip, query: query} = socket.assigns

    searched = Enum.filter(entries, &matches?(&1, query))
    owned = Enum.filter(searched, &owned?(&1, owner))

    visible =
      case chip do
        "resolved" ->
          Enum.filter(socket.assigns.resolved, &(matches?(&1, query) and owned?(&1, owner)))

        nil ->
          owned

        chip ->
          Enum.filter(owned, &(chip in &1.groups))
      end

    socket
    |> assign(
      :owner_counts,
      Map.new(@owners, &{&1, Enum.count(searched, fn e -> owned?(e, &1) end)})
    )
    |> assign(:chip_counts, Map.new(@chips, &{&1, Enum.count(owned, fn e -> &1 in e.groups end)}))
    |> assign(:visible_count, length(visible))
    |> stream(
      :entries,
      Enum.map(
        visible,
        &(&1 |> mark_selected(socket.assigns.selected) |> mark_back(socket.assigns.online))
      ),
      reset: true,
      dom_id: & &1.id
    )
  end

  defp mark_selected(entry, selected), do: Map.put(entry, :selected?, entry.key == selected)

  # A player to review who is on the server right now.
  defp mark_back(%{item: %{kind: :review, subject: %{execution: execution}}} = entry, online) do
    if MapSet.member?(online, {execution.server_id, execution.player_id}) do
      name = execution.player_name || execution.player_id

      %{
        entry
        | title: gettext("%{player} is back", player: name),
          detail: gettext("On the watchlist · %{rule}", rule: execution.rule.name)
      }
    else
      entry
    end
  end

  defp mark_back(entry, _online), do: entry

  defp matches?(_entry, ""), do: true

  defp matches?(entry, query),
    do: String.contains?(entry.search, String.downcase(query))

  defp owned?(_entry, "all"), do: true
  defp owned?(entry, "mine"), do: entry.owner == :mine
  defp owned?(entry, "unowned"), do: entry.owner == :unowned

  # Handling an item here takes it off the header's bell at once.
  defp refresh_bell(%{assigns: %{nav: %{attention: count} = nav}} = socket)
       when is_integer(count) do
    user = socket.assigns.current_user
    servers = socket.assigns.servers
    statuses = Map.new(servers, &{&1.id, LogStream.status(&1.id)})
    assign(socket, :nav, %{nav | attention: Attention.count(user, servers, statuses)})
  end

  defp refresh_bell(socket), do: socket

  # ── Entries ────────────────────────────────────────────────────────────────

  defp item_entry(item) do
    %{
      id: "inbox-item-#{AttentionLive.item_dom_id(item.key)}",
      key: {:item, item.key},
      type: :item,
      item: item,
      ticket: nil,
      at: item.at,
      rank: item_rank(item.severity),
      groups: item_groups(item),
      owner: :unowned,
      title: row_title(item),
      detail: row_detail(item),
      search:
        String.downcase(
          Enum.join(
            [
              row_title(item),
              row_detail(item),
              AttentionLive.item_title(item),
              AttentionLive.item_detail(item)
            ],
            " "
          )
        )
    }
  end

  defp item_rank(:error), do: 0
  defp item_rank(:warning), do: 1
  defp item_rank(_info), do: 3

  defp item_groups(item) do
    kind =
      case item.kind do
        kind when kind in [:stream_down, :rule_broken, :failures] -> ["rules"]
        kind when kind in [:review, :vip_failed] -> ["players"]
        kind when kind in [:ready_to_go_live, :rule_quiet] -> ["suggestions"]
        :ticket_waiting -> ["tickets"]
        _other -> []
      end

    if item.severity == :error, do: ["urgent" | kind], else: kind
  end

  # The short title and line a row of the Caixa shows for an Attention item;
  # the item's own page has the longer wording.
  defp row_title(%{kind: :stream_down}), do: gettext("Stream down")

  defp row_title(%{kind: :failures, subject: %{rule: rule, count: count}}),
    do: gettext("%{rule} failed %{count}×", rule: rule.name, count: count)

  defp row_title(%{kind: kind, subject: %{rule: rule}}) when kind in [:rule_broken, :rule_quiet],
    do: rule.name

  defp row_title(%{kind: :ready_to_go_live, subject: %{rule: rule}}),
    do: gettext("%{rule} ready to act", rule: rule.name)

  defp row_title(%{kind: :vip_failed}), do: gettext("Paid VIP not granted")
  defp row_title(item), do: AttentionLive.item_title(item)

  defp row_detail(%{kind: :stream_down, subject: %{server: server}}),
    do: gettext("%{server} · rules are blind", server: server.name)

  defp row_detail(%{kind: :failures, subject: %{error: error}}),
    do: error || gettext("unknown error")

  defp row_detail(%{kind: kind, subject: %{issue: issue}})
       when kind in [:rule_broken, :rule_quiet],
       do: Labels.health_issue(issue.id)

  defp row_detail(%{kind: :ready_to_go_live, subject: %{rule: rule, runs: runs}}) do
    days = max(1, DateTime.diff(DateTime.utc_now(), rule.inserted_at, :day))

    ngettext("1 day simulating", "%{count} days simulating", days) <>
      " · " <> ngettext("1 run", "%{count} runs", runs)
  end

  defp row_detail(%{kind: :review, subject: %{execution: execution}}),
    do: "#{execution.rule.name} · #{execution.server.name}"

  defp row_detail(%{kind: :vip_failed, subject: %{order: order}}),
    do: gettext("Order #%{id} · %{package}", id: order.id, package: order.package_name)

  defp row_detail(item), do: AttentionLive.item_detail(item)

  defp ticket_entry(ticket, socket, overdue, now) do
    me = socket.assigns.current_user.id
    minutes = attention_minutes(socket.assigns.settings_by_server, ticket.server_id)
    age = TicketIndex.age_tone(ticket, minutes, now)
    urgent? = ticket.status != :closed and (ticket.priority == :urgent or ticket.id in overdue)

    %{
      id: "inbox-ticket-#{ticket.id}",
      key: {:ticket, ticket.id},
      type: :ticket,
      item: nil,
      ticket: ticket,
      at: ticket.last_activity_at,
      rank: ticket_rank(ticket, urgent?),
      groups: if(urgent?, do: ["urgent", "tickets"], else: ["tickets"]),
      owner:
        cond do
          is_nil(ticket.assigned_to_id) -> :unowned
          ticket.assigned_to_id == me -> :mine
          true -> :other
        end,
      age: if(urgent? and age != :idle, do: :overdue, else: age),
      waited: wait_share(ticket, minutes, now),
      search:
        String.downcase(
          "##{ticket.id} #{ticket.id} #{ticket.player_name} #{ticket.player_id} #{ticket.category} " <>
            "#{ticket.reported_player_name} " <> ticket.server.name
        )
    }
  end

  defp ticket_rank(_ticket, true), do: 0
  defp ticket_rank(%{status: :open, priority: :high}, false), do: 1
  defp ticket_rank(%{status: :open}, false), do: 2
  defp ticket_rank(%{status: :closed}, false), do: 4
  defp ticket_rank(_answered, false), do: 3

  defp attention_minutes(settings_by_server, server_id) do
    case settings_by_server[server_id] do
      %{attention_minutes: minutes} when is_integer(minutes) and minutes > 0 -> minutes
      _other -> @default_attention_minutes
    end
  end

  # How much of the server's alert time the player has waited, in percent,
  # for a ticket nobody picked up yet.
  defp wait_share(
         %{status: :open, assigned_to_id: nil, last_activity_at: %DateTime{} = at},
         minutes,
         now
       ) do
    waited = DateTime.diff(now, at, :second)
    waited |> Kernel./(minutes * 60) |> Kernel.*(100) |> round() |> max(4) |> min(100)
  end

  defp wait_share(_ticket, _minutes, _now), do: nil

  # Newest first within a rank; rows without a time go last.
  defp sort_time(nil), do: 0
  defp sort_time(%DateTime{} = at), do: -DateTime.to_unix(at)

  defp entry_path(%{key: {:ticket, id}}, owner), do: inbox_path(owner, ticket: id)
  defp entry_path(%{key: {:item, key}}, owner), do: inbox_path(owner, item: key)

  # The Caixa's address: the owner tab and what is open, the defaults left out.
  defp inbox_path(owner, open \\ []) do
    params = if owner == "all", do: open, else: [{:owner, owner} | open]
    if params == [], do: ~p"/inbox", else: ~p"/inbox?#{params}"
  end

  # The owner tabs, beside the page title.
  defp owner_tabs(assigns) do
    open =
      case assigns.selected do
        {:ticket, id} -> [ticket: id]
        {:item, key} -> [item: key]
        nil -> []
      end

    Enum.map(@owners, fn owner ->
      %{
        label: owner_tab_label(owner),
        path: inbox_path(owner, open),
        patch: true,
        active: assigns.owner == owner,
        count: assigns.owner_counts[owner]
      }
    end)
  end

  defp last_line(ticket) do
    ticket.messages
    |> Enum.filter(&(&1.author == :player))
    |> List.last()
  end

  @doc """
  How long ago, the way the Caixa's rows say it: "4 min", "2 h",
  "yesterday", "3 d".
  """
  @spec short_age(DateTime.t() | nil, DateTime.t()) :: String.t()
  def short_age(nil, _now), do: ""

  def short_age(at, now) do
    seconds = max(DateTime.diff(now, at), 0)

    cond do
      seconds < 60 -> gettext("now")
      seconds < 3600 -> gettext("%{count} min", count: div(seconds, 60))
      seconds < 86_400 -> gettext("%{count} h", count: div(seconds, 3600))
      seconds < 172_800 -> gettext("yesterday")
      true -> gettext("%{count} d", count: div(seconds, 86_400))
    end
  end

  # The line under a ticket row: who has it and whose turn it is.
  defp owner_line(%{ticket: %{status: :closed} = ticket}),
    do: Labels.close_reason(ticket.close_reason || "resolved")

  defp owner_line(%{ticket: %{status: :answered}} = entry),
    do: gettext("Waiting for the player") <> " · " <> owner_label(entry)

  defp owner_line(%{owner: :unowned}), do: gettext("unassigned")
  defp owner_line(%{owner: :mine}), do: gettext("With you")

  defp owner_line(%{ticket: %{assigned_to: %{} = user}}),
    do: gettext("With %{name}", name: user.name || user.username)

  defp owner_line(_entry), do: gettext("Assigned")

  defp owner_label(%{owner: :unowned}), do: gettext("unassigned")
  defp owner_label(%{owner: :mine}), do: gettext("you")

  defp owner_label(%{ticket: %{assigned_to: %{} = user}}),
    do: gettext("with %{name}", name: user.name || user.username)

  defp owner_label(_entry), do: gettext("assigned")

  defp time_class(%{type: :item, rank: 0}), do: "text-error"
  defp time_class(%{type: :ticket, age: :overdue}), do: "text-error"
  defp time_class(%{type: :ticket, age: :aging}), do: "text-warning"
  defp time_class(%{type: :ticket, waited: waited}) when is_integer(waited), do: "text-warning"
  defp time_class(_entry), do: "text-muted"

  defp wait_class(:overdue), do: "text-error"
  defp wait_class(_age), do: "text-warning"

  # "Urgente 1": the chip and its count; the resolved one has none.
  defp chip_text("resolved", _counts), do: chip_label("resolved")
  defp chip_text(chip, counts), do: "#{chip_label(chip)} #{counts[chip]}"

  defp chip_label("urgent"), do: gettext("Urgent")
  defp chip_label("tickets"), do: gettext("Tickets")
  defp chip_label("rules"), do: gettext("Rules")
  defp chip_label("players"), do: gettext("Players")
  defp chip_label("suggestions"), do: gettext("Suggestions")
  defp chip_label("resolved"), do: gettext("Solved")

  defp owner_tab_label("all"), do: gettext("Everything")
  defp owner_tab_label("mine"), do: gettext("Mine")
  defp owner_tab_label("unowned"), do: gettext("Unowned")

  defp severity_label(:error), do: gettext("Urgent")
  defp severity_label(:warning), do: gettext("To review")
  defp severity_label(_info), do: gettext("Suggestion")

  defp severity_pill(:error), do: "error"
  defp severity_pill(:warning), do: "warning"
  defp severity_pill(_info), do: "engine"

  defp minutes_label(nil), do: "–"
  defp minutes_label(seconds) when seconds < 60, do: gettext("%{count} s", count: seconds)
  defp minutes_label(seconds), do: gettext("%{count} min", count: div(seconds, 60))

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :selected_item,
        case assigns.selected do
          {:item, key} -> Enum.find(assigns.entries, &(&1.key == {:item, key}))
          _other -> nil
        end
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      tabs={owner_tabs(assigns)}
      inline_tabs
      bell={false}
    >
      <:search>
        <form id="inbox-search" phx-change="search" phx-submit="search" role="search">
          <label class="flex h-12 w-12 cursor-text items-center gap-2.5 overflow-hidden rounded-full border border-base-300 bg-base-100 px-[0.9375rem] text-muted transition-[width] focus-within:w-64 xl:w-[18.75rem] xl:px-[1.125rem] has-[input:not(:placeholder-shown)]:w-64 xl:has-[input:not(:placeholder-shown)]:w-[18.75rem]">
            <.icon name="hero-magnifying-glass" class="size-[1.125rem] shrink-0" />
            <input
              type="search"
              name="q"
              value={@query}
              phx-debounce="200"
              aria-label={gettext("Search the inbox")}
              placeholder={gettext("Search by player or ticket")}
              class="min-w-0 flex-1 border-0 bg-transparent p-0 text-sm text-base-content outline-none placeholder:text-muted focus:ring-0"
            />
          </label>
        </form>
      </:search>
      <:actions>
        <TicketComponents.alert_toggle :if={@tickets?} id="inbox-alert-toggle" compact />
        <.link
          :if={@configure_path}
          id="inbox-configure"
          navigate={@configure_path}
          aria-label={gettext("Configure tickets")}
          class="inline-flex h-12 items-center gap-2 rounded-full border border-base-300 bg-base-100 px-3.5 text-sm font-semibold transition-colors hover:bg-secondary lg:px-5"
        >
          <.icon name="hero-cog-6-tooth" class="size-[1.125rem] shrink-0" />
          <span class="hidden lg:inline">{gettext("Configure tickets")}</span>
        </.link>
      </:actions>

      <TicketComponents.frame
        id="inbox-grid"
        class="grid grid-cols-[minmax(0,1fr)] gap-4 md:mt-4 xl:mt-0 md:grid-cols-[18.75rem_minmax(0,1fr)] min-[85rem]:grid-cols-[26.25rem_minmax(0,1fr)_20rem] min-[85rem]:gap-5"
      >
        <section
          id="inbox-list-panel"
          aria-label={gettext("Inbox items")}
          class={[
            "inbox-panel flex min-h-0 flex-col gap-1 rounded-[1.75rem] bg-base-100 p-3.5 min-[85rem]:gap-1.5 min-[85rem]:p-4",
            @selected && "max-md:hidden"
          ]}
        >
          <div
            id="inbox-chips"
            class="flex flex-wrap gap-1.5 px-0.5 pb-2.5 pt-0.5 min-[85rem]:px-1 min-[85rem]:pt-1"
          >
            <button
              :for={chip <- ~w(urgent tickets rules players suggestions resolved)}
              :if={@tickets? or chip not in ["tickets", "resolved"]}
              type="button"
              phx-click="chip"
              phx-value-chip={chip}
              data-chip={chip}
              aria-pressed={to_string(@chip == chip)}
              class={[
                "h-10 cursor-pointer whitespace-nowrap rounded-full border px-3 text-xs transition-colors min-[85rem]:h-8",
                cond do
                  @chip == chip ->
                    "border-base-content bg-base-content font-semibold text-base-100"

                  chip == "urgent" and @chip_counts[chip] > 0 ->
                    "border-error/40 bg-error/10 font-semibold text-error"

                  chip == "resolved" ->
                    "border-transparent text-subtle hover:text-base-content min-[85rem]:text-muted"

                  true ->
                    "inbox-chip border-base-300 hover:border-base-content/30"
                end
              ]}
            >
              {chip_text(chip, @chip_counts)}
            </button>
          </div>

          <p
            :if={@chip == "resolved" and @handled > 0}
            id="inbox-handled-note"
            class="mx-1 mb-1 rounded-2xl bg-secondary px-3 py-2 text-xs text-subtle"
          >
            {ngettext(
              "1 Attention item was marked as handled.",
              "%{count} Attention items were marked as handled.",
              @handled
            )}
            <.link navigate={~p"/attention"} class="text-primary hover:underline">
              {gettext("See Attention")}
            </.link>
          </p>

          <div
            :if={@visible_count == 0}
            id="inbox-empty"
            class="flex flex-col items-center gap-2 px-4 py-12 text-center"
          >
            <span class="flex size-12 items-center justify-center rounded-2xl bg-primary/12 text-primary">
              <.icon name="hero-sparkles" class="size-6" />
            </span>
            <p class="font-display text-lg font-semibold">
              {if @entries == [] and is_nil(@chip) and @query == "",
                do: gettext("All clear"),
                else: gettext("Nothing here")}
            </p>
            <p class="max-w-64 text-sm text-muted">
              {if @entries == [] and is_nil(@chip) and @query == "",
                do: gettext("Nothing needs you right now. New items show up here on their own."),
                else: gettext("No item matches these filters.")}
            </p>
          </div>

          <div
            id="inbox-list"
            phx-update="stream"
            class="-mx-1 flex min-h-0 flex-1 flex-col gap-1 overflow-y-auto px-1 min-[85rem]:gap-1.5"
          >
            <.link
              :for={{dom_id, entry} <- @streams.entries}
              id={dom_id}
              patch={entry_path(entry, @owner)}
              data-type={entry.type}
              aria-current={entry.selected? && "true"}
              class={[
                "flex shrink-0 gap-3 rounded-[1.125rem] border px-2.5 py-3 transition-colors min-[85rem]:p-3",
                if(entry.selected?,
                  do: "inbox-row-current",
                  else: "border-transparent hover:bg-secondary/60"
                )
              ]}
            >
              <%= if entry.type == :ticket do %>
                <TicketComponents.avatar_tile name={
                  entry.ticket.player_name || entry.ticket.player_id
                } />
              <% else %>
                <span class={[
                  "flex size-[2.375rem] shrink-0 items-center justify-center rounded-xl",
                  item_tint(entry.item)
                ]}>
                  <.icon name={AttentionLive.item_icon(entry.item)} class="size-[1.0625rem]" />
                </span>
              <% end %>
              <span class="flex min-w-0 flex-1 flex-col gap-[3px]">
                <span class="flex items-baseline justify-between gap-2">
                  <strong class="truncate text-sm font-semibold">
                    <%= if entry.type == :ticket do %>
                      #{entry.ticket.id} · {entry.ticket.player_name || entry.ticket.player_id}
                    <% else %>
                      {entry.title}
                    <% end %>
                  </strong>
                  <span
                    :if={entry.at}
                    class={["shrink-0 font-mono text-[0.6875rem]", time_class(entry)]}
                  >
                    {short_age(entry.at, @now)}
                  </span>
                </span>
                <span class={[
                  "truncate text-[0.8125rem]",
                  if(entry.selected?, do: "text-subtle", else: "text-muted")
                ]}>
                  <%= cond do %>
                    <% entry.type == :item -> %>
                      {entry.detail}
                    <% line = last_line(entry.ticket) -> %>
                      {line.body}
                    <% true -> %>
                      {entry.ticket.category || entry.ticket.server.name}
                  <% end %>
                </span>
                <span
                  :if={entry.type == :ticket and entry.waited}
                  class={["mt-1 flex items-center gap-2", wait_class(entry.age)]}
                >
                  <span class="inbox-wait" aria-hidden="true">
                    <span style={"width: #{entry.waited}%"}></span>
                  </span>
                  <span class="shrink-0 text-[0.6875rem] text-muted">{owner_line(entry)}</span>
                </span>
                <span
                  :if={entry.type == :ticket and is_nil(entry.waited)}
                  class="mt-0.5 truncate text-[0.6875rem] text-muted"
                >
                  {owner_line(entry)}
                </span>
              </span>
            </.link>
          </div>

          <.link
            :if={@today}
            id="inbox-today"
            navigate={~p"/tickets/metrics"}
            class="mt-auto flex min-h-14 shrink-0 items-center gap-3 rounded-[1.125rem] bg-secondary px-3.5 py-2.5 min-[85rem]:hidden"
          >
            <span class="flex min-w-0 flex-1 flex-col gap-0.5">
              <span class="text-xs text-muted">{gettext("Today")}</span>
              <span class="text-[0.8125rem]">
                {ngettext("1 resolved", "%{count} resolved", @today.resolved)} · {gettext(
                  "1st answer in"
                )} <strong class="font-semibold">{minutes_label(@today.median_response)}</strong>
              </span>
            </span>
            <.icon name="hero-chevron-right" class="size-4 shrink-0 text-muted" />
          </.link>
        </section>

        <%= cond do %>
          <% @ticket -> %>
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
            >
              <:lead>
                <.link
                  patch={inbox_path(@owner)}
                  aria-label={gettext("Back to the inbox")}
                  class="flex size-11 shrink-0 items-center justify-center self-start rounded-full border border-base-300 bg-base-100 md:hidden"
                >
                  <.icon name="hero-chevron-left" class="size-[1.125rem]" />
                </.link>
              </:lead>
            </TicketComponents.conversation>
            <TicketComponents.ticket_aside
              ticket={@ticket}
              player_info={@player_info}
              cited_info={@cited_info}
              ticket_count={@ticket_count}
              can_manage?={@can_manage?}
              can_act?={@can_act?}
              class="max-[85rem]:hidden"
            />
            <TicketComponents.ticket_sheets
              ticket={@ticket}
              pending_act={@pending_act}
              act_form={@act_form}
              more_open?={@more_open?}
              can_manage?={@can_manage?}
              assignable={@assignable}
              history={@history}
              transcript={@transcript}
              history_path={fn earlier -> inbox_path(@owner, ticket: earlier.id) end}
            />
          <% @selected_item -> %>
            <.item_detail
              item={@selected_item.item}
              owner={@owner}
              can_resolve?={@can_resolve?}
              current_user={@current_user}
            />
          <% @selected -> %>
            <section
              id="inbox-gone"
              class="inbox-panel flex min-h-0 flex-col items-center justify-center gap-3 rounded-[1.75rem] bg-base-100 p-8 text-center min-[85rem]:col-span-2"
            >
              <.icon_tile icon="hero-check" tone="primary" size="lg" />
              <p class="font-display text-xl font-semibold">{gettext("Not open anymore")}</p>
              <p class="max-w-sm text-sm text-muted">
                {gettext("Somebody dealt with it, or the problem went away on its own.")}
              </p>
              <.link patch={inbox_path(@owner)} class="text-sm text-primary hover:underline">
                {gettext("Back to the inbox")}
              </.link>
            </section>
          <% true -> %>
            <section
              id="inbox-pick"
              class="inbox-panel flex min-h-0 flex-col items-center justify-center gap-3 rounded-[1.75rem] bg-base-100 p-8 text-center max-md:hidden min-[85rem]:col-span-2"
            >
              <.icon_tile icon="hero-inbox" tone="neutral" size="lg" />
              <p class="font-display text-xl font-semibold">
                {gettext("Pick something from the list")}
              </p>
              <p class="max-w-sm text-sm text-muted">
                {gettext(
                  "A ticket opens its conversation here; anything else shows what it is about and where to deal with it."
                )}
              </p>
            </section>
        <% end %>
      </TicketComponents.frame>
    </Layouts.app>
    """
  end

  defp item_tint(item) do
    case AttentionLive.item_tone(item) do
      "error" -> "bg-error/14 text-error"
      "axis" -> "bg-axis/14 text-axis"
      "warning" -> "bg-warning/13 text-warning"
      "primary" -> "bg-primary/12 text-primary"
      _engine -> "bg-accent/13 text-accent"
    end
  end

  attr :item, :map, required: true
  attr :owner, :string, default: "all"
  attr :can_resolve?, :boolean, required: true
  attr :current_user, :map, required: true

  defp item_detail(assigns) do
    ~H"""
    <section
      id="inbox-item"
      data-kind={@item.kind}
      class="inbox-panel flex min-h-0 flex-col gap-6 overflow-y-auto rounded-[1.75rem] bg-base-100 p-6 sm:p-8 min-[85rem]:col-span-2"
    >
      <.link
        patch={inbox_path(@owner)}
        class="inline-flex w-fit items-center gap-1.5 text-sm text-subtle hover:text-base-content md:hidden"
      >
        <.icon name="hero-chevron-left" class="size-4" /> {gettext("Back to the inbox")}
      </.link>

      <div class="flex items-start gap-4">
        <.icon_tile
          icon={AttentionLive.item_icon(@item)}
          tone={AttentionLive.item_tone(@item)}
          size="lg"
        />
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-2">
            <.pill tone={severity_pill(@item.severity)}>{severity_label(@item.severity)}</.pill>
            <.local_time
              :if={@item.at}
              id="inbox-item-at"
              at={@item.at}
              class="font-mono text-xs text-muted"
            />
          </div>
          <h2 class="mt-3 font-display text-[1.375rem] font-semibold leading-tight">
            {AttentionLive.item_title(@item)}
          </h2>
          <p class="mt-2 break-words leading-relaxed text-subtle">
            {AttentionLive.item_detail(@item)}
          </p>
        </div>
      </div>

      <dl :if={facts(@item) != []} class="grid gap-2.5 sm:grid-cols-2">
        <div :for={{label, value, path} <- facts(@item)} class="rounded-2xl bg-secondary px-4 py-3">
          <dt class="text-xs text-muted">{label}</dt>
          <dd class="mt-0.5 truncate font-medium">
            <.link :if={path} navigate={path} class="hover:underline">{value}</.link>
            <span :if={!path}>{value}</span>
          </dd>
        </div>
      </dl>

      <div class="flex flex-wrap items-center gap-2">
        <.link
          navigate={AttentionLive.item_path(@item)}
          class="inbox-solid inline-flex h-11 items-center rounded-full px-5 text-sm font-semibold transition-opacity hover:opacity-90"
        >
          {AttentionLive.item_link_label(@item)}
        </.link>
        <button
          :if={@item.resolvable? and @can_resolve?}
          id="inbox-resolve"
          type="button"
          phx-click="resolve"
          phx-value-key={@item.key}
          class="inline-flex h-11 cursor-pointer items-center gap-1.5 rounded-full border border-base-300 bg-secondary px-[1.125rem] text-sm transition-colors hover:border-base-content/30"
        >
          <.icon name="hero-check" class="size-4" /> {gettext("Mark as handled")}
        </button>
      </div>

      <p class="mt-auto text-xs text-muted">
        {if @item.resolvable?,
          do:
            gettext(
              "Marking it as handled takes it off everybody's inbox. It comes back if it happens again."
            ),
          else: gettext("It leaves the inbox on its own once the problem is fixed.")}
      </p>
    </section>
    """
  end

  # The facts of an item worth a glance, each with where it leads.
  defp facts(%{kind: :stream_down, subject: %{server: server}}),
    do: [{gettext("Server"), server.name, ~p"/servers/#{server}"}]

  defp facts(%{kind: :ticket_waiting, subject: %{ticket: ticket}}),
    do: [
      {gettext("Player"), ticket.player_name || ticket.player_id,
       ~p"/players/#{ticket.player_id}"},
      {gettext("Server"), ticket.server.name, nil}
    ]

  defp facts(%{kind: kind, subject: %{rule: rule, issue: issue}})
       when kind in [:rule_broken, :rule_quiet],
       do: [
         {gettext("Rule"), rule.name, ~p"/rules/#{rule.id}"},
         {gettext("Problem"), Labels.health_issue(issue.id), nil}
       ]

  defp facts(%{kind: :failures, subject: %{rule: rule, count: count}}),
    do: [
      {gettext("Rule"), rule.name, ~p"/rules/#{rule.id}"},
      {gettext("Failures in the last day"), count, nil}
    ]

  defp facts(%{kind: :review, subject: %{execution: execution}}),
    do: [
      {gettext("Player"), execution.player_name || execution.player_id,
       ~p"/players/#{execution.player_id}"},
      {gettext("Rule"), execution.rule.name, ~p"/rules/#{execution.rule_id}"},
      {gettext("Server"), execution.server.name, nil}
    ]

  defp facts(%{kind: :ready_to_go_live, subject: %{rule: rule, runs: runs}}),
    do: [
      {gettext("Rule"), rule.name, ~p"/rules/#{rule.id}"},
      {gettext("Simulated runs"), runs, nil}
    ]

  defp facts(%{kind: :vip_failed, subject: %{order: order}}),
    do: [
      {gettext("Order"), "##{order.id}", nil},
      {gettext("Package"), order.package_name, nil},
      {gettext("Player"), order.player_name || order.player_id, nil}
    ]

  defp facts(_item), do: []
end
