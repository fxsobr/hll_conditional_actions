defmodule HllConditionalActionsWeb.CommandPalette do
  @moduledoc """
  The command palette (Ctrl K, or the search field in the header): one box
  that finds players, rules, tickets and past matches, offers the actions
  that go with the best player found, and jumps to any page.

  The searching is `HllConditionalActions.Search`, scoped to what the user
  may see. Past matches come from CRCON, so they are fetched once, in the
  background, the first time a query is long enough, and filtered locally
  from then on.

  Opening, closing and the keyboard (arrows, Enter, Tab, Esc) are the
  `CommandPalette` hook in `assets/js/shell.js`; this component only answers
  queries, so typing re-renders the palette and never the page under it.
  """

  use HllConditionalActionsWeb, :live_component

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Search
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.Layouts
  alias HllConditionalActionsWeb.MapArt
  alias HllConditionalActionsWeb.Nav
  alias HllConditionalActionsWeb.RelativeTime

  @groups ~w(players rules tickets matches actions pages)

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     assign(socket,
       query: "",
       filter: "all",
       results: empty(),
       recent: nil,
       matches_loading?: false
     )}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:current_user, assigns.current_user)
      |> assign(:nav, assigns[:nav])

    {:ok,
     if(socket.assigns.query == "",
       do: assign(socket, :results, pages_only(socket)),
       else: socket
     )}
  end

  @impl Phoenix.LiveComponent
  def handle_event("opened", _params, socket) do
    {:noreply, socket |> assign(query: "", filter: "all") |> assign(:results, pages_only(socket))}
  end

  def handle_event("search", %{"q" => query}, socket) do
    query = String.slice(query, 0, 80)
    {:noreply, socket |> assign(:query, query) |> assign(:filter, "all") |> run()}
  end

  def handle_event("filter", %{"filter" => filter}, socket) when filter in ["all" | @groups],
    do: {:noreply, assign(socket, :filter, filter)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveComponent
  def handle_async(:matches, {:ok, recent}, socket) do
    {:noreply, socket |> assign(recent: recent, matches_loading?: false) |> run()}
  end

  def handle_async(:matches, _failed, socket),
    do: {:noreply, assign(socket, recent: [], matches_loading?: false)}

  defp run(socket) do
    %{current_user: user, query: query} = socket.assigns

    case Search.term(query) do
      nil ->
        assign(socket, :results, pages_only(socket))

      term ->
        players = Search.players(user, term)
        player_ids = Enum.map(players, & &1.id)

        socket = maybe_fetch_matches(socket, term)

        names = Map.new(players, &{&1.id, &1.name || &1.id})

        rules =
          user
          |> Search.rules(term, player_ids)
          |> Enum.map(&Map.put(&1, :player_name, names[&1.player_id]))

        assign(socket, :results, %{
          players: players,
          rules: rules,
          tickets: Search.tickets(user, term),
          matches: Search.matches(socket.assigns.recent || [], term),
          actions: actions(user, socket.assigns.nav, List.first(players)),
          pages: socket |> pages() |> filter_pages(term)
        })
    end
  end

  # CRCON is asked once per page, the first time a query could name a map.
  defp maybe_fetch_matches(%{assigns: %{recent: nil, matches_loading?: false}} = socket, term)
       when byte_size(term) >= 3 do
    user = socket.assigns.current_user

    if Accounts.can?(user, :view_stats) do
      servers =
        user
        |> Servers.list_servers_for()
        |> Enum.filter(&Nav.feature?(Map.put(socket.assigns.nav || %{}, :server, &1), :stats))

      socket
      |> assign(:matches_loading?, true)
      |> start_async(:matches, fn -> Search.recent_matches(servers) end)
    else
      assign(socket, :recent, [])
    end
  end

  defp maybe_fetch_matches(socket, _term), do: socket

  defp empty, do: Map.new(@groups, &{String.to_existing_atom(&1), []})

  defp pages_only(socket), do: %{empty() | pages: pages(socket)}

  # ── Actions and pages ──────────────────────────────────────────────────────

  # What can be done about the best player found: open them, message or ban
  # them (both confirmed on the player page), and watch where they were last
  # seen.
  defp actions(_user, _nav, nil), do: []

  defp actions(user, nav, player) do
    name = player.name || player.id

    server =
      player.server_id && Enum.find((nav && nav[:servers]) || [], &(&1.id == player.server_id))

    manage? = Accounts.can?(user, :manage_players)

    [
      manage? &&
        %{
          id: "ban",
          icon: "hero-no-symbol",
          tone: "axis",
          label: {gettext("Ban"), name},
          hint: gettext("asks for a reason and a confirmation"),
          path: ~p"/players/#{player.id}?#{[act: "ban"]}"
        },
      manage? &&
        %{
          id: "message",
          icon: "hero-chat-bubble-left",
          tone: "neutral",
          label: {gettext("Message"), name},
          hint: gettext("in game"),
          path: ~p"/players/#{player.id}?#{[act: "message"]}"
        },
      server && Accounts.can?(user, :view_live_feed) &&
        %{
          id: "feed",
          icon: "hero-signal",
          tone: "neutral",
          label: {gettext("Open the feed of %{server}", server: server.name), nil},
          hint: gettext("where %{player} was last seen", player: name),
          path: ~p"/servers/#{server.id}/feed"
        }
    ]
    |> Enum.filter(& &1)
  end

  # Every page the user can open, by area, plus the few commands worth a
  # shortcut.
  defp pages(socket) do
    user = socket.assigns.current_user
    nav = socket.assigns.nav
    area_pages = user |> Layouts.areas(nav) |> Enum.flat_map(&area_pages/1)
    base = if nav && nav[:server], do: "/servers/#{nav.server.id}", else: ""

    (area_pages ++ commands(user, nav, base)) |> Enum.uniq_by(& &1.path)
  end

  defp area_pages(area) do
    [%{label: area.label, hint: nil, path: area.path, icon: area.icon}] ++
      for tab <- area.tabs,
          tab.path != area.path,
          do: %{label: tab.label, hint: area.label, path: tab.path, icon: area.icon}
  end

  defp commands(user, nav, base) do
    [
      (Accounts.can?(user, :view_tickets) and Nav.feature?(nav, :tickets)) &&
        %{
          label: gettext("Tickets"),
          hint: gettext("Inbox"),
          path: base <> "/tickets",
          icon: "hero-chat-bubble-left"
        },
      Accounts.can?(user, :view_executions) &&
        %{
          label: gettext("Attention"),
          hint: gettext("Inbox"),
          path: base <> "/attention",
          icon: "hero-exclamation-triangle"
        },
      Accounts.can?(user, :manage_rules) &&
        %{
          label: gettext("New rule"),
          hint: gettext("Rules"),
          path: ~p"/rules/new",
          icon: "hero-plus"
        },
      Accounts.can?(user, :view_servers) &&
        %{
          label: gettext("Servers"),
          hint: gettext("Settings"),
          path: ~p"/servers",
          icon: "hero-server-stack"
        },
      Accounts.can?(user, :manage_servers) &&
        %{
          label: gettext("Add a server"),
          hint: gettext("Settings"),
          path: ~p"/servers/new",
          icon: "hero-plus"
        },
      Accounts.can?(user, :manage_integrations) &&
        %{
          label: gettext("Discord"),
          hint: gettext("Settings"),
          path: ~p"/discord",
          icon: "hero-chat-bubble-left-right"
        },
      Accounts.can?(user, :view_executions) &&
        %{
          label: gettext("Engine metrics"),
          hint: gettext("Settings"),
          path: ~p"/metrics",
          icon: "hero-chart-bar"
        },
      %{
        label: gettext("My account"),
        hint: gettext("Settings"),
        path: ~p"/account",
        icon: "hero-user-circle"
      }
    ]
    |> Enum.filter(& &1)
  end

  defp filter_pages(pages, term) do
    needle = String.downcase(term)

    pages
    |> Enum.filter(fn page ->
      String.contains?(String.downcase(page.label), needle) or
        String.contains?(String.downcase(page.hint || ""), needle)
    end)
    |> Enum.take(6)
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveComponent
  def render(assigns) do
    term = Search.term(assigns.query)
    counts = Map.new(assigns.results, fn {group, list} -> {group, length(list)} end)
    total = counts |> Map.values() |> Enum.sum()

    groups =
      for group <- @groups,
          key = String.to_existing_atom(group),
          assigns.filter in ["all", group],
          do: {group, Map.fetch!(assigns.results, key)}

    assigns =
      assign(assigns,
        term: term,
        counts: counts,
        total: total,
        groups: groups,
        now: DateTime.utc_now(),
        signature: :erlang.phash2({assigns.query, assigns.filter, counts})
      )

    ~H"""
    <div id={@id}>
      <dialog
        id="command-palette-dialog"
        class="palette"
        phx-hook="CommandPalette"
        aria-label={gettext("Command palette")}
        data-results={@signature}
      >
        <div class="palette-panel">
          <form
            id="command-palette-form"
            phx-change="search"
            phx-submit="search"
            phx-target={@myself}
            class="palette-input-row"
          >
            <.icon name="hero-magnifying-glass" class="size-[1.375rem] shrink-0 text-primary" />
            <input
              id="command-palette-input"
              name="q"
              value={@query}
              type="text"
              autocomplete="off"
              spellcheck="false"
              phx-debounce="150"
              aria-label={gettext("Search or run a command")}
              aria-controls="command-palette-results"
              placeholder={gettext("Search players, rules, matches…")}
              class="palette-input"
            />
            <span :if={@term} class="shrink-0 text-xs text-muted">
              {ngettext("1 result", "%{count} results", @total)}
            </span>
            <kbd class="kbd">Esc</kbd>
          </form>

          <div
            :if={@term}
            role="tablist"
            aria-label={gettext("Filter results")}
            class="flex flex-wrap gap-1.5 px-[1.125rem] pb-1 pt-3"
          >
            <button
              type="button"
              role="tab"
              aria-selected={to_string(@filter == "all")}
              class="palette-filter"
              phx-click="filter"
              phx-value-filter="all"
              phx-target={@myself}
            >
              {gettext("Everything")}
            </button>
            <button
              :for={group <- ~w(players rules tickets matches actions pages)}
              :if={@counts[String.to_existing_atom(group)] > 0}
              type="button"
              role="tab"
              aria-selected={to_string(@filter == group)}
              class="palette-filter"
              phx-click="filter"
              phx-value-filter={group}
              phx-target={@myself}
            >
              {group_label(group)} {@counts[String.to_existing_atom(group)]}
            </button>
          </div>

          <div id="command-palette-results" role="listbox" class="palette-results">
            <%= for {group, items} <- @groups, items != [] do %>
              <p class="palette-heading" data-group={group}>{group_heading(group, @term)}</p>
              <.result
                :for={item <- items}
                group={group}
                item={item}
                term={@term}
                now={@now}
                nav={@nav}
              />
            <% end %>

            <p :if={@matches_loading? and @filter in ["all", "matches"]} class="palette-heading">
              {gettext("Looking for matches…")}
            </p>

            <div :if={@term && @total == 0 && !@matches_loading?} class="px-4 py-10 text-center">
              <p class="font-display text-lg font-semibold">{gettext("Nothing found")}</p>
              <p class="mt-1 text-[0.8125rem] text-subtle">
                {gettext("Nothing with “%{term}” among players, rules, tickets and matches.",
                  term: @term
                )}
              </p>
            </div>
          </div>

          <div class="palette-footer">
            <span class="flex items-center gap-1.5">
              <kbd class="kbd kbd--sm">↑</kbd><kbd class="kbd kbd--sm">↓</kbd>
              {gettext("navigate")}
            </span>
            <span class="flex items-center gap-1.5">
              <kbd class="kbd kbd--sm">Enter</kbd> {gettext("open")}
            </span>
            <span class="hidden items-center gap-1.5 sm:flex">
              <kbd class="kbd kbd--sm">Tab</kbd> {gettext("result actions")}
            </span>
            <span class="flex-1"></span>
            <span class="flex items-center gap-1.5">
              <kbd class="kbd kbd--sm">Esc</kbd> {gettext("close")}
            </span>
          </div>
        </div>
      </dialog>
    </div>
    """
  end

  attr :group, :string, required: true
  attr :item, :map, required: true
  attr :term, :string, default: nil
  attr :now, :any, required: true
  attr :nav, :map, default: nil

  defp result(%{group: "players"} = assigns) do
    ~H"""
    <.link navigate={~p"/players/#{@item.id}"} role="option" class="palette-option" data-option>
      <span class="palette-tile palette-tile--axis text-xs font-bold">{initials(@item.name)}</span>
      <span class="palette-text">
        <span class="palette-title"><.marked text={@item.name || @item.id} term={@term} /></span>
        <span class="palette-sub">{player_line(@item, @now, @nav)}</span>
      </span>
      <kbd class="kbd palette-enter">Enter</kbd>
    </.link>
    """
  end

  defp result(%{group: "rules"} = assigns) do
    ~H"""
    <.link navigate={~p"/rules/#{@item.rule.id}"} role="option" class="palette-option" data-option>
      <span class="palette-tile palette-tile--engine"><.icon name="hero-bolt" class="size-4" /></span>
      <span class="palette-text">
        <span class="palette-title"><.marked text={@item.rule.name} term={@term} /></span>
        <span class="palette-sub">
          {String.downcase(rule_state_label(@item.rule))}
          <%= if server_name(@item.rule) do %>
            · {server_name(@item.rule)}
          <% end %>
          <%= if @item.hits > 0 and @item.player_name do %>
            · {ngettext("hit %{player} once", "hit %{player} %{count} times", @item.hits,
              player: @item.player_name
            )}
          <% end %>
        </span>
      </span>
      <kbd class="kbd palette-enter">Enter</kbd>
    </.link>
    """
  end

  defp result(%{group: "tickets"} = assigns) do
    ~H"""
    <.link
      navigate={~p"/inbox?#{[ticket: @item.ticket.id]}"}
      role="option"
      class="palette-option"
      data-option
    >
      <span class={[
        "palette-tile font-mono text-[0.6875rem]",
        @item.ticket.status == :closed && "text-subtle"
      ]}>
        #{@item.ticket.id}
      </span>
      <span class="palette-text">
        <span class="palette-title">
          <.marked text={ticket_title(@item.ticket)} term={@term} />
        </span>
        <span class="palette-sub">
          {ticket_line(@item.ticket, @now)}
          <%= if @item.snippet do %>
            · “<.marked text={clip(@item.snippet)} term={@term} />”
          <% end %>
        </span>
      </span>
      <span
        :if={@item.ticket.status != :closed and @item.ticket.priority in [:high, :urgent]}
        class={[
          "rounded-full px-2.5 py-1 text-[0.6875rem] font-bold",
          if(@item.ticket.priority == :urgent,
            do: "bg-error/14 text-error",
            else: "bg-axis/14 text-axis"
          )
        ]}
      >
        {Labels.ticket_priority(@item.ticket.priority)}
      </span>
      <kbd class="kbd palette-enter">Enter</kbd>
    </.link>
    """
  end

  defp result(%{group: "matches"} = assigns) do
    ~H"""
    <.link
      navigate={~p"/servers/#{@item.server.id}/matches/#{@item.id}"}
      role="option"
      class="palette-option"
      data-option
    >
      <img
        src={MapArt.url(@item.server.game, @item.layer || @item.map)}
        alt=""
        class="size-[2.125rem] shrink-0 rounded-[0.6875rem] object-cover"
      />
      <span class="palette-text">
        <span class="palette-title">
          <.marked text={@item.map} term={@term} />
          <span :if={@item.mode} class="font-normal text-muted">· {@item.mode}</span>
        </span>
        <span class="palette-sub">
          {@item.server.name}
          <%= if is_integer(@item.allied) and is_integer(@item.axis) do %>
            · <span class="text-allies">{@item.allied}</span>:<span class="text-axis">{@item.axis}</span>
          <% end %>
          <%= if @item.started_at do %>
            · {RelativeTime.ago(@item.started_at, @now)}
          <% end %>
        </span>
      </span>
      <kbd class="kbd palette-enter">Enter</kbd>
    </.link>
    """
  end

  defp result(%{group: "actions"} = assigns) do
    ~H"""
    <.link
      navigate={@item.path}
      role="option"
      class="palette-option"
      data-option
      data-action={@item.id}
    >
      <span class={["palette-tile", @item.tone == "axis" && "palette-tile--axis"]}>
        <.icon name={@item.icon} class="size-4" />
      </span>
      <span class="palette-title flex-1">
        <%= case @item.label do %>
          <% {verb, nil} -> %>
            {verb}
          <% {verb, name} -> %>
            {verb} <.marked text={name} term={@term} />…
        <% end %>
      </span>
      <span class="hidden text-xs text-muted sm:inline">{@item.hint}</span>
      <kbd class="kbd palette-enter">Enter</kbd>
    </.link>
    """
  end

  defp result(%{group: "pages"} = assigns) do
    ~H"""
    <.link navigate={@item.path} role="option" class="palette-option" data-option>
      <span class="palette-tile"><.icon name={@item.icon} class="size-4" /></span>
      <span class="palette-title flex-1"><.marked text={@item.label} term={@term} /></span>
      <span :if={@item.hint} class="text-xs text-muted">{@item.hint}</span>
      <kbd class="kbd palette-enter">Enter</kbd>
    </.link>
    """
  end

  attr :text, :string, required: true
  attr :term, :string, default: nil

  # The part of a name that matched, in the signal colour.
  defp marked(assigns) do
    assigns = assign(assigns, :parts, split_match(assigns.text || "", assigns.term))

    ~H"""
    <%= for {kind, part} <- @parts do %>
      <span :if={kind == :hit} class="text-primary">{part}</span>
      <%= if kind == :text do %>
        {part}
      <% end %>
    <% end %>
    """
  end

  @doc false
  @spec split_match(String.t(), String.t() | nil) :: [{:hit | :text, String.t()}]
  def split_match(text, nil), do: [{:text, text}]

  def split_match(text, term) do
    case Regex.compile(Regex.escape(term), "iu") do
      {:ok, regex} ->
        regex
        |> Regex.split(text, include_captures: true, trim: true)
        |> Enum.map(&match_part(&1, term))

      _error ->
        [{:text, text}]
    end
  end

  defp match_part(part, term) do
    if String.downcase(part) == String.downcase(term), do: {:hit, part}, else: {:text, part}
  end

  # ── Wording ────────────────────────────────────────────────────────────────

  defp group_label("players"), do: gettext("Players")
  defp group_label("rules"), do: gettext("Rules")
  defp group_label("tickets"), do: gettext("Tickets")
  defp group_label("matches"), do: gettext("Matches")
  defp group_label("actions"), do: gettext("Actions")
  defp group_label("pages"), do: gettext("Pages")

  defp group_heading("rules", term) when is_binary(term), do: gettext("Rules that mention")
  defp group_heading("pages", nil), do: gettext("Go to")
  defp group_heading(group, _term), do: group_label(group)

  defp player_line(player, now, nav) do
    server =
      player.server_id &&
        Enum.find((nav && nav[:servers]) || [], &(&1.id == player.server_id))

    [
      player.seen_at &&
        if(server,
          do:
            gettext("seen %{ago} on %{server}",
              ago: RelativeTime.ago(player.seen_at, now),
              server: server.name
            ),
          else: gettext("seen %{ago}", ago: RelativeTime.ago(player.seen_at, now))
        ),
      player.matches > 0 && ngettext("1 match", "%{count} matches", player.matches),
      player.hits > 0 && ngettext("1 rule hit", "%{count} rule hits", player.hits),
      player.tickets > 0 && ngettext("1 ticket", "%{count} tickets", player.tickets)
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp server_name(%{server: %{name: name}}), do: name
  defp server_name(_rule), do: nil

  defp ticket_title(ticket) do
    ticket.category ||
      gettext("Ticket from %{player}", player: ticket.player_name || ticket.player_id)
  end

  defp ticket_line(%{status: :closed} = ticket, _now) do
    by = ticket.closed_by && (ticket.closed_by.name || ticket.closed_by.username)
    date = ticket.closed_at && Calendar.strftime(ticket.closed_at, "%d/%m")

    cond do
      by && date -> gettext("closed by %{name} on %{date}", name: by, date: date)
      date -> gettext("closed on %{date}", date: date)
      true -> gettext("closed")
    end
  end

  defp ticket_line(ticket, now) do
    gettext("opened by %{player} %{ago}",
      player: ticket.player_name || ticket.player_id,
      ago: RelativeTime.ago(ticket.inserted_at, now)
    )
  end

  defp clip(text) do
    if String.length(text) > 60, do: String.slice(text, 0, 60) <> "…", else: text
  end

  defp initials(nil), do: "?"

  # Letters only: "Rudi_88" is RU, like the boards.
  defp initials(name) do
    case String.split(name, ~r/[^\p{L}]+/u, trim: true) do
      [] -> name |> String.slice(0, 2) |> String.upcase()
      [word] -> word |> String.slice(0, 2) |> String.upcase()
      [first, second | _rest] -> String.upcase(String.first(first) <> String.first(second))
    end
  end
end
