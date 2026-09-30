defmodule HllConditionalActionsWeb.MatchLive.Show do
  @moduledoc """
  The report of one past match: the result, the MVP, the best of each
  category, the best squads, what the rules did while it was played, and
  the full scoreboard - with a CSV of the scoreboard and a button that posts
  the report to the Discord channel the match rule posts to.

  The players come from CRCON (`get_map_scoreboard`); the rule activity is
  this app's own history, cut to the match's start and end. Together they
  answer "what happened last night" on one page.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_stats}}

  import HllConditionalActionsWeb.CommunityComponents

  import HllConditionalActionsWeb.MatchLive.Index,
    only: [mode_label: 1, result_text: 1]

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Matches
  alias HllConditionalActions.MatchHistory
  alias HllConditionalActions.MatchReport
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Workers.DeliverWebhook
  alias HllConditionalActionsWeb.MapArt

  @rows 12

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
       |> assign(report: nil, team: "all", search: "", all?: false)
       |> assign(:discord, MatchHistory.discord_rule([server.id]))
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
          until: DateTime.add(match.ended_at, 300),
          limit: 1000
        )
      else
        []
      end

    {:noreply,
     socket
     |> assign(:match, match)
     |> assign(:report, MatchReport.build(match, executions))}
  end

  def handle_async(:match, _failed, socket), do: {:noreply, assign(socket, :error?, true)}

  @impl Phoenix.LiveView
  def handle_event("team", %{"value" => team}, socket) when team in ~w(all allies axis),
    do: {:noreply, assign(socket, :team, team)}

  def handle_event("search", %{"q" => q}, socket), do: {:noreply, assign(socket, :search, q)}

  def handle_event("show_all", _params, socket), do: {:noreply, assign(socket, :all?, true)}

  def handle_event("export", _params, %{assigns: %{match: match}} = socket) when match != nil do
    rows =
      for {player, rank} <- Enum.with_index(ranked_players(match.roster), 1) do
        [
          rank,
          player["name"],
          player["player_id"],
          team_label(player["team"]),
          player["kills"],
          player["deaths"],
          decimal(kd(player), 2),
          player["combat"],
          player["offense"],
          player["defense"],
          player["support"],
          player["team_kills"]
        ]
      end

    csv =
      to_csv(
        [
          "#",
          gettext("Player"),
          gettext("Player ID"),
          gettext("Team"),
          gettext("Kills"),
          gettext("Deaths"),
          gettext("K/D"),
          gettext("Combat"),
          gettext("Offense"),
          gettext("Defense"),
          gettext("Support"),
          gettext("Team kills")
        ],
        rows
      )

    {:noreply,
     push_event(socket, "download_csv", %{filename: "match-#{match.id}.csv", content: csv})}
  end

  def handle_event("post_discord", _params, socket) do
    %{match: match, report: report, discord: discord, server: server} = socket.assigns

    with true <- Accounts.can?(socket.assigns.current_user, :manage_rules),
         %{webhook: %{id: webhook_id}} <- discord,
         %{} <- report do
      text =
        MatchReport.discord_text(match, report, server.name, %{
          allies: gettext("Allies"),
          axis: gettext("Axis"),
          mvp: gettext("MVP"),
          kills: gettext("Kills"),
          combat: gettext("Combat"),
          support: gettext("Support")
        })

      case DeliverWebhook.enqueue(webhook_id, %{"content" => text}) do
        {:ok, _job} ->
          {:noreply, put_flash(socket, :info, gettext("The report is on its way to Discord."))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("The report could not be sent."))}
      end
    else
      _cannot -> {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assign(assigns,
        crumb:
          [
            gettext("Community / Matches"),
            assigns.server.name,
            assigns.match && "##{assigns.match.id}"
          ]
          |> Enum.filter(& &1)
          |> Enum.join(" · ")
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      crumb={@crumb}
      back={~p"/servers/#{@server}/matches"}
      back_label={gettext("Back to Matches")}
      global_search={false}
      scope={false}
      bell={false}
    >
      <:actions>
        <.pill_button
          id="match-export"
          type="button"
          icon="hero-arrow-down-tray"
          phx-click="export"
          disabled={is_nil(@match)}
          class="max-md:hidden"
        >
          {gettext("Export CSV")}
        </.pill_button>
        <.pill_button
          :if={@discord && @discord.webhook && Accounts.can?(@current_user, :manage_rules)}
          id="match-discord"
          type="button"
          primary
          icon="hero-paper-airplane"
          phx-click="post_discord"
          disabled={is_nil(@report)}
          data-confirm={gettext("Post this report to %{channel}?", channel: @discord.webhook.name)}
        >
          {gettext("Post on Discord")}
        </.pill_button>
      </:actions>

      <.csv_download id="match-csv" />

      <.error_state
        :if={@error?}
        id="match-error"
        title={gettext("This match could not be loaded")}
        icon="hero-signal-slash"
      >
        {gettext("CRCON did not answer, or it no longer has this match.")}
      </.error_state>

      <div :if={is_nil(@match) && not @error?} class="space-y-5">
        <.skeleton_block class="h-[17.5rem] rounded-[1.75rem]" />
        <div class="grid gap-5 xl:grid-cols-[23.75rem_minmax(0,1fr)]">
          <.skeleton_block class="h-80 rounded-[1.75rem]" />
          <.skeleton_block class="h-80 rounded-[1.75rem]" />
        </div>
      </div>

      <div :if={@match && @report} id="match-report" class="flex flex-col gap-5">
        <.hero match={@match} report={@report} server={@server} />

        <div class="grid gap-5 xl:grid-cols-[23.75rem_minmax(0,1fr)]">
          <.mvp_card :if={@report.mvp} report={@report} server={@server} />
          <.best_categories report={@report} />
        </div>

        <div class="grid gap-5 xl:grid-cols-2">
          <.best_squads squads={@report.squads} />
          <.rules_fired report={@report} server={@server} />
        </div>

        <.scoreboard
          match={@match}
          report={@report}
          team={@team}
          search={@search}
          all?={@all?}
        />
      </div>
    </Layouts.app>
    """
  end

  # ── Hero ───────────────────────────────────────────────────────────────────

  attr :match, :map, required: true
  attr :report, :map, required: true
  attr :server, :map, required: true

  defp hero(assigns) do
    assigns =
      assign(assigns,
        started: local(assigns.match.started_at, assigns.server),
        ended: local(assigns.match.ended_at, assigns.server)
      )

    ~H"""
    <section
      id="match-hero"
      aria-label={gettext("Result")}
      class="match-report-hero relative overflow-hidden rounded-[1.75rem]"
    >
      <img
        src={MapArt.url(@server.game, @match.layer || @match.map)}
        alt=""
        class="absolute inset-0 size-full object-cover"
      />
      <div class="match-hero-scrim absolute inset-0"></div>
      <div class="relative grid gap-6 p-5 sm:p-7 lg:min-h-[17.5rem] lg:grid-cols-[1fr_1.2fr_1fr] lg:gap-8 lg:px-[2.125rem]">
        <div class="flex flex-col gap-2.5">
          <span class="flex h-7 items-center gap-1.5 self-start rounded-full bg-[#181916]/80 px-3 text-xs font-semibold text-[#cfcfc6]">
            <.icon name="hero-check" class="size-3 stroke-[2.4]" />
            <span>
              {gettext("Finished")}{if @ended, do: " · " <> long_date(DateTime.to_date(@ended))}
            </span>
          </span>
          <h2 class="mt-2 font-display text-5xl font-bold leading-[0.95] tracking-[-0.035em] lg:text-6xl">
            {@match.map}
          </h2>
          <span class="text-[0.9375rem] text-[#cfcfc6]">
            {mode_label(@match.mode)} ·
            <span class="font-mono text-sm">{clock(@started)} → {clock(@ended)}</span>
            · {duration(@match.duration_seconds)}
          </span>
          <span class="flex-1"></span>
          <span class="text-[0.8125rem] text-[#cfcfc6]">
            {ngettext(
              "1 player went through the match",
              "%{count} players went through the match",
              @report.players
            )}
          </span>
        </div>

        <div class="flex flex-col items-center justify-center gap-3.5">
          <div class="flex items-center gap-7">
            <div class="flex flex-col items-center">
              <span class="text-[0.8125rem] font-semibold tracking-[0.06em] text-allies uppercase">
                {gettext("Allies")}
              </span>
              <span class={[
                "font-display text-7xl font-bold leading-none text-allies lg:text-[5.75rem]",
                @match.winner == :axis && "opacity-75"
              ]}>
                {@match.allied || "–"}
              </span>
            </div>
            <span class="font-display text-4xl text-[#6d6f66]">:</span>
            <div class="flex flex-col items-center">
              <span class="text-[0.8125rem] font-semibold tracking-[0.06em] text-axis uppercase">
                {gettext("Axis")}
              </span>
              <span class={[
                "font-display text-7xl font-bold leading-none text-axis lg:text-[5.75rem]",
                @match.winner == :allies && "opacity-75"
              ]}>
                {@match.axis || "–"}
              </span>
            </div>
          </div>
          <.sector_bar
            :if={
              is_integer(@match.allied) and is_integer(@match.axis) and
                @match.allied + @match.axis == 5
            }
            allied={@match.allied}
            size="lg"
            class="w-full max-w-[23.75rem]"
          />
          <span
            :if={hero_result(@match)}
            class={[
              "flex h-[1.875rem] items-center rounded-full px-3.5 text-[0.8125rem] font-semibold",
              if(@match.winner == :allies,
                do: "bg-allies/18 text-allies",
                else: "bg-axis/18 text-axis"
              )
            ]}
          >
            {hero_result(@match)}
          </span>
        </div>

        <div class="grid grid-cols-2 gap-2.5">
          <div class="match-hero-tile flex flex-col justify-center rounded-[1.125rem] px-4 py-3.5">
            <span class="text-xs text-[#b3b4ab]">{gettext("Kills")}</span>
            <span class="font-display text-[1.625rem] font-semibold">{number(@report.kills)}</span>
          </div>
          <div class="match-hero-tile flex flex-col justify-center rounded-[1.125rem] px-4 py-3.5">
            <span class="text-xs text-[#b3b4ab]">{gettext("Vehicles destroyed")}</span>
            <span class="font-display text-[1.625rem] font-semibold">{number(@report.vehicles)}</span>
          </div>
          <div class="match-hero-tile flex flex-col justify-center rounded-[1.125rem] px-4 py-3.5">
            <span class="text-xs text-[#b3b4ab]">{gettext("Rules fired")}</span>
            <span class="font-display text-[1.625rem] font-semibold text-[#d2f36b]">
              {number(@report.fired)}
            </span>
          </div>
          <div class="match-hero-tile flex flex-col justify-center rounded-[1.125rem] px-4 py-3.5">
            <span class="text-xs text-[#b3b4ab]">{gettext("Team kills")}</span>
            <span class="font-display text-[1.625rem] font-semibold text-[#f4c95d]">
              {number(@report.team_kills)}
            </span>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # Warfare that ends without taking every sector ends on the clock.
  defp hero_result(%{winner: winner, mode: mode} = match) when winner in [:allies, :axis] do
    if to_string(mode) == "warfare" and not MatchHistory.total_win?(match),
      do: gettext("%{side} won on time", side: team_label(winner)),
      else: result_text(match)
  end

  defp hero_result(match), do: result_text(match)

  # ── MVP ────────────────────────────────────────────────────────────────────

  attr :report, :map, required: true
  attr :server, :map, required: true

  defp mvp_card(assigns) do
    assigns = assign(assigns, mvp: assigns.report.mvp, reward: assigns.report.mvp_reward)

    ~H"""
    <section
      id="match-mvp"
      aria-label={gettext("MVP")}
      class="mvp-card flex flex-col gap-3.5 rounded-[1.75rem] px-6 py-[1.375rem]"
    >
      <div class="flex items-center justify-between">
        <span class="text-xs tracking-[0.06em] text-[var(--mvp-dim)] uppercase">
          {gettext("MVP of the match")}
        </span>
        <span class="medal medal--gold flex size-9 items-center justify-center" aria-hidden="true">
          <.icon name="hero-star" class="size-4" />
        </span>
      </div>
      <.link navigate={~p"/players/#{@mvp.player_id}"} class="flex items-center gap-3.5">
        <.team_avatar
          name={@mvp.name}
          team={@mvp.team}
          class="size-16 rounded-[1.25rem] text-[1.25rem]"
        />
        <span class="flex min-w-0 flex-col gap-0.5">
          <strong class="truncate font-display text-[1.875rem] font-bold leading-none tracking-[-0.02em]">
            {@mvp.name}
          </strong>
          <span class="truncate text-[0.8125rem] text-[var(--mvp-dim)]">{mvp_line(@mvp)}</span>
        </span>
      </.link>
      <div class="grid grid-cols-4 gap-2">
        <.mvp_stat label={gettext("Kills")} value={number(@mvp.kills)} />
        <.mvp_stat label={gettext("Deaths")} value={number(@mvp.deaths)} />
        <.mvp_stat label={gettext("K/D")} value={decimal(@mvp.kill_death_ratio, 2)} />
        <.mvp_stat label={gettext("Combat")} value={number(@mvp.combat)} />
      </div>
      <span class="flex-1"></span>
      <.link
        :if={@reward}
        navigate={~p"/rules/#{@reward.rule.id}"}
        class="flex items-center gap-2.5 rounded-[0.875rem] border border-accent/25 bg-accent/10 px-3 py-2.5 text-[0.8125rem] text-accent"
      >
        <span class="shrink-0 rounded-full bg-accent/18 px-2 py-[0.1875rem] text-[0.6875rem] font-bold">
          {gettext("+%{hours} h VIP", hours: @reward.hours)}
        </span>
        <span class="min-w-0 flex-1 truncate">
          {if @reward.simulated,
            do: gettext("simulated by the rule %{rule}", rule: @reward.rule.name),
            else: gettext("by the rule %{rule}", rule: @reward.rule.name)}
        </span>
        <span class="font-mono text-[0.6875rem] opacity-80">
          {clock(local(@reward.at, @server))}
        </span>
      </.link>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp mvp_stat(assigns) do
    ~H"""
    <div class="rounded-[0.875rem] bg-[var(--mvp-tile)] px-3 py-2.5">
      <div class="text-[0.6875rem] text-[var(--mvp-dim)]">{@label}</div>
      <div class="font-display text-[1.25rem] font-semibold">{@value}</div>
    </div>
    """
  end

  defp mvp_line(mvp) do
    squad = mvp.unit && mvp.unit not in ["", "command"] && String.capitalize(mvp.unit)

    role =
      cond do
        mvp.role == "armycommander" ->
          gettext("commander")

        squad && mvp.role in ~w(officer tankcommander spotter) ->
          gettext("leader of squad %{squad}", squad: squad)

        squad ->
          gettext("squad %{squad}", squad: squad)

        true ->
          nil
      end

    [team_label(mvp.team), role] |> Enum.filter(& &1) |> Enum.join(" · ")
  end

  # ── Best by category ───────────────────────────────────────────────────────

  attr :report, :map, required: true

  defp best_categories(assigns) do
    ~H"""
    <section
      id="match-best"
      aria-label={gettext("Best by category")}
      class="flex min-w-0 flex-col gap-3 rounded-[1.75rem] bg-base-100 px-5 py-[1.125rem]"
    >
      <div class="flex flex-wrap items-baseline gap-x-3">
        <h2 class="flex-1 font-display text-[1.25rem] font-semibold">
          {gettext("Best by category")}
        </h2>
        <span class="text-xs text-muted">
          <span class="text-allies">{gettext("blue Allies")}</span>
          · <span class="text-axis">{gettext("orange Axis")}</span>
        </span>
      </div>
      <div class="grid flex-1 grid-cols-2 gap-2.5 xl:grid-cols-4">
        <div
          :for={category <- MatchReport.categories()}
          id={"match-board-#{category}"}
          class="flex flex-col gap-[0.4375rem] rounded-[1.125rem] bg-secondary px-3.5 py-3"
        >
          <span class="text-xs font-semibold text-subtle">{category_label(category)}</span>
          <%= case @report.best[category] do %>
            <% [first | rest] -> %>
              <div class="flex items-baseline gap-2">
                <span class={["size-2 shrink-0 rounded-full", team_dot(first.team)]}></span>
                <strong class="min-w-0 flex-1 truncate text-sm font-semibold">{first.name}</strong>
                <span class="font-display text-[1.25rem] font-semibold">{value(first.value)}</span>
              </div>
              <div :for={row <- rest} class="flex items-center gap-2 text-xs">
                <span class={["size-1.5 shrink-0 rounded-full", team_dot(row.team)]}></span>
                <span class="min-w-0 flex-1 truncate text-subtle">{row.name}</span>
                <span class="font-mono text-subtle">{value(row.value)}</span>
              </div>
            <% _none -> %>
              <span class="text-xs text-muted">–</span>
          <% end %>
        </div>
      </div>
    </section>
    """
  end

  defp category_label(:kills), do: gettext("Kills")
  defp category_label(:kill_death_ratio), do: gettext("K/D")
  defp category_label(:combat), do: gettext("Combat")
  defp category_label(:offense), do: gettext("Offense")
  defp category_label(:defense), do: gettext("Defense")
  defp category_label(:support), do: gettext("Support")
  defp category_label(:vehicles_destroyed), do: gettext("Vehicles destroyed")
  defp category_label(:kills_per_minute), do: gettext("Kills / min")

  defp value(value) when is_float(value), do: decimal(value, 2)
  defp value(value), do: number(value)

  # ── Squads ─────────────────────────────────────────────────────────────────

  attr :squads, :list, required: true

  defp best_squads(assigns) do
    ~H"""
    <section
      id="match-squads"
      aria-label={gettext("Best squads")}
      class="flex flex-col gap-1.5 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-5"
    >
      <div class="mb-1.5 flex flex-wrap items-baseline gap-x-3">
        <h2 class="flex-1 font-display text-[1.25rem] font-semibold">{gettext("Best squads")}</h2>
        <span class="text-xs text-muted">{gettext("squad score added up")}</span>
      </div>
      <p :if={@squads == []} class="py-6 text-center text-sm text-muted">
        {gettext("CRCON kept no squad for this match.")}
      </p>
      <div
        :for={{squad, index} <- Enum.with_index(@squads, 1)}
        class={[
          "grid grid-cols-[1.375rem_2.375rem_minmax(0,1fr)_auto_4.375rem] items-center gap-3 rounded-[0.875rem] px-2.5 py-[0.4375rem]",
          index == 1 && "bg-secondary"
        ]}
      >
        <span class={["font-mono text-xs", if(index == 1, do: "text-primary", else: "text-muted")]}>
          {String.pad_leading(to_string(index), 2, "0")}
        </span>
        <span class={[
          "flex size-[2.375rem] items-center justify-center rounded-xl text-[0.8125rem] font-bold",
          team_tint(squad.team)
        ]}>
          {squad.name |> String.first() |> String.upcase()}
        </span>
        <span class="flex min-w-0 flex-col">
          <strong class="truncate text-sm font-semibold">{String.capitalize(squad.name)}</strong>
          <span class="truncate text-xs text-muted">
            {Labels.squad_type(squad.type)} ·
            <span class="font-mono">{squad.size}/{squad.capacity}</span>
            <span :if={squad.leader}>· {squad.leader}</span>
          </span>
        </span>
        <span
          :if={squad.has_leader}
          class="text-[0.6875rem] font-semibold text-primary"
        >
          {gettext("with leader")}
        </span>
        <span
          :if={not squad.has_leader}
          class="rounded-full bg-warning/13 px-2 py-[0.1875rem] text-[0.6875rem] font-semibold text-warning"
        >
          {gettext("no leader")}
        </span>
        <span class="text-right font-display text-lg font-semibold">{number(squad.score)}</span>
      </div>
    </section>
    """
  end

  # ── Rules ──────────────────────────────────────────────────────────────────

  attr :report, :map, required: true
  attr :server, :map, required: true

  defp rules_fired(assigns) do
    ~H"""
    <section
      id="match-rules"
      aria-label={gettext("Rules that fired in this match")}
      class="flex flex-col gap-1 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-5"
    >
      <div class="mb-2 flex flex-wrap items-baseline gap-x-3">
        <h2 class="flex-1 font-display text-[1.25rem] font-semibold">
          {gettext("Rules that fired in this match")}
        </h2>
        <.link
          navigate={~p"/servers/#{@server}/history"}
          class="text-[0.8125rem] text-primary hover:underline"
        >
          {ngettext("1 in the history", "%{count} in the history", @report.fired)}
        </.link>
      </div>
      <p :if={@report.rules == []} class="py-6 text-center text-sm text-muted">
        {gettext("No rule fired during this match.")}
      </p>
      <.link
        :for={row <- Enum.take(@report.rules, 8)}
        navigate={~p"/rules/#{row.rule.id}"}
        class={[
          "grid grid-cols-[0.625rem_minmax(0,1fr)_auto_2.25rem] items-center gap-3 rounded-xl px-2.5 py-[0.4375rem] transition-colors hover:bg-secondary",
          row.failed > 0 && "bg-error/6"
        ]}
      >
        <span class={[
          "size-2 rounded-full",
          cond do
            row.failed > 0 -> "bg-error"
            row.simulated == row.count -> "border-[1.5px] border-dashed border-accent"
            true -> "bg-primary"
          end
        ]}></span>
        <span class="truncate text-sm">{row.rule.name}</span>
        <span class={[
          "text-xs",
          cond do
            row.failed > 0 -> "font-semibold text-error"
            row.simulated == row.count -> "font-semibold text-accent"
            true -> "text-muted"
          end
        ]}>
          {rule_status(row, @server)}
        </span>
        <span class="text-right font-mono text-[0.8125rem]">{row.count}</span>
      </.link>
    </section>
    """
  end

  defp rule_status(row, server) do
    cond do
      row.failed > 0 -> ngettext("1 failed", "%{count} failed", row.failed)
      row.simulated == row.count -> gettext("simulated")
      row.count == 1 and row.player -> gettext("executed · %{player}", player: row.player)
      row.count == 1 -> gettext("executed · %{time}", time: clock(local(row.last_at, server)))
      true -> gettext("executed")
    end
  end

  # ── Scoreboard ─────────────────────────────────────────────────────────────

  attr :match, :map, required: true
  attr :report, :map, required: true
  attr :team, :string, required: true
  attr :search, :string, required: true
  attr :all?, :boolean, required: true

  defp scoreboard(assigns) do
    ranked = assigns.match.roster |> ranked_players() |> Enum.with_index(1)
    query = assigns.search |> String.trim() |> String.downcase()

    rows =
      Enum.filter(ranked, fn {player, _rank} ->
        (assigns.team == "all" or player["team"] == assigns.team) and
          (query == "" or String.contains?(String.downcase(player["name"] || ""), query))
      end)

    assigns =
      assign(assigns,
        rows: if(assigns.all?, do: rows, else: Enum.take(rows, @rows)),
        total: length(rows),
        mvp_id: assigns.report.mvp && assigns.report.mvp.player_id
      )

    ~H"""
    <section
      id="match-scoreboard"
      aria-label={gettext("Full scoreboard")}
      class="flex min-w-0 flex-col rounded-[1.75rem] bg-base-100 px-4 py-5 sm:px-6"
    >
      <div class="mb-3 flex flex-wrap items-center gap-3">
        <h2 class="font-display text-[1.25rem] font-semibold">{gettext("Full scoreboard")}</h2>
        <.seg id="scoreboard-teams" label={gettext("Team")}>
          <:item click="team" value="all" active={@team == "all"}>
            {gettext("All players %{count}", count: @report.players)}
          </:item>
          <:item click="team" value="allies" active={@team == "allies"} class="text-allies">
            {gettext("Allies %{count}", count: @report.teams.allies)}
          </:item>
          <:item click="team" value="axis" active={@team == "axis"} class="text-axis">
            {gettext("Axis %{count}", count: @report.teams.axis)}
          </:item>
        </.seg>
        <span class="hidden flex-1 md:block"></span>
        <form
          id="scoreboard-search"
          phx-change="search"
          phx-submit="search"
          class="w-full md:w-[16.25rem]"
        >
          <label class="flex h-10 items-center gap-2 rounded-full bg-secondary px-3.5 text-muted">
            <.icon name="hero-magnifying-glass" class="size-4" />
            <input
              type="text"
              name="q"
              value={@search}
              phx-debounce="200"
              aria-label={gettext("Find a player on the scoreboard")}
              placeholder={gettext("Find a player")}
              class="min-w-0 flex-1 border-0 bg-transparent p-0 text-[0.8125rem] text-base-content outline-0 focus:ring-0"
            />
          </label>
        </form>
      </div>

      <div class="scoreboard-grid border-b border-line-soft px-2.5 py-2 text-xs text-muted">
        <span>#</span>
        <span>{gettext("Player")}</span>
        <span class="hidden lg:block">{gettext("Team")}</span>
        <span class="text-right">{gettext("Kills")}</span>
        <span class="hidden text-right lg:block">{gettext("Deaths")}</span>
        <span class="hidden text-right lg:block">{gettext("K/D")}</span>
        <span class="text-right font-semibold text-base-content">{gettext("Combat")} ↓</span>
        <span class="hidden text-right lg:block">{gettext("Offense")}</span>
        <span class="hidden text-right lg:block">{gettext("Defense")}</span>
        <span class="hidden text-right lg:block">{gettext("Support")}</span>
      </div>

      <.link
        :for={{player, rank} <- @rows}
        navigate={~p"/players/#{player["player_id"]}"}
        class="scoreboard-grid border-b border-line-soft px-2.5 py-[0.4375rem] text-[0.8125rem] transition-colors hover:bg-secondary"
      >
        <span class={["font-mono", if(rank <= 3, do: "text-primary", else: "text-muted")]}>
          {String.pad_leading(to_string(rank), 2, "0")}
        </span>
        <span class="flex min-w-0 items-center gap-2.5">
          <.team_avatar name={player["name"]} team={player["team"]} />
          <strong class="truncate font-semibold">{player["name"]}</strong>
          <span
            :if={player["player_id"] == @mvp_id}
            class="rounded-full bg-[#f4c95d] px-1.5 py-0.5 text-[0.625rem] font-bold text-[#2a1e02]"
          >
            MVP
          </span>
          <span :if={(player["team_kills"] || 0) > 0} class="shrink-0 text-[0.6875rem] text-warning">
            {ngettext("1 TK", "%{count} TKs", player["team_kills"])}
          </span>
        </span>
        <span class="hidden lg:block">
          <span
            :if={team_label(player["team"])}
            class={[
              "rounded-full px-2.5 py-[0.1875rem] text-xs font-semibold",
              team_tint(player["team"])
            ]}
          >
            {team_label(player["team"])}
          </span>
        </span>
        <span class="text-right font-mono">{player["kills"] || 0}</span>
        <span class="hidden text-right font-mono text-subtle lg:block">{player["deaths"] || 0}</span>
        <span class="hidden text-right font-mono lg:block">{decimal(kd(player), 2)}</span>
        <span class="text-right font-mono font-medium">{number(player["combat"] || 0)}</span>
        <span class="hidden text-right font-mono text-subtle lg:block">
          {number(player["offense"] || 0)}
        </span>
        <span class="hidden text-right font-mono text-subtle lg:block">
          {number(player["defense"] || 0)}
        </span>
        <span class="hidden text-right font-mono text-subtle lg:block">
          {number(player["support"] || 0)}
        </span>
      </.link>

      <p :if={@rows == []} class="py-8 text-center text-sm text-muted">
        {gettext("Nobody by that name on this scoreboard.")}
      </p>

      <div class="flex items-center gap-3 pt-3">
        <span class="flex-1 text-[0.8125rem] text-muted">
          {gettext("%{shown} of %{total} players · sorted by combat",
            shown: length(@rows),
            total: @total
          )}
        </span>
        <button
          :if={length(@rows) < @total}
          id="scoreboard-all"
          type="button"
          phx-click="show_all"
          class="h-10 rounded-full border border-base-300 bg-secondary px-[1.125rem] text-[0.8125rem] transition-colors hover:bg-base-300"
        >
          {gettext("Show the %{count} players", count: @total)}
        </button>
      </div>
    </section>
    """
  end

  defp ranked_players(roster) do
    roster |> Map.values() |> Enum.sort_by(&{-(&1["combat"] || 0), -(&1["kills"] || 0)})
  end

  defp kd(player), do: (player["kills"] || 0) / max(player["deaths"] || 0, 1)
end
