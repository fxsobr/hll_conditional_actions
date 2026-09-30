defmodule HllConditionalActionsWeb.PlayerLive.Show do
  @moduledoc """
  The 360 view of a player: who they are, what happened to them and why,
  and the buttons to act on them.

  The question this screen exists for is the one an admin gets in Discord -
  *"why was I kicked?"* - so the timeline puts on one line of time the rules
  that hit the player, the penalties CRCON recorded (by whom, with what
  reason), the tickets they opened or were cited in, their achievements and
  their VIP purchases.

  What the app recorded is read from its own tables. On top of that, after
  the page connects: the live player lists (are they playing, on which team,
  this match's numbers), the VIP list and the watchlist - one cached read per
  server - and the player's CRCON profile (sessions, playtime, penalties,
  flags). The finished matches of their servers are read from CRCON's match
  history into `player_match_stats` the first time (see
  `HllConditionalActions.Players.MatchHistory`), which feeds "the last 10
  matches". When CRCON does not answer, the page goes without.

  Actions (message, punish, kick, ban, watchlist, VIP) open a confirmation
  dialog and run through `HllConditionalActions.Players.Actions`, which
  checks the permission again; `?act=ban` (from the command palette) opens
  the dialog straight away.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_stats}}

  import Ecto.Query, only: [from: 2, where: 3, order_by: 3, limit: 2, preload: 2]

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Engine
  alias HllConditionalActions.Players
  alias HllConditionalActions.Players.Actions
  alias HllConditionalActions.Players.MatchHistory
  alias HllConditionalActions.Progression
  alias HllConditionalActions.Progression.PlayerTotal
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Tickets.Ticket
  alias HllConditionalActions.VipShop.Order
  alias HllConditionalActionsWeb.PlayerLive.Parts

  @tabs ~w(overview executions matches tickets purchases)
  @timeline_filters ~w(all penalties rules tickets)
  @timeline_size 25
  @ban_hours [1, 2, 6, 24]
  @vip_days [7, 30, 90]
  @punitive ~w(punish_player kick_player temp_ban_player perma_ban_player blacklist_player switch_player_team switch_player_on_death)a
  @act_params %{
    "message" => :message,
    "punish" => :punish,
    "kick" => :kick,
    "ban" => :temp_ban,
    "temp_ban" => :temp_ban,
    "perma_ban" => :perma_ban,
    "watch" => :watch,
    "watchlist" => :watch,
    "unwatch" => :unwatch,
    "vip" => :add_vip,
    "add_vip" => :add_vip,
    "remove_vip" => :remove_vip
  }

  @impl Phoenix.LiveView
  def mount(%{"player_id" => player_id}, _session, socket) do
    if connected?(socket), do: Engine.subscribe(nil)
    user = socket.assigns.current_user

    socket =
      socket
      |> assign(:player_id, player_id)
      |> assign(:tab, "overview")
      |> assign(:timeline_filter, "all")
      |> assign(:selected_execution, nil)
      |> assign(:tickets?, Accounts.can?(user, :view_tickets))
      |> assign(:history?, Accounts.can?(user, :view_executions))
      |> assign(:servers, Players.servers_for(user))
      |> assign(:live, nil)
      |> assign(:vip, nil)
      |> assign(:watch, nil)
      |> assign(:profile, :loading)
      |> assign(:pending, nil)
      |> load()

    socket =
      if connected?(socket) do
        send(self(), :refresh_crcon)
        # What is already cached shows at once; the rest comes with the read.
        servers = socket.assigns.servers
        {live, _status} = Players.live(servers, cached_only: true)

        socket
        |> assign(:live, Map.get(live, player_id))
        |> assign(:vip, Map.get(Players.vips(servers, cached_only: true), player_id))
        |> assign(:watch, Map.get(Players.watchlist(servers, cached_only: true), player_id))
      else
        socket
      end

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    socket = assign(socket, :tab, tab_param(params["tab"], socket.assigns.tickets?))

    socket =
      case Map.get(@act_params, params["act"]) do
        nil -> socket
        action -> open_action(socket, action)
      end

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("select_execution", %{"id" => id}, socket) do
    {:noreply,
     update(socket, :selected_execution, fn current -> if current == id, do: nil, else: id end)}
  end

  def handle_event("timeline_filter", %{"filter" => filter}, socket)
      when filter in @timeline_filters do
    {:noreply, assign(socket, :timeline_filter, filter)}
  end

  def handle_event("timeline_filter", _params, socket), do: {:noreply, socket}

  def handle_event("action_open", %{"action" => action} = params, socket) do
    case Actions.parse(action) do
      nil ->
        {:noreply, socket}

      action ->
        socket = open_action(socket, action)

        socket =
          case {socket.assigns.pending, params["hours"]} do
            {%{} = pending, hours} when is_binary(hours) ->
              assign(socket, :pending, set_hours(pending, hours))

            _other ->
              socket
          end

        {:noreply, socket}
    end
  end

  def handle_event("action_cancel", _params, socket),
    do: {:noreply, assign(socket, :pending, nil)}

  def handle_event(
        "action_duration",
        %{"value" => value},
        %{assigns: %{pending: %{} = p}} = socket
      ) do
    pending =
      case {p.action, value} do
        {action, "permanent"} when action in [:temp_ban, :perma_ban] ->
          %{p | action: :perma_ban}

        {action, hours} when action in [:temp_ban, :perma_ban] ->
          set_hours(%{p | action: :temp_ban}, hours)

        {:add_vip, "forever"} ->
          %{p | days: nil}

        {:add_vip, days} ->
          case Integer.parse(days) do
            {days, ""} when days in @vip_days -> %{p | days: days}
            _other -> p
          end

        _other ->
          p
      end

    {:noreply, assign(socket, :pending, pending)}
  end

  def handle_event("action_duration", _params, socket), do: {:noreply, socket}

  def handle_event(
        "action_change",
        %{"action" => params},
        %{assigns: %{pending: %{} = p}} = socket
      ) do
    {:noreply, assign(socket, :pending, merge_form(p, params, socket.assigns.servers))}
  end

  def handle_event("action_change", _params, socket), do: {:noreply, socket}

  def handle_event("action_run", %{"action" => params}, %{assigns: %{pending: %{} = p}} = socket) do
    pending = merge_form(p, params, socket.assigns.servers)
    server = Enum.find(socket.assigns.servers, &(&1.id == pending.server_id))

    cond do
      is_nil(server) ->
        {:noreply, put_flash(socket, :error, gettext("Choose a server."))}

      needs_typing?(pending.action) and not typed?(pending, socket.assigns) ->
        {:noreply,
         socket
         |> assign(:pending, pending)
         |> put_flash(:error, gettext("Type the player's name to confirm."))}

      true ->
        run_action(socket, server, pending)
    end
  end

  def handle_event("action_run", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_info({:rule_fired, execution}, socket) do
    if execution.player_id == socket.assigns.player_id,
      do: {:noreply, load(socket)},
      else: {:noreply, socket}
  end

  def handle_info(:refresh_crcon, socket) do
    %{servers: servers, player_id: player_id} = socket.assigns
    profile_server = profile_server(socket.assigns)
    match_servers = match_servers(socket.assigns)

    socket =
      start_async(socket, :matches, fn ->
        match_servers |> Enum.map(&MatchHistory.sync/1) |> Enum.sum()
      end)

    {:noreply,
     start_async(socket, :crcon, fn ->
       {live, _status} = Players.live(servers)
       entry = Map.get(live, player_id)
       server = (entry && Enum.find(servers, &(&1.id == entry.server_id))) || profile_server

       %{
         live: entry,
         vip: Map.get(Players.vips(servers), player_id),
         watch: Map.get(Players.watchlist(servers), player_id),
         profile: if(server, do: Players.profile(server, player_id), else: :none)
       }
     end)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_async(:crcon, {:ok, crcon}, socket) do
    profile =
      case crcon.profile do
        {:ok, profile} -> profile
        :none -> :none
        :error -> :unavailable
      end

    socket =
      socket
      |> assign(:live, crcon.live)
      |> assign(:vip, crcon.vip)
      |> assign(:watch, crcon.watch)
      |> assign(:profile, profile)

    {:noreply, socket}
  end

  def handle_async(:crcon, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :profile, :unavailable)}

  # New finished matches were read from CRCON's history: the last 10 change.
  def handle_async(:matches, {:ok, read}, socket) when read > 0,
    do: {:noreply, load_matches(socket)}

  def handle_async(:matches, _result, socket), do: {:noreply, socket}

  # ── Loading ────────────────────────────────────────────────────────────────

  defp load(socket) do
    player_id = socket.assigns.player_id
    user = socket.assigns[:current_user]
    scope = Accounts.server_scope(user)

    executions = Rules.list_executions_for(user, player_id: player_id, limit: 100)
    totals = server_totals(user, player_id)
    tickets = if socket.assigns.tickets?, do: player_tickets(user, player_id), else: []
    cited = if socket.assigns.tickets?, do: cited_tickets(user, player_id), else: []
    directory = Players.get_profile(player_id)

    socket
    |> assign(:scope, scope)
    |> assign(:executions, executions)
    |> assign(:stats, Rules.execution_stats(player_id: player_id))
    |> assign(:rules, top_rules(player_id))
    |> assign(:achievements, Progression.player_achievements(player_id))
    |> assign(:totals, totals)
    |> assign(:tickets, tickets)
    |> assign(:cited, cited)
    |> assign(:orders, orders(player_id))
    |> assign(:directory, directory)
    |> load_matches()
    |> then(fn socket ->
      name = player_name(socket.assigns)
      socket |> assign(:player_name, name) |> assign(:page_title, name || player_id)
    end)
  end

  defp load_matches(socket) do
    %{player_id: player_id, scope: scope} = socket.assigns
    since = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)

    socket
    |> assign(:recent, MatchHistory.recent(player_id, scope, 10))
    |> assign(:team_kills_30d, MatchHistory.team_kills_since(player_id, scope, since))
    |> assign(:first_match, MatchHistory.first(player_id, scope))
    |> assign(:match_count, MatchHistory.count(player_id, scope))
    |> assign(:match_list, MatchHistory.list(player_id, scope, limit: 50))
  end

  defp server_totals(user, player_id) do
    PlayerTotal
    |> scoped(user)
    |> where([p], p.player_id == ^player_id)
    |> order_by([p], desc: p.updated_at)
    |> preload(:server)
    |> Repo.all()
  end

  defp player_tickets(user, player_id) do
    Ticket
    |> scoped(user)
    |> where([t], t.player_id == ^player_id)
    |> order_by([t], desc: t.inserted_at, desc: t.id)
    |> limit(50)
    |> preload([:server, :messages])
    |> Repo.all()
  end

  defp cited_tickets(user, player_id) do
    Ticket
    |> scoped(user)
    |> where([t], t.reported_player_id == ^player_id and t.player_id != ^player_id)
    |> order_by([t], desc: t.inserted_at, desc: t.id)
    |> limit(50)
    |> preload([:server, :messages])
    |> Repo.all()
  end

  defp orders(player_id) do
    Order
    |> where([o], o.player_id == ^player_id and o.status in ~w(paid fulfilled partial refunded))
    |> order_by([o], desc: o.inserted_at)
    |> limit(50)
    |> preload(:grants)
    |> Repo.all()
  end

  # The rules that hit the player most, each marked punitive or not: a rule
  # that punishes draws its bar in the engine's colour, a friendly one in
  # the signal's.
  defp top_rules(player_id) do
    rows = Rules.rules_for_player(player_id, limit: 6)
    ids = Enum.map(rows, & &1.rule_id)

    punitive =
      from(r in Rule, where: r.id in ^ids, select: {r.id, r.actions})
      |> Repo.all()
      |> Map.new(fn {id, actions} ->
        {id, Enum.any?(actions || [], &(&1.type in @punitive))}
      end)

    Enum.map(rows, &Map.put(&1, :punitive?, Map.get(punitive, &1.rule_id, false)))
  end

  defp scoped(query, user) do
    case Accounts.server_scope(user) do
      :all -> query
      ids -> where(query, [x], x.server_id in ^ids)
    end
  end

  # The server to ask CRCON about the player: the one they were last seen
  # on, or the first one there is.
  defp profile_server(assigns) do
    last = last_server_id(assigns)
    Enum.find(assigns.servers, &(&1.id == last)) || List.first(assigns.servers)
  end

  defp last_server_id(assigns) do
    [
      assigns.executions |> List.first() |> then(&(&1 && &1.server_id)),
      assigns.totals |> List.first() |> then(&(&1 && &1.server_id)),
      assigns.recent |> List.first() |> then(&(&1 && &1.server_id)),
      assigns.tickets |> List.first() |> then(&(&1 && &1.server_id))
    ]
    |> Enum.find(& &1)
  end

  # Where the player's matches are: the servers they have totals on, or
  # every server when nothing was recorded yet.
  defp match_servers(assigns) do
    ids =
      (Enum.map(assigns.totals, & &1.server_id) ++ Enum.map(assigns.recent, & &1.server_id))
      |> Enum.uniq()

    case Enum.filter(assigns.servers, &(&1.id in ids)) do
      [] -> assigns.servers
      servers -> servers
    end
  end

  defp tab_param("tickets", false), do: "overview"
  defp tab_param(tab, _tickets?) when tab in @tabs, do: tab
  defp tab_param(_other, _tickets?), do: "overview"

  # The most recent name wins: players rename themselves, and the newest one
  # is what an admin will recognise.
  defp player_name(assigns) do
    [
      assigns.directory && assigns.directory.name,
      Enum.find_value(assigns.executions, &present_name(&1.player_name)),
      Enum.find_value(assigns.recent, &present_name(&1.player_name)),
      Enum.find_value(assigns.totals, &present_name(&1.player_name)),
      Enum.find_value(assigns.tickets, &present_name(&1.player_name)),
      Enum.find_value(assigns.cited, &present_name(&1.reported_player_name))
    ]
    |> Enum.find(&present_name/1)
  end

  defp present_name(name) when is_binary(name) and name != "", do: name
  defp present_name(_name), do: nil

  defp nothing_recorded?(assigns) do
    assigns.executions == [] and assigns.totals == [] and assigns.tickets == [] and
      assigns.achievements == [] and assigns.recent == [] and is_nil(assigns.directory) and
      assigns.cited == [] and not is_map(assigns.live) and not is_map(assigns.profile)
  end

  # ── Actions ────────────────────────────────────────────────────────────────

  defp can_act?(assigns) do
    Enum.any?(assigns.servers, &Players.can_act?(assigns.current_user, &1))
  end

  defp open_action(socket, action) do
    if can_act?(socket.assigns) and Actions.parse(action) do
      server_id =
        (socket.assigns.live && socket.assigns.live.server_id) || last_server_id(socket.assigns)

      server =
        Enum.find(socket.assigns.servers, &(&1.id == server_id)) ||
          Enum.find(socket.assigns.servers, &Players.can_act?(socket.assigns.current_user, &1))

      assign(socket, :pending, %{
        action: action,
        server_id: server && server.id,
        hours: 2,
        days: 30,
        reason: "",
        typed: ""
      })
    else
      socket
    end
  end

  defp set_hours(pending, hours) do
    case Integer.parse(to_string(hours)) do
      {hours, ""} when hours in 1..8760 -> %{pending | hours: hours}
      _other -> pending
    end
  end

  defp merge_form(pending, params, servers) do
    server_id =
      case Integer.parse(to_string(params["server_id"] || "")) do
        {id, ""} -> if Enum.any?(servers, &(&1.id == id)), do: id, else: pending.server_id
        _other -> pending.server_id
      end

    %{
      pending
      | reason: String.slice(params["reason"] || pending.reason, 0, 200),
        typed: params["typed"] || pending.typed,
        server_id: server_id
    }
  end

  defp needs_typing?(action), do: action in [:temp_ban, :perma_ban]

  defp typed?(pending, assigns) do
    expected = assigns.player_name || assigns.player_id
    String.trim(pending.typed) in [expected, assigns.player_id]
  end

  defp run_action(socket, server, pending) do
    %{current_user: user, player_id: player_id, player_name: name} = socket.assigns

    opts = [hours: pending.hours, days: pending.days, player_name: name]

    case Actions.run(user, server, player_id, pending.action, pending.reason, opts) do
      {:ok, _result} ->
        send(self(), :refresh_crcon)

        {:noreply,
         socket
         |> assign(:pending, nil)
         |> put_flash(:info, done_message(pending, name || player_id, server))}

      {:error, :empty_reason} ->
        {:noreply,
         socket
         |> assign(:pending, pending)
         |> put_flash(:error, gettext("Write the reason the player reads."))}

      {:error, :bad_duration} ->
        {:noreply, put_flash(socket, :error, gettext("The ban lasts between 1 hour and 1 year."))}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign(:pending, nil)
         |> put_flash(:error, gettext("You cannot act on players of this server."))}

      {:error, message} when is_binary(message) ->
        {:noreply,
         put_flash(socket, :error, gettext("CRCON refused it: %{error}", error: message))}

      {:error, _other} ->
        {:noreply, socket}
    end
  end

  defp done_message(%{action: :message}, name, server),
    do: gettext("Message sent to %{player} on %{server}.", player: name, server: server.name)

  defp done_message(%{action: :punish}, name, server),
    do: gettext("%{player} was punished on %{server}.", player: name, server: server.name)

  defp done_message(%{action: :kick}, name, server),
    do: gettext("%{player} was kicked from %{server}.", player: name, server: server.name)

  defp done_message(%{action: :temp_ban, hours: hours}, name, server),
    do:
      gettext("%{player} was banned for %{hours} h on %{server}.",
        player: name,
        hours: hours,
        server: server.name
      )

  defp done_message(%{action: :perma_ban}, name, server),
    do: gettext("%{player} was banned for good on %{server}.", player: name, server: server.name)

  defp done_message(%{action: :watch}, name, _server),
    do: gettext("%{player} is on the watchlist.", player: name)

  defp done_message(%{action: :unwatch}, name, _server),
    do: gettext("%{player} left the watchlist.", player: name)

  defp done_message(%{action: :add_vip}, name, server),
    do: gettext("%{player} has VIP on %{server}.", player: name, server: server.name)

  defp done_message(%{action: :remove_vip}, name, server),
    do: gettext("%{player} no longer has VIP on %{server}.", player: name, server: server.name)

  # ── Figures ────────────────────────────────────────────────────────────────

  defp sum(list, field), do: list |> Enum.map(&(Map.get(&1, field) || 0)) |> Enum.sum()

  defp playtime(%{profile: %{playtime_seconds: seconds}}) when is_integer(seconds), do: seconds
  defp playtime(%{directory: %{playtime_seconds: seconds}}) when is_integer(seconds), do: seconds
  defp playtime(assigns), do: sum(assigns.totals, :playtime_seconds)

  defp sessions(%{profile: %{sessions: sessions}}) when is_integer(sessions), do: sessions
  defp sessions(%{directory: %{sessions: sessions}}) when is_integer(sessions), do: sessions
  defp sessions(_assigns), do: nil

  defp playtime_hint(assigns) do
    case sessions(assigns) do
      nil ->
        matches = sum(assigns.totals, :matches)

        if matches > 0,
          do: ngettext("in %{count} match", "in %{count} matches", matches, count: matches),
          else: gettext("no match recorded")

      sessions ->
        ngettext("in %{count} session", "in %{count} sessions", sessions,
          count: Parts.number(sessions)
        )
    end
  end

  defp kd_recent([]), do: "–"

  defp kd_recent(recent) do
    kills = sum(recent, :kills)
    deaths = sum(recent, :deaths)
    if deaths == 0, do: to_string(kills), else: Parts.decimal(kills / deaths)
  end

  defp kd_hint([]), do: gettext("no match recorded")

  defp kd_hint(recent) do
    gettext("%{count} kills per match", count: round(sum(recent, :kills) / length(recent)))
  end

  defp penalties(%{profile: %{penalties: count}}), do: count

  defp penalties(%{directory: %{penalties: count}, profile: profile}) when profile != :loading,
    do: count

  defp penalties(_assigns), do: nil

  defp penalty_hint(%{profile: %{penalty_counts: counts}}) when map_size(counts) > 0 do
    bans = Map.get(counts, "TEMPBAN", 0) + Map.get(counts, "PERMABAN", 0)
    kicks = Map.get(counts, "KICK", 0)
    punishes = Map.get(counts, "PUNISH", 0)

    [
      bans > 0 && ngettext("%{count} ban", "%{count} bans", bans, count: bans),
      kicks > 0 && ngettext("%{count} kick", "%{count} kicks", kicks, count: kicks),
      bans + kicks == 0 && punishes > 0 &&
        ngettext("%{count} punishment", "%{count} punishments", punishes, count: punishes)
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  defp penalty_hint(%{profile: %{}}), do: gettext("a clean record in CRCON")
  defp penalty_hint(%{profile: :loading}), do: gettext("asking CRCON…")
  defp penalty_hint(%{profile: :unavailable}), do: gettext("CRCON did not answer")
  defp penalty_hint(_assigns), do: gettext("never seen on a server")

  defp gold_count(achievements) do
    Enum.count(achievements, &(&1.achievement.tier in [:gold, :legendary]))
  end

  defp vip_label(assigns) do
    expires =
      (assigns.vip && assigns.vip.expires_at) ||
        (is_map(assigns.profile) && assigns.profile.vip_expires)

    cond do
      not vip?(assigns) -> nil
      expires -> gettext("VIP until %{date}", date: short_date(expires))
      true -> gettext("VIP")
    end
  end

  defp vip?(assigns), do: assigns.vip != nil or (is_map(assigns.profile) and assigns.profile.vip?)

  defp watched?(assigns),
    do: assigns.watch != nil or (is_map(assigns.profile) and assigns.profile.watch != nil)

  defp short_date(%DateTime{} = at) do
    "#{at.day} #{Parts.month(at.month)}"
  end

  defp role_line(nil), do: nil

  defp role_line(live) do
    [Parts.team_label(live.team), Parts.role_label(live.role)]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
    |> case do
      "" -> nil
      line -> line
    end
  end

  defp level(assigns) do
    (assigns.live && assigns.live.level) || (assigns.directory && assigns.directory.level) ||
      Enum.find_value(assigns.recent, & &1.level)
  end

  defp platform(assigns) do
    platform_name(
      (assigns.live && assigns.live.platform) ||
        (is_map(assigns.profile) && assigns.profile.platform)
    )
  end

  defp platform_name("steam"), do: "Steam"
  defp platform_name("epic"), do: "Epic"
  defp platform_name("xbl"), do: "Xbox"
  defp platform_name("psn"), do: "PlayStation"
  defp platform_name(other), do: other

  defp crumb(assigns) do
    case assigns.cited do
      [ticket | _] -> gettext("Players · cited in #%{id}", id: ticket.id)
      [] -> gettext("Players")
    end
  end

  # ── The last ten matches ───────────────────────────────────────────────────

  # Oldest on the left; with the player online, the match being played is
  # the last bar.
  defp match_bars(assigns) do
    finished = if assigns.live, do: Enum.take(assigns.recent, 9), else: assigns.recent

    bars =
      finished
      |> Enum.reverse()
      |> Enum.map(fn stat ->
        %{
          id: "match-#{stat.id}",
          kills: stat.kills,
          team_kills: stat.team_kills,
          live?: false,
          title:
            gettext("%{map} · %{kills} kills · %{tk} TKs",
              map: stat.map || "?",
              kills: stat.kills,
              tk: stat.team_kills
            )
        }
      end)

    bars =
      if assigns.live do
        bars ++
          [
            %{
              id: "match-live",
              kills: assigns.live.kills,
              team_kills: assigns.live.team_kills,
              live?: true,
              title:
                gettext("Now · %{kills} kills · %{tk} TKs",
                  kills: assigns.live.kills,
                  tk: assigns.live.team_kills
                )
            }
          ]
      else
        bars
      end

    top_kills = bars |> Enum.map(& &1.kills) |> Enum.max(fn -> 1 end) |> max(1)
    top_tk = bars |> Enum.map(& &1.team_kills) |> Enum.max(fn -> 1 end) |> max(3)

    Enum.map(bars, fn bar ->
      bar
      |> Map.put(:kills_height, max(round(bar.kills / top_kills * 84), 4))
      |> Map.put(
        :tk_height,
        if(bar.team_kills > 0, do: max(round(bar.team_kills / top_tk * 18), 6), else: 0)
      )
    end)
  end

  defp bar_width(count, rules) do
    top = rules |> Enum.map(& &1.count) |> Enum.max(fn -> 1 end) |> max(1)
    max(round(count / top * 100), 4)
  end

  # ── The timeline ───────────────────────────────────────────────────────────
  # Rule runs, penalties, tickets, achievements and purchases on one line of
  # time, newest first.

  defp timeline_entries(assigns) do
    filter = assigns.timeline_filter
    show? = fn kind -> filter == "all" or filter == kind end

    [
      if(show?.("rules"), do: Enum.map(assigns.executions, &execution_entry/1), else: []),
      if(show?.("penalties"), do: penalty_entries(assigns.profile), else: []),
      if(show?.("tickets"),
        do:
          Enum.map(assigns.tickets, &ticket_entry(&1, :opened)) ++
            Enum.map(assigns.cited, &ticket_entry(&1, :cited)),
        else: []
      ),
      if(filter == "all", do: achievement_entries(assigns), else: []),
      if(filter == "all", do: Enum.map(assigns.orders, &order_entry/1), else: []),
      if(filter == "all", do: first_entry(assigns), else: [])
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil(&1.at))
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> group_runs()
    |> Enum.take(@timeline_size)
  end

  # A rule that fires every few minutes would bury everything else, so the
  # runs of one rule (same outcome, same step) that follow each other with
  # nothing else in between - and less than `@run_gap` apart - read as one
  # line with a count. The line keeps the newest run; the "rules" tab still
  # lists every run.
  @run_gap 3 * 3600

  defp group_runs(entries) do
    {groups, order, _open} = Enum.reduce(entries, {%{}, [], %{}}, &take_entry/2)
    order |> Enum.reverse() |> Enum.map(&Map.fetch!(groups, &1))
  end

  defp take_entry(%{kind: :execution} = entry, {groups, order, open}) do
    key = run_key(entry)
    id = Map.get(open, key)

    if id && DateTime.diff(groups[id].since, entry.at) <= @run_gap,
      do: {Map.update!(groups, id, &add_run(&1, entry)), order, open},
      else: open_run(entry, key, groups, order, open)
  end

  defp take_entry(entry, {groups, order, _open}),
    do: {Map.put(groups, entry.id, entry), [entry.id | order], %{}}

  defp open_run(entry, key, groups, order, open),
    do: {Map.put(groups, entry.id, entry), [entry.id | order], Map.put(open, key, entry.id)}

  defp run_key(%{execution: execution, step: step}),
    do: {execution.rule_id, execution.status, step, execution.server_id}

  defp add_run(group, entry), do: %{group | runs: group.runs + 1, since: entry.at}

  defp execution_entry(execution) do
    step = get_in(execution.trace || %{}, ["step"])

    %{
      id: "execution-#{execution.id}",
      kind: :execution,
      execution: execution,
      at: execution.executed_at,
      since: execution.executed_at,
      runs: 1,
      icon: "hero-bolt",
      tone: status_tone(execution.status),
      detail: trigger_label(execution.trigger_event),
      server: execution.server && execution.server.name,
      step: step,
      action: first_action(execution)
    }
  end

  defp penalty_entries(%{actions: actions}) do
    actions
    |> Enum.filter(&(&1.type in ~w(PUNISH KICK TEMPBAN PERMABAN BLACKLIST)))
    |> Enum.with_index()
    |> Enum.map(fn {action, index} ->
      %{
        id: "penalty-#{index}",
        kind: :penalty,
        at: action.at,
        icon: penalty_icon(action.type),
        tone: penalty_tone(action.type),
        penalty: action,
        detail: action.reason && "“#{action.reason}”"
      }
    end)
  end

  defp penalty_entries(_profile), do: []

  defp ticket_entry(ticket, how) do
    %{
      id: "#{how}-ticket-#{ticket.id}",
      kind: how,
      ticket: ticket,
      at: ticket.inserted_at,
      icon: "hero-chat-bubble-left",
      tone: "engine",
      detail:
        case first_message(ticket) do
          nil -> ticket.server && ticket.server.name
          text -> "“#{text}”"
        end
    }
  end

  defp first_message(%{messages: [_ | _] = messages}) do
    Enum.find_value(messages, fn message ->
      if message.author == :player, do: String.slice(message.body || "", 0, 140)
    end)
  end

  defp first_message(_ticket), do: nil

  # The same achievement can be unlocked on each server; the server's name
  # tells those lines apart when the player has unlocks on more than one.
  defp achievement_entries(%{achievements: unlocks, servers: servers}) do
    names = Map.new(servers, &{&1.id, &1.name})
    several? = unlocks |> Enum.map(& &1.server_id) |> Enum.uniq() |> length() > 1

    Enum.map(unlocks, fn unlock ->
      server = if several?, do: Map.get(names, unlock.server_id)
      unlock |> achievement_entry() |> Map.put(:server, server)
    end)
  end

  defp achievement_entry(unlock) do
    %{
      id: "unlock-#{unlock.id}",
      kind: :achievement,
      at: unlock.unlocked_at,
      icon: "hero-trophy",
      tone: "warning",
      unlock: unlock,
      detail:
        if(unlock.simulated,
          do: gettext("simulated, never announced"),
          else: unlock.achievement.description
        )
    }
  end

  defp order_entry(order) do
    delivered = Enum.count(order.grants, &(&1.status in ["granted", "delivered", "ok"]))

    %{
      id: "order-#{order.id}",
      kind: :order,
      at: order.paid_at || order.inserted_at,
      icon: "hero-shopping-bag",
      tone: "primary",
      order: order,
      detail:
        [
          money(order.amount_cents, order.currency),
          provider(order),
          delivered > 0 &&
            ngettext(
              "delivered on %{count} server",
              "delivered on the %{count} servers",
              delivered,
              count: delivered
            )
        ]
        |> Enum.filter(&(&1 not in [nil, false, ""]))
        |> Enum.join(" · ")
    }
  end

  # The first session: the first match read with the player in it, unless
  # CRCON saw them earlier than that (its history goes further back).
  defp first_entry(assigns) do
    [first_match_entry(assigns.first_match), first_seen_entry(assigns.profile)]
    |> Enum.reject(&(is_nil(&1) or is_nil(&1.at)))
    |> Enum.min_by(& &1.at, DateTime, fn -> nil end)
    |> List.wrap()
  end

  defp first_match_entry(%{} = first) do
    %{
      id: "first-session",
      kind: :first,
      at: first.started_at || first.ended_at,
      icon: "hero-arrow-right-end-on-rectangle",
      tone: "neutral",
      detail: first.map,
      server: first.server && first.server.name
    }
  end

  defp first_match_entry(_first), do: nil

  defp first_seen_entry(%{first_seen_at: %DateTime{} = at}) do
    %{
      id: "first-session",
      kind: :first,
      at: at,
      icon: "hero-arrow-right-end-on-rectangle",
      tone: "neutral",
      detail: nil
    }
  end

  defp first_seen_entry(_profile), do: nil

  defp trigger_label(nil), do: nil

  defp trigger_label(trigger) do
    Labels.trigger(String.to_existing_atom(trigger))
  rescue
    _error -> nil
  end

  defp first_action(%{results: [%{"type" => type} | _]}), do: short_action(type)

  defp first_action(%{rule: %Rule{actions: [action | _]}}),
    do: short_action(to_string(action.type))

  defp first_action(_execution), do: nil

  defp short_action("punish_player"), do: gettext("Punish")
  defp short_action("kick_player"), do: gettext("Kick")
  defp short_action("temp_ban_player"), do: gettext("Ban")
  defp short_action("perma_ban_player"), do: gettext("Ban")
  defp short_action("message_player"), do: gettext("Message")
  defp short_action("grant_vip"), do: gettext("VIP")

  defp short_action(type) when is_binary(type) do
    Labels.action(String.to_existing_atom(type))
  rescue
    _error -> nil
  end

  defp short_action(_type), do: nil

  defp verb(:executed), do: gettext("carried out")
  defp verb(:simulated), do: gettext("only simulated")
  defp verb(:partial), do: gettext("carried out in part")
  defp verb(:failed), do: gettext("failed")

  defp status_tone(:executed), do: "primary"
  defp status_tone(:partial), do: "warning"
  defp status_tone(:failed), do: "error"
  defp status_tone(:simulated), do: "engine"
  defp status_tone(_status), do: "neutral"

  defp verb_class(:simulated), do: "text-accent"
  defp verb_class(:failed), do: "text-error"
  defp verb_class(:partial), do: "text-warning"
  defp verb_class(_status), do: "text-primary"

  defp penalty_icon(type) when type in ~w(TEMPBAN PERMABAN BLACKLIST), do: "hero-no-symbol"
  defp penalty_icon("KICK"), do: "hero-arrow-right-start-on-rectangle"
  defp penalty_icon(_punish), do: "hero-exclamation-triangle"

  defp penalty_tone(type) when type in ~w(TEMPBAN PERMABAN BLACKLIST), do: "error"
  defp penalty_tone(_type), do: "warning"

  defp penalty_text("TEMPBAN", nil), do: gettext("Banned for a while")
  defp penalty_text("TEMPBAN", by), do: gettext("Banned for a while by %{by}", by: by)
  defp penalty_text("PERMABAN", nil), do: gettext("Banned for good")
  defp penalty_text("PERMABAN", by), do: gettext("Banned for good by %{by}", by: by)
  defp penalty_text("BLACKLIST", nil), do: gettext("Blacklisted")
  defp penalty_text("BLACKLIST", by), do: gettext("Blacklisted by %{by}", by: by)
  defp penalty_text("KICK", nil), do: gettext("Kicked")
  defp penalty_text("KICK", by), do: gettext("Kicked by %{by}", by: by)
  defp penalty_text(_punish, nil), do: gettext("Punished")
  defp penalty_text(_punish, by), do: gettext("Punished by %{by}", by: by)

  defp tile(tone) do
    case tone do
      "primary" -> "bg-primary/12 text-primary"
      "engine" -> "bg-accent/13 text-accent"
      "warning" -> "bg-warning/14 text-warning"
      "error" -> "bg-error/14 text-error"
      _neutral -> "bg-secondary text-subtle"
    end
  end

  defp money(nil, _currency), do: nil

  defp money(cents, currency) do
    whole = div(cents, 100)
    part = cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")

    case currency do
      "BRL" -> "R$ #{Parts.number(whole)},#{part}"
      "USD" -> "US$ #{whole}.#{part}"
      "EUR" -> "€ #{whole},#{part}"
      other -> "#{other} #{whole}.#{part}"
    end
  end

  defp provider(%{provider: "mercado_pago"}), do: "Mercado Pago"
  defp provider(%{provider: "stripe"}), do: "Stripe"
  defp provider(%{provider: "dodo"}), do: "Dodo Payments"
  defp provider(%{granted_by: by}) when is_binary(by), do: gettext("given by %{name}", name: by)
  defp provider(_order), do: nil

  defp timeline_filters(tickets?) do
    [
      {"all", gettext("Everything")},
      {"penalties", gettext("Penalties")},
      {"rules", gettext("Rules")},
      tickets? && {"tickets", gettext("Tickets")}
    ]
    |> Enum.filter(& &1)
  end

  defp entry_execution_id(%{kind: :execution, execution: execution}), do: to_string(execution.id)
  defp entry_execution_id(_entry), do: :none

  defp result_tone("ok"), do: "text-primary"
  defp result_tone("skipped"), do: "text-muted"
  defp result_tone("simulated"), do: "text-accent"
  defp result_tone(_status), do: "text-error"

  defp action_label(nil), do: nil

  defp action_label(type) do
    Labels.action(String.to_existing_atom(type))
  rescue
    _error -> type
  end

  defp status_pill(:executed), do: "live"
  defp status_pill(:partial), do: "warning"
  defp status_pill(:failed), do: "error"
  defp status_pill(:simulated), do: "simulating"
  defp status_pill(_status), do: "neutral"

  defp ticket_pill(:open), do: "warning"
  defp ticket_pill(:answered), do: "info"
  defp ticket_pill(_closed), do: "neutral"

  defp order_pill("fulfilled"), do: "live"
  defp order_pill("paid"), do: "info"
  defp order_pill("partial"), do: "warning"
  defp order_pill(_other), do: "neutral"

  defp order_status("fulfilled"), do: gettext("Delivered")
  defp order_status("paid"), do: gettext("Paid")
  defp order_status("partial"), do: gettext("Partly delivered")
  defp order_status("refunded"), do: gettext("Refunded")
  defp order_status(other), do: other

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assigns
      |> assign(:can_act?, can_act?(assigns))
      |> assign(:vip_label, vip_label(assigns))
      |> assign(:watched?, watched?(assigns))
      |> assign(:level, level(assigns))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@player_name || gettext("Player")}
      back={~p"/players"}
      back_label={gettext("Back to players")}
      tabs={false}
      tab_bar={false}
      header={false}
    >
      <div class="player-360 flex flex-col gap-3 md:gap-5">
        <%!-- Phone: the page's own header (MobilePlayer board). --%>
        <header class="flex h-[3.25rem] items-center gap-2.5 md:hidden">
          <.link
            navigate={~p"/players"}
            aria-label={gettext("Back to players")}
            class="flex size-11 shrink-0 items-center justify-center rounded-full border border-base-300 bg-base-100"
          >
            <.icon name="hero-chevron-left" class="size-[1.125rem]" />
          </.link>
          <div class="flex min-w-0 flex-1 flex-col gap-px">
            <span class="truncate text-xs text-muted">{crumb(assigns)}</span>
            <h1 class="truncate font-display text-[1.375rem] font-semibold tracking-[-0.01em]">
              {@player_name || @player_id}
            </h1>
          </div>
          <.more_menu
            :if={@can_act?}
            id="player-more-phone"
            vip?={vip?(assigns)}
            watched?={@watched?}
            round
          />
        </header>

        <.empty_state
          :if={nothing_recorded?(assigns) and @profile != :loading}
          icon="hero-user"
          title={gettext("Nothing recorded for this player")}
          description={
            gettext(
              "No rule has ever acted on this player, no match recorded them and CRCON does not know them."
            )
          }
        />

        <%!-- Wide screens: the hero with the actions (Player board). --%>
        <section
          id="player-hero"
          class="player-card hidden items-center gap-[1.375rem] px-7 py-6 md:flex"
        >
          <.link
            navigate={~p"/players"}
            aria-label={gettext("Back to players")}
            class="flex size-11 shrink-0 items-center justify-center rounded-full bg-secondary transition-colors hover:bg-base-300"
          >
            <.icon name="hero-chevron-left" class="size-[1.125rem]" />
          </.link>
          <Parts.avatar_tile name={@player_name} team={@live && @live.team} size="lg" />

          <div class="flex min-w-0 flex-1 flex-col gap-2">
            <div class="flex min-w-0 flex-wrap items-center gap-3">
              <h1
                id="player-name"
                class="min-w-0 truncate font-display text-[2.5rem] font-bold leading-tight tracking-[-0.03em]"
              >
                {@player_name || gettext("Unknown player")}
              </h1>
              <.online_pill live={@live} profile={@profile} />
            </div>

            <div class="flex flex-wrap items-center gap-2.5 text-[0.8125rem] text-subtle">
              <span class="select-all font-mono text-xs">{@player_id}</span>
              <%= if role_line(@live) do %>
                <span class="text-line-strong" aria-hidden="true">·</span>
                <span class={team_text(@live.team)}>{role_line(@live)}</span>
              <% end %>
              <%= if @level do %>
                <span class="text-line-strong" aria-hidden="true">·</span>
                <span>{gettext("Level %{level}", level: @level)}</span>
              <% end %>
              <%= if platform(assigns) do %>
                <span class="text-line-strong" aria-hidden="true">·</span>
                <span>{platform(assigns)}</span>
              <% end %>
              <.hero_marks
                vip_label={@vip_label}
                watched?={@watched?}
                profile={@profile}
                live={nil}
              />
            </div>
          </div>

          <div :if={@can_act?} id="player-actions" class="flex shrink-0 flex-wrap justify-end gap-2">
            <button
              type="button"
              id="player-act-message"
              class="player-action"
              phx-click="action_open"
              phx-value-action="message"
            >
              {gettext("Message")}
            </button>
            <button
              type="button"
              id="player-act-punish"
              class="player-action"
              phx-click="action_open"
              phx-value-action="punish"
              disabled={is_nil(@live)}
              title={is_nil(@live) && gettext("Only a player on a server can be punished")}
            >
              {gettext("Punish")}
            </button>
            <button
              type="button"
              id="player-act-kick"
              class="player-action"
              phx-click="action_open"
              phx-value-action="kick"
              disabled={is_nil(@live)}
              title={is_nil(@live) && gettext("Only a player on a server can be kicked")}
            >
              {gettext("Kick")}
            </button>
            <.more_menu id="player-more" vip?={vip?(assigns)} watched?={@watched?} />
          </div>
        </section>

        <%!-- Phone: identity card and the numbers strip. --%>
        <section
          id="player-identity"
          aria-label={gettext("Identity")}
          class="flex flex-col gap-3 rounded-box bg-base-100 p-4 md:hidden"
        >
          <div class="flex items-center gap-3.5">
            <Parts.avatar_tile name={@player_name} team={@live && @live.team} size="md" />
            <div class="flex min-w-0 flex-col gap-1">
              <.online_pill live={@live} profile={@profile} class="self-start" />
              <span :if={role_line(@live) || @level} class="text-[0.8125rem] text-subtle">
                <span :if={role_line(@live)} class={team_text(@live.team)}>{role_line(@live)}</span>
                <span :if={role_line(@live) && @level}>·</span>
                <span :if={@level}>{gettext("level %{level}", level: @level)}</span>
              </span>
              <span class="truncate font-mono text-xs text-muted">{@player_id}</span>
            </div>
          </div>
          <div class="flex flex-wrap gap-1.5">
            <.hero_marks vip_label={@vip_label} watched?={@watched?} profile={@profile} live={@live} />
          </div>
        </section>

        <section
          aria-label={gettext("Numbers")}
          class="grid grid-cols-4 rounded-[1.25rem] bg-base-100 px-1 py-3 md:hidden"
        >
          <.phone_number value={Parts.hours(playtime(assigns))} label={gettext("played")} />
          <.phone_number value={kd_recent(@recent)} label={gettext("K/D · 10 matches")} />
          <.phone_number
            value={@team_kills_30d}
            label={gettext("TKs · 30 days")}
            class={@team_kills_30d > 0 && "text-axis"}
          />
          <.phone_number value={penalties(assigns) || "–"} label={gettext("penalties")} />
        </section>

        <div class="flex items-center gap-3">
          <nav
            id="player-tabs"
            role="tablist"
            aria-label={gettext("Player sections")}
            class="player-tabs"
          >
            <.link
              patch={~p"/players/#{@player_id}"}
              role="tab"
              aria-selected={to_string(@tab == "overview")}
              class="player-tab"
            >
              <span class="hidden md:inline">{gettext("Overview")}</span>
              <span class="md:hidden">{gettext("Timeline")}</span>
            </.link>
            <.link
              patch={~p"/players/#{@player_id}?tab=executions"}
              role="tab"
              aria-selected={to_string(@tab == "executions")}
              class="player-tab"
            >
              <span class="hidden md:inline">{gettext("Rules that hit them")}</span>
              <span class="md:hidden">{gettext("Rules")}</span>
              <span :if={@stats.total > 0} class="player-tab-count">{Parts.number(@stats.total)}</span>
            </.link>
            <.link
              patch={~p"/players/#{@player_id}?tab=matches"}
              role="tab"
              aria-selected={to_string(@tab == "matches")}
              class="player-tab player-tab--wide"
            >
              {gettext("Matches")}
            </.link>
            <.link
              :if={@tickets?}
              patch={~p"/players/#{@player_id}?tab=tickets"}
              role="tab"
              aria-selected={to_string(@tab == "tickets")}
              class="player-tab"
            >
              {gettext("Tickets")}
              <span :if={@tickets != [] or @cited != []} class="player-tab-count">
                {length(@tickets) + length(@cited)}
              </span>
            </.link>
            <.link
              patch={~p"/players/#{@player_id}?tab=purchases"}
              role="tab"
              aria-selected={to_string(@tab == "purchases")}
              class="player-tab"
            >
              <span class="hidden md:inline">{gettext("VIP purchases")}</span>
              <span class="md:hidden">{gettext("Purchases")}</span>
            </.link>
          </nav>
        </div>

        <div id="player-kpis" class="hidden grid-cols-5 gap-3 md:grid">
          <.player_kpi
            label={gettext("Playtime")}
            value={Parts.hours(playtime(assigns))}
            hint={playtime_hint(assigns)}
          />
          <.player_kpi
            label={gettext("K/D last 10")}
            value={kd_recent(@recent)}
            hint={kd_hint(@recent)}
          />
          <.player_kpi
            label={gettext("Team kills")}
            value={@team_kills_30d}
            tone={if @team_kills_30d > 0, do: "axis"}
            hint={gettext("in the last 30 days")}
          />
          <.player_kpi
            label={gettext("Penalties")}
            value={penalties(assigns) || "–"}
            hint={penalty_hint(assigns)}
          />
          <.player_kpi
            label={gettext("Achievements")}
            value={length(@achievements)}
            hint={
              ngettext("%{count} gold", "%{count} gold", gold_count(@achievements),
                count: gold_count(@achievements)
              )
            }
          />
        </div>

        <div
          :if={@tab == "overview"}
          class="grid gap-5 xl:grid-cols-[minmax(0,1fr)_26.25rem]"
        >
          <section
            id="player-timeline"
            aria-label={gettext("Timeline")}
            class="player-card flex flex-col px-4 py-1.5 md:px-[1.625rem] md:py-[1.375rem]"
          >
            <div class="mb-2.5 hidden flex-wrap items-center gap-3 md:flex">
              <h2 class="flex-1 font-display text-[1.25rem] font-semibold">{gettext("Timeline")}</h2>
              <div class="flex flex-wrap gap-1.5" role="group" aria-label={gettext("Show")}>
                <button
                  :for={{filter, label} <- timeline_filters(@tickets?)}
                  type="button"
                  id={"timeline-filter-#{filter}"}
                  phx-click="timeline_filter"
                  phx-value-filter={filter}
                  aria-pressed={to_string(@timeline_filter == filter)}
                  class="player-filter"
                >
                  {label}
                </button>
              </div>
            </div>

            <p :if={timeline_entries(assigns) == []} class="py-8 text-center text-sm text-muted">
              {gettext("Nothing of this kind recorded for this player.")}
            </p>

            <ol class="flex flex-col">
              <li :for={entry <- timeline_entries(assigns)} id={"timeline-#{entry.id}"}>
                <.timeline_entry
                  entry={entry}
                  selected={@selected_execution == entry_execution_id(entry)}
                />
              </li>
            </ol>
          </section>

          <div class="hidden flex-col gap-5 md:flex">
            <section
              id="player-matches"
              aria-label={gettext("Last 10 matches")}
              class="player-card flex flex-col gap-3 px-[1.375rem] py-5"
            >
              <div class="flex items-baseline gap-2">
                <h2 class="flex-1 font-display text-[1.25rem] font-semibold">
                  {gettext("Last 10 matches")}
                </h2>
                <span class="text-xs text-muted">
                  {gettext("kills")} · <span class="text-axis">{gettext("TKs")}</span>
                </span>
              </div>
              <%= if match_bars(assigns) == [] do %>
                <p class="py-6 text-center text-sm text-muted">
                  {gettext("No finished match of this player was read yet.")}
                </p>
              <% else %>
                <div
                  class="player-matches"
                  role="img"
                  aria-label={gettext("Kills and team kills in the last matches")}
                >
                  <span
                    :for={bar <- match_bars(assigns)}
                    id={"player-#{bar.id}"}
                    class="player-match"
                    title={bar.title}
                  >
                    <span
                      class={["player-match-kills", bar.live? && "player-match-kills--live"]}
                      style={"height: #{bar.kills_height}%"}
                    ></span>
                    <span
                      :if={bar.tk_height > 0}
                      class="player-match-tk"
                      style={"height: #{bar.tk_height}%"}
                    ></span>
                  </span>
                </div>
                <span :if={@live} class="text-xs text-muted">
                  {gettext("The last bar is the match being played.")}
                </span>
              <% end %>
            </section>

            <section
              id="player-rules"
              aria-label={gettext("Rules that hit them most")}
              class="player-card flex flex-1 flex-col gap-2.5 px-[1.375rem] py-5"
            >
              <h2 class="mb-1 font-display text-[1.25rem] font-semibold">
                {gettext("Rules that hit them most")}
              </h2>
              <p :if={@rules == []} class="py-2 text-sm text-muted">
                {gettext("No rule has acted on this player.")}
              </p>
              <.link
                :for={row <- @rules}
                navigate={~p"/rules/#{row.rule_id}"}
                class="flex items-center gap-2.5 rounded-[0.875rem] bg-secondary px-3 py-2.5 leading-[1.125rem] transition-colors hover:bg-base-300/60"
              >
                <span class="min-w-0 flex-1 truncate text-sm leading-[1.125rem]">{row.rule_name}</span>
                <span class="player-rule-bar">
                  <span
                    class={["rounded-[3px]", if(row.punitive?, do: "bg-accent", else: "bg-primary")]}
                    style={"width: #{bar_width(row.count, @rules)}%"}
                  ></span>
                </span>
                <span class="w-6 shrink-0 text-right font-mono text-[0.8125rem] text-subtle">
                  {row.count}
                </span>
              </.link>
              <.link
                :if={@rules != []}
                navigate={~p"/rules/#{hd(@rules).rule_id}?tab=why&player=#{@player_id}"}
                class="mt-1 text-[0.8125rem] text-primary hover:underline"
              >
                {gettext("Why did a rule not fire for them?")}
              </.link>
            </section>
          </div>
        </div>

        <section
          :if={@tab == "executions"}
          id="player-executions"
          class="player-card p-2 sm:p-3"
        >
          <p :if={@executions == []} class="py-10 text-center text-sm text-muted">
            {gettext("No rule has acted on this player.")}
          </p>

          <table :if={@executions != []} class="table-collapse app-table">
            <thead>
              <tr>
                <th>{gettext("When")}</th>
                <th>{gettext("Rule")}</th>
                <th>{gettext("Server")}</th>
                <th>{gettext("Outcome")}</th>
                <th>{gettext("What it did")}</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-300">
              <tr :for={execution <- @executions} class="sm:hover:bg-secondary/60">
                <td data-cell="lead" class="whitespace-nowrap font-mono text-xs text-subtle">
                  <.local_time
                    id={"player-row-#{execution.id}"}
                    at={execution.executed_at}
                    format="datetime"
                  />
                </td>
                <td data-label={gettext("Rule")}>
                  <.link
                    navigate={~p"/rules/#{execution.rule_id}"}
                    class="text-sm font-semibold hover:text-primary hover:underline"
                  >
                    {execution.rule.name}
                  </.link>
                </td>
                <td data-label={gettext("Server")} class="text-sm text-subtle">
                  {execution.server.name}
                </td>
                <td data-label={gettext("Outcome")}>
                  <.pill tone={status_pill(execution.status)} class="h-6 px-2.5 text-[0.6875rem]">
                    {Labels.execution_status(execution.status)}
                  </.pill>
                </td>
                <td data-label={gettext("What it did")}>
                  <ul class="space-y-0.5">
                    <li :for={result <- execution.results} class="flex flex-wrap gap-x-1.5 text-xs">
                      <span class={result_tone(result["status"])}>{action_label(result["type"])}</span>
                      <span class="text-muted">{result["detail"]}</span>
                    </li>
                  </ul>
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <section :if={@tab == "matches"} id="player-match-list" class="player-card p-2 sm:p-3">
          <p :if={@match_list == []} class="py-10 text-center text-sm text-muted">
            {gettext("No finished match of this player was read yet.")}
          </p>
          <table :if={@match_list != []} class="table-collapse app-table">
            <thead>
              <tr>
                <th>{gettext("When")}</th>
                <th>{gettext("Map")}</th>
                <th>{gettext("Server")}</th>
                <th>{gettext("Team")}</th>
                <th class="text-right">{gettext("Kills")}</th>
                <th class="text-right">{gettext("Deaths")}</th>
                <th class="text-right">{gettext("TKs")}</th>
                <th class="text-right">{gettext("Time")}</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-300">
              <tr :for={stat <- @match_list} id={"player-match-row-#{stat.id}"}>
                <td data-cell="lead" class="whitespace-nowrap font-mono text-xs text-subtle">
                  <.local_time id={"player-match-at-#{stat.id}"} at={stat.ended_at} format="datetime" />
                </td>
                <td data-label={gettext("Map")} class="text-sm font-semibold">{stat.map}</td>
                <td data-label={gettext("Server")} class="text-sm text-subtle">
                  {stat.server && stat.server.name}
                </td>
                <td data-label={gettext("Team")} class={["text-sm", team_text(stat.team)]}>
                  {Parts.team_label(stat.team) || "–"}
                </td>
                <td data-label={gettext("Kills")} class="text-right font-mono text-[0.8125rem]">
                  {stat.kills}
                </td>
                <td data-label={gettext("Deaths")} class="text-right font-mono text-[0.8125rem]">
                  {stat.deaths}
                </td>
                <td
                  data-label={gettext("TKs")}
                  class={[
                    "text-right font-mono text-[0.8125rem]",
                    if(stat.team_kills > 0, do: "text-axis", else: "text-muted")
                  ]}
                >
                  {stat.team_kills}
                </td>
                <td data-label={gettext("Time")} class="text-right font-mono text-[0.8125rem]">
                  {gettext("%{count} min", count: div(stat.playtime_seconds, 60))}
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <section :if={@tab == "tickets"} id="player-tickets" class="player-card p-3 sm:p-4">
          <p :if={@tickets == [] and @cited == []} class="py-10 text-center text-sm text-muted">
            {gettext("This player never opened a ticket and was never cited in one.")}
          </p>
          <ul class="flex flex-col">
            <li :for={
              {ticket, how} <- Enum.map(@tickets, &{&1, :opened}) ++ Enum.map(@cited, &{&1, :cited})
            }>
              <.list_row
                id={"player-ticket-#{how}-#{ticket.id}"}
                navigate={~p"/tickets/#{ticket.id}"}
                icon="hero-chat-bubble-left-ellipsis"
                tone={if how == :cited, do: "engine", else: "info"}
                title={ticket_title(ticket, how)}
                meta={
                  [ticket.category, ticket.server && ticket.server.name]
                  |> Enum.reject(&(&1 in [nil, ""]))
                  |> Enum.join(" · ")
                }
              >
                <:aside>
                  <span class="flex shrink-0 items-center gap-3">
                    <.local_time
                      id={"player-ticket-#{how}-#{ticket.id}-at"}
                      at={ticket.inserted_at}
                      class="hidden text-xs text-muted sm:inline"
                    />
                    <.pill tone={ticket_pill(ticket.status)} class="h-6 px-2.5 text-[0.6875rem]">
                      {Labels.ticket_status(ticket.status)}
                    </.pill>
                  </span>
                </:aside>
              </.list_row>
            </li>
          </ul>
        </section>

        <section :if={@tab == "purchases"} id="player-purchases" class="player-card p-3 sm:p-4">
          <p :if={@orders == []} class="py-10 text-center text-sm text-muted">
            {gettext("No VIP bought in the shop for this player.")}
          </p>
          <ul class="flex flex-col">
            <li :for={order <- @orders} id={"player-order-#{order.id}"}>
              <div class="flex items-center gap-3.5 rounded-2xl px-2 py-2.5">
                <.icon_tile icon="hero-shopping-bag" tone="primary" />
                <span class="flex min-w-0 flex-1 flex-col gap-0.5">
                  <strong class="truncate text-sm font-semibold">{order.package_name}</strong>
                  <span class="truncate text-xs text-muted">{order_entry(order).detail}</span>
                </span>
                <.local_time
                  id={"player-order-#{order.id}-at"}
                  at={order.paid_at || order.inserted_at}
                  class="hidden text-xs text-muted sm:inline"
                />
                <.pill tone={order_pill(order.status)} class="h-6 px-2.5 text-[0.6875rem]">
                  {order_status(order.status)}
                </.pill>
              </div>
            </li>
          </ul>
        </section>
      </div>

      <%!-- Phone: the actions stay at hand at the bottom (MobilePlayer). --%>
      <div
        :if={@can_act?}
        role="group"
        aria-label={gettext("Quick actions")}
        class="player-phone-actions"
      >
        <button
          type="button"
          class="player-phone-action"
          phx-click="action_open"
          phx-value-action="message"
        >
          <.icon name="hero-chat-bubble-left" class="size-[1.1875rem]" />{gettext("Message")}
        </button>
        <button
          type="button"
          class="player-phone-action"
          phx-click="action_open"
          phx-value-action="punish"
          disabled={is_nil(@live)}
        >
          <.icon name="hero-exclamation-triangle" class="size-[1.1875rem]" />{gettext("Punish")}
        </button>
        <button
          type="button"
          class="player-phone-action"
          phx-click="action_open"
          phx-value-action="kick"
          disabled={is_nil(@live)}
        >
          <.icon name="hero-arrow-right-start-on-rectangle" class="size-[1.1875rem]" />{gettext(
            "Kick"
          )}
        </button>
        <button
          type="button"
          class="player-phone-action player-phone-action--ban"
          phx-click="action_open"
          phx-value-action="temp_ban"
          phx-value-hours="2"
        >
          <.icon name="hero-no-symbol" class="size-[1.1875rem]" />{gettext("Ban %{hours} h", hours: 2)}
        </button>
      </div>
      <div :if={@can_act?} class="h-24 md:hidden" aria-hidden="true"></div>

      <.action_dialog
        :if={@pending}
        pending={@pending}
        servers={Enum.filter(@servers, &Players.can_act?(@current_user, &1))}
        player={@player_name || @player_id}
        live={@live}
      />
    </Layouts.app>
    """
  end

  defp ticket_title(ticket, :cited) do
    gettext("Cited in ticket #%{id} by %{player}",
      id: ticket.id,
      player: ticket.player_name || ticket.player_id
    )
  end

  defp ticket_title(ticket, :opened), do: gettext("Opened ticket #%{id}", id: ticket.id)

  # ── Pieces ─────────────────────────────────────────────────────────────────

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil
  attr :tone, :string, default: nil

  defp player_kpi(assigns) do
    ~H"""
    <div class="player-card flex min-w-0 flex-col gap-1.5 rounded-[1.375rem] px-5 py-[1.125rem]">
      <span class="text-[0.8125rem] leading-[1.2] text-subtle">{@label}</span>
      <strong class={[
        "font-display text-[2rem] font-semibold leading-[1.2] tabular-nums",
        @tone == "axis" && "text-axis"
      ]}>
        {@value}
      </strong>
      <span :if={@hint} class="truncate text-xs leading-[1.25] text-muted">{@hint}</span>
    </div>
    """
  end

  attr :value, :any, required: true
  attr :label, :string, required: true
  attr :class, :any, default: nil

  defp phone_number(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-0.5 border-l border-line-soft first:border-l-0">
      <strong class={["font-display text-[1.25rem] font-semibold", @class]}>{@value}</strong>
      <span class="text-[0.6875rem] text-muted">{@label}</span>
    </div>
    """
  end

  attr :vip_label, :string, default: nil
  attr :watched?, :boolean, default: false
  attr :profile, :any, default: nil
  attr :live, :any, default: nil

  defp hero_marks(assigns) do
    ~H"""
    <span :if={@vip_label} class="players-mark players-mark--engine px-[0.5625rem]">{@vip_label}</span>
    <span :if={@watched?} class="players-mark players-mark--axis px-[0.5625rem]">
      {gettext("Watchlist")}
    </span>
    <span
      :if={is_map(@profile) and @profile.blacklisted?}
      class="players-mark players-mark--error px-[0.5625rem]"
    >
      {gettext("Blacklisted")}
    </span>
    <span
      :if={@live && @live.team_kills > 0}
      class="players-mark players-mark--error px-[0.5625rem]"
    >
      {ngettext("%{count} TK this match", "%{count} TKs this match", @live.team_kills,
        count: @live.team_kills
      )}
    </span>
    """
  end

  attr :live, :any, required: true
  attr :profile, :any, default: nil
  attr :class, :any, default: nil

  defp online_pill(%{live: %{}} = assigns) do
    ~H"""
    <.pill tone="live" class={@class}>
      {gettext("Playing on %{server}", server: Players.short_name(@live.server_name))}
    </.pill>
    """
  end

  defp online_pill(%{profile: :loading} = assigns) do
    ~H"""
    <.skeleton_block class={["h-7 w-28 rounded-full", @class]} />
    """
  end

  defp online_pill(assigns) do
    ~H"""
    <.pill tone="neutral" class={@class}>{gettext("Offline")}</.pill>
    """
  end

  attr :id, :string, required: true
  attr :vip?, :boolean, default: false
  attr :watched?, :boolean, default: false
  attr :round, :boolean, default: false

  # The ban button opens the rarer actions: a longer ban, the watchlist, VIP.
  defp more_menu(assigns) do
    ~H"""
    <div class="relative">
      <%= if @round do %>
        <button
          type="button"
          id={"#{@id}-button"}
          aria-label={gettext("More options")}
          aria-haspopup="menu"
          class="flex size-11 shrink-0 items-center justify-center rounded-full border border-base-300 bg-base-100"
          phx-click={JS.toggle(to: "##{@id}-menu")}
        >
          <.icon name="hero-ellipsis-horizontal" class="size-[1.125rem]" />
        </button>
      <% else %>
        <button
          type="button"
          id={"#{@id}-button"}
          aria-haspopup="menu"
          class="player-action player-action--ban"
          phx-click={JS.toggle(to: "##{@id}-menu")}
        >
          {gettext("Ban")} <.icon name="hero-chevron-down" class="size-3.5" />
        </button>
      <% end %>
      <div
        id={"#{@id}-menu"}
        role="menu"
        class="players-menu players-menu--end hidden"
        phx-click-away={JS.hide(to: "##{@id}-menu")}
      >
        <button
          type="button"
          role="menuitem"
          id={"#{@id}-ban"}
          class="players-menu-item players-menu-item--danger w-full"
          phx-click={
            JS.hide(to: "##{@id}-menu") |> JS.push("action_open", value: %{action: "temp_ban"})
          }
        >
          <.icon name="hero-no-symbol" class="size-4" />{gettext("Ban for a while…")}
        </button>
        <button
          type="button"
          role="menuitem"
          id={"#{@id}-perma"}
          class="players-menu-item players-menu-item--danger w-full"
          phx-click={
            JS.hide(to: "##{@id}-menu") |> JS.push("action_open", value: %{action: "perma_ban"})
          }
        >
          <.icon name="hero-lock-closed" class="size-4" />{gettext("Ban for good…")}
        </button>
        <button
          type="button"
          role="menuitem"
          id={"#{@id}-watch"}
          class="players-menu-item w-full"
          phx-click={
            JS.hide(to: "##{@id}-menu")
            |> JS.push("action_open", value: %{action: if(@watched?, do: "unwatch", else: "watch")})
          }
        >
          <.icon name="hero-eye" class="size-4" />
          {if @watched?,
            do: gettext("Remove from the watchlist"),
            else: gettext("Add to the watchlist")}
        </button>
        <button
          type="button"
          role="menuitem"
          id={"#{@id}-vip"}
          class="players-menu-item w-full"
          phx-click={
            JS.hide(to: "##{@id}-menu")
            |> JS.push("action_open", value: %{action: if(@vip?, do: "remove_vip", else: "add_vip")})
          }
        >
          <.icon name="hero-star" class="size-4" />
          {if @vip?, do: gettext("Remove VIP"), else: gettext("Give VIP…")}
        </button>
      </div>
    </div>
    """
  end

  attr :pending, :map, required: true
  attr :servers, :list, required: true
  attr :player, :string, required: true
  attr :live, :any, default: nil

  defp action_dialog(assigns) do
    assigns =
      assign(assigns, :server, Enum.find(assigns.servers, &(&1.id == assigns.pending.server_id)))

    ~H"""
    <.confirm_dialog
      id="player-action-dialog"
      tone={dialog_tone(@pending.action)}
      icon={dialog_icon(@pending.action)}
      title={dialog_title(@pending, @player)}
      subtitle={dialog_subtitle(@pending, @server, @live)}
      on_cancel={JS.push("action_cancel")}
    >
      <.form
        for={%{}}
        as={:action}
        id="player-action-form"
        phx-change="action_change"
        phx-submit="action_run"
        class="flex flex-col gap-3.5"
      >
        <label :if={length(@servers) > 1} class="flex flex-col gap-1.5">
          <span class="text-xs text-muted">{gettext("Server")}</span>
          <select name="action[server_id]" class="player-field">
            <option
              :for={server <- @servers}
              value={server.id}
              selected={server.id == @pending.server_id}
            >
              {server.name}
            </option>
          </select>
        </label>

        <div :if={@pending.action in [:temp_ban, :perma_ban]} class="flex flex-col gap-2">
          <span id="player-ban-duration" class="text-xs text-muted">{gettext("Duration")}</span>
          <div role="radiogroup" aria-labelledby="player-ban-duration" class="flex flex-wrap gap-1.5">
            <button
              :for={hours <- ban_hours()}
              type="button"
              role="radio"
              id={"player-ban-#{hours}"}
              aria-checked={to_string(@pending.action == :temp_ban and @pending.hours == hours)}
              class="player-duration"
              phx-click="action_duration"
              phx-value-value={hours}
            >
              {gettext("%{count} h", count: hours)}
            </button>
            <button
              type="button"
              role="radio"
              id="player-ban-permanent"
              aria-checked={to_string(@pending.action == :perma_ban)}
              class="player-duration"
              phx-click="action_duration"
              phx-value-value="permanent"
            >
              {gettext("Permanent")}
            </button>
          </div>
        </div>

        <div :if={@pending.action == :add_vip} class="flex flex-col gap-2">
          <span id="player-vip-duration" class="text-xs text-muted">{gettext("Duration")}</span>
          <div role="radiogroup" aria-labelledby="player-vip-duration" class="flex flex-wrap gap-1.5">
            <button
              :for={days <- vip_days()}
              type="button"
              role="radio"
              id={"player-vip-#{days}"}
              aria-checked={to_string(@pending.days == days)}
              class="player-duration"
              phx-click="action_duration"
              phx-value-value={days}
            >
              {ngettext("%{count} day", "%{count} days", days, count: days)}
            </button>
            <button
              type="button"
              role="radio"
              id="player-vip-forever"
              aria-checked={to_string(is_nil(@pending.days))}
              class="player-duration"
              phx-click="action_duration"
              phx-value-value="forever"
            >
              {gettext("No end")}
            </button>
          </div>
        </div>

        <label :if={Actions.needs_reason?(@pending.action)} class="flex flex-col gap-1.5">
          <span class="text-xs text-muted">{reason_label(@pending.action)}</span>
          <textarea
            id="player-action-reason"
            name="action[reason]"
            rows="2"
            maxlength="200"
            class="player-field"
            phx-debounce="200"
          >{@pending.reason}</textarea>
        </label>

        <label :if={@pending.action in [:temp_ban, :perma_ban]} class="flex flex-col gap-1.5">
          <span class="text-xs text-muted">
            {gettext("To confirm, type")}
            <strong class="font-mono font-medium text-base-content">{@player}</strong>
          </span>
          <input
            id="player-action-typed"
            name="action[typed]"
            value={@pending.typed}
            autocomplete="off"
            aria-label={gettext("Player name to confirm")}
            class="player-field h-11 font-mono"
            phx-debounce="150"
          />
        </label>
      </.form>
      <:note>{gettext("It stays in their CRCON history.")}</:note>
      <:confirm>
        <button
          type="submit"
          form="player-action-form"
          id="player-action-confirm"
          class={[
            "chip-button h-12 px-[1.375rem] text-sm",
            if(@pending.action in [:temp_ban, :perma_ban, :kick, :punish],
              do: "chip-button--danger",
              else: "chip-button--signal"
            )
          ]}
          phx-disable-with={gettext("Sending...")}
        >
          {confirm_label(@pending)}
        </button>
      </:confirm>
    </.confirm_dialog>
    """
  end

  defp ban_hours, do: @ban_hours
  defp vip_days, do: @vip_days

  defp dialog_tone(action) when action in [:temp_ban, :perma_ban, :kick, :watch], do: "axis"
  defp dialog_tone(:punish), do: "warning"
  defp dialog_tone(action) when action in [:add_vip, :remove_vip], do: "engine"
  defp dialog_tone(_action), do: "neutral"

  defp dialog_icon(action) when action in [:temp_ban, :perma_ban], do: "hero-no-symbol"
  defp dialog_icon(:kick), do: "hero-arrow-right-start-on-rectangle"
  defp dialog_icon(:punish), do: "hero-exclamation-triangle"
  defp dialog_icon(action) when action in [:watch, :unwatch], do: "hero-eye"
  defp dialog_icon(action) when action in [:add_vip, :remove_vip], do: "hero-star"
  defp dialog_icon(_message), do: "hero-chat-bubble-left"

  defp dialog_title(%{action: :temp_ban, hours: hours}, player),
    do:
      ngettext("Ban %{player} for %{count} hour?", "Ban %{player} for %{count} hours?", hours,
        player: player,
        count: hours
      )

  defp dialog_title(%{action: :perma_ban}, player),
    do: gettext("Ban %{player} for good?", player: player)

  defp dialog_title(%{action: :kick}, player), do: gettext("Kick %{player}?", player: player)
  defp dialog_title(%{action: :punish}, player), do: gettext("Punish %{player}?", player: player)

  defp dialog_title(%{action: :message}, player),
    do: gettext("Message %{player}", player: player)

  defp dialog_title(%{action: :watch}, player),
    do: gettext("Add %{player} to the watchlist?", player: player)

  defp dialog_title(%{action: :unwatch}, player),
    do: gettext("Remove %{player} from the watchlist?", player: player)

  defp dialog_title(%{action: :add_vip}, player),
    do: gettext("Give VIP to %{player}?", player: player)

  defp dialog_title(%{action: :remove_vip}, player),
    do: gettext("Remove the VIP of %{player}?", player: player)

  defp dialog_subtitle(_pending, nil, _live), do: nil

  defp dialog_subtitle(%{action: action}, server, %{server_id: id})
       when action in [:temp_ban, :perma_ban, :kick] do
    if id == server.id,
      do: gettext("They leave %{server} now.", server: server.name),
      else: gettext("On %{server}.", server: server.name)
  end

  defp dialog_subtitle(%{action: action}, server, _live) when action in [:temp_ban, :perma_ban],
    do: gettext("On %{server}, even while they are away.", server: server.name)

  defp dialog_subtitle(%{action: action}, server, _live) when action in [:watch, :unwatch],
    do: gettext("CRCON warns the admins of %{server} when they join.", server: server.name)

  defp dialog_subtitle(_pending, server, _live), do: gettext("On %{server}.", server: server.name)

  defp reason_label(:message), do: gettext("Message")
  defp reason_label(:watch), do: gettext("Why watch them")
  defp reason_label(:add_vip), do: gettext("Description in CRCON")
  defp reason_label(_action), do: gettext("Reason · the player reads this message")

  defp confirm_label(%{action: :temp_ban, hours: hours}),
    do: ngettext("Ban for %{count} hour", "Ban for %{count} hours", hours, count: hours)

  defp confirm_label(%{action: :perma_ban}), do: gettext("Ban for good")
  defp confirm_label(%{action: :kick}), do: gettext("Kick")
  defp confirm_label(%{action: :punish}), do: gettext("Punish")
  defp confirm_label(%{action: :message}), do: gettext("Send")
  defp confirm_label(%{action: :watch}), do: gettext("Add to the watchlist")
  defp confirm_label(%{action: :unwatch}), do: gettext("Remove from the watchlist")
  defp confirm_label(%{action: :add_vip}), do: gettext("Give VIP")
  defp confirm_label(%{action: :remove_vip}), do: gettext("Remove VIP")

  attr :entry, :map, required: true
  attr :selected, :boolean, default: false

  defp timeline_entry(assigns) do
    ~H"""
    <div class="player-timeline-row">
      <Parts.seen
        id={"#{@entry.id}-at"}
        at={@entry.at}
        variant="timeline"
        class="player-timeline-when"
      />
      <span class={[
        "flex size-7 items-center justify-center rounded-[0.625rem] max-md:size-[1.875rem]",
        tile(@entry.tone)
      ]}>
        <.icon name={@entry.icon} class="size-3.5" />
      </span>
      <div class="flex min-w-0 flex-col gap-0.5">
        <.entry_title entry={@entry} selected={@selected} />
        <span class="truncate text-xs text-muted">
          <Parts.seen
            id={"#{@entry.id}-at-phone"}
            at={@entry.at}
            variant="short"
            class="player-timeline-phone-when font-mono text-[0.6875rem]"
          /><span
            :if={@entry.detail || @entry[:server]}
            class="player-timeline-phone-when"
          > · </span>{@entry.detail}<span :if={@entry.detail && @entry[:server]}> · </span><span
            :if={@entry[:server]}
            class="max-md:hidden"
          >{@entry.server}</span><span
            :if={@entry[:server]}
            class="md:hidden"
          >{Players.short_name(@entry.server)}</span>
        </span>
        <ul
          :if={@entry.kind == :execution and @selected}
          id={"#{@entry.id}-results"}
          class="mt-2 space-y-1 rounded-xl bg-secondary p-3"
        >
          <li :if={@entry.execution.results == []} class="text-xs text-muted">
            {gettext("No action was recorded for this run.")}
          </li>
          <li :for={result <- @entry.execution.results} class="flex flex-wrap gap-x-1.5 text-xs">
            <span class={result_tone(result["status"])}>{action_label(result["type"])}</span>
            <span class="text-muted">{result["detail"]}</span>
          </li>
          <li :if={@entry.execution.error} class="text-xs text-error">{@entry.execution.error}</li>
        </ul>
      </div>
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :selected, :boolean, default: false

  defp entry_title(%{entry: %{kind: :execution}} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_execution"
      phx-value-id={@entry.execution.id}
      aria-expanded={to_string(@selected)}
      class="cursor-pointer text-left text-sm hover:opacity-80"
    >
      {@entry.execution.rule.name}
      <span class={verb_class(@entry.execution.status)}>{verb(@entry.execution.status)}</span>
      <span :if={@entry.step}>{gettext("step %{step}", step: @entry.step)}</span>
      <span :if={@entry.action}>· {@entry.action}</span>
      <span
        :if={@entry.runs > 1}
        id={"#{@entry.id}-runs"}
        class="player-timeline-runs"
        title={
          ngettext("%{count} run in a row", "%{count} runs in a row", @entry.runs, count: @entry.runs)
        }
      >
        ×{@entry.runs}
      </span>
    </button>
    """
  end

  defp entry_title(%{entry: %{kind: :penalty}} = assigns) do
    ~H"""
    <span class="text-sm">{penalty_text(@entry.penalty.type, @entry.penalty.by)}</span>
    """
  end

  defp entry_title(%{entry: %{kind: kind}} = assigns) when kind in [:opened, :cited] do
    ~H"""
    <.link navigate={~p"/tickets/#{@entry.ticket.id}"} class="text-sm hover:text-primary">
      {ticket_title(@entry.ticket, @entry.kind)}
    </.link>
    """
  end

  defp entry_title(%{entry: %{kind: :achievement}} = assigns) do
    ~H"""
    <span class="text-sm">
      {gettext("Unlocked")}
      <strong class="font-semibold">{@entry.unlock.achievement.name}</strong>
      · {String.downcase(Labels.tier(@entry.unlock.achievement.tier))}
    </span>
    """
  end

  defp entry_title(%{entry: %{kind: :order}} = assigns) do
    ~H"""
    <span class="text-sm">
      {gettext("Bought")}
      <strong class="font-semibold">{@entry.order.package_name}</strong>
      {gettext("in the shop")}
    </span>
    """
  end

  defp entry_title(assigns) do
    ~H"""
    <span class="text-sm">{gettext("First session recorded")}</span>
    """
  end
end
