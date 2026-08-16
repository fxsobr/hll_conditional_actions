defmodule HllConditionalActionsWeb.ServerLive.Show do
  @moduledoc """
  The 360 view of a server: what it is, whether it is healthy, and what the
  engine has been doing on it.

  Same shape as the rule overview (and as the health product's patient 360
  it was ported from): identity header, metric strip, tabs, activity
  timeline. An admin arrives asking *is this server connected, what is it
  playing, which rules are watching it, and did anything fire?* — the
  metrics answer that on arrival and every one of them is a button into the
  tab that explains it.

  The gamestate is a CRCON round trip, so it is fetched after the first
  render: the match card shows a skeleton instead of blocking the page on a
  server that may be slow or down.
  """

  use HllConditionalActionsWeb, :live_view

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_servers}}

  import HllConditionalActionsWeb.Overview

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Engine
  alias HllConditionalActions.Engine.Runner
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Servers

  @refresh_ms :timer.seconds(15)
  @tabs ~w(overview rules activity settings)

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    server = Servers.get_server!(id)

    if connected?(socket) do
      LogStream.subscribe(server.id)
      Engine.subscribe(server.id)
      :timer.send_interval(@refresh_ms, :refresh)
      send(self(), :fetch_gamestate)
    end

    {:ok,
     socket
     |> assign(:server, server)
     |> assign(:page_title, server.name)
     |> assign(:stream_status, LogStream.status(server.id))
     |> assign(:gamestate, :loading)
     |> assign(:tab, "overview")
     |> assign(:selected_execution, nil)
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    {:noreply, assign(socket, :tab, tab_param(params["tab"]))}
  end

  @impl Phoenix.LiveView
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :tab, tab_param(tab))}
  end

  def handle_event("select_execution", %{"id" => id}, socket) do
    {:noreply,
     update(socket, :selected_execution, fn current ->
       if current == id, do: nil, else: id
     end)}
  end

  @impl Phoenix.LiveView
  def handle_info({:crcon_stream_status, _server_id, status}, socket) do
    {:noreply, assign(socket, :stream_status, status)}
  end

  def handle_info({:rule_fired, _execution}, socket), do: {:noreply, load(socket)}

  def handle_info(:refresh, socket) do
    {:noreply,
     socket
     |> load()
     |> assign(:gamestate, fetch_gamestate(socket.assigns.server))}
  end

  def handle_info(:fetch_gamestate, socket) do
    {:noreply, assign(socket, :gamestate, fetch_gamestate(socket.assigns.server))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    server = socket.assigns.server

    socket
    |> assign(:runner, Runner.info(server.id))
    |> assign(:rules, Rules.list_rules_applying_to(server))
    |> assign(:executions, Rules.list_executions(server_id: server.id, limit: 50))
    |> assign(:stats, Rules.execution_stats(server_id: server.id))
  end

  defp tab_param(tab) when tab in @tabs, do: tab
  defp tab_param(_other), do: "overview"

  # A server that is down should not take the page down with it: the card just
  # shows that the state is unavailable.
  defp fetch_gamestate(server) do
    case Crcon.get_gamestate(server) do
      {:ok, gamestate} when is_map(gamestate) -> gamestate
      _error -> nil
    end
  end

  defp map_name(gamestate) when not is_map(gamestate), do: nil

  defp map_name(gamestate) do
    case gamestate["current_map"] do
      %{"pretty_name" => name} -> name
      %{"map" => %{"pretty_name" => name}} -> name
      _other -> nil
    end
  end

  defp player_count(gamestate) when not is_map(gamestate), do: nil

  defp player_count(gamestate) do
    (gamestate["num_allied_players"] || 0) + (gamestate["num_axis_players"] || 0)
  end

  defp team_counts(gamestate) when not is_map(gamestate), do: nil

  defp team_counts(gamestate) do
    %{
      allied: gamestate["num_allied_players"] || 0,
      axis: gamestate["num_axis_players"] || 0
    }
  end

  # ── What the header and the metric strip say ───────────────────────────────

  defp header_badges(server, stream_status) do
    [
      if server.enabled do
        %{
          id: "stream",
          label: Labels.stream_status(stream_status),
          tone: stream_tone(stream_status)
        }
      else
        %{id: "state", label: gettext("Disabled"), tone: "neutral"}
      end
    ]
  end

  defp header_meta(server) do
    [Labels.game(server.game), server.base_url, server.timezone]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp kpi_list(assigns) do
    %{gamestate: gamestate, rules: rules, stats: stats, stream_status: status} = assigns

    [
      %{
        id: "players",
        label: gettext("Players online"),
        value: loading_or(gamestate, &player_count/1),
        hint: team_hint(gamestate),
        icon: "hero-users",
        tone: "info"
      },
      %{
        id: "rules",
        label: gettext("Rules watching"),
        value: Enum.count(rules, & &1.enabled),
        hint: rules_hint(assigns[:runner]),
        icon: "hero-bolt",
        tone: "primary",
        event: "rules"
      },
      %{
        id: "fired",
        label: gettext("Last 24 hours"),
        value: stats.last_24h,
        hint: gettext("rules that fired here"),
        icon: "hero-clock",
        tone: if(stats.last_24h > 0, do: "success", else: "neutral"),
        event: "activity"
      },
      %{
        id: "stream",
        label: gettext("Log stream"),
        value: Labels.stream_status(status),
        hint: stream_hint(status),
        icon: "hero-signal",
        tone: stream_tone(status),
        event: "settings"
      }
    ]
  end

  # The KPI strip renders `:loading` as a skeleton; a failed CRCON call is a
  # different thing and says so.
  defp loading_or(:loading, _fun), do: :loading
  defp loading_or(gamestate, fun), do: fun.(gamestate) || gettext("unavailable")

  defp team_hint(:loading), do: nil

  defp team_hint(gamestate) do
    case team_counts(gamestate) do
      nil ->
        gettext("CRCON did not answer")

      %{allied: allied, axis: axis} ->
        gettext("%{allied} allied · %{axis} axis", allied: allied, axis: axis)
    end
  end

  # A disabled rule still belongs to the server, so the list keeps it and this
  # line says how many of them are actually running.
  defp rules_summary(rules) do
    live = Enum.count(rules, & &1.enabled)
    off = length(rules) - live

    cond do
      off == 0 ->
        ngettext("%{count} rule running", "%{count} rules running", live, count: live)

      live == 0 ->
        ngettext("%{count} rule, all switched off", "%{count} rules, all switched off", off,
          count: off
        )

      true ->
        gettext("%{live} running · %{off} switched off", live: live, off: off)
    end
  end

  defp rules_hint(%{rules: count}) when is_integer(count),
    do:
      ngettext("%{count} loaded in the engine", "%{count} loaded in the engine", count,
        count: count
      )

  defp rules_hint(_info), do: gettext("engine offline")

  defp stream_hint(:connected), do: gettext("events are arriving")
  defp stream_hint(:connecting), do: gettext("handshaking with CRCON")
  defp stream_hint({:error, _reason}), do: gettext("see the settings tab")
  defp stream_hint(_status), do: gettext("no events are arriving")

  defp stream_tone(:connected), do: "success"
  defp stream_tone(:connecting), do: "warning"
  defp stream_tone({:error, _reason}), do: "error"
  defp stream_tone(_status), do: "neutral"

  defp status_tone(:executed), do: "success"
  defp status_tone(:partial), do: "warning"
  defp status_tone(:failed), do: "error"
  defp status_tone(:simulated), do: "info"
  defp status_tone(_status), do: "neutral"

  defp status_icon(:executed), do: "hero-check-circle"
  defp status_icon(:partial), do: "hero-exclamation-circle"
  defp status_icon(:failed), do: "hero-x-circle"
  defp status_icon(:simulated), do: "hero-beaker"
  defp status_icon(_status), do: "hero-minus-circle"

  defp execution_snippet(execution) do
    [execution.rule.name, execution.player_name || gettext("server wide")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp settings_rows(server) do
    [
      {gettext("Game"), Labels.game(server.game)},
      {gettext("CRCON address"), server.base_url},
      {gettext("Time zone"), server.timezone},
      {gettext("Enabled"), yes_no(server.enabled)},
      {gettext("Consume the live log stream"), yes_no(server.log_stream_enabled)}
    ]
  end

  defp yes_no(true), do: gettext("Yes")
  defp yes_no(_false), do: gettext("No")

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      page_title={@server.name}
      page_subtitle={gettext("What this server is, and what the engine is doing on it")}
    >
      <.entity_header
        title={@server.name}
        meta={header_meta(@server)}
        back={~p"/servers"}
        back_label={gettext("Back to servers")}
        icon="hero-server-stack"
        tone={if @server.enabled, do: "primary", else: "neutral"}
        badges={header_badges(@server, @stream_status)}
      >
        <:actions>
          <.button
            :if={Accounts.can?(@current_user, :manage_servers)}
            link_type="live_redirect"
            to={~p"/servers/#{@server}/edit"}
            size="sm"
            variant="outline"
            color="gray"
            icon="hero-pencil-square"
            label={gettext("Edit")}
          />
          <.button
            :if={Accounts.can?(@current_user, :manage_rules)}
            link_type="live_redirect"
            to={~p"/rules/new?server_id=#{@server.id}"}
            size="sm"
            color="primary"
            icon="hero-plus"
            label={gettext("New rule")}
          />
        </:actions>
      </.entity_header>

      <.kpi_cards cards={kpi_list(assigns)} on_select="select_tab" />

      <.view_tabs
        id="server-tabs"
        active={@tab}
        on_change="select_tab"
        label={gettext("Server sections")}
        items={[
          %{id: "overview", label: gettext("Overview")},
          %{id: "rules", label: gettext("Rules"), count: length(@rules)},
          %{id: "activity", label: gettext("Activity"), count: @stats.total},
          %{id: "settings", label: gettext("Settings")}
        ]}
      />

      <%!-- ── Overview ───────────────────────────────────────────────────── --%>
      <div :if={@tab == "overview"} class="min-w-0 space-y-6">
        <div class="relative h-28 overflow-hidden rounded-box sm:h-32">
          <img src={server_art(@server)} alt="" class="size-full object-cover" aria-hidden="true" />
          <div class="absolute inset-0 bg-gradient-to-r from-black/75 via-black/40 to-transparent">
          </div>

          <div class="absolute inset-0 z-10 flex items-end justify-between gap-3 p-4 text-white">
            <div class="min-w-0">
              <p class="text-label-small text-white/70">{gettext("Now playing")}</p>

              <p class="truncate text-headline-medium leading-tight">
                <%= cond do %>
                  <% @gamestate == :loading -> %>
                    <.skeleton_block class="h-6 w-40" />
                  <% map_name(@gamestate) -> %>
                    {map_name(@gamestate)}
                  <% true -> %>
                    {gettext("unavailable")}
                <% end %>
              </p>
            </div>

            <p :if={player_count(@gamestate)} class="shrink-0 text-label-medium text-white/80">
              {ngettext("%{count} player", "%{count} players", player_count(@gamestate),
                count: player_count(@gamestate)
              )}
            </p>
          </div>
        </div>

        <.alert
          :if={match?({:error, _}, @stream_status)}
          color="danger"
          variant="soft"
          with_icon
          label={elem(@stream_status, 1)}
        />

        <div>
          <div class="mb-2 flex items-baseline justify-between gap-2">
            <h3 class="text-title-medium">{gettext("Recent activity")}</h3>

            <button
              :if={@executions != []}
              type="button"
              phx-click="select_tab"
              phx-value-tab="activity"
              class="cursor-pointer text-label-small text-muted hover:text-primary hover:underline"
            >
              {gettext("See all")}
            </button>
          </div>

          <.empty_state
            :if={@executions == []}
            icon="hero-clock"
            title={gettext("No rule has fired here yet.")}
            description={
              gettext(
                "As soon as a rule matches something on this server, every run shows up here with what it did."
              )
            }
          />

          <.timeline :if={@executions != []} id="server-timeline" label={gettext("Recent activity")}>
            <.timeline_card
              :for={execution <- Enum.take(@executions, 12)}
              icon={status_icon(execution.status)}
              tone={status_tone(execution.status)}
              kind={Labels.execution_status(execution.status)}
              at={execution.executed_at}
              at_id={"server-timeline-#{execution.id}"}
              snippet={execution_snippet(execution)}
              selected={@selected_execution == to_string(execution.id)}
              phx-click="select_execution"
              phx-value-id={execution.id}
            />
          </.timeline>
        </div>
      </div>

      <%!-- ── Rules ─────────────────────────────────────────────────────── --%>
      <div :if={@tab == "rules"}>
        <p :if={@rules != []} class="mb-2 text-body-small text-muted">
          {rules_summary(@rules)}
        </p>

        <.empty_state
          :if={@rules == []}
          icon="hero-bolt-slash"
          title={gettext("No rules apply to this server yet.")}
          description={
            gettext(
              "A rule watches for something happening on your server and answers it: a warning, a switch, a kick."
            )
          }
        >
          <:action>
            <.button
              :if={Accounts.can?(@current_user, :manage_rules)}
              link_type="live_redirect"
              to={~p"/rules/new?server_id=#{@server.id}"}
              size="sm"
              color="primary"
              icon="hero-plus"
              label={gettext("Write your first rule")}
            />
          </:action>
        </.empty_state>

        <.card :if={@rules != []} padded={false}>
          <.data_table id="server-rules" rows={@rules}>
            <:col :let={rule} label={gettext("Rule")}>
              <div class="flex flex-wrap items-center gap-1.5">
                <.link
                  navigate={~p"/rules/#{rule}"}
                  class={[
                    "font-medium hover:text-primary hover:underline",
                    not rule.enabled && "text-muted"
                  ]}
                >
                  {rule.name}
                </.link>

                <.rule_state rule={rule} />
              </div>
            </:col>

            <:col :let={rule} label={gettext("Trigger")}>
              <span class="inline-flex items-center gap-1.5 text-body-small">
                <.icon name={Icons.trigger(rule.trigger_event)} class="size-4 shrink-0 text-muted" />
                {Labels.trigger(rule.trigger_event)}
              </span>
            </:col>

            <:col :let={rule} label={gettext("Then")}>
              <div class="flex flex-wrap justify-end gap-1 sm:justify-start">
                <.tone_badge
                  :for={action <- rule.actions}
                  tone={to_string(Icons.action_tone(action.type))}
                  title={Labels.action(action.type)}
                >
                  <.icon name={Icons.action(action.type)} class="size-3" />
                  <span class="hidden lg:inline">{Labels.action(action.type)}</span>
                </.tone_badge>
              </div>
            </:col>

            <:col :let={rule} label={gettext("Priority")} class="text-right font-mono text-sm">
              {rule.priority}
            </:col>

            <:action :let={rule}>
              <.button
                link_type="live_redirect"
                to={~p"/rules/#{rule}"}
                size="xs"
                variant="ghost"
                color="gray"
                label={gettext("Open")}
              />
            </:action>
          </.data_table>
        </.card>
      </div>

      <%!-- ── Activity ──────────────────────────────────────────────────── --%>
      <div :if={@tab == "activity"}>
        <.empty_state
          :if={@executions == []}
          icon="hero-clock"
          title={gettext("No rule has fired here yet.")}
          description={
            gettext(
              "As soon as a rule matches something on this server, every run shows up here with what it did."
            )
          }
        />

        <.card :if={@executions != []} padded={false}>
          <table class="table-collapse app-table">
            <thead>
              <tr>
                <th>{gettext("When")}</th>

                <th>{gettext("Rule")}</th>

                <th>{gettext("Player")}</th>

                <th>{gettext("Outcome")}</th>
              </tr>
            </thead>

            <tbody class="divide-y divide-base-300">
              <tr :for={execution <- @executions} class="sm:hover:bg-base-200/60">
                <td data-cell="lead" class="whitespace-nowrap text-body-small text-subtle">
                  <.local_time id={"server-row-#{execution.id}"} at={execution.executed_at} />
                </td>

                <td data-label={gettext("Rule")}>
                  <.link
                    navigate={~p"/rules/#{execution.rule_id}"}
                    class="text-body-small font-medium hover:underline"
                  >
                    {execution.rule.name}
                  </.link>
                </td>

                <td data-label={gettext("Player")} class="text-body-small">
                  <span :if={execution.player_name}>{execution.player_name}</span>
                  <span :if={is_nil(execution.player_name)} class="text-muted">
                    {gettext("server wide")}
                  </span>
                </td>

                <td data-label={gettext("Outcome")}>
                  <.tone_badge tone={status_tone(execution.status)}>
                    {Labels.execution_status(execution.status)}
                  </.tone_badge>
                </td>
              </tr>
            </tbody>
          </table>
        </.card>
      </div>

      <%!-- ── Settings ──────────────────────────────────────────────────── --%>
      <div :if={@tab == "settings"} class="grid items-start gap-4 lg:grid-cols-2">
        <.card title={gettext("Connection")} icon="hero-server-stack">
          <dl class="divide-y divide-base-300 text-body-small">
            <div
              :for={{label, value} <- settings_rows(@server)}
              class="flex justify-between gap-3 py-2"
            >
              <dt class="text-muted">{label}</dt>
              <dd class="min-w-0 truncate text-right">{value}</dd>
            </div>
          </dl>

          <.button
            :if={Accounts.can?(@current_user, :manage_servers)}
            link_type="live_redirect"
            to={~p"/servers/#{@server}/edit"}
            size="sm"
            variant="outline"
            color="gray"
            icon="hero-pencil-square"
            class="w-fit"
            label={gettext("Edit this server")}
          />
        </.card>

        <.card title={gettext("Log stream")} icon="hero-signal">
          <p class="flex items-center gap-2 text-body-small">
            <.status_dot
              tone={stream_tone(@stream_status)}
              label={Labels.stream_status(@stream_status)}
            />
            {stream_hint(@stream_status)}
          </p>

          <.alert
            :if={match?({:error, _}, @stream_status)}
            color="danger"
            variant="soft"
            with_icon
            label={elem(@stream_status, 1)}
          />

          <p :if={@server.notes not in [nil, ""]} class="border-t border-base-300 pt-3">
            <span class="mb-1 block text-label-small text-muted">{gettext("Notes")}</span>
            <span class="text-body-small">{@server.notes}</span>
          </p>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
