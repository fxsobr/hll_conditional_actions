defmodule HllConditionalActionsWeb.PlayerLive.Index do
  @moduledoc """
  Jogadores: every player this install knows, searchable, each opening the
  player 360 page.

  "Knows" is CRCON's player history of the servers (kept locally by
  `HllConditionalActions.Players`) joined with what the app recorded
  itself - match totals, rule hits, tickets; see
  `HllConditionalActions.Players.Directory`. A player who left an hour ago
  is still here, which is exactly when an admin comes looking.

  Who is online, VIP or watched lives in CRCON: one read per server of each,
  cached, made after the page connects and again every half minute, so the
  list shows first and the live columns fill in.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_stats}}

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Players
  alias HllConditionalActions.Players.Directory
  alias HllConditionalActions.Players.MatchHistory
  alias HllConditionalActionsWeb.PlayerLive.Parts

  @per_page 50
  @refresh_ms :timer.seconds(30)
  @base_filters ~w(all online vip watchlist penalties new)
  @more_filters ~w(matches rules tickets)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    servers = Players.servers_for(user)

    socket =
      socket
      |> assign(:page_title, gettext("Players"))
      |> assign(:tickets?, Accounts.can?(user, :view_tickets))
      |> assign(:servers, servers)
      |> assign(:query, "")
      |> assign(:filter, "all")
      |> assign(:sort, "seen")
      |> assign(:found, [])
      |> assign(:live, %{})
      |> assign(:live_status, %{})
      |> assign(:vips, %{})
      |> assign(:watched, %{})
      |> assign(:crcon_loaded?, false)
      |> assign(:shown, 0)
      |> assign(:counts, empty_counts())
      |> assign(:totals, empty_counts())
      |> stream(:players, [])

    socket =
      if connected?(socket) do
        send(self(), :refresh_crcon)
        # What is already cached shows at once; the rest comes with the read.
        {live, status} = Players.live(servers, cached_only: true)

        socket
        |> assign(:live, live)
        |> assign(:live_status, status)
        |> assign(:vips, Players.vips(servers, cached_only: true))
        |> assign(:watched, Players.watchlist(servers, cached_only: true))
      else
        socket
      end

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    query = params |> Map.get("q", "") |> to_string() |> String.slice(0, 80)
    filter = filter_param(params["filter"], socket.assigns.tickets?)
    sort = if params["sort"] in Directory.sorts(), do: params["sort"], else: "seen"
    searching? = query != socket.assigns.query

    socket =
      socket
      |> assign(:query, query)
      |> assign(:filter, filter)
      |> assign(:sort, sort)
      |> then(fn socket -> if searching?, do: assign(socket, :found, []), else: socket end)
      |> load_first_page()

    {:noreply, maybe_search_crcon(socket, searching?)}
  end

  @impl Phoenix.LiveView
  def handle_event("search", %{"q" => query}, socket) do
    %{filter: filter, sort: sort} = socket.assigns
    {:noreply, push_patch(socket, to: players_path(query, filter, sort))}
  end

  def handle_event("load_more", _params, socket) do
    %{shown: shown} = socket.assigns
    players = socket |> list_players(shown, @per_page) |> decorate(socket.assigns)

    {:noreply,
     socket
     |> assign(:shown, shown + length(players))
     |> stream(:players, players)}
  end

  def handle_event("export", _params, socket) do
    rows = socket |> list_players(0, 10_000) |> decorate(socket.assigns)

    {:noreply,
     push_event(socket, "players:csv", %{
       filename: "players-#{Date.to_iso8601(Date.utc_today())}.csv",
       content: Parts.csv(rows)
     })}
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh_crcon, socket) do
    Process.send_after(self(), :refresh_crcon, @refresh_ms)
    servers = socket.assigns.servers

    {:noreply,
     start_async(socket, :crcon, fn ->
       {live, status} = Players.live(servers)
       vips = Players.vips(servers)
       watched = Players.watchlist(servers)
       %{live: live, status: status, vips: vips, watched: watched}
     end)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_async(:crcon, {:ok, crcon}, socket) do
    {:noreply,
     socket
     |> assign(:live, crcon.live)
     |> assign(:live_status, crcon.status)
     |> assign(:vips, crcon.vips)
     |> assign(:watched, crcon.watched)
     |> assign(:crcon_loaded?, true)
     |> reload_shown()
     |> sync()}
  end

  def handle_async(:crcon, {:exit, _reason}, socket),
    do: {:noreply, socket |> assign(:crcon_loaded?, true) |> sync()}

  # CRCON's player history and match history, read into the directory in
  # the background; the list takes in what came once it is there.
  def handle_async(:sync, {:ok, read}, socket) when read > 0, do: {:noreply, reload_shown(socket)}
  def handle_async(:sync, _result, socket), do: {:noreply, socket}

  def handle_async(:search, {:ok, {query, found}}, socket) do
    if query == socket.assigns.query and found != [] do
      {:noreply, socket |> assign(:found, found) |> reload_shown()}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:search, {:exit, _reason}, socket), do: {:noreply, socket}

  # ── Loading ────────────────────────────────────────────────────────────────

  defp load_first_page(socket) do
    players = socket |> list_players(0, @per_page) |> decorate(socket.assigns)

    socket =
      assign(
        socket,
        :counts,
        Directory.counts(socket.assigns.current_user, directory_opts(socket))
      )

    socket
    |> assign(:totals, totals(socket))
    |> assign(:shown, length(players))
    |> stream(:players, players, reset: true)
  end

  # What the live data changed: the same rows again, with the live columns.
  defp reload_shown(socket) do
    count = max(socket.assigns.shown, @per_page)
    players = socket |> list_players(0, count) |> decorate(socket.assigns)

    socket =
      assign(
        socket,
        :counts,
        Directory.counts(socket.assigns.current_user, directory_opts(socket))
      )

    socket
    |> assign(:totals, totals(socket))
    |> assign(:shown, length(players))
    |> stream(:players, players, reset: true)
  end

  defp sync(socket) do
    servers = socket.assigns.servers

    start_async(socket, :sync, fn ->
      Players.sync_history(servers) + (servers |> Enum.map(&MatchHistory.sync/1) |> Enum.sum())
    end)
  end

  defp maybe_search_crcon(socket, true) do
    query = socket.assigns.query
    servers = socket.assigns.servers

    if connected?(socket) and String.length(String.trim(query)) >= 3 do
      start_async(socket, :search, fn -> {query, Players.search_history(servers, query)} end)
    else
      socket
    end
  end

  defp maybe_search_crcon(socket, false), do: socket

  defp list_players(socket, offset, limit) do
    Directory.list(
      socket.assigns.current_user,
      directory_opts(socket) ++ [offset: offset, limit: limit]
    )
  end

  defp totals(socket) do
    if socket.assigns.query == "" do
      socket.assigns.counts
    else
      Directory.counts(
        socket.assigns.current_user,
        Keyword.put(directory_opts(socket), :query, "")
      )
    end
  end

  defp directory_opts(socket) do
    %{query: query, filter: filter, sort: sort, found: found, tickets?: tickets?} = socket.assigns

    [
      query: query,
      filter: filter,
      sort: sort,
      found: found,
      tickets?: tickets?,
      sets: %{
        online: Map.keys(socket.assigns.live),
        vip: Map.keys(socket.assigns.vips),
        watchlist: Map.keys(socket.assigns.watched)
      }
    ]
  end

  # The live columns and the marks of each row.
  defp decorate(rows, assigns) do
    levels =
      rows
      |> Enum.filter(&(is_nil(&1.level) and not Map.has_key?(assigns.live, &1.id)))
      |> Enum.map(& &1.id)
      |> MatchHistory.last_levels()

    Enum.map(rows, fn row ->
      live = Map.get(assigns.live, row.id)

      row
      |> Map.put(:live, live)
      |> Map.put(:level, (live && live.level) || row.level || Map.get(levels, row.id))
      |> Map.put(:vip?, Map.has_key?(assigns.vips, row.id))
      |> Map.put(:watched?, Map.has_key?(assigns.watched, row.id))
      |> then(&Map.put(&1, :marks, Parts.marks(&1)))
    end)
  end

  defp empty_counts, do: Map.new(Directory.filters(), &{&1, 0})

  defp filter_param("tickets", false), do: "all"

  defp filter_param(filter, _tickets?),
    do: if(filter in Directory.filters(), do: filter, else: "all")

  defp players_path(query, filter, sort) do
    params =
      [q: String.trim(query || ""), filter: filter, sort: sort]
      |> Enum.reject(fn {key, value} ->
        value in ["", nil] or (key == :filter and value == "all") or
          (key == :sort and value == "seen")
      end)

    ~p"/players?#{params}"
  end

  # ── Labels ─────────────────────────────────────────────────────────────────

  defp chip_label("all"), do: gettext("Everyone")
  defp chip_label("online"), do: gettext("Online now")
  defp chip_label("vip"), do: gettext("VIP")
  defp chip_label("watchlist"), do: gettext("Watchlist")
  defp chip_label("penalties"), do: gettext("With penalties")
  defp chip_label("new"), do: gettext("New this week")
  defp chip_label("matches"), do: gettext("Seen in matches")
  defp chip_label("rules"), do: gettext("Hit by rules")
  defp chip_label("tickets"), do: gettext("With tickets")

  defp sort_label("seen"), do: gettext("last seen")
  defp sort_label("playtime"), do: gettext("playtime")
  defp sort_label("penalties"), do: gettext("penalties")
  defp sort_label("rules"), do: gettext("rule hits")
  defp sort_label("name"), do: gettext("name")

  defp base_filters, do: @base_filters

  defp more_filters(tickets?) do
    Enum.reject(@more_filters, &(&1 == "tickets" and not tickets?))
  end

  defp meta(totals) do
    [
      ngettext("%{number} known", "%{number} known", totals["all"],
        number: format_number(totals["all"])
      ),
      ngettext("%{number} playing now", "%{number} playing now", totals["online"],
        number: format_number(totals["online"])
      )
    ]
    |> Enum.join(" · ")
  end

  defp format_number(value), do: Parts.number(value)

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      page_meta={meta(@totals)}
      global_search={false}
      tabs={false}
    >
      <:actions>
        <button
          type="button"
          id="players-export"
          phx-click="export"
          phx-hook=".CsvDownload"
          class="players-header-button"
        >
          <.icon name="hero-arrow-down-tray" class="size-[1.125rem]" />
          <span class="hidden sm:inline">{gettext("Export CSV")}</span>
        </button>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".CsvDownload">
          export default {
            mounted() {
              this.handleEvent("players:csv", ({filename, content}) => {
                const blob = new Blob(["﻿" + content], {type: "text/csv;charset=utf-8"})
                const link = document.createElement("a")
                link.href = URL.createObjectURL(blob)
                link.download = filename
                document.body.appendChild(link)
                link.click()
                link.remove()
                setTimeout(() => URL.revokeObjectURL(link.href), 2000)
              })
            }
          }
        </script>
      </:actions>

      <div class="flex flex-col gap-[1.125rem]">
        <form
          id="player-search"
          phx-change="search"
          phx-submit="search"
          phx-hook=".SlashFocus"
          class="players-search"
          role="search"
        >
          <.icon name="hero-magnifying-glass" class="size-[1.375rem] shrink-0" />
          <label for="player-search-input" class="sr-only">{gettext("Search players")}</label>
          <input
            id="player-search-input"
            type="search"
            name="q"
            value={@query}
            placeholder={gettext("Name, Steam ID, clan or something they wrote in chat")}
            autocomplete="off"
            phx-debounce="300"
            class="players-search-input"
          />
          <span class="hidden shrink-0 text-xs md:inline">
            {gettext("also searches CRCON's history")}
          </span>
          <kbd class="players-search-kbd hidden md:inline-flex">/</kbd>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".SlashFocus">
            export default {
              mounted() {
                this.onKey = (e) => {
                  if (e.key !== "/" || e.ctrlKey || e.metaKey || e.altKey) return
                  const tag = (document.activeElement && document.activeElement.tagName) || ""
                  if (["INPUT", "TEXTAREA", "SELECT"].includes(tag) || document.activeElement.isContentEditable) return
                  e.preventDefault()
                  this.el.querySelector("input").focus()
                }
                window.addEventListener("keydown", this.onKey)
              },
              destroyed() { window.removeEventListener("keydown", this.onKey) }
            }
          </script>
        </form>

        <nav
          id="player-filters"
          aria-label={gettext("Filter players")}
          class="flex flex-wrap items-center gap-2"
        >
          <.link
            :for={filter <- base_filters()}
            id={"player-filter-#{filter}"}
            patch={players_path(@query, filter, @sort)}
            aria-current={@filter == filter && "true"}
            class="players-chip"
          >
            <span
              :if={filter == "online"}
              class="size-[7px] shrink-0 rounded-full bg-primary"
              aria-hidden="true"
            ></span>
            {chip_label(filter)}
            <span class="players-chip-count">{Parts.number(@counts[filter])}</span>
          </.link>

          <.link
            :if={@filter in more_filters(@tickets?)}
            id={"player-filter-#{@filter}"}
            patch={players_path(@query, @filter, @sort)}
            aria-current="true"
            class="players-chip"
          >
            {chip_label(@filter)}
            <span class="players-chip-count">{Parts.number(@counts[@filter])}</span>
          </.link>

          <div class="relative">
            <button
              type="button"
              id="player-filter-more"
              class="players-chip players-chip--add"
              aria-haspopup="menu"
              phx-click={JS.toggle(to: "#player-filter-menu")}
            >
              {gettext("+ Filter")}
            </button>
            <div
              id="player-filter-menu"
              role="menu"
              class="players-menu hidden"
              phx-click-away={JS.hide(to: "#player-filter-menu")}
            >
              <.link
                :for={filter <- more_filters(@tickets?)}
                id={"player-filter-menu-#{filter}"}
                role="menuitem"
                patch={players_path(@query, filter, @sort)}
                class="players-menu-item"
              >
                <span class="flex-1">{chip_label(filter)}</span>
                <span class="font-mono text-xs text-muted">{Parts.number(@counts[filter])}</span>
              </.link>
            </div>
          </div>

          <span class="flex-1"></span>

          <div class="relative">
            <button
              type="button"
              id="player-sort"
              class="players-sort"
              aria-haspopup="menu"
              phx-click={JS.toggle(to: "#player-sort-menu")}
            >
              {gettext("Sort:")}
              <strong class="font-semibold text-base-content">{sort_label(@sort)}</strong>
              <.icon name="hero-chevron-down" class="size-3.5" />
            </button>
            <div
              id="player-sort-menu"
              role="menu"
              class="players-menu players-menu--end hidden"
              phx-click-away={JS.hide(to: "#player-sort-menu")}
            >
              <.link
                :for={sort <- Directory.sorts()}
                id={"player-sort-#{sort}"}
                role="menuitemradio"
                aria-checked={to_string(@sort == sort)}
                patch={players_path(@query, @filter, sort)}
                class="players-menu-item"
              >
                <span class="flex-1">{sort_label(sort)}</span>
                <.icon :if={@sort == sort} name="hero-check" class="size-4 text-primary" />
              </.link>
            </div>
          </div>
        </nav>

        <.empty_state
          :if={@totals["all"] == 0 and @query == ""}
          icon="hero-user-group"
          title={gettext("No player recorded yet")}
          description={
            gettext(
              "Players appear here once CRCON's history is read, a match ends with the stats module installed, or a rule acts on them."
            )
          }
        />

        <section
          :if={@totals["all"] > 0 or @query != ""}
          id="player-list"
          aria-label={gettext("Player list")}
          class="players-panel"
        >
          <div class="players-grid players-grid--head" aria-hidden="true">
            <span>{gettext("Player")}</span>
            <span class="players-col-now">{gettext("Now")}</span>
            <span class="players-col-level text-right">{gettext("Level")}</span>
            <span class="players-col-time text-right">{gettext("Time")}</span>
            <span class="players-col-sessions text-right">{gettext("Sessions")}</span>
            <span class="players-col-penalties text-right">{gettext("Penalties")}</span>
            <span class="players-col-rules text-right">{gettext("Rules")}</span>
            <span class="players-col-seen">{gettext("Seen")}</span>
            <span class="players-col-marks">{gettext("Marks")}</span>
            <span></span>
          </div>

          <div id="players" phx-update="stream" class="flex flex-col">
            <p
              id="players-empty"
              class="hidden px-2.5 py-10 text-center text-sm text-muted only:block"
            >
              {gettext("No player matches this search.")}
            </p>

            <.link
              :for={{dom_id, player} <- @streams.players}
              id={dom_id}
              navigate={~p"/players/#{player.id}"}
              class="players-grid players-row group"
            >
              <span class="flex min-w-0 items-center gap-3">
                <Parts.avatar_tile
                  name={player.name}
                  team={player.live && player.live.stream? && player.live.team}
                  size="sm"
                />
                <span class="flex min-w-0 flex-col">
                  <strong class="truncate font-semibold">{player.name || player.id}</strong>
                  <span class="truncate font-mono text-[0.6875rem] text-muted">{player.id}</span>
                  <span class="players-row-phone-now">
                    <Parts.now_cell live={player.live} />
                  </span>
                </span>
              </span>
              <span class="players-col-now min-w-0">
                <Parts.now_cell live={player.live} />
              </span>
              <span class="players-col-level text-right font-mono text-[0.8125rem]">
                {player.level || "–"}
              </span>
              <span class="players-col-time text-right font-mono text-[0.8125rem]">
                {Parts.hours(player.playtime)}
              </span>
              <span class="players-col-sessions text-right font-mono text-[0.8125rem]">
                {player.sessions || "–"}
              </span>
              <span class={[
                "players-col-penalties text-right font-mono text-[0.8125rem]",
                Parts.penalty_tone(player.penalties)
              ]}>
                {player.penalties}
              </span>
              <span class="players-col-rules text-right font-mono text-[0.8125rem]">
                {player.hits}
              </span>
              <span class="players-col-seen min-w-0 truncate text-[0.8125rem]">
                <%= if player.live do %>
                  <span class="text-primary">{gettext("playing")}</span>
                <% else %>
                  <Parts.seen id={"#{dom_id}-seen"} at={player.seen_at} class="text-subtle" />
                <% end %>
              </span>
              <span class="players-col-marks flex min-w-0 gap-1.5 overflow-hidden">
                <Parts.mark :for={mark <- Enum.take(player.marks, 2)} mark={mark} />
              </span>
              <.icon
                name="hero-chevron-right"
                class="size-4 justify-self-end text-muted transition-transform group-hover:translate-x-0.5"
              />
            </.link>
          </div>

          <div class="players-foot">
            <span id="players-shown" class="min-w-0 flex-1 text-[0.8125rem] text-muted">
              {gettext("Showing %{shown} of %{total}",
                shown: Parts.number(@shown),
                total: Parts.number(@counts[@filter])
              )}
              <span class="hidden sm:inline">
                · {ngettext(
                  "data from the CRCON history of %{count} server",
                  "data from the CRCON history of the %{count} servers",
                  length(@servers),
                  count: length(@servers)
                )}
              </span>
            </span>
            <button
              :if={@shown < @counts[@filter]}
              id="players-load-more"
              type="button"
              phx-click="load_more"
              class="players-more"
            >
              {gettext("Load %{count} more", count: 50)}
            </button>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
