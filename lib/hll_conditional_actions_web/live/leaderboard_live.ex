defmodule HllConditionalActionsWeb.LeaderboardLive do
  @moduledoc """
  The live scoreboard of one server - *Placar* and *Squads* of the *Ao vivo*
  area: the top three of every category and the best squads of every type,
  as the current match stands.

  It reads the same `get_detailed_players` snapshot the rules are judged on,
  through `HllConditionalActions.Leaderboards`, so what an admin sees here is
  exactly what `{top_kills}` or a "position in kills" condition would see.
  The snapshot is fetched off the LiveView process every ten seconds; a slow
  CRCON leaves the last table on screen instead of a spinner.

  The page opens on a slim strip of the match (map, start, score, sectors,
  head count) and can narrow the rankings to one team (`?team=allies|axis`).
  `?view=squads` shows the squads alone, each type in its own column. The
  admin can also post the scoreboard to the game's chat.
  """

  use HllConditionalActionsWeb, :live_view

  import HllConditionalActionsWeb.LiveComponents

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_stats}}

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Engine.Snapshot
  alias HllConditionalActions.Leaderboards
  alias HllConditionalActions.LiveMatch
  alias HllConditionalActions.Servers

  @refresh_ms :timer.seconds(10)
  @size 3

  # The categories of the board, in its order: the combined offense and
  # defense score stays a rule variable, not a card.
  @categories [
    :kills,
    :kill_death_ratio,
    :kills_per_minute,
    :combat,
    :offense,
    :defense,
    :support,
    :vehicles_destroyed,
    :teamplay
  ]

  # What goes to the chat: four headings of three players each, which is
  # what the game's message box holds without scrolling.
  @chat_categories [:kills, :combat, :support, :defense]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    {:ok,
     socket
     |> assign(:page_title, gettext("Live"))
     |> assign(:servers, Servers.list_servers_for(socket.assigns.current_user))
     |> assign(:server, nil)
     |> assign(:roster, nil)
     |> assign(:gamestate, nil)
     |> assign(:match, %{started_at: nil, max_players: nil})
     |> assign(:stream_status, nil)
     |> assign(:team, nil)
     |> assign(:view, :leaderboard)
     |> assign(:loaded_at, nil)
     |> assign(:size, @size)
     |> assign(:error?, false)}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"server_id" => id} = params, _url, socket) do
    server = Enum.find(socket.assigns.servers, &(to_string(&1.id) == id))

    socket =
      if server && server != socket.assigns.server,
        do:
          socket
          |> assign(server: server, roster: nil, gamestate: nil, loaded_at: nil)
          |> load(),
        else: assign(socket, :server, server)

    {:noreply,
     assign(socket,
       team: team_key(params["team"]),
       view: if(params["view"] == "squads", do: :squads, else: :leaderboard)
     )}
  end

  # The leaderboard is always a server's: the old address opens the first.
  def handle_params(_params, _url, socket) do
    case socket.assigns.servers do
      [server | _rest] ->
        {:noreply, push_navigate(socket, to: ~p"/servers/#{server}/leaderboard")}

      [] ->
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("post_to_chat", _params, socket) do
    %{server: server, roster: roster, current_user: user} = socket.assigns

    if Accounts.can?(user, :manage_servers) and roster not in [nil, %{}] do
      text = chat_text(roster)
      {:noreply, start_async(socket, :post, fn -> Crcon.message_all_players(server, text) end)}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_async(:snapshot, {:ok, {server_id, snapshot, match}}, socket) do
    cond do
      is_nil(socket.assigns.server) or socket.assigns.server.id != server_id ->
        {:noreply, socket}

      # A failed fetch: keep the last table if there is one, otherwise say
      # CRCON is not answering - an empty roster here does not mean an empty
      # server.
      snapshot.stale? ->
        {:noreply, assign(socket, :error?, is_nil(socket.assigns.roster))}

      true ->
        {:noreply,
         assign(socket,
           roster: snapshot.players,
           gamestate: snapshot.gamestate,
           match: match || socket.assigns.match,
           loaded_at: DateTime.utc_now(),
           error?: false
         )}
    end
  end

  def handle_async(:snapshot, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :error?, is_nil(socket.assigns.roster))}
  end

  def handle_async(:post, {:ok, {:ok, _result}}, socket) do
    {:noreply, put_flash(socket, :info, gettext("Scoreboard sent to the chat."))}
  end

  def handle_async(:post, _failed, socket) do
    {:noreply, put_flash(socket, :error, gettext("CRCON did not take the message. Try again."))}
  end

  defp load(%{assigns: %{server: nil}} = socket), do: socket

  defp load(socket) do
    server = socket.assigns.server

    socket
    |> assign(:stream_status, LogStream.status(server.id))
    |> start_async(:snapshot, fn ->
      match =
        case LiveMatch.info(server) do
          {:ok, info} -> info
          {:error, _error} -> nil
        end

      {server.id, Snapshot.refresh(server), match}
    end)
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assign(assigns,
        teams: team_names(assigns.server && assigns.server.game),
        ranked: assigns.roster && only_team(assigns.roster, assigns.team),
        base: assigns.server && "/servers/#{assigns.server.id}",
        feed?: Accounts.can?(assigns.current_user, :view_live_feed),
        post?: Accounts.can?(assigns.current_user, :manage_servers)
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
        <button
          :if={@server && @post?}
          id="leaderboard-post"
          type="button"
          phx-click="post_to_chat"
          disabled={@roster in [nil, %{}]}
          data-confirm={
            gettext("Send the scoreboard to every player on %{server}?", server: @server.name)
          }
          aria-label={gettext("Send the scoreboard to the chat")}
          class="flex size-12 cursor-pointer items-center justify-center gap-2 rounded-full border border-base-300 bg-white text-sm font-medium transition-colors hover:bg-base-100 disabled:cursor-not-allowed disabled:opacity-50 xl:w-auto xl:pl-4 xl:pr-5 dark:bg-secondary dark:hover:bg-base-300"
        >
          <.icon name="hero-chat-bubble-left" class="size-[1.125rem]" />
          <span class="hidden xl:inline">{gettext("Send the scoreboard to the chat")}</span>
        </button>
      </:actions>

      <div class="flex flex-col gap-3.5 md:gap-5">
        <.empty_state
          :if={@servers == []}
          icon="hero-trophy"
          title={gettext("No server to rank")}
          description={gettext("Connect a server and its live leaderboard shows up here.")}
        />

        <.live_hero
          :if={@server && not @error?}
          id="leaderboard-live"
          compact
          server={@server}
          gamestate={@gamestate}
          roster={@roster}
          stream_status={@stream_status}
          started_at={@match.started_at || LiveMatch.started_at_from_gamestate(@gamestate)}
          max_players={@match.max_players}
          loading?={is_nil(@roster)}
        >
          <:action :if={@feed?}>
            <.link
              navigate={@base}
              class="flex h-9 shrink-0 items-center whitespace-nowrap rounded-full border border-white/8 bg-base-100/80 px-3.5 text-[0.8125rem] transition-colors hover:bg-base-100"
            >
              {gettext("See feed")}
            </.link>
          </:action>
        </.live_hero>

        <.empty_state
          :if={@server && @error?}
          icon="hero-signal-slash"
          title={gettext("CRCON did not answer")}
          description={gettext("The leaderboard comes back as soon as the server does.")}
        />

        <div
          :if={@server && is_nil(@roster) && not @error?}
          class="grid gap-3.5 sm:grid-cols-2 xl:grid-cols-3"
        >
          <.skeleton_block :for={_ <- 1..6} class="h-44 w-full rounded-[1.375rem]" />
        </div>

        <.empty_state
          :if={@roster == %{} and not @error?}
          icon="hero-moon"
          title={gettext("Nobody is playing right now")}
          description={gettext("The leaderboard fills in as soon as a match has players.")}
        />

        <div
          :if={@roster not in [nil, %{}]}
          class={[
            "grid items-start gap-5",
            @view == :leaderboard && "xl:grid-cols-[minmax(0,1fr)_26.875rem]"
          ]}
        >
          <section
            :if={@view == :leaderboard}
            id="leaderboard"
            class="flex min-w-0 flex-col gap-3.5"
            aria-labelledby="board-title"
          >
            <.board_header
              title={gettext("Best of the match")}
              loaded_at={@loaded_at}
              server={@server}
              base={@base}
              team={@team}
              view={@view}
              teams={@teams}
            />

            <div class="grid gap-3.5 sm:grid-cols-2 xl:grid-cols-3">
              <.rank_card
                :for={category <- categories()}
                id={"board-#{category}"}
                title={category_title(category)}
                note={category_note(category)}
                icon={category_icon(category)}
                teams={@teams}
                rows={
                  for row <- Leaderboards.top_players(@ranked, category, @size),
                      do: %{name: row.name, team: row.team, value: format_number(row.value)}
                }
              />
            </div>
          </section>

          <.board_header
            :if={@view == :squads}
            title={gettext("Best squads")}
            loaded_at={@loaded_at}
            server={@server}
            base={@base}
            team={@team}
            view={@view}
            teams={@teams}
          />

          <.live_panel
            id="leaderboard-squads"
            title={if @view == :leaderboard, do: gettext("Best squads")}
            gap="gap-1.5"
          >
            <:aside :if={@view == :leaderboard}>
              <span class="text-xs text-muted">{gettext("by type · combined score")}</span>
            </:aside>

            <div class={[
              "grid gap-x-8",
              @view == :squads && "md:grid-cols-2"
            ]}>
              <section
                :for={{type, index} <- Enum.with_index(Leaderboards.squad_types())}
                id={"board-squads-#{type}"}
                class="flex flex-col gap-1.5"
                aria-labelledby={"board-squads-#{type}-title"}
              >
                <h3
                  id={"board-squads-#{type}-title"}
                  class={[
                    "px-0.5 pb-0.5 font-mono text-[0.6875rem] tracking-[0.1em] text-muted uppercase",
                    if(index == 0 or (@view == :squads and index == 1), do: "pt-1.5", else: "pt-2.5")
                  ]}
                >
                  {Labels.squad_type(type)}
                </h3>
                <p
                  :if={Leaderboards.top_squads(@ranked, type, @size) == []}
                  class="px-2.5 py-2 text-xs text-muted"
                >
                  {gettext("Nobody ranked yet")}
                </p>
                <.squad_row
                  :for={
                    {squad, rank} <- Enum.with_index(Leaderboards.top_squads(@ranked, type, @size), 1)
                  }
                  squad={squad}
                  type={type}
                  first?={rank == 1}
                />
              </section>
            </div>
          </.live_panel>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :loaded_at, :any, required: true
  attr :server, :map, required: true
  attr :base, :string, required: true
  attr :team, :string, default: nil
  attr :view, :atom, required: true
  attr :teams, :map, required: true

  defp board_header(assigns) do
    ~H"""
    <header class="flex min-h-10 flex-wrap items-center gap-x-3 gap-y-2">
      <h2 id="board-title" class="font-display text-xl font-semibold">{@title}</h2>
      <span class="text-xs text-muted">
        {gettext("refreshes every 10 s")}
        <span :if={@loaded_at}>
          · <span class="font-mono">{clock(@loaded_at, @server)}</span>
        </span>
      </span>
      <span class="grow"></span>
      <nav
        id="leaderboard-teams"
        aria-label={gettext("Team")}
        class="flex gap-1 rounded-full bg-base-100 p-1"
      >
        <.team_tab patch={board_path(@base, @view, nil)} active={is_nil(@team)}>
          {gettext("Both teams")}
        </.team_tab>
        <.team_tab
          :for={team <- ["allies", "axis"]}
          patch={board_path(@base, @view, team)}
          active={@team == team}
          team={team}
        >
          {@teams[team]}
        </.team_tab>
      </nav>
    </header>
    """
  end

  attr :squad, :map, required: true
  attr :type, :atom, required: true
  attr :first?, :boolean, default: false

  # One squad: its initial on the team's tint, its head count against the
  # type's size and its leader, whether it has one, the combined score.
  defp squad_row(assigns) do
    ~H"""
    <div class={[
      "grid grid-cols-[2.375rem_minmax(0,1fr)_auto_auto] items-center gap-3 rounded-[0.875rem] px-2.5 py-2",
      @first? && "bg-secondary"
    ]}>
      <.initials_tile name={String.first(@squad.name)} team={@squad.team} size="lg" />
      <span class="flex min-w-0 flex-col">
        <strong class="truncate text-sm font-semibold">{String.capitalize(@squad.name)}</strong>
        <span class="truncate text-xs text-muted">
          <span class="font-mono">{@squad.size}/{Leaderboards.capacity(@type)}</span>
          <%= if @squad.leader do %>
            · {gettext("leader %{name}", name: @squad.leader)}
          <% else %>
            · {Enum.join(Enum.take(@squad.members, 2), ", ")}
          <% end %>
        </span>
      </span>
      <%= if @squad.has_leader do %>
        <span class="text-[0.6875rem] font-semibold text-primary">{gettext("with leader")}</span>
      <% else %>
        <span class="rounded-full bg-warning/13 px-2 py-0.5 text-[0.6875rem] font-semibold text-warning">
          {gettext("no leader")}
        </span>
      <% end %>
      <span class="min-w-14 text-right font-display text-lg font-semibold tabular-nums">
        {format_number(@squad.score)}
      </span>
    </div>
    """
  end

  attr :patch, :string, required: true
  attr :active, :boolean, default: false
  attr :team, :string, default: nil
  slot :inner_block, required: true

  defp team_tab(assigns) do
    ~H"""
    <.link
      patch={@patch}
      aria-current={@active && "page"}
      class={[
        "flex h-8 items-center rounded-full px-3.5 text-xs transition-colors",
        if(@active,
          do: "bg-base-content font-semibold text-base-100",
          else: [if(@team, do: team_text(@team), else: "text-subtle"), "hover:bg-secondary"]
        )
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp categories, do: @categories

  defp board_path(base, view, team) do
    params =
      [view: view == :squads && "squads", team: team]
      |> Enum.filter(fn {_key, value} -> value end)

    if params == [],
      do: base <> "/leaderboard",
      else: base <> "/leaderboard?" <> URI.encode_query(params)
  end

  # The roster narrowed to one team, or whole.
  defp only_team(roster, nil), do: roster

  defp only_team(roster, team),
    do: Map.filter(roster, fn {_id, p} -> team_key(p["team"]) == team end)

  # The time of the last read in the server's time zone, the clock its
  # players live by.
  defp clock(at, server) do
    at =
      case DateTime.shift_zone(at, server.timezone || "Etc/UTC") do
        {:ok, local} -> local
        {:error, _reason} -> at
      end

    Calendar.strftime(at, "%H:%M:%S")
  end

  defp chat_text(roster) do
    Enum.map_join(@chat_categories, "\n", fn category ->
      "#{category_title(category)}:#{Leaderboards.line(roster, category, @size)}"
    end)
  end

  defp category_title(:kills), do: gettext("Kills")
  defp category_title(:kill_death_ratio), do: gettext("K/D")
  defp category_title(:kills_per_minute), do: gettext("Kills / min")
  defp category_title(:combat), do: gettext("Combat")
  defp category_title(:offense), do: gettext("Offense")
  defp category_title(:defense), do: gettext("Defense")
  defp category_title(:support), do: gettext("Support")
  defp category_title(:vehicles_destroyed), do: gettext("Vehicles")
  defp category_title(:teamplay), do: gettext("Teamwork")

  defp category_note(:kill_death_ratio),
    do: gettext("min. %{count} kills", count: Leaderboards.min_kills_for_ratio())

  defp category_note(:vehicles_destroyed), do: gettext("destroyed")
  defp category_note(_category), do: nil

  defp category_icon(:kills), do: "hero-viewfinder-circle"
  defp category_icon(:kill_death_ratio), do: "hero-scale"
  defp category_icon(:kills_per_minute), do: "hero-clock"
  defp category_icon(:combat), do: "hero-fire"
  defp category_icon(:offense), do: "hero-arrow-trending-up"
  defp category_icon(:defense), do: "hero-shield-check"
  defp category_icon(:support), do: "hero-lifebuoy"
  defp category_icon(:vehicles_destroyed), do: "hero-truck"
  defp category_icon(:teamplay), do: "hero-heart"
end
