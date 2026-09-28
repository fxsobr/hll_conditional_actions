defmodule HllConditionalActionsWeb.MatchLive.Show do
  @moduledoc """
  The report of one past match: the result, who stood out, the best squads,
  what the rules did while it was played, and the full scoreboard.

  The players come from CRCON (`get_map_scoreboard`); the rule activity is
  this app's own history, cut to the match's start and end. Together they
  answer "what happened last night" on one page.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_stats}}

  import HllConditionalActionsWeb.MatchLive.Index,
    only: [mode_label: 1, date: 1, duration: 1]

  alias HllConditionalActions.Leaderboards
  alias HllConditionalActions.Matches
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.MapArt

  @board_size 5

  @impl Phoenix.LiveView
  def mount(%{"server_id" => server_id, "id" => id}, _session, socket) do
    server =
      Enum.find(
        Servers.list_servers_for(socket.assigns.current_user),
        &(to_string(&1.id) == server_id)
      )

    if server do
      {:ok,
       socket
       |> assign(page_title: gettext("Match report"), server: server, match: nil, error?: false)
       |> assign(:board_size, @board_size)
       |> start_async(:match, fn -> Matches.get(server, id) end)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl Phoenix.LiveView
  def handle_async(:match, {:ok, {:ok, match}}, socket) do
    executions =
      if match.started_at && match.ended_at do
        Rules.list_executions_for(socket.assigns.current_user,
          server_id: socket.assigns.server.id,
          from: match.started_at,
          until: match.ended_at,
          limit: 200
        )
        |> Enum.reverse()
      else
        []
      end

    {:noreply,
     socket
     |> assign(:page_title, match.map)
     |> assign(:match, match)
     |> assign(:executions, executions)}
  end

  def handle_async(:match, _failed, socket), do: {:noreply, assign(socket, :error?, true)}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      page_subtitle={subtitle(@match, @server)}
    >
      <:actions>
        <.button
          link_type="live_redirect"
          to={~p"/servers/#{@server}/matches"}
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-arrow-left"
        >
          <span class="hidden sm:inline">{gettext("All matches")}</span>
        </.button>
      </:actions>

      <.empty_state
        :if={@error?}
        icon="hero-signal-slash"
        title={gettext("This match could not be loaded")}
        description={gettext("CRCON did not answer, or it no longer has this match.")}
      />

      <div :if={is_nil(@match) && not @error?} class="space-y-4">
        <.skeleton_block class="h-28 rounded-box" />
        <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <.skeleton_block :for={_ <- 1..4} class="h-32 rounded-box" />
        </div>
      </div>

      <div :if={@match} id="match-report" class="space-y-4">
        <section
          class="cockpit-hero"
          style={"--hero-art: url('#{MapArt.url(@server.game, @match.layer || @match.map)}')"}
        >
          <div class="cockpit-hero-scrim"></div>
          <div class="relative flex flex-wrap items-center justify-between gap-4 text-white">
            <div class="min-w-0">
              <p class="text-xs font-medium tracking-wide text-white/70 uppercase">
                {mode_label(@match.mode)}
              </p>
              <h2 class="text-3xl font-semibold tracking-tight">{@match.map}</h2>
              <p class="mt-1 text-sm text-white/75">
                {date(@match.started_at)} · {duration(@match.duration_seconds)}
              </p>
            </div>
            <div class="flex flex-col items-center gap-1">
              <p class="font-mono text-5xl font-bold tabular-nums">
                {@match.allied || 0}<span class="px-2 text-white/40">:</span>{@match.axis || 0}
              </p>
              <span :if={@match.winner} class="text-sm text-white/80">
                {winner_label(@match.winner)}
              </span>
            </div>
          </div>
        </section>

        <div id="match-kpis" class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <.stat icon="hero-users" label={gettext("Players")} value={map_size(@match.roster)} />
          <.stat
            icon="hero-fire"
            tone="error"
            label={gettext("Kills")}
            value={total(@match.roster, "kills")}
            hint={gettext("across both teams")}
          />
          <.stat
            icon="hero-star"
            tone="warning"
            label={gettext("MVP")}
            value={mvp(@match.roster)}
            hint={gettext("best teamplay (combat + support)")}
          />
          <.stat
            icon="hero-bolt"
            tone="primary"
            label={gettext("Rules fired")}
            value={length(@executions)}
            hint={gettext("while this match was played")}
          />
        </div>

        <.card title={gettext("Top players")} icon="hero-trophy">
          <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            <.rank_board
              :for={category <- Leaderboards.categories()}
              id={"match-board-#{category}"}
              title={Labels.leaderboard_category(category)}
              rows={
                for row <- Leaderboards.top_players(@match.roster, category, @board_size),
                    do: %{name: row.name, team: row.team, value: format(row.value), note: nil}
              }
            />
          </div>
        </.card>

        <.card title={gettext("Top squads")} icon="hero-user-group">
          <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
            <.rank_board
              :for={type <- Leaderboards.squad_types()}
              id={"match-squads-#{type}"}
              title={Labels.squad_type(type)}
              rows={
                for squad <- Leaderboards.top_squads(@match.roster, type, @board_size),
                    do: %{
                      name: String.capitalize(squad.name),
                      team: squad.team,
                      value: format(squad.score),
                      note: ngettext("1 player", "%{count} players", squad.size)
                    }
              }
            />
          </div>
        </.card>

        <div class="grid gap-4 xl:grid-cols-3">
          <.card title={gettext("What the rules did")} icon="hero-bolt" id="match-rules">
            <p :if={@executions == []} class="py-4 text-center text-sm text-muted">
              {gettext("No rule fired during this match.")}
            </p>
            <ol
              :if={@executions != []}
              class="-my-1 max-h-[32rem] divide-y divide-base-300 overflow-y-auto"
            >
              <li :for={execution <- @executions} class="flex items-start gap-2.5 py-2">
                <span class="mt-0.5 w-12 shrink-0 font-mono text-xs text-muted tabular-nums">
                  {minute(@match.started_at, execution.executed_at)}
                </span>
                <div class="min-w-0 flex-1">
                  <p class="truncate text-sm font-medium">{execution.rule.name}</p>
                  <p class="truncate text-xs text-muted">
                    {execution.player_name || gettext("server wide")}
                  </p>
                </div>
                <.tone_badge tone={execution_tone(execution.status)} size="xs">
                  {Labels.execution_status(execution.status)}
                </.tone_badge>
              </li>
            </ol>
          </.card>

          <div class="min-w-0 xl:col-span-2">
            <.card
              title={gettext("Scoreboard")}
              icon="hero-table-cells"
              padded={false}
              id="match-scoreboard"
            >
              <div class="max-h-[34rem] overflow-auto">
                <table class="w-full min-w-[40rem] text-sm">
                  <thead class="sticky top-0 bg-base-100 text-left text-xs tracking-wide text-muted uppercase">
                    <tr class="border-b border-base-300">
                      <th class="px-4 py-2 font-medium sm:px-5">{gettext("Player")}</th>
                      <th :for={{_key, label} <- columns()} class="px-2 py-2 text-right font-medium">
                        {label}
                      </th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-base-300">
                    <tr :for={player <- scoreboard(@match.roster)} class="hover:bg-base-200/50">
                      <td class="px-4 py-2 sm:px-5">
                        <.link
                          navigate={~p"/players/#{player["player_id"]}"}
                          class="flex items-center gap-2 hover:underline"
                        >
                          <span class={["size-1.5 shrink-0 rounded-full", team_dot(player["team"])]}></span>
                          <span class="truncate">{player["name"]}</span>
                        </.link>
                      </td>
                      <td
                        :for={{key, _label} <- columns()}
                        class="px-2 py-2 text-right font-mono text-xs tabular-nums"
                      >
                        {cell(player, key)}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </.card>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp subtitle(nil, server), do: server.name
  defp subtitle(match, server), do: "#{server.name} · #{date(match.started_at)}"

  defp winner_label(:allies), do: gettext("Allies won")
  defp winner_label(:axis), do: gettext("Axis won")
  defp winner_label(:draw), do: gettext("Draw")

  defp columns do
    [
      {"kills", gettext("Kills")},
      {"deaths", gettext("Deaths")},
      {:kd, gettext("K/D")},
      {"combat", gettext("Combat")},
      {"offense", gettext("Offense")},
      {"defense", gettext("Defense")},
      {"support", gettext("Support")}
    ]
  end

  defp scoreboard(roster) do
    roster |> Map.values() |> Enum.sort_by(&(&1["kills"] || 0), :desc)
  end

  defp cell(player, :kd) do
    kills = player["kills"] || 0
    :erlang.float_to_binary(kills / max(player["deaths"] || 0, 1), decimals: 2)
  end

  defp cell(player, key), do: player[key] || 0

  defp total(roster, key), do: roster |> Map.values() |> Enum.sum_by(&(&1[key] || 0))

  defp mvp(roster) do
    case Leaderboards.top_players(roster, :teamplay, 1) do
      [best] -> best.name
      [] -> "–"
    end
  end

  # "12'" - minutes into the match, the way a match report counts time.
  defp minute(nil, _at), do: ""
  defp minute(started_at, at), do: "#{max(div(DateTime.diff(at, started_at), 60), 0)}'"

  defp execution_tone(:executed), do: "success"
  defp execution_tone(:partial), do: "warning"
  defp execution_tone(:failed), do: "error"
  defp execution_tone(:simulated), do: "info"
  defp execution_tone(_status), do: "neutral"

  defp team_dot("allies"), do: "bg-info"
  defp team_dot("axis"), do: "bg-error"
  defp team_dot(_team), do: "bg-base-300"

  defp format(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format(value), do: to_string(value)
end
