defmodule HllConditionalActionsWeb.PlayerLive.Show do
  @moduledoc """
  The 360 view of a player: what this app has done to them, and why.

  The question this screen exists for is the one an admin gets in Discord —
  *"why was I kicked?"* — and until now answering it meant opening the
  history and filtering by a 17 digit id. Here it is one search away: which
  rules hit them, how many times, and the run by run detail.

  Everything is read from the execution history rather than from CRCON, so a
  player who left an hour ago is still answerable. Where they are connected
  right now, the live profile fills in the rest.
  """

  use HllConditionalActionsWeb, :live_view

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_executions}}

  import HllConditionalActionsWeb.Overview

  alias HllConditionalActions.Engine
  alias HllConditionalActions.Rules

  @tabs ~w(overview executions)

  @impl Phoenix.LiveView
  def mount(%{"player_id" => player_id}, _session, socket) do
    if connected?(socket), do: Engine.subscribe(nil)

    {:ok,
     socket
     |> assign(:player_id, player_id)
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
  def handle_info({:rule_fired, execution}, socket) do
    # Only reload when it is about the player on screen.
    if execution.player_id == socket.assigns.player_id do
      {:noreply, load(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    player_id = socket.assigns.player_id
    user = socket.assigns[:current_user]

    executions =
      Rules.list_executions_for(user, player_id: player_id, limit: 100)

    socket
    |> assign(:executions, executions)
    |> assign(:stats, Rules.execution_stats(player_id: player_id))
    |> assign(:rules, Rules.rules_for_player(player_id))
    |> assign(:player_name, player_name(executions))
    |> assign(:page_title, player_name(executions) || player_id)
  end

  defp tab_param(tab) when tab in @tabs, do: tab
  defp tab_param(_other), do: "overview"

  # The most recent name wins: players rename themselves, and the newest one
  # is what an admin will recognise.
  defp player_name([%{player_name: name} | _rest]) when is_binary(name) and name != "", do: name
  defp player_name([_execution | rest]), do: player_name(rest)
  defp player_name(_none), do: nil

  defp initials(nil), do: "?"

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  defp kpi_list(stats) do
    [
      %{
        id: "total",
        label: gettext("Rules that hit them"),
        value: stats.total,
        hint: gettext("across the whole history"),
        icon: "hero-bolt",
        tone: "primary",
        event: "executions"
      },
      %{
        id: "recent",
        label: gettext("Last 24 hours"),
        value: stats.last_24h,
        hint: gettext("how active they are right now"),
        icon: "hero-clock",
        tone: if(stats.last_24h > 0, do: "warning", else: "neutral"),
        event: "executions"
      },
      %{
        id: "punished",
        label: gettext("Punishments"),
        value: punishments(stats),
        hint: gettext("kicks, bans and punishes"),
        icon: "hero-exclamation-triangle",
        tone: if(punishments(stats) > 0, do: "error", else: "neutral"),
        event: "executions"
      },
      %{
        id: "simulated",
        label: gettext("Only simulated"),
        value: Map.get(stats.by_status, :simulated, 0),
        hint: gettext("recorded, never sent to the game"),
        icon: "hero-beaker",
        tone: "info",
        event: "executions"
      }
    ]
  end

  # Anything that actually landed on the player, as opposed to a simulated or
  # skipped run.
  defp punishments(stats) do
    Map.get(stats.by_status, :executed, 0) + Map.get(stats.by_status, :partial, 0)
  end

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

  defp result_tone("ok"), do: "text-success"
  defp result_tone("skipped"), do: "text-muted"
  defp result_tone("simulated"), do: "text-info"
  defp result_tone(_status), do: "text-error"

  defp action_label(type) do
    Labels.action(String.to_existing_atom(type))
  rescue
    ArgumentError -> type
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      page_title={@player_name || @player_id}
      page_subtitle={gettext("What this app has done to this player, and why")}
      back={~p"/executions"}
      back_label={gettext("Back to history")}
    >
      <.empty_state
        :if={@executions == []}
        icon="hero-user"
        title={gettext("Nothing recorded for this player")}
        description={
          gettext(
            "No rule has ever acted on this player, or the history that did has already been pruned."
          )
        }
      />

      <div :if={@executions != []} class="space-y-6">
        <.card>
          <div class="flex flex-wrap items-center gap-3">
            <span class="flex size-11 shrink-0 items-center justify-center rounded-full bg-gradient-primary text-title-medium text-primary">
              {initials(@player_name)}
            </span>

            <div class="min-w-0 flex-1">
              <p class="truncate text-title-large">{@player_name || gettext("Unknown player")}</p>

              <p class="truncate font-mono text-label-small text-muted">{@player_id}</p>
            </div>

            <.button
              link_type="live_redirect"
              to={~p"/executions?player_id=#{@player_id}"}
              size="sm"
              variant="outline"
              color="gray"
              icon="hero-clock"
            >
              <span class="hidden sm:inline">{gettext("Open in history")}</span>
            </.button>
          </div>
        </.card>

        <.kpi_cards cards={kpi_list(@stats)} on_select="select_tab" />

        <.view_tabs
          id="player-tabs"
          active={@tab}
          on_change="select_tab"
          label={gettext("Player sections")}
          items={[
            %{id: "overview", label: gettext("Overview")},
            %{id: "executions", label: gettext("History"), count: @stats.total}
          ]}
        />

        <div :if={@tab == "overview"} class="grid items-start gap-4 lg:grid-cols-3">
          <div class="min-w-0 space-y-4 lg:col-span-2">
            <.card title={gettext("Recent activity")} icon="hero-clock">
              <.timeline id="player-timeline" label={gettext("Recent activity")}>
                <.timeline_card
                  :for={execution <- Enum.take(@executions, 12)}
                  icon={status_icon(execution.status)}
                  tone={status_tone(execution.status)}
                  kind={Labels.execution_status(execution.status)}
                  at={execution.executed_at}
                  at_id={"player-timeline-#{execution.id}"}
                  snippet={execution.rule.name}
                  selected={@selected_execution == to_string(execution.id)}
                  phx-click="select_execution"
                  phx-value-id={execution.id}
                />
              </.timeline>
            </.card>
          </div>

          <.card title={gettext("Which rules hit them")} icon="hero-bolt">
            <ul class="divide-y divide-base-300">
              <li :for={row <- @rules} class="flex items-center justify-between gap-3 py-2">
                <div class="min-w-0">
                  <.link
                    navigate={~p"/rules/#{row.rule_id}"}
                    class="truncate text-body-small font-medium hover:text-primary hover:underline"
                  >
                    {row.rule_name}
                  </.link>

                  <.local_time
                    id={"player-rule-#{row.rule_id}"}
                    at={row.last_executed_at}
                    class="block text-label-small text-muted"
                  />
                </div>

                <.tone_badge tone="ghost">
                  {ngettext("%{count} time", "%{count} times", row.count, count: row.count)}
                </.tone_badge>
              </li>
            </ul>
          </.card>
        </div>

        <div :if={@tab == "executions"}>
          <.card padded={false}>
            <table class="table-collapse app-table">
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
                <tr :for={execution <- @executions} class="sm:hover:bg-base-200/60">
                  <td data-cell="lead" class="whitespace-nowrap text-body-small text-subtle">
                    <.local_time id={"player-row-#{execution.id}"} at={execution.executed_at} />
                  </td>

                  <td data-label={gettext("Rule")}>
                    <.link
                      navigate={~p"/rules/#{execution.rule_id}"}
                      class="text-body-small font-medium hover:underline"
                    >
                      {execution.rule.name}
                    </.link>
                  </td>

                  <td data-label={gettext("Server")} class="text-body-small text-subtle">
                    {execution.server.name}
                  </td>

                  <td data-label={gettext("Outcome")}>
                    <.tone_badge tone={status_tone(execution.status)}>
                      {Labels.execution_status(execution.status)}
                    </.tone_badge>
                  </td>

                  <td data-label={gettext("What it did")}>
                    <ul class="space-y-0.5">
                      <li
                        :for={result <- execution.results}
                        class="flex flex-wrap gap-x-1.5 text-label-small"
                      >
                        <span class={result_tone(result["status"])}>
                          {action_label(result["type"])}
                        </span>
                        <span class="text-muted">{result["detail"]}</span>
                      </li>
                    </ul>
                  </td>
                </tr>
              </tbody>
            </table>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
