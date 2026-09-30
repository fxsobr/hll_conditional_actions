defmodule HllConditionalActionsWeb.MatchLive.Index do
  @moduledoc """
  The matches of the last days, from CRCON's match history: across every
  server the user reaches (`/matches`) or one of them
  (`/servers/:id/matches`), grouped by day, with what each server is
  playing right now on top. Beside the list, the numbers of the period -
  how many matches, how long, which side wins, and by map - and the rule
  that posts each match to Discord.

  Everything CRCON answers is fetched off the LiveView process: a slow
  history leaves a skeleton on screen, not a frozen page. The size of each
  match is read only for the matches on screen.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_stats}}

  import HllConditionalActionsWeb.CommunityComponents

  alias HllConditionalActions.MatchHistory
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.MapArt

  @periods [7, 30, 90]
  @page 8

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Community"))
     |> assign(:servers, Servers.list_servers_for(socket.assigns.current_user))
     |> assign(server: nil, days: 30, map: nil, mode: nil, shown: @page)
     |> assign(loaded_key: nil, history: nil, error?: false, live: [], details: %{})
     |> assign(:details_loading?, false)
     |> assign(:discord, nil)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    server =
      params["server_id"] &&
        Enum.find(socket.assigns.servers, &(to_string(&1.id) == params["server_id"]))

    days =
      case Integer.parse(params["days"] || "") do
        {days, ""} when days in @periods -> days
        _other -> 30
      end

    socket =
      socket
      |> assign(
        server: server,
        days: days,
        map: blank(params["map"]),
        mode: blank(params["mode"])
      )
      |> load()

    {:noreply, socket}
  end

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value

  defp scope(%{server: nil, servers: servers}), do: servers
  defp scope(%{server: server}), do: [server]

  # The history is read again only when the servers or the period change;
  # the map and mode filters work on what is already here.
  defp load(socket) do
    servers = scope(socket.assigns)
    key = {Enum.map(servers, & &1.id), socket.assigns.days}

    cond do
      servers == [] ->
        assign(socket, history: %{matches: [], failed: []}, loaded_key: key)

      key == socket.assigns.loaded_key ->
        socket |> assign(:shown, @page) |> load_details()

      true ->
        days = socket.assigns.days

        socket
        |> assign(history: nil, error?: false, loaded_key: key, shown: @page)
        |> assign(:discord, MatchHistory.discord_rule(Enum.map(servers, & &1.id)))
        |> start_async(:history, fn -> {key, MatchHistory.period(servers, days)} end)
        |> start_async(:live, fn -> {key, MatchHistory.live(servers)} end)
    end
  end

  @impl Phoenix.LiveView
  def handle_event("filter", params, socket) do
    query =
      [days: params["days"], map: params["map"], mode: params["mode"]]
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

    {:noreply, push_patch(socket, to: list_path(socket.assigns.server, query))}
  end

  def handle_event("more", _params, socket) do
    {:noreply, socket |> update(:shown, &(&1 + @page * 2)) |> load_details()}
  end

  def handle_event("export", _params, socket) do
    matches = filtered(socket.assigns)

    rows =
      for match <- matches do
        at = local(match.started_at, match.server)
        facts = socket.assigns.details[key(match)] || %{}

        [
          at && Calendar.strftime(at, "%Y-%m-%d"),
          clock(at),
          match.server.name,
          match.map,
          mode_label(match.mode),
          match.duration_seconds && div(match.duration_seconds, 60),
          match.allied,
          match.axis,
          result_text(match),
          facts[:players],
          facts[:mvp]
        ]
      end

    csv =
      to_csv(
        [
          gettext("Date"),
          gettext("Start"),
          gettext("Server"),
          gettext("Map"),
          gettext("Mode"),
          gettext("Minutes"),
          gettext("Allies"),
          gettext("Axis"),
          gettext("Result"),
          gettext("Players"),
          gettext("MVP")
        ],
        rows
      )

    {:noreply,
     push_event(socket, "download_csv", %{
       filename: "matches-#{Date.utc_today()}.csv",
       content: csv
     })}
  end

  @impl Phoenix.LiveView
  def handle_async(:history, {:ok, {key, history}}, socket) do
    if key == socket.assigns.loaded_key do
      error? = history.matches == [] and history.failed != []
      {:noreply, socket |> assign(history: history, error?: error?) |> load_details()}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:history, _failed, socket), do: {:noreply, assign(socket, :error?, true)}

  def handle_async(:live, {:ok, {key, live}}, socket) do
    if key == socket.assigns.loaded_key,
      do: {:noreply, assign(socket, :live, live)},
      else: {:noreply, socket}
  end

  def handle_async(:live, _failed, socket), do: {:noreply, socket}

  def handle_async(:details, {:ok, details}, socket) do
    {:noreply,
     socket
     |> update(:details, &Map.merge(&1, details))
     |> assign(:details_loading?, false)
     |> load_details()}
  end

  def handle_async(:details, _failed, socket),
    do: {:noreply, assign(socket, :details_loading?, false)}

  # The players and MVP of the matches on screen, a batch at a time.
  defp load_details(%{assigns: %{history: nil}} = socket), do: socket

  defp load_details(socket) do
    missing =
      socket.assigns
      |> filtered()
      |> Enum.take(socket.assigns.shown)
      |> Enum.reject(&Map.has_key?(socket.assigns.details, key(&1)))

    if missing == [] or socket.assigns.details_loading? do
      socket
    else
      batch = Enum.take(missing, 16)
      known = Map.new(batch, &{key(&1), nil})

      socket
      |> update(:details, &Map.merge(known, &1))
      |> assign(:details_loading?, true)
      |> start_async(:details, fn ->
        details = MatchHistory.details(batch)
        Map.merge(known, details)
      end)
    end
  end

  defp key(match), do: {match.server.id, match.id}

  defp filtered(%{history: nil}), do: []

  defp filtered(assigns) do
    Enum.filter(assigns.history.matches, fn match ->
      (assigns.map == nil or match.map == assigns.map) and
        (assigns.mode == nil or to_string(match.mode) == assigns.mode)
    end)
  end

  defp list_path(nil, query), do: ~p"/matches?#{query}"
  defp list_path(server, query), do: ~p"/servers/#{server}/matches?#{query}"

  defp query(assigns) do
    [days: assigns.days != 30 && assigns.days, map: assigns.map, mode: assigns.mode]
    |> Enum.reject(fn {_key, value} -> value in [nil, false] end)
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    matches = filtered(assigns)
    shown = Enum.take(matches, assigns.shown)
    today = today(scope(assigns))

    assigns =
      assign(assigns,
        matches: matches,
        groups: groups(shown, today),
        today: today,
        summary: assigns.history && MatchHistory.summary(assigns.history.matches),
        live_rows: if(assigns.map || assigns.mode, do: [], else: assigns.live)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
    >
      <:actions>
        <.pill_button
          id="matches-export"
          type="button"
          icon="hero-arrow-down-tray"
          phx-click="export"
          disabled={@matches == []}
        >
          {gettext("Export CSV")}
        </.pill_button>
      </:actions>

      <.csv_download id="matches-csv" />

      <.empty_state
        :if={@servers == []}
        icon="hero-flag"
        title={gettext("No server yet")}
        description={gettext("Connect a server and its match history shows up here.")}
      />

      <div
        :if={@servers != []}
        class="grid items-start gap-5 xl:grid-cols-[minmax(0,1fr)_21.25rem]"
      >
        <section
          id="match-list"
          aria-label={gettext("Match list")}
          class="flex min-w-0 flex-col rounded-[1.75rem] bg-base-100 px-3 pt-4 pb-4 sm:px-[1.375rem] sm:pt-[1.125rem]"
        >
          <form
            id="match-filters"
            phx-change="filter"
            class="mb-2.5 flex flex-wrap items-center gap-2"
          >
            <.seg id="match-servers" label={gettext("Server")} class="max-w-full">
              <:item patch={list_path(nil, query(assigns))} active={is_nil(@server)}>
                {gettext("All servers")}
              </:item>
              <:item
                :for={server <- @servers}
                patch={list_path(server, query(assigns))}
                active={@server && @server.id == server.id}
                dot={failed?(@history, server) && "bg-error"}
              >
                {server.name}
              </:item>
            </.seg>

            <label class="com-filter">
              <span class="text-muted">{gettext("Map")}</span>
              <select name="map" aria-label={gettext("Map")}>
                <option value="">{gettext("All")}</option>
                <option :for={map <- maps(@history)} value={map} selected={map == @map}>
                  {map}
                </option>
              </select>
            </label>
            <label class="com-filter">
              <span class="text-muted">{gettext("Mode")}</span>
              <select name="mode" aria-label={gettext("Mode")}>
                <option value="">{gettext("All")}</option>
                <option :for={mode <- modes(@history)} value={mode} selected={mode == @mode}>
                  {mode_label(mode)}
                </option>
              </select>
            </label>
            <span class="hidden flex-1 sm:block"></span>
            <label class="com-filter">
              <.icon name="hero-calendar" class="size-4 text-muted" />
              <select name="days" aria-label={gettext("Period")}>
                <option :for={days <- periods()} value={days} selected={days == @days}>
                  {period_label(days)}
                </option>
              </select>
            </label>
          </form>

          <div class="hidden lg:block">
            <div class="match-row-grid border-b border-line-soft px-2 py-2 text-xs text-muted">
              <span>{gettext("Map")}</span>
              <span></span>
              <span>{gettext("Server")}</span>
              <span>{gettext("Start")}</span>
              <span>{gettext("Duration")}</span>
              <span class="text-center">{gettext("Allies × Axis")}</span>
              <span>{gettext("Result")}</span>
              <span></span>
            </div>
          </div>

          <.error_state
            :if={@error?}
            id="matches-error"
            title={gettext("CRCON did not answer")}
            icon="hero-signal-slash"
            class="my-6"
          >
            {gettext(
              "The match history comes from CRCON. Check that the server is reachable and that its key may read scoreboards."
            )}
          </.error_state>

          <div :if={is_nil(@history) and not @error?} class="mt-3 space-y-2">
            <.skeleton_block :for={_ <- 1..6} class="h-[4.5rem] rounded-2xl" />
          </div>

          <div :if={@history && not @error?} id="matches" class="flex flex-col">
            <%= if @live_rows != [] do %>
              <p class="px-2 pt-3 pb-1 text-xs font-semibold text-subtle">
                {gettext("Now")}
              </p>
              <.link
                :for={live <- @live_rows}
                id={"live-match-#{live.server.id}"}
                navigate={~p"/servers/#{live.server}"}
                class="match-row-grid rounded-2xl bg-primary/4 px-2 py-[0.4375rem] transition-colors hover:bg-secondary"
              >
                <img
                  src={MapArt.url(live.server.game, live.layer)}
                  alt=""
                  class="h-11 w-18 rounded-xl object-cover lg:h-[3.625rem] lg:w-24"
                />
                <span class="flex min-w-0 flex-col">
                  <strong class="truncate font-display text-[1.0625rem] font-semibold">
                    {live.map}
                  </strong>
                  <span class="truncate text-xs text-muted">
                    {mode_label(live.mode)} · {ngettext("1 player", "%{count} players", live.players)}
                    <span class="lg:hidden">· {live.server.name}</span>
                  </span>
                </span>
                <span class="hidden truncate text-[0.8125rem] text-subtle lg:block">
                  {live.server.name}
                </span>
                <span class="hidden font-mono text-xs text-subtle lg:block">
                  {clock(local(live.started_at, live.server))}
                </span>
                <span class="hidden font-mono text-xs text-subtle lg:block">
                  {live.started_at && duration(DateTime.diff(DateTime.utc_now(), live.started_at))}
                </span>
                <.score allied={live.allied} axis={live.axis} class="hidden lg:block" />
                <.pill tone="live" class="justify-self-end lg:justify-self-start">
                  {gettext("Live")}
                </.pill>
                <.icon name="hero-chevron-right" class="hidden size-4 text-muted lg:block" />
              </.link>
            <% end %>

            <%= for {date, rows} <- @groups do %>
              <p class="px-2 pt-3 pb-1 text-xs font-semibold text-subtle">
                {day_heading(date, @today)}
              </p>
              <.link
                :for={match <- rows}
                id={"match-#{match.server.id}-#{match.id}"}
                navigate={~p"/servers/#{match.server}/matches/#{match.id}"}
                class="match-row-grid rounded-2xl px-2 py-[0.4375rem] transition-colors hover:bg-secondary"
              >
                <img
                  src={MapArt.url(match.server.game, match.layer || match.map)}
                  alt=""
                  loading="lazy"
                  class="h-11 w-18 rounded-xl object-cover lg:h-[3.625rem] lg:w-24"
                />
                <span class="flex min-w-0 flex-col">
                  <strong class="truncate font-display text-[1.0625rem] font-semibold">
                    {match.map}
                  </strong>
                  <span class="truncate text-xs text-muted">
                    {mode_label(match.mode)}{facts_line(@details[key(match)])}
                    <span class="lg:hidden">
                      · {match.server.name} · {clock(local(match.started_at, match.server))}
                    </span>
                  </span>
                </span>
                <span class="hidden truncate text-[0.8125rem] text-subtle lg:block">
                  {match.server.name}
                </span>
                <span class="hidden font-mono text-xs text-subtle lg:block">
                  {clock(local(match.started_at, match.server))}
                </span>
                <span class="hidden font-mono text-xs text-subtle lg:block">
                  {duration(match.duration_seconds)}
                </span>
                <.score allied={match.allied} axis={match.axis} class="hidden lg:block" />
                <span class="flex items-center justify-end gap-2 lg:justify-start">
                  <.score allied={match.allied} axis={match.axis} class="text-lg lg:hidden" />
                  <.result_pill match={match} />
                </span>
                <.icon name="hero-chevron-right" class="hidden size-4 text-muted lg:block" />
              </.link>
            <% end %>

            <p
              :if={@matches == [] and @live_rows == []}
              class="px-2 py-10 text-center text-sm text-muted"
            >
              {if @map || @mode,
                do: gettext("No match with these filters in the period."),
                else: gettext("No match recorded in the period. CRCON records a match when it ends.")}
            </p>
          </div>

          <div
            :if={@history && @matches != []}
            class="mt-2 flex items-center gap-3 border-t border-line-soft pt-2.5"
          >
            <span class="flex-1 text-[0.8125rem] text-muted">
              {showing(min(@shown, length(@matches)), length(@matches), @days)}
            </span>
            <button
              :if={@shown < length(@matches)}
              id="matches-more"
              type="button"
              phx-click="more"
              class="h-10 rounded-full border border-base-300 bg-secondary px-[1.125rem] text-[0.8125rem] transition-colors hover:bg-base-300"
            >
              {gettext("Load more")}
            </button>
          </div>
        </section>

        <div class="flex min-w-0 flex-col gap-5">
          <section
            id="matches-summary"
            aria-label={gettext("Summary of the period")}
            class="flex flex-col gap-3.5 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-5"
          >
            <h2 class="font-display text-xl font-semibold">{period_label(@days)}</h2>
            <%= if @summary do %>
              <div class="grid grid-cols-2 gap-2.5">
                <div class="rounded-2xl bg-secondary px-3.5 py-3">
                  <div class="text-xs text-subtle">{gettext("Matches")}</div>
                  <div class="font-display text-2xl font-semibold">{number(@summary.count)}</div>
                </div>
                <div class="rounded-2xl bg-secondary px-3.5 py-3">
                  <div class="text-xs text-subtle">{gettext("Average length")}</div>
                  <div class="font-display text-2xl font-semibold">
                    {duration(@summary.average_seconds)}
                  </div>
                </div>
              </div>
              <div :if={@summary.allies + @summary.axis > 0} class="flex flex-col gap-1.5">
                <div class="flex justify-between text-[0.8125rem]">
                  <span class="font-semibold text-allies">
                    {gettext("Allies %{share}%", share: share(@summary.allies, @summary))}
                  </span>
                  <span class="text-subtle">{gettext("wins")}</span>
                  <span class="font-semibold text-axis">
                    {gettext("%{share}% Axis", share: share(@summary.axis, @summary))}
                  </span>
                </div>
                <.balance_bar allies={@summary.allies} axis={@summary.axis} class="h-2.5" />
                <span class="text-xs text-muted">
                  {ngettext(
                    "1 total win (5 × 0)",
                    "%{count} total wins (5 × 0)",
                    @summary.total_wins
                  )}
                </span>
              </div>
            <% else %>
              <.skeleton_block class="h-20 rounded-2xl" />
            <% end %>
          </section>

          <section
            id="matches-by-map"
            aria-label={gettext("Most played maps")}
            class="flex flex-col gap-3 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-5"
          >
            <div class="flex items-baseline">
              <h2 class="flex-1 font-display text-xl font-semibold">{gettext("By map")}</h2>
              <span class="text-xs text-muted">{gettext("wins of each side")}</span>
            </div>
            <%= if @summary do %>
              <% top = Enum.take(@summary.by_map, 6) %>
              <% most = top |> Enum.map(& &1.count) |> Enum.max(fn -> 1 end) %>
              <div :for={map <- top} class="flex flex-col gap-[0.3125rem]">
                <div class="flex justify-between text-[0.8125rem]">
                  <span class="truncate">{map.map}</span>
                  <span class="font-mono text-subtle">{map.count}</span>
                </div>
                <div
                  class="flex h-2 gap-0.5"
                  style={"width: #{max(round(map.count * 100 / most), 4)}%"}
                >
                  <span
                    :if={map.allies > 0}
                    class="rounded-[3px] bg-allies"
                    style={"flex-grow: #{map.allies}"}
                  ></span>
                  <span
                    :if={map.axis > 0}
                    class="rounded-[3px] bg-axis"
                    style={"flex-grow: #{map.axis}"}
                  ></span>
                  <span
                    :if={map.allies + map.axis == 0}
                    class="flex-1 rounded-[3px] bg-base-300"
                  ></span>
                </div>
              </div>
              <span :if={top == []} class="text-[0.8125rem] text-muted">
                {gettext("No match in the period.")}
              </span>
              <span :if={length(@summary.by_map) > 6} class="text-xs text-muted">
                {other_maps(@summary.by_map)}
              </span>
            <% else %>
              <.skeleton_block :for={_ <- 1..4} class="h-8 rounded-xl" />
            <% end %>
          </section>

          <section
            id="matches-discord"
            class="flex flex-col gap-2 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-[1.125rem]"
          >
            <strong class="text-sm font-semibold">{gettext("Summary on Discord")}</strong>
            <%= if @discord do %>
              <span class="text-[0.8125rem] leading-relaxed text-subtle">
                {gettext("The rule %{rule} posts each report to", rule: @discord.rule.name)}
                <span class="font-mono text-base-content">
                  {(@discord.webhook && @discord.webhook.name) || gettext("a webhook")}
                </span>.
              </span>
              <.link
                navigate={~p"/rules/#{@discord.rule.id}"}
                class="text-[0.8125rem] text-primary hover:underline"
              >
                {gettext("Open the rule")}
              </.link>
            <% else %>
              <span class="text-[0.8125rem] leading-relaxed text-subtle">
                {gettext(
                  "No rule posts the matches to Discord yet: a rule on \"match ends\" with a Discord action does it."
                )}
              </span>
              <.link navigate={~p"/rules/new"} class="text-[0.8125rem] text-primary hover:underline">
                {gettext("Create the rule")}
              </.link>
            <% end %>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :allied, :any, default: nil
  attr :axis, :any, default: nil
  attr :class, :any, default: nil

  @doc false
  def score(assigns) do
    ~H"""
    <span class={["text-center font-display text-[1.375rem] font-bold whitespace-nowrap", @class]}>
      <span class="text-allies">{@allied || "–"}</span><span class="font-medium text-muted"> × </span><span class="text-axis">{@axis ||
        "–"}</span>
    </span>
    """
  end

  attr :match, :map, required: true

  @doc false
  def result_pill(assigns) do
    assigns = assign(assigns, :text, result_text(assigns.match))

    ~H"""
    <span
      :if={@text}
      class={[
        "flex h-7 shrink-0 items-center rounded-full px-2.5 text-xs font-semibold whitespace-nowrap",
        case @match.winner do
          :allies -> "bg-allies/14 text-allies"
          :axis -> "bg-axis/14 text-axis"
          _draw -> "bg-secondary text-subtle"
        end
      ]}
    >
      {@text}
    </span>
    """
  end

  @doc "What the result of a match says, in words, or nil when unknown."
  @spec result_text(map()) :: String.t() | nil
  def result_text(%{winner: nil}), do: nil
  def result_text(%{winner: :draw}), do: gettext("Draw")

  def result_text(%{winner: winner} = match) do
    side = team_label(winner)
    attackers = get_in(match, [:layer, "attackers"])

    cond do
      MatchHistory.total_win?(match) ->
        gettext("%{side} · total", side: side)

      to_string(match.mode) == "offensive" and is_binary(attackers) and
          String.downcase(attackers) != to_string(winner) ->
        gettext("%{side} held", side: side)

      true ->
        gettext("%{side} won", side: side)
    end
  end

  @doc false
  def mode_label(nil), do: gettext("Unknown mode")

  def mode_label(mode) do
    case mode |> to_string() |> String.downcase() do
      "warfare" -> gettext("Warfare")
      "offensive" -> gettext("Offensive")
      "skirmish" -> gettext("Skirmish")
      "control" -> gettext("Control")
      other -> String.capitalize(other)
    end
  end

  # Kept for the pages that still import them.
  @doc false
  def date(nil), do: "–"
  def date(at), do: Calendar.strftime(at, "%d/%m/%Y %H:%M UTC")

  @doc false
  def duration_label(seconds), do: duration(seconds)

  defp facts_line(%{players: players, mvp: mvp}) when is_binary(mvp),
    do: " · " <> ngettext("1 player", "%{count} players", players) <> " · MVP " <> mvp

  defp facts_line(%{players: players}),
    do: " · " <> ngettext("1 player", "%{count} players", players)

  defp facts_line(_loading), do: ""

  defp failed?(nil, _server), do: false
  defp failed?(%{failed: failed}, server), do: server.id in failed

  defp maps(nil), do: []
  defp maps(%{matches: matches}), do: matches |> Enum.map(& &1.map) |> Enum.uniq() |> Enum.sort()

  defp modes(nil), do: []

  defp modes(%{matches: matches}),
    do:
      matches
      |> Enum.map(&to_string(&1.mode))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

  defp periods, do: @periods

  defp period_label(days), do: gettext("Last %{count} days", count: days)

  defp showing(shown, total, days),
    do:
      gettext("%{shown} of %{total} matches in the last %{days} days",
        shown: shown,
        total: total,
        days: days
      )

  defp share(count, summary),
    do: round(count * 100 / max(summary.allies + summary.axis, 1))

  defp other_maps(by_map) do
    rest = Enum.drop(by_map, 6)

    gettext("+ %{matches} matches on %{maps} other maps",
      matches: Enum.sum_by(rest, & &1.count),
      maps: length(rest)
    )
  end

  defp today(servers) do
    now = local(DateTime.utc_now(), List.first(servers))
    DateTime.to_date(now)
  end

  defp groups(matches, _today) do
    matches
    |> Enum.chunk_by(&local_date/1)
    |> Enum.map(fn [first | _] = rows -> {local_date(first), rows} end)
  end

  defp local_date(match) do
    case local(match.started_at, match.server) do
      nil -> nil
      at -> DateTime.to_date(at)
    end
  end

  defp day_heading(nil, _today), do: gettext("Unknown date")

  defp day_heading(date, today) do
    cond do
      date == today -> gettext("Today · %{date}", date: long_date(date))
      date == Date.add(today, -1) -> gettext("Yesterday · %{date}", date: long_date(date))
      true -> String.capitalize(long_date(date))
    end
  end
end
