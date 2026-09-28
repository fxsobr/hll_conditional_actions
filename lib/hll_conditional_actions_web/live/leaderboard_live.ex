defmodule HllConditionalActionsWeb.LeaderboardLive do
  @moduledoc """
  The live leaderboard of one server: the top players of every category and
  the best squads of every type, as the current match stands.

  It reads the same `get_detailed_players` snapshot the rules are judged on,
  through `HllConditionalActions.Leaderboards`, so what an admin sees here is
  exactly what `{top_kills}` or a "position in kills" condition would see.
  The snapshot is fetched off the LiveView process and refreshed on a timer;
  a slow CRCON leaves the last table on screen instead of a spinner.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_stats}}

  alias HllConditionalActions.Engine.Snapshot
  alias HllConditionalActions.Leaderboards
  alias HllConditionalActions.Servers

  @refresh_ms :timer.seconds(20)
  @size 5

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    {:ok,
     socket
     |> assign(:page_title, gettext("Leaderboard"))
     |> assign(:servers, Servers.list_servers_for(socket.assigns.current_user))
     |> assign(:server, nil)
     |> assign(:roster, nil)
     |> assign(:loaded_at, nil)
     |> assign(:size, @size)
     |> assign(:error?, false)}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"server_id" => id}, _url, socket) do
    server = Enum.find(socket.assigns.servers, &(to_string(&1.id) == id))

    socket =
      if server && server != socket.assigns.server,
        do: socket |> assign(server: server, roster: nil, loaded_at: nil) |> load(),
        else: assign(socket, :server, server)

    {:noreply, socket}
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
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_async(:snapshot, {:ok, {server_id, snapshot}}, socket) do
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
         assign(socket, roster: snapshot.players, loaded_at: DateTime.utc_now(), error?: false)}
    end
  end

  def handle_async(:snapshot, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :error?, is_nil(socket.assigns.roster))}
  end

  defp load(%{assigns: %{server: nil}} = socket), do: socket

  defp load(socket) do
    server = socket.assigns.server

    start_async(socket, :snapshot, fn ->
      {server.id, Snapshot.refresh(server)}
    end)
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      page_subtitle={gettext("Who is on top in the current match, refreshed every 20 seconds")}
    >
      <.empty_state
        :if={@servers == []}
        icon="hero-trophy"
        title={gettext("No server to rank")}
        description={gettext("Connect a server and its live leaderboard shows up here.")}
      />

      <.empty_state
        :if={@server && @error?}
        icon="hero-signal-slash"
        title={gettext("CRCON did not answer")}
        description={gettext("The leaderboard comes back as soon as the server does.")}
      />

      <div
        :if={@server && is_nil(@roster) && not @error?}
        class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4"
      >
        <.skeleton_block :for={_ <- 1..4} class="h-32 rounded-box" />
      </div>

      <.empty_state
        :if={@roster == %{} and not @error?}
        icon="hero-moon"
        title={gettext("Nobody is playing right now")}
        description={gettext("The leaderboard fills in as soon as a match has players.")}
      />

      <div :if={@roster not in [nil, %{}]} id="leaderboard" class="space-y-4">
        <div id="leaderboard-kpis" class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <.stat
            icon="hero-users"
            label={gettext("Players")}
            value={map_size(@roster)}
            hint={
              if @loaded_at,
                do: gettext("updated at %{time} UTC", time: Calendar.strftime(@loaded_at, "%H:%M:%S"))
            }
          />
          <.leader_stat roster={@roster} category={:kills} icon="hero-fire" tone="error" />
          <.leader_stat roster={@roster} category={:teamplay} icon="hero-heart" tone="success" />
          <.stat
            icon="hero-user-group"
            tone="primary"
            label={gettext("Best squad")}
            value={best_squad(@roster)}
            hint={gettext("highest combined score")}
          />
        </div>

        <.card title={gettext("Top players")} icon="hero-trophy">
          <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            <.rank_board
              :for={category <- Leaderboards.categories()}
              id={"board-#{category}"}
              title={Labels.leaderboard_category(category)}
              placeholder={"{top_#{category}}"}
              rows={
                for row <- Leaderboards.top_players(@roster, category, @size),
                    do: %{name: row.name, team: row.team, value: format(row.value), note: nil}
              }
            />
          </div>
        </.card>

        <.card title={gettext("Top squads")} icon="hero-user-group">
          <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
            <.rank_board
              :for={type <- Leaderboards.squad_types()}
              id={"board-squads-#{type}"}
              title={Labels.squad_type(type)}
              placeholder={"{top_#{type}_squads}"}
              rows={
                for squad <- Leaderboards.top_squads(@roster, type, @size),
                    do: %{
                      name: String.capitalize(squad.name),
                      team: squad.team,
                      value: format(squad.score),
                      note: squad_note(squad)
                    }
              }
            />
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  attr :roster, :map, required: true
  attr :category, :atom, required: true
  attr :icon, :string, required: true
  attr :tone, :string, required: true

  defp leader_stat(assigns) do
    assigns =
      assign(
        assigns,
        :leader,
        List.first(Leaderboards.top_players(assigns.roster, assigns.category, 1))
      )

    ~H"""
    <.stat
      icon={@icon}
      tone={@tone}
      label={gettext("Top · %{category}", category: Labels.leaderboard_category(@category))}
      value={if @leader, do: @leader.name, else: "–"}
      hint={if @leader, do: format(@leader.value)}
    />
    """
  end

  defp best_squad(roster) do
    roster
    |> Leaderboards.squads()
    |> Map.values()
    |> List.flatten()
    |> Enum.max_by(& &1.score, fn -> nil end)
    |> case do
      nil -> "–"
      squad -> String.capitalize(squad.name)
    end
  end

  defp squad_note(squad) do
    if squad.has_leader,
      do: ngettext("1 player", "%{count} players", squad.size),
      else: gettext("no leader")
  end

  defp format(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format(value), do: to_string(value)
end
