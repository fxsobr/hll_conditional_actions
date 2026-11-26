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
  alias HllConditionalActions.Balance.Analysis
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
     |> assign(:tab, "overview")
     |> assign(:sim_params, Analysis.defaults())
     |> assign(:sim, nil)
     |> assign(:sim_loading?, false)
     |> assign(:sim_rule, :either)
     |> load()
     |> fetch_strength()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    server = pick_server(socket.assigns.servers, params["server"])
    tab = if params["tab"] == "simulator", do: "simulator", else: "overview"

    socket =
      socket
      |> assign(:server, server)
      |> assign(:tab, tab)
      |> assign_form()

    socket =
      if tab == "simulator" and is_nil(socket.assigns.sim),
        do: simulate(socket),
        else: socket

    {:noreply, socket}
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

  def handle_event("simulate", %{"sim" => params}, socket) do
    {:noreply, socket |> assign(:sim_params, Analysis.normalize(params)) |> simulate()}
  end

  def handle_event("sim_rule", %{"rule" => rule}, socket) do
    rule = Enum.find(Analysis.rules(), :either, &(to_string(&1) == rule))
    {:noreply, assign(socket, :sim_rule, rule)}
  end

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

  def handle_async(:simulate, {:ok, result}, socket),
    do: {:noreply, assign(socket, sim: result, sim_loading?: false)}

  def handle_async(:simulate, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:sim_loading?, false)
     |> put_flash(:error, gettext("The simulation could not be run. Try a shorter period."))}
  end

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

  # The replay reads hundreds of matches: off the page's process, and the
  # last run's numbers stay on screen until the new ones arrive.
  defp simulate(socket) do
    servers = socket.assigns.servers

    if connected?(socket) and servers != [] do
      params = socket.assigns.sim_params
      ids = Enum.map(servers, & &1.id)
      game = hd(servers).game

      socket
      |> assign(:sim_loading?, true)
      |> start_async(:simulate, fn -> Analysis.run(ids, params, game) end)
    else
      socket
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

      <nav
        :if={@servers != []}
        id="balance-tabs"
        class="flex flex-wrap gap-1.5"
        aria-label={gettext("Views")}
      >
        <.link
          :for={
            {tab, label} <- [{"overview", gettext("Overview")}, {"simulator", gettext("Simulator")}]
          }
          id={"balance-tab-#{tab}"}
          patch={~p"/balance?#{[tab: tab]}"}
          aria-current={@tab == tab && "page"}
          class={[
            "rounded-full border px-3.5 py-1.5 text-[0.8125rem]",
            if(@tab == tab,
              do: "border-base-content bg-base-content font-semibold text-base-100",
              else: "border-base-300 text-subtle hover:text-base-content"
            )
          ]}
        >
          {label}
        </.link>
      </nav>

      <.simulator
        :if={@servers != [] and @tab == "simulator"}
        params={@sim_params}
        sim={@sim}
        loading?={@sim_loading?}
        rule={@sim_rule}
      />

      <div :if={@servers != [] and @tab == "overview"} class="flex flex-col gap-5">
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
                patch={~p"/balance?#{[server: server.id, tab: @tab]}"}
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

  attr :params, :map, required: true
  attr :sim, :map, default: nil
  attr :loading?, :boolean, default: false
  attr :rule, :atom, required: true

  defp simulator(assigns) do
    ~H"""
    <div id="balance-simulator" class="flex flex-col gap-5">
      <section class="flex flex-col gap-4 rounded-[1.75rem] bg-base-100 p-4 sm:p-5">
        <header class="flex flex-col gap-1">
          <h2 class="font-display text-lg font-semibold">{gettext("What if")}</h2>
          <p class="text-sm text-subtle">
            {gettext(
              "The balance replayed over past Warfare matches with 60+ players, with the settings below, comparing four ways of deciding when to act. Nobody is moved."
            )}
          </p>
        </header>

        <.form
          for={%{}}
          as={:sim}
          id="simulator-form"
          phx-change="simulate"
          class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4"
        >
          <.input
            name="sim[source]"
            type="select"
            value={@params["source"]}
            label={gettext("Matches")}
            options={[
              {gettext("History, today's ratings (optimistic)"), "history"},
              {gettext("Measured live, ratings of the time (honest)"), "live"}
            ]}
            no_margin
          />
          <.input
            name="sim[days]"
            type="select"
            value={@params["days"]}
            label={gettext("Period")}
            options={
              for d <- [7, 14, 30, 45],
                  do: {ngettext("Last %{count} day", "Last %{count} days", d), d}
            }
            no_margin
          />
          <.input
            name="sim[trigger_gap]"
            type="number"
            min="5"
            max="200"
            value={@params["trigger_gap"]}
            label={gettext("Unbalanced from (points of gap)")}
            phx-debounce="400"
            no_margin
          />
          <.input
            name="sim[max_moves]"
            type="number"
            min="1"
            max="30"
            value={@params["max_moves"]}
            label={gettext("Most players moved per match")}
            phx-debounce="400"
            no_margin
          />
          <.input
            name="sim[kills_ratio]"
            type="number"
            min="100"
            max="400"
            value={@params["kills_ratio"]}
            label={gettext("Dominant previous match: winner's kills (% of the loser's)")}
            phx-debounce="400"
            no_margin
          />
          <.input
            name="sim[points_ratio]"
            type="number"
            min="100"
            max="400"
            value={@params["points_ratio"]}
            label={gettext("... or winner's points (% of the loser's)")}
            phx-debounce="400"
            no_margin
          />
          <.input
            name="sim[together]"
            type="number"
            min="50"
            max="100"
            value={@params["together"]}
            label={gettext("Winners still together on one side (%)")}
            phx-debounce="400"
            no_margin
          />
          <.input
            name="sim[stack_bonus]"
            type="number"
            min="0"
            max="200"
            value={@params["stack_bonus"]}
            label={gettext("Extra points for the previous winners")}
            phx-debounce="400"
            no_margin
          />
          <.input
            name="sim[max_count_gap]"
            type="number"
            min="0"
            max="6"
            value={@params["max_count_gap"]}
            label={gettext("Most extra players on one team")}
            phx-debounce="400"
            no_margin
          />
          <.input
            name="sim[partner_matches]"
            type="number"
            min="2"
            max="20"
            value={@params["partner_matches"]}
            label={gettext("Matches in one squad to count as a group")}
            phx-debounce="400"
            no_margin
          />
        </.form>
      </section>

      <div :if={@loading? and is_nil(@sim)} class="flex flex-col gap-3">
        <.skeleton_block class="h-40 w-full" />
        <.skeleton_block class="h-40 w-full" />
      </div>

      <div :if={@sim} class={["flex flex-col gap-5", @loading? && "opacity-60"]}>
        <p
          :if={@sim.params["source"] == "history"}
          class="rounded-2xl bg-warning/13 px-4 py-3 text-sm text-warning"
        >
          {gettext(
            "History uses today's ratings, which already learned from these matches: the chances read higher than they will be. The live matches are honest, and grow every match."
          )}
        </p>

        <.empty_state
          :if={@sim.matches == 0}
          card={false}
          icon="hero-scale"
          title={gettext("No match in this period")}
          description={gettext("Live matches start counting from the module's first measured match.")}
        />

        <section
          :if={@sim.matches > 0}
          id="simulator-rules"
          class="flex flex-col gap-3 rounded-[1.75rem] bg-base-100 p-4 sm:p-5"
        >
          <header class="flex flex-col gap-1">
            <h2 class="font-display text-lg font-semibold">{gettext("Four ways of deciding")}</h2>
            <p class="text-sm text-subtle">
              {ngettext(
                "%{count} match, %{fast} of them over in 30 minutes or less.",
                "%{count} matches, %{fast} of them over in 30 minutes or less.",
                @sim.matches,
                fast: @sim.fast
              )}
            </p>
          </header>

          <div class="overflow-x-auto">
            <table class="w-full min-w-[56rem] text-sm">
              <thead class="text-left text-xs text-muted">
                <tr>
                  <th class="py-2 pr-3 font-medium">{gettext("Rule")}</th>
                  <th class="py-2 pr-3 font-medium">{gettext("Acts on")}</th>
                  <th class="py-2 pr-3 font-medium">{gettext("Fast matches caught")}</th>
                  <th class="py-2 pr-3 font-medium">{gettext("Repeated stomps caught")}</th>
                  <th class="py-2 pr-3 font-medium">{gettext("Gap before → after")}</th>
                  <th class="py-2 pr-3 font-medium">
                    {gettext("Favourite's chance before → after")}
                  </th>
                  <th class="py-2 pr-3 font-medium">{gettext("Moved per match")}</th>
                  <th class="py-2 font-medium">{gettext("Different players moved")}</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={rule <- Analysis.rules()}
                  id={"sim-rule-#{rule}"}
                  class="border-t border-base-300 tabular-nums"
                >
                  <td class="py-2.5 pr-3">
                    <span class="font-semibold">{rule_label(rule)}</span>
                    <span class="block text-xs text-muted">{rule_hint(rule)}</span>
                  </td>
                  <td class="py-2.5 pr-3">
                    {pct(@sim.rules[rule].share)}
                    <span class="text-xs text-muted">({@sim.rules[rule].fired})</span>
                  </td>
                  <td class="py-2.5 pr-3">{pct(@sim.rules[rule].fast_share)}</td>
                  <td class="py-2.5 pr-3">{pct(@sim.rules[rule].repeat_share)}</td>
                  <td class="py-2.5 pr-3">
                    {num(@sim.rules[rule].gap_before)} → {num(@sim.rules[rule].gap_after)}
                  </td>
                  <td class="py-2.5 pr-3">
                    {pct(@sim.rules[rule].chance_before)} → {pct(@sim.rules[rule].chance_after)}
                  </td>
                  <td class="py-2.5 pr-3">{@sim.rules[rule].moved_median || "–"}</td>
                  <td class="py-2.5">{@sim.rules[rule].players_moved}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <p class="text-xs text-muted">
            {gettext(
              "Repeated stomps: matches where the previous match's dominant winners, still together, won again. The favourite's chance is read from the table below."
            )}
          </p>
        </section>

        <div :if={@sim.matches > 0} class="grid gap-5 lg:grid-cols-2">
          <section
            id="simulator-calibration"
            class="flex flex-col gap-3 rounded-[1.75rem] bg-base-100 p-4 sm:p-5"
          >
            <header class="flex flex-col gap-1">
              <h2 class="font-display text-lg font-semibold">
                {gettext("Does the rating predict?")}
              </h2>
              <p class="text-sm text-subtle">
                {gettext(
                  "For each band of gap: how often the stronger side won, and how often the match was over in 30 minutes."
                )}
              </p>
            </header>
            <table class="w-full text-sm tabular-nums">
              <thead class="text-left text-xs text-muted">
                <tr>
                  <th class="py-2 pr-3 font-medium">{gettext("Gap")}</th>
                  <th class="py-2 pr-3 font-medium">{gettext("Matches")}</th>
                  <th class="py-2 pr-3 font-medium">{gettext("Stronger side won")}</th>
                  <th class="py-2 font-medium">{gettext("Over in 30 min")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={band <- @sim.calibration} class="border-t border-base-300">
                  <td class="py-2 pr-3">{band_label(band)}</td>
                  <td class="py-2 pr-3">{band.matches}</td>
                  <td class="py-2 pr-3">{pct(band.favourite_won)}</td>
                  <td class="py-2">{pct(band.fast)}</td>
                </tr>
              </tbody>
            </table>
          </section>

          <section
            id="simulator-moved"
            class="flex flex-col gap-3 rounded-[1.75rem] bg-base-100 p-4 sm:p-5"
          >
            <header class="flex flex-wrap items-center gap-2">
              <h2 class="flex-1 font-display text-lg font-semibold">
                {gettext("Who would pay for it")}
              </h2>
              <form id="simulator-rule" phx-change="sim_rule">
                <.input
                  name="rule"
                  type="select"
                  value={@rule}
                  options={for r <- Analysis.rules(), do: {rule_label(r), r}}
                  label={gettext("Rule")}
                  no_margin
                />
              </form>
            </header>
            <p class="text-sm text-subtle">
              {gettext("%{moved} moves of %{players} different players. The ones it would move most:",
                moved: @sim.rules[@rule].moved,
                players: @sim.rules[@rule].players_moved
              )}
            </p>
            <ol class="flex flex-col gap-1 text-sm">
              <li :for={p <- @sim.rules[@rule].most_moved} class="flex justify-between gap-3">
                <span class="truncate">{p.name || p.id}</span>
                <span class="tabular-nums text-subtle">
                  {ngettext("%{count} time", "%{count} times", p.times)}
                </span>
              </li>
            </ol>
          </section>
        </div>
      </div>
    </div>
    """
  end

  defp rule_label(:gap), do: gettext("Rating gap")
  defp rule_label(:previous), do: gettext("Previous match")
  defp rule_label(:both), do: gettext("Both")
  defp rule_label(:either), do: gettext("Either")

  defp rule_hint(:gap), do: gettext("the teams are far apart")
  defp rule_hint(:previous), do: gettext("a dominant group is together again")
  defp rule_hint(:both), do: gettext("far apart and a dominant group")
  defp rule_hint(:either), do: gettext("far apart or a dominant group")

  defp band_label(%{from: from, to: nil}), do: gettext("%{from}+ pts", from: from)
  defp band_label(%{from: from, to: to}), do: gettext("%{from}-%{to} pts", from: from, to: to - 1)

  defp pct(nil), do: "–"
  defp pct(value), do: "#{round(value * 100)}%"

  defp num(nil), do: "–"
  defp num(value), do: round(value)

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
