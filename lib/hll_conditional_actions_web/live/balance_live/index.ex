defmodule HllConditionalActionsWeb.BalanceLive.Index do
  @moduledoc """
  The team balance, in simulation (`HllConditionalActions.Balance`): how
  even each server's teams are right now, what the last week of matches
  looked like, every match's plan - the groups that would have changed
  team - and each server's settings.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_progression}}

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Balance
  alias HllConditionalActions.Balance.Plan
  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Discord
  alias HllConditionalActions.Features
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Workers.BalanceRebuild
  alias HllConditionalActionsWeb.NumberFormat

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    installed = Features.installed_by_server(Enum.map(Servers.list_servers_for(user), & &1.id))

    servers =
      user
      |> Servers.list_servers_for()
      |> Enum.filter(&MapSet.member?(Map.get(installed, &1.id, MapSet.new()), :balance))

    if connected?(socket), do: Balance.subscribe()

    {:ok,
     socket
     |> assign(:page_title, gettext("Team balance"))
     |> assign(:servers, servers)
     |> assign(:can_manage?, Accounts.can?(user, :manage_progression))
     |> assign(:webhooks, Discord.list_webhooks())
     |> assign(:strength, %{})
     |> assign(:filter, "all")
     |> assign(:rebuilding?, false)
     |> load()
     |> fetch_strength()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    server = pick_server(socket.assigns.servers, params["server"])
    {:noreply, socket |> assign(:server, server) |> assign_form()}
  end

  @impl Phoenix.LiveView
  def handle_event("filter", %{"status" => status}, socket) when status in ~w(all simulated) do
    {:noreply, socket |> assign(:filter, status) |> load()}
  end

  def handle_event("validate", %{"settings" => attrs}, socket) do
    changeset =
      socket.assigns.settings
      |> Balance.change_settings(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :settings))}
  end

  def handle_event("save", %{"settings" => attrs}, socket) do
    if socket.assigns.can_manage? do
      case Balance.save_settings(socket.assigns.settings, attrs) do
        {:ok, _settings} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Balance settings saved."))
           |> assign_form()}

        {:error, changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset, as: :settings))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("rebuild", _params, socket) do
    if socket.assigns.can_manage? do
      {:ok, _job} = BalanceRebuild.enqueue()

      {:noreply,
       socket
       |> assign(:rebuilding?, true)
       |> put_flash(
         :info,
         gettext(
           "Learning from the match history in the background. It takes a few minutes; this page updates when it is done."
         )
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("refresh_strength", _params, socket), do: {:noreply, fetch_strength(socket)}

  @impl Phoenix.LiveView
  def handle_info({:balance_planned, _plan}, socket),
    do: {:noreply, socket |> load() |> fetch_strength()}

  def handle_info({:balance_rebuilt, result}, socket) do
    {:noreply,
     socket
     |> assign(:rebuilding?, false)
     |> put_flash(
       :info,
       gettext("Learned from %{count} matches.", count: result.learned)
     )
     |> load()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_async(:strength, {:ok, strength}, socket),
    do: {:noreply, assign(socket, :strength, strength)}

  def handle_async(:strength, {:exit, _reason}, socket), do: {:noreply, socket}

  # ── Loading ────────────────────────────────────────────────────────────────

  defp load(socket) do
    ids = Enum.map(socket.assigns.servers, & &1.id)
    status = if socket.assigns.filter == "simulated", do: "simulated"

    socket
    |> assign(:plans, Balance.list_plans(ids, status: status, limit: 60))
    |> assign(:summary, Balance.summary(ids, 7))
    |> assign(:rated, Balance.rated_players())
  end

  # Who is on each team now and how strong, read from CRCON off the page's
  # process.
  defp fetch_strength(socket) do
    servers = socket.assigns.servers

    if connected?(socket) and servers != [] do
      start_async(socket, :strength, fn ->
        Map.new(servers, &{&1.id, server_strength(&1)})
      end)
    else
      socket
    end
  end

  defp server_strength(server) do
    case Crcon.get_detailed_players(server) do
      {:ok, %{"players" => players}} when is_map(players) -> Balance.strength(server, players)
      _error -> nil
    end
  end

  defp pick_server([], _id), do: nil

  defp pick_server(servers, id),
    do: Enum.find(servers, hd(servers), &(to_string(&1.id) == id))

  defp assign_form(%{assigns: %{server: nil}} = socket),
    do: assign(socket, settings: nil, form: nil)

  defp assign_form(socket) do
    settings = Balance.get_settings(socket.assigns.server.id)

    socket
    |> assign(:settings, settings)
    |> assign(:form, to_form(Balance.change_settings(settings), as: :settings))
  end

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
      page_subtitle={gettext("Simulation: the plans are worked out, nobody is moved")}
    >
      <.empty_state
        :if={@servers == []}
        icon="hero-scale"
        title={gettext("No server runs the team balance")}
        description={gettext("Install it from a server's Modules page.")}
      />

      <div :if={@servers != []} class="flex flex-col gap-5">
        <section id="balance-summary" class="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <.kpi_tile
            label={gettext("Matches measured")}
            value={NumberFormat.integer(@summary.matches)}
            hint={gettext("last 7 days")}
          />
          <.kpi_tile
            label={gettext("Unbalanced")}
            value={percent(@summary.unbalanced, @summary.matches)}
            hint={
              ngettext("%{count} match", "%{count} matches", @summary.unbalanced,
                count: @summary.unbalanced
              )
            }
            tone="warning"
          />
          <.kpi_tile
            label={gettext("Average gap")}
            value={points(@summary.gap)}
            hint={gettext("%{points} with the plans", points: points(@summary.gap_after))}
          />
          <.kpi_tile
            label={gettext("Stronger team won again")}
            value={if @summary.repeat_rate, do: "#{@summary.repeat_rate}%", else: "–"}
            hint={gettext("on the next map, together again")}
            tone="error"
          />
        </section>

        <section id="balance-now" class="flex flex-col gap-3 rounded-[1.75rem] bg-base-100 p-4 sm:p-5">
          <header class="flex flex-wrap items-center gap-2">
            <h2 class="flex-1 font-display text-lg font-semibold">{gettext("Right now")}</h2>
            <.button
              type="button"
              size="xs"
              variant="outline"
              icon="hero-arrow-path"
              phx-click="refresh_strength"
              label={gettext("Refresh")}
            />
          </header>
          <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
            <.strength_card
              :for={server <- @servers}
              server={server}
              strength={Map.get(@strength, server.id, :loading)}
            />
          </div>
          <p class="text-xs text-muted">
            {gettext(
              "Average balance rating of each team. Players with few matches count closer to 1000. %{count} players rated so far.",
              count: NumberFormat.integer(@rated |> Map.values() |> Enum.sum())
            )}
          </p>
        </section>

        <section
          id="balance-plans"
          class="flex flex-col gap-3 rounded-[1.75rem] bg-base-100 p-4 sm:p-5"
        >
          <header class="flex flex-wrap items-center gap-2">
            <h2 class="flex-1 font-display text-lg font-semibold">{gettext("Match by match")}</h2>
            <form id="balance-filter" phx-change="filter">
              <.segmented
                name="status"
                label={gettext("Show")}
                value={@filter}
                options={[{gettext("All"), "all"}, {gettext("Unbalanced"), "simulated"}]}
              />
            </form>
          </header>

          <.empty_state
            :if={@plans == []}
            card={false}
            icon="hero-scale"
            title={gettext("No match measured yet")}
            description={
              gettext("Each match is measured when it ends, on the servers with the module.")
            }
          />

          <ul id="balance-plan-list" class="flex flex-col gap-1">
            <li :for={plan <- @plans} id={"plan-#{plan.id}"}>
              <.plan_row plan={plan} />
            </li>
          </ul>
        </section>

        <section
          :if={@can_manage? and @form}
          id="balance-settings"
          class="flex flex-col gap-4 rounded-[1.75rem] bg-base-100 p-4 sm:p-5"
        >
          <header class="flex flex-wrap items-center gap-2">
            <h2 class="flex-1 font-display text-lg font-semibold">{gettext("Settings")}</h2>
            <nav
              :if={length(@servers) > 1}
              class="flex flex-wrap gap-1.5"
              aria-label={gettext("Server")}
            >
              <.link
                :for={server <- @servers}
                patch={~p"/balance?server=#{server.id}"}
                aria-current={server.id == @server.id && "page"}
                class={[
                  "rounded-full border px-3 py-1 text-[0.8125rem]",
                  if(server.id == @server.id,
                    do: "border-base-content bg-base-content font-semibold text-base-100",
                    else: "border-base-300 text-subtle hover:text-base-content"
                  )
                ]}
              >
                {server.name}
              </.link>
            </nav>
          </header>

          <.form
            for={@form}
            id="balance-settings-form"
            phx-change="validate"
            phx-submit="save"
            class="grid gap-4 sm:grid-cols-2"
          >
            <.input
              field={@form[:trigger_gap]}
              type="number"
              min="5"
              max="200"
              label={gettext("Unbalanced from (points of gap)")}
              help_text={gettext("15 by default. The plan aims for half of it.")}
              no_margin
            />
            <.input
              field={@form[:max_moves]}
              type="number"
              min="1"
              max="30"
              label={gettext("Most players moved per match")}
              no_margin
            />
            <.input
              field={@form[:max_count_gap]}
              type="number"
              min="0"
              max="6"
              label={gettext("Most extra players on one team")}
              no_margin
            />
            <.input
              field={@form[:partner_matches]}
              type="number"
              min="2"
              max="20"
              label={gettext("Matches in one squad to count as a group")}
              help_text={gettext("Groups are never split.")}
              no_margin
            />
            <.input
              field={@form[:webhook_id]}
              type="select"
              prompt={gettext("Do not post")}
              options={Enum.map(@webhooks, &{&1.remote_name || &1.name, &1.id})}
              label={gettext("Post each unbalanced match on Discord")}
              no_margin
            />
            <div class="flex items-end justify-end gap-2">
              <.button
                type="button"
                variant="outline"
                phx-click="rebuild"
                disabled={@rebuilding?}
                icon="hero-arrow-path"
                label={gettext("Learn from the history again")}
                data-confirm={
                  gettext(
                    "Ratings and groups are worked out again from the latest 500 matches of each server. Continue?"
                  )
                }
              />
              <.button type="submit" color="primary" label={gettext("Save")} />
            </div>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :server, :map, required: true
  attr :strength, :any, required: true

  defp strength_card(assigns) do
    ~H"""
    <div id={"strength-#{@server.id}"} class="flex flex-col gap-2 rounded-[1.25rem] bg-secondary p-4">
      <span class="text-sm font-semibold">{@server.name}</span>
      <%= case @strength do %>
        <% :loading -> %>
          <.skeleton_block class="h-12 w-full" />
        <% nil -> %>
          <span class="text-xs text-muted">{gettext("CRCON did not answer.")}</span>
        <% %{allies: %{players: 0}, axis: %{players: 0}} -> %>
          <span class="text-xs text-muted">{gettext("Nobody is playing.")}</span>
        <% strength -> %>
          <div class="flex items-baseline justify-between gap-3 font-display tabular-nums">
            <span>
              <span class="text-2xl font-semibold text-allies">{strength.allies.rating || "–"}</span>
              <span class="text-xs text-muted">
                {gettext("Allies")} · {strength.allies.players}
              </span>
            </span>
            <span class="text-right">
              <span class="text-xs text-muted">{strength.axis.players} · {gettext("Axis")}</span>
              <span class="text-2xl font-semibold text-axis">{strength.axis.rating || "–"}</span>
            </span>
          </div>
          <span class={["text-xs", gap_class(strength.gap)]}>
            {gettext("Gap of %{points} points", points: strength.gap)}
          </span>
      <% end %>
    </div>
    """
  end

  attr :plan, Plan, required: true

  defp plan_row(assigns) do
    ~H"""
    <details class="group rounded-[1.125rem] p-3 transition-colors open:bg-secondary hover:bg-secondary">
      <summary class="flex cursor-pointer list-none flex-wrap items-center gap-x-4 gap-y-1">
        <span class="w-24 font-mono text-[0.6875rem] text-muted">
          <.local_time id={"plan-#{@plan.id}-at"} at={@plan.ended_at} />
        </span>
        <span class="min-w-0 flex-1 truncate text-sm">
          <span class="font-semibold">{@plan.map || "?"}</span>
          <span class="text-muted">· {@plan.server && @plan.server.name}</span>
          <span :if={@plan.allied_score} class="font-mono text-xs text-subtle">
            · {@plan.allied_score}-{@plan.axis_score}
          </span>
        </span>
        <span class="font-mono text-xs tabular-nums text-subtle">
          <span class="text-allies">{@plan.allies_rating}</span>
          × <span class="text-axis">{@plan.axis_rating}</span>
        </span>
        <.pill
          tone={if @plan.status == "simulated", do: "warning", else: "success"}
          class="h-6 px-2.5 text-[0.6875rem]"
        >
          {status_label(@plan)}
        </.pill>
        <span
          :if={not is_nil(@plan.strong_won_again)}
          class="text-xs text-muted"
          title={gettext("The stronger team, together again on the next map")}
        >
          {if @plan.strong_won_again,
            do: gettext("won again"),
            else: gettext("lost the next one")}
        </span>
      </summary>

      <div class="mt-3 flex flex-col gap-2 pl-1 text-sm">
        <p class="text-subtle">
          {gettext("%{team} stronger by %{gap} points, %{count} players.",
            team: team_label(@plan.strong_team),
            gap: @plan.gap,
            count: @plan.players
          )}
          <span :if={@plan.status == "simulated"}>
            {gettext("With the plan: %{gap} points.", gap: @plan.gap_after)}
          </span>
        </p>
        <ul :if={@plan.moves != []} class="flex flex-col gap-1.5">
          <li :for={move <- @plan.moves} class="rounded-xl bg-base-100 px-3 py-2">
            <span class="font-semibold">
              {squad_label(move["squad"])} ({length(move["players"])})
            </span>
            <span class="text-xs text-muted">
              {gettext("from %{team} to the other team", team: team_label(move["from"]))}
            </span>
            <span class="block text-xs text-subtle">
              {Enum.map_join(move["players"], ", ", &"#{&1["name"] || &1["id"]} (#{&1["rating"]})")}
            </span>
          </li>
        </ul>
        <p :if={@plan.status == "simulated" and @plan.moves == []} class="text-xs text-muted">
          {gettext("No group could be moved within the limits.")}
        </p>
      </div>
    </details>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp status_label(%Plan{status: "simulated"} = plan),
    do: ngettext("Would move %{count}", "Would move %{count}", Plan.moved(plan))

  defp status_label(_plan), do: gettext("Balanced")

  defp team_label("allies"), do: gettext("Allies")
  defp team_label(_axis), do: gettext("Axis")

  defp squad_label(nil), do: gettext("No squad")
  defp squad_label(squad), do: String.capitalize(squad)

  defp gap_class(gap) when gap >= 30, do: "font-semibold text-error"
  defp gap_class(gap) when gap >= 15, do: "font-semibold text-warning"
  defp gap_class(_gap), do: "text-subtle"

  defp points(nil), do: "–"
  defp points(value), do: gettext("%{points} pts", points: value)

  defp percent(_part, 0), do: "–"
  defp percent(part, total), do: "#{round(part * 100 / total)}%"
end
