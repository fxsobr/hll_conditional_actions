defmodule HllConditionalActionsWeb.AchievementLive do
  @moduledoc """
  The achievements of a server (Achievements board): a gallery of medals
  filtered by tier and scope, each with how many of the server's players
  have it and how many times it was unlocked; the latest unlocks and what
  they delivered; and the starter set. `new` and `edit` open the form
  (AchievementForm board) with a live preview: the medal, the messages the
  game shows, and who would already have it after the last matches.

  Achievements are counted at the end of every match by
  `HllConditionalActions.Progression`; this page only defines them. They
  belong to a server, so the page lives under `/servers/:server_id`; the old
  `/achievements` address sends to the first server.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_progression}}

  import HllConditionalActionsWeb.CommunityComponents

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Crcon.GameText
  alias HllConditionalActions.Progression
  alias HllConditionalActions.Progression.Achievement
  alias HllConditionalActions.Progression.Metrics
  alias HllConditionalActions.Progression.Preview
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.SeasonLive.Dashboard

  @icons ~w(hero-viewfinder-circle hero-fire hero-shield-check hero-truck hero-heart
            hero-arrow-trending-up hero-chevron-double-up hero-trophy hero-flag hero-star
            hero-clock hero-bolt)

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    servers = Servers.list_servers_for(socket.assigns.current_user)

    case Enum.find(servers, &(to_string(&1.id) == params["server_id"])) do
      nil ->
        to = if first = List.first(servers), do: base(first), else: ~p"/servers"
        {:ok, push_navigate(socket, to: to)}

      server ->
        {:ok,
         socket
         |> assign(:page_title, gettext("Community"))
         |> assign(:server, server)
         |> assign(:servers, servers)
         |> assign(:base, base(server))
         |> assign(tier: nil, scope: nil, form: nil)
         |> load()}
    end
  end

  defp base(server), do: ~p"/servers/#{server.id}/achievements"

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: assign(socket, :form, nil)

  defp apply_action(socket, action, params) when action in [:new, :edit] do
    if manage?(socket) do
      achievement =
        if action == :edit,
          do: find!(socket, params["id"]),
          else: %Achievement{simulation: true, server_id: socket.assigns.server.id}

      socket
      |> assign(:achievement, achievement)
      |> load_preview_matches()
      |> validate(%{})
    else
      push_patch(socket, to: socket.assigns.base)
    end
  end

  # Only this server's achievements can be changed from its page.
  defp find!(socket, id) do
    achievement = Progression.get_achievement!(id)

    if achievement.server_id in [nil, socket.assigns.server.id],
      do: achievement,
      else: raise(Ecto.NoResultsError, queryable: Achievement)
  end

  # The server's last matches, read once per page: every form opened on it
  # previews against the same history.
  defp load_preview_matches(socket) do
    if Map.has_key?(socket.assigns, :preview_matches) do
      socket
    else
      server = socket.assigns.server

      socket
      |> assign(:preview_matches, nil)
      |> start_async(:preview_matches, fn -> Preview.recent_matches([server]) end)
    end
  end

  @impl Phoenix.LiveView
  def handle_async(:preview_matches, result, socket) do
    matches =
      case result do
        {:ok, matches} -> matches
        _failed -> []
      end

    socket = assign(socket, :preview_matches, matches)
    {:noreply, if(socket.assigns[:changeset], do: assign_preview(socket), else: socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"achievement" => params}, socket) do
    {:noreply, validate(socket, params)}
  end

  def handle_event("save", %{"achievement" => params}, socket) do
    params = Map.put(params, "server_id", target_server(socket, params["server_id"]).id)

    result =
      if socket.assigns.achievement.id,
        do: Progression.update_achievement(socket.assigns.achievement, params),
        else: Progression.create_achievement(params)

    case result do
      {:ok, achievement} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Achievement \"%{name}\" saved.", name: achievement.name))
         |> push_navigate(to: base(target_server(socket, to_string(achievement.server_id))))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset), changeset: changeset)}
    end
  end

  def handle_event("tier", %{"value" => tier}, socket),
    do: {:noreply, assign(socket, :tier, if(tier == "", do: nil, else: tier))}

  def handle_event("scope", %{"value" => scope}, socket),
    do: {:noreply, assign(socket, :scope, if(scope == "", do: nil, else: scope))}

  def handle_event("toggle", %{"id" => id}, socket) do
    with true <- manage?(socket) do
      achievement = find!(socket, id)

      {:ok, _achievement} =
        Progression.update_achievement(achievement, %{enabled: !achievement.enabled})
    end

    {:noreply, load(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with true <- manage?(socket) do
      {:ok, _achievement} =
        socket |> find!(id) |> Progression.delete_achievement()
    end

    {:noreply, socket |> put_flash(:info, gettext("Achievement removed.")) |> load()}
  end

  def handle_event("starter_set", _params, socket) do
    if manage?(socket), do: Progression.create_starter_set(socket.assigns.server.id)

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext(
         "Starter achievements added, in simulation. Turn simulation off when you like them."
       )
     )
     |> load()}
  end

  # A server the user reaches: the one picked in the form, or the page's.
  defp target_server(socket, id) do
    Enum.find(socket.assigns.servers, &(to_string(&1.id) == to_string(id))) ||
      socket.assigns.server
  end

  defp load(socket) do
    server_id = socket.assigns.server.id

    socket
    |> assign(:achievements, Progression.list_achievements(server_id))
    |> assign(:recent, Progression.recent_unlocks(server_id, 8))
    |> assign(:player_count, Progression.server_player_count(server_id))
  end

  defp manage?(socket), do: Accounts.can?(socket.assigns.current_user, :manage_progression)

  defp validate(socket, params) do
    changeset =
      socket.assigns.achievement
      |> Progression.change_achievement(params)
      |> then(&if(params == %{}, do: &1, else: Map.put(&1, :action, :validate)))

    socket
    |> assign(:form, to_form(changeset))
    |> assign(:changeset, changeset)
    |> assign(
      :form_server,
      target_server(socket, params["server_id"] || socket.assigns.achievement.server_id)
    )
    |> assign_preview()
  end

  # Who would have it: from the last matches for a match goal, from the
  # career totals for a career one - recomputed on every change.
  defp assign_preview(socket) do
    draft = Ecto.Changeset.apply_changes(socket.assigns.changeset)

    preview =
      cond do
        draft.metric == nil or not is_integer(draft.threshold) or draft.threshold <= 0 ->
          :incomplete

        draft.scope == :match and socket.assigns.preview_matches == nil ->
          :loading

        true ->
          Preview.achievement(
            draft,
            socket.assigns.preview_matches || [],
            socket.assigns.server.id
          )
      end

    socket |> assign(:draft, draft) |> assign(:preview, preview)
  end

  # ── Rendering ──────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(%{form: form} = assigns) when form != nil, do: render_form(assigns)
  def render(assigns), do: render_gallery(assigns)

  defp render_gallery(assigns) do
    shown =
      Enum.filter(assigns.achievements, fn achievement ->
        (assigns.tier == nil or to_string(achievement.tier) == assigns.tier) and
          (assigns.scope == nil or to_string(achievement.scope) == assigns.scope)
      end)

    assigns =
      assign(assigns,
        shown: shown,
        counts: Enum.frequencies_by(assigns.achievements, &to_string(&1.tier)),
        manage?: Accounts.can?(assigns.current_user, :manage_progression)
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
          :if={@manage?}
          id="new-achievement"
          patch={@base <> "/new"}
          primary
          icon="hero-plus"
        >
          {gettext("New achievement")}
        </.pill_button>
      </:actions>

      <div class="grid items-start gap-5 xl:grid-cols-[minmax(0,1fr)_22.5rem]">
        <div class="flex min-w-0 flex-col gap-4">
          <div class="flex flex-wrap items-center gap-2">
            <button
              id="tier-all"
              type="button"
              phx-click="tier"
              value=""
              aria-pressed={to_string(is_nil(@tier))}
              class={["com-tier-chip", is_nil(@tier) && "is-active"]}
            >
              {gettext("All")} <span class="font-mono">{length(@achievements)}</span>
            </button>
            <button
              :for={tier <- Achievement.tiers()}
              id={"tier-#{tier}"}
              type="button"
              phx-click="tier"
              value={tier}
              aria-pressed={to_string(@tier == to_string(tier))}
              class={["com-tier-chip", @tier == to_string(tier) && "is-active"]}
            >
              <span class={["size-2.5 rounded-[3px]", "tier-dot--#{tier}"]}></span>
              {Labels.tier(tier)}
              <span class="font-mono">{Map.get(@counts, to_string(tier), 0)}</span>
            </button>
            <span class="hidden flex-1 md:block"></span>
            <.seg id="achievement-scope" label={gettext("Scope")} raised={false}>
              <:item click="scope" value="" active={is_nil(@scope)}>{gettext("Everything")}</:item>
              <:item click="scope" value="match" active={@scope == "match"}>
                {gettext("In the match")}
              </:item>
              <:item click="scope" value="career" active={@scope == "career"}>
                {gettext("Over the career")}
              </:item>
            </.seg>
          </div>

          <.empty_state
            :if={@achievements == []}
            icon="hero-trophy"
            title={gettext("No achievements yet")}
            description={
              gettext(
                "Start from a set covering fighting, teamwork and helping the server: kills, support, tanks destroyed, matches as commander or squad leader, hours played."
              )
            }
          >
            <:action :if={@manage?}>
              <.pill_button type="button" primary icon="hero-sparkles" phx-click="starter_set">
                {gettext("Add the starter set")}
              </.pill_button>
            </:action>
          </.empty_state>

          <ul
            :if={@achievements != []}
            id="achievements"
            class="grid gap-3.5 sm:grid-cols-2 lg:grid-cols-3"
          >
            <li
              :for={achievement <- @shown}
              id={"achievement-#{achievement.id}"}
              class={[
                "group relative flex min-h-[11.5rem] flex-col gap-2 rounded-[1.5rem] border border-transparent bg-base-100 p-5 shadow-[var(--shadow-card)]",
                achievement.tier == :gold && "achievement-tile--gold",
                achievement.tier == :legendary && "achievement-tile--legendary",
                not achievement.enabled && "opacity-60"
              ]}
            >
              <div class="flex items-start justify-between gap-2">
                <.medal tier={to_string(achievement.tier)} icon={achievement.icon} />
                <span class="flex flex-col items-end gap-1.5">
                  <span
                    :if={achievement.reward_vip_hours > 0}
                    class="rounded-full bg-accent/13 px-2 py-[0.1875rem] text-[0.6875rem] font-semibold text-accent"
                  >
                    {vip_badge(achievement.reward_vip_hours)}
                  </span>
                  <span :if={achievement.reward_vip_hours == 0} class="text-[0.6875rem] text-muted">
                    {scope_word(achievement.scope)}
                  </span>
                  <.pill
                    :if={achievement.simulation}
                    tone="simulating"
                    class="h-6 px-2 text-[0.6875rem]"
                  >
                    {gettext("Simulation")}
                  </.pill>
                  <span :if={not achievement.enabled} class="text-[0.6875rem] text-muted">
                    {gettext("Off")}
                  </span>
                </span>
              </div>
              <.link
                :if={@manage?}
                patch={@base <> "/#{achievement.id}/edit"}
                class="text-base font-semibold hover:underline"
              >
                {achievement.name}
              </.link>
              <strong :if={not @manage?} class="text-base font-semibold">{achievement.name}</strong>
              <span class="achievement-tile-sub line-clamp-2 text-[0.8125rem] text-muted">
                {achievement.description || Labels.achievement_goal(achievement)}
              </span>
              <span class="flex-1"></span>
              <span class="achievement-tile-sub flex justify-between gap-2 text-xs text-subtle">
                <span>{players_share(achievement.unlocked_count, @player_count)}</span>
                <span class="font-mono">{number(achievement.unlocked_count)}×</span>
              </span>
              <div
                :if={@manage?}
                class="absolute top-[4.25rem] right-4 transition-opacity group-hover:opacity-100 focus-within:opacity-100 md:opacity-0"
              >
                <.row_menu id={"achievement-menu-#{achievement.id}"}>
                  <.menu_item
                    icon="hero-pencil-square"
                    phx-click={JS.patch(@base <> "/#{achievement.id}/edit")}
                  >
                    {gettext("Edit")}
                  </.menu_item>
                  <.menu_item icon="hero-power" phx-click="toggle" phx-value-id={achievement.id}>
                    {if achievement.enabled, do: gettext("Disable"), else: gettext("Enable")}
                  </.menu_item>
                  <.menu_item
                    tone="error"
                    icon="hero-trash"
                    phx-click="delete"
                    phx-value-id={achievement.id}
                    data-confirm={gettext("Remove this achievement and every unlock of it?")}
                  >
                    {gettext("Remove")}
                  </.menu_item>
                </.row_menu>
              </div>
            </li>
            <li :if={@shown == []} class="col-span-full py-10 text-center text-sm text-muted">
              {gettext("No achievement with these filters.")}
            </li>
          </ul>
        </div>

        <section
          id="achievement-unlocks"
          class="flex min-w-0 flex-col gap-1.5 rounded-[1.75rem] bg-base-100 p-[1.375rem] shadow-[var(--shadow-card)]"
        >
          <div class="mb-2.5 flex items-baseline">
            <h2 class="flex-1 font-display text-xl font-semibold">{gettext("Latest unlocks")}</h2>
            <.live_mark />
          </div>
          <p :if={@recent == []} class="py-6 text-center text-sm text-muted">
            {gettext("Nothing unlocked yet. Achievements are counted when a match ends.")}
          </p>
          <div
            :for={unlock <- @recent}
            class="flex items-center gap-3 border-b border-line-soft px-1 py-2.5 last:border-b-0"
          >
            <.medal tier={to_string(unlock.achievement.tier)} size="sm" />
            <span class="flex min-w-0 flex-1 flex-col">
              <span class="truncate text-sm">
                <.link
                  navigate={~p"/players/#{unlock.player_id}"}
                  class="font-semibold hover:underline"
                >
                  {unlock.player_name || unlock.player_id}
                </.link>
                · {unlock.achievement.name}
              </span>
              <span class={["truncate text-xs", delivered_tone(unlock)]}>{delivered(unlock)}</span>
            </span>
            <span class="shrink-0 font-mono text-[0.6875rem] text-muted">
              {when_label(unlock.unlocked_at, unlock.server || @server)}
            </span>
          </div>
          <span class="flex-1"></span>
          <div
            :if={@manage?}
            id="starter-set"
            class="mt-2 flex flex-col gap-1.5 rounded-[1.125rem] bg-secondary px-4 py-3.5"
          >
            <strong class="text-sm font-semibold">{gettext("Starter set")}</strong>
            <span class="text-[0.8125rem] leading-snug text-subtle">
              {ngettext(
                "1 achievement ready for new servers, starting in simulation.",
                "%{count} achievements ready for new servers, all starting in simulation.",
                Progression.starter_set_size()
              )}
            </span>
            <button
              type="button"
              phx-click="starter_set"
              class="self-start text-[0.8125rem] text-primary hover:underline"
            >
              {gettext("Install the set")}
            </button>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp render_form(assigns) do
    assigns =
      assign(assigns,
        editing?: assigns.achievement.id != nil,
        hint: threshold_hint(assigns.preview, assigns.draft),
        description: assigns.form[:description].value || ""
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={if @editing?, do: gettext("Edit achievement"), else: gettext("New achievement")}
      crumb={gettext("Community / Achievements")}
      back={@base}
      back_label={gettext("Back to Achievements")}
      global_search={false}
      scope={false}
      bell={false}
    >
      <:actions>
        <.pill_button patch={@base} class="max-sm:hidden">{gettext("Cancel")}</.pill_button>
        <.pill_button
          id="achievement-submit"
          type="submit"
          form="achievement-form"
          primary
          phx-disable-with={gettext("Saving...")}
        >
          {if @editing?, do: gettext("Save achievement"), else: gettext("Create achievement")}
        </.pill_button>
      </:actions>

      <div class="grid items-start gap-5 xl:grid-cols-[minmax(0,1fr)_26.875rem]">
        <.form
          for={@form}
          id="achievement-form"
          phx-change="validate"
          phx-submit="save"
          class="flex min-w-0 flex-col gap-[1.125rem] rounded-[1.75rem] bg-base-100 px-4 py-5 shadow-[var(--shadow-card)] sm:px-7 sm:py-[1.375rem]"
        >
          <.section_label first>{gettext("Identity")}</.section_label>

          <div class="grid gap-5 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)]">
            <label class="flex flex-col gap-2">
              <span class="com-label">{gettext("Name")}</span>
              <input
                type="text"
                name={@form[:name].name}
                value={@form[:name].value}
                class="com-field"
                required
              />
              <span :for={msg <- errors(@form, :name)} class="text-sm text-error">{msg}</span>
            </label>
            <div class="flex flex-col gap-2">
              <span class="com-label">{gettext("Tier")}</span>
              <.radio_seg
                id="achievement-tier"
                name={@form[:tier].name}
                value={@form[:tier].value}
                label={gettext("Tier")}
                class="com-tier-seg"
                options={Enum.map(Achievement.tiers(), &{Labels.tier(&1), to_string(&1)})}
              >
                <:option_prefix :let={tier}>
                  <span class={["hex size-3.5 shrink-0", "tier-dot--#{tier}"]}></span>
                </:option_prefix>
              </.radio_seg>
            </div>
          </div>

          <label class="flex flex-col gap-2">
            <span class="com-label flex justify-between gap-3">
              {gettext("Description")}
              <span class="font-normal text-muted">
                {gettext("the player reads it in game · %{count}/140",
                  count: String.length(@description)
                )}
              </span>
            </span>
            <textarea
              name={@form[:description].name}
              rows="2"
              maxlength="140"
              class="com-field"
            >{@description}</textarea>
            <span :for={msg <- errors(@form, :description)} class="text-sm text-error">{msg}</span>
          </label>

          <div class="flex flex-col gap-2">
            <span class="com-label">{gettext("Icon")}</span>
            <div
              role="radiogroup"
              aria-label={gettext("Icon")}
              class="grid grid-cols-6 gap-2 sm:grid-cols-12"
            >
              <label :for={icon <- icons(@form[:icon].value)} class="cursor-pointer">
                <input
                  type="radio"
                  name={@form[:icon].name}
                  value={icon}
                  checked={to_string(@form[:icon].value || "hero-trophy") == icon}
                  class="peer sr-only"
                  aria-label={icon_label(icon)}
                />
                <span class="flex h-[3.125rem] items-center justify-center rounded-[0.875rem] border border-line-raised bg-secondary text-subtle transition-colors peer-checked:border-2 peer-checked:border-primary peer-checked:bg-primary/10 peer-checked:text-primary peer-focus-visible:outline-2 peer-focus-visible:outline-primary">
                  <.icon name={icon} class="size-5" />
                </span>
              </label>
            </div>
          </div>

          <.section_label>{gettext("When it unlocks")}</.section_label>

          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-[13.75rem_minmax(0,1fr)_8.75rem_7.25rem] lg:items-end">
            <div class="flex flex-col gap-2">
              <span class="com-label">{gettext("Scope")}</span>
              <.radio_seg
                id="achievement-scope-field"
                name={@form[:scope].name}
                value={@form[:scope].value}
                label={gettext("Scope")}
                options={[{gettext("Match"), "match"}, {gettext("Career"), "career"}]}
              />
            </div>
            <label class="flex flex-col gap-2">
              <span class="com-label">{gettext("Metric")}</span>
              <select name={@form[:metric].name} class="com-field">
                <option :if={is_nil(@form[:metric].value)} value="">
                  {gettext("Pick a metric")}
                </option>
                <option
                  :for={{label, value} <- Labels.metric_options(metrics_for(@form))}
                  value={value}
                  selected={to_string(@form[:metric].value) == value}
                >
                  {label}
                </option>
              </select>
            </label>
            <div class="flex flex-col gap-2">
              <span class="com-label">{gettext("Comparison")}</span>
              <span class="com-field flex items-center text-subtle">{gettext("at least")}</span>
            </div>
            <label class="flex flex-col gap-2">
              <span class="com-label">{gettext("Threshold")}</span>
              <input
                type="number"
                min="1"
                name={@form[:threshold].name}
                value={@form[:threshold].value}
                class="com-field font-mono"
                required
              />
            </label>
          </div>
          <span
            :for={msg <- errors(@form, :metric) ++ errors(@form, :threshold)}
            class="-mt-2 text-sm text-error"
          >
            {msg}
          </span>
          <span :if={@hint} class="-mt-2 text-xs text-muted">
            {@hint}
          </span>

          <div class="flex flex-col gap-2">
            <span class="com-label">{gettext("Counts on")}</span>
            <div role="radiogroup" aria-label={gettext("Counts on")} class="flex flex-wrap gap-2">
              <label :for={server <- @servers} class="com-chip">
                <input
                  type="radio"
                  name="achievement[server_id]"
                  value={server.id}
                  checked={server.id == @form_server.id}
                  class="sr-only"
                />
                <span>
                  <.icon name="hero-check" class="com-chip-check size-4" />
                  {server.name}
                </span>
              </label>
            </div>
          </div>

          <.section_label>{gettext("Reward and behaviour")}</.section_label>

          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-[11.25rem_13.75rem_minmax(0,1fr)] lg:items-end">
            <label class="flex flex-col gap-2">
              <span class="com-label">{gettext("VIP hours")}</span>
              <span class="com-field flex items-center gap-2 !px-3.5">
                <input
                  type="number"
                  min="0"
                  name={@form[:reward_vip_hours].name}
                  value={@form[:reward_vip_hours].value}
                  class="w-full min-w-0 border-0 bg-transparent p-0 font-mono text-base outline-0 focus:ring-0"
                />
                <span class="text-[0.8125rem] text-muted">h</span>
              </span>
            </label>
            <label class="flex flex-col gap-2">
              <span class="com-label">{gettext("CRCON flag")}</span>
              <input
                type="text"
                maxlength="8"
                name={@form[:reward_flag].name}
                value={@form[:reward_flag].value}
                class="com-field font-mono text-sm"
              />
            </label>
            <span class="pb-1.5 text-xs leading-snug text-muted">
              {gettext(
                "The VIP adds to what the player already has. The flag stays on the CRCON profile and can exempt from rules."
              )}
            </span>
          </div>

          <div class="grid gap-3 md:grid-cols-3">
            <div class="flex items-start gap-3 rounded-[1.125rem] bg-secondary px-4 py-3.5">
              <span class="flex min-w-0 flex-1 flex-col gap-[0.1875rem]">
                <strong class="text-sm font-semibold">{gettext("Announce in game")}</strong>
                <span class="text-xs leading-snug text-muted">
                  {gettext("a message to everybody on the server")}
                </span>
              </span>
              <.toggle_switch
                id="achievement-announce"
                name={@form[:announce].name}
                checked={truthy?(@form[:announce].value)}
                label={gettext("Announce in game")}
              />
            </div>
            <div class="engine-card flex items-start gap-3 rounded-[1.125rem] px-4 py-3.5">
              <span class="flex min-w-0 flex-1 flex-col gap-[0.1875rem]">
                <strong class="engine-card-title text-sm font-semibold">
                  {gettext("Start in simulation")}
                </strong>
                <span class="engine-card-sub text-xs leading-snug">
                  {gettext("records it, without announcing or giving VIP")}
                </span>
              </span>
              <.toggle_switch
                id="achievement-simulation"
                name={@form[:simulation].name}
                checked={truthy?(@form[:simulation].value)}
                label={gettext("Start in simulation")}
                tone="engine"
              />
            </div>
            <div class="flex items-start gap-3 rounded-[1.125rem] bg-secondary px-4 py-3.5">
              <span class="flex min-w-0 flex-1 flex-col gap-[0.1875rem]">
                <strong class="text-sm font-semibold">{gettext("Active")}</strong>
                <span class="text-xs leading-snug text-muted">{gettext("counts from now on")}</span>
              </span>
              <.toggle_switch
                id="achievement-enabled"
                name={@form[:enabled].name}
                checked={truthy?(@form[:enabled].value)}
                label={gettext("Active")}
              />
            </div>
          </div>
        </.form>

        <aside aria-label={gettext("Live preview")} class="flex min-w-0 flex-col gap-4">
          <.medal_preview draft={@draft} />
          <.game_preview draft={@draft} preview={@preview} />
          <.reach_preview draft={@draft} preview={@preview} server={@server} />
        </aside>
      </div>
    </Layouts.app>
    """
  end

  attr :draft, :map, required: true

  defp medal_preview(assigns) do
    ~H"""
    <section
      id="achievement-preview"
      class="flex flex-col gap-3.5 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-5 shadow-[var(--shadow-card)]"
    >
      <div class="flex items-center gap-2">
        <h2 class="flex-1 font-display text-xl font-semibold">{gettext("Preview")}</h2>
        <.live_mark />
      </div>
      <article class={[
        "flex flex-col gap-2 rounded-[1.5rem] border border-transparent bg-secondary px-5 py-[1.125rem]",
        @draft.tier == :gold && "achievement-tile--gold",
        @draft.tier == :legendary && "achievement-tile--legendary"
      ]}>
        <div class="flex items-start justify-between">
          <.medal
            tier={to_string(@draft.tier || :bronze)}
            icon={@draft.icon || "hero-trophy"}
            size="lg"
          />
          <span class="flex flex-col items-end gap-1.5">
            <span
              :if={(@draft.reward_vip_hours || 0) > 0}
              class="rounded-full bg-accent/13 px-2 py-[0.1875rem] text-[0.6875rem] font-semibold text-accent"
            >
              {vip_badge(@draft.reward_vip_hours)}
            </span>
            <span class="text-[0.6875rem] text-muted">
              {scope_word(@draft.scope)} · {String.downcase(Labels.tier(@draft.tier || :bronze))}
            </span>
          </span>
        </div>
        <strong class="text-[1.0625rem] font-semibold">
          {blank(@draft.name, gettext("Achievement name"))}
        </strong>
        <span class="achievement-tile-sub text-[0.8125rem] leading-snug text-subtle">
          {@draft.description ||
            (@draft.metric && @draft.threshold && Labels.achievement_goal(@draft))}
        </span>
      </article>
    </section>
    """
  end

  attr :draft, :map, required: true
  attr :preview, :any, required: true

  defp game_preview(assigns) do
    sample =
      case assigns.preview do
        %{top: [%{name: name} | _rest]} when is_binary(name) -> name
        _none -> gettext("Player")
      end

    assigns =
      assign(assigns,
        announcement:
          GameText.clean(
            "#{Progression.game_mark(assigns.draft.tier || :bronze)} #{sample}: #{blank(assigns.draft.name, "…")}"
          ),
        private:
          GameText.clean(
            Progression.unlock_message(%{assigns.draft | name: blank(assigns.draft.name, "…")})
          )
      )

    ~H"""
    <section
      id="achievement-game-message"
      class="flex flex-col gap-2.5 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-[1.125rem] shadow-[var(--shadow-card)]"
    >
      <div class="flex items-baseline gap-2">
        <strong class="flex-1 text-sm font-semibold">{gettext("How it looks in game")}</strong>
        <span class="text-xs text-muted">
          {if @draft.announce,
            do: gettext("message to everybody"),
            else: gettext("to the player only")}
        </span>
      </div>
      <div class="game-message rounded-[0.875rem] px-4 py-3.5 font-mono text-[0.78125rem] leading-[1.7]">
        <span :if={@draft.announce and not @draft.simulation} class="block">{@announcement}</span>
        <span class="game-message-dim block whitespace-pre-line">{@private}</span>
      </div>
      <span class="text-xs text-muted">
        {if @draft.simulation,
          do: gettext("In simulation nothing reaches the game: the unlock is only recorded."),
          else: gettext("The player gets the second message privately. The game shows no emoji.")}
      </span>
    </section>
    """
  end

  attr :draft, :map, required: true
  attr :preview, :any, required: true
  attr :server, :map, required: true

  defp reach_preview(assigns) do
    ~H"""
    <section
      id="achievement-reach"
      class="flex flex-col gap-3 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-[1.125rem] shadow-[var(--shadow-card)]"
    >
      <strong class="text-sm font-semibold">{gettext("Who would already have it")}</strong>
      <%= case @preview do %>
        <% :incomplete -> %>
          <p class="text-sm text-muted">
            {gettext("Pick a metric and a goal to see who reaches it.")}
          </p>
        <% :loading -> %>
          <p class="text-xs text-muted">{gettext("Reading the last matches from CRCON...")}</p>
          <.skeleton_block class="h-24 rounded-2xl" />
        <% %{seen: 0} = preview -> %>
          <p class="text-sm text-muted">
            {if preview.source == :career,
              do: gettext("No career recorded on this server yet."),
              else: gettext("No finished match in CRCON's history yet.")}
          </p>
        <% preview -> %>
          <div class="flex items-baseline gap-2">
            <span class="font-display text-[2.5rem] font-semibold leading-none">{number(preview.count)}</span>
            <span class="text-sm text-subtle">
              {if preview.source == :career,
                do:
                  ngettext("player, over their career", "players, over their career", preview.count),
                else:
                  ngettext(
                    "players in the last match",
                    "players in the last %{count} matches",
                    preview.matches
                  )}
            </span>
          </div>
          <div class="flex flex-wrap items-center gap-2.5">
            <div :if={preview.top != []} class="flex">
              <.team_avatar
                :for={{row, index} <- Enum.with_index(Enum.take(preview.top, 4))}
                name={row.name || "?"}
                team={row.team}
                ring
                class={["size-[1.875rem] rounded-full text-[0.625rem]", index > 0 && "-ml-2"]}
              />
              <span
                :if={preview.count > 4}
                class="-ml-2 flex size-[1.875rem] items-center justify-center rounded-full bg-base-300 text-[0.625rem] font-semibold text-subtle ring-2 ring-base-100"
              >
                +{preview.count - 4}
              </span>
            </div>
            <span class="text-xs text-muted">
              {players_share_percent(preview.share)} · {ngettext(
                "1 time",
                "%{count} times",
                preview.times
              )}
            </span>
          </div>
          <.histogram preview={preview} draft={@draft} server={@server} />
          <div :if={preview.top != []} class="flex flex-col gap-0.5 border-t border-line-soft pt-2.5">
            <div
              :for={row <- Enum.take(preview.top, 3)}
              class="flex items-center gap-2.5 py-1 text-[0.8125rem]"
            >
              <span class={["size-2 rounded-full", team_dot(row.team)]}></span>
              <span class="min-w-0 flex-1 truncate">{row.name}</span>
              <span class="font-mono text-xs text-subtle">
                {ngettext("1 time", "%{count} times", row.times)} · {gettext("best %{value}",
                  value: number(row.best)
                )}
              </span>
            </div>
          </div>
      <% end %>
    </section>
    """
  end

  attr :preview, :map, required: true
  attr :draft, :map, required: true
  attr :server, :map, required: true

  defp histogram(assigns) do
    %{bins: bins, width: width} = assigns.preview.histogram
    top = Enum.max([1 | bins])
    marker = min(assigns.draft.threshold / (width * length(bins)) * 100, 100)

    assigns = assign(assigns, bins: bins, top: top, width: width, marker: marker)

    ~H"""
    <div class="mt-1 flex flex-col gap-1.5">
      <div
        aria-hidden="true"
        class="relative grid h-[5.25rem] items-end gap-[3px]"
        style={"grid-template-columns: repeat(#{length(@bins)}, minmax(0, 1fr))"}
      >
        <span
          :for={{count, index} <- Enum.with_index(@bins)}
          class={[
            "rounded-[3px]",
            if((index + 1) * @width > @draft.threshold,
              do: "histogram-bar--hit",
              else: "histogram-bar"
            )
          ]}
          style={"height: #{max(round(count * 100 / @top), if(count > 0, do: 3, else: 0))}%"}
        ></span>
        <span
          class="absolute top-[-4px] bottom-0 border-l-[1.5px] border-dashed border-primary"
          style={"left: calc(#{@marker}% - 1px)"}
        ></span>
      </div>
      <div class="flex justify-between font-mono text-[0.6875rem] text-muted">
        <span>0</span>
        <span class="text-primary">{gettext("threshold %{value}", value: @draft.threshold)}</span>
        <span>{number(round(@width * (length(@bins) - 1)))}+</span>
      </div>
      <span class="text-xs text-muted">
        {if @preview.source == :career,
          do:
            gettext("%{metric} over each career, %{server}",
              metric: Labels.metric(@draft.metric),
              server: @server.name
            ),
          else:
            gettext("%{metric} per match, %{server}",
              metric: Labels.metric(@draft.metric),
              server: @server.name
            )}
      </span>
    </div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp icons(current) do
    current = to_string(current || "hero-trophy")
    if current in @icons, do: @icons, else: @icons ++ [current]
  end

  defp icon_label(icon),
    do: icon |> String.replace_prefix("hero-", "") |> String.replace("-", " ")

  # A match can only reach the match metrics; a career can count them all.
  defp metrics_for(form) do
    case to_string(form[:scope].value) do
      "career" -> Metrics.all()
      _match -> Metrics.match()
    end
  end

  defp errors(form, field), do: Enum.map(form[field].errors, &translate_error/1)

  defp truthy?(value), do: value in [true, "true", "on"]

  defp blank(value, fallback) when value in [nil, ""], do: fallback
  defp blank(value, _fallback), do: value

  defp scope_word(:career), do: gettext("career")
  defp scope_word(_match), do: gettext("match")

  defp vip_badge(hours) when hours >= 168 and rem(hours, 24) == 0,
    do: gettext("+%{days} days VIP", days: div(hours, 24))

  defp vip_badge(hours), do: gettext("+%{hours} h VIP", hours: hours)

  defp players_share(_count, 0), do: gettext("no player seen yet")

  defp players_share(count, players), do: players_share_percent(count / players)

  defp players_share_percent(share) do
    percent = share * 100

    value =
      cond do
        percent == 0 -> "0"
        percent < 10 -> decimal(percent, 1)
        true -> to_string(round(percent))
      end

    gettext("%{percent}% of the players", percent: value)
  end

  defp threshold_hint(%{best_name: name, best: best, median_top: median} = preview, draft)
       when is_binary(name) and best > 0 do
    metric = Labels.metric(draft.metric) |> String.downcase()

    where =
      if preview.source == :career,
        do: gettext("On this server"),
        else: ngettext("In the last match", "In the last %{count} matches", preview.matches)

    gettext(
      "%{where} the best %{metric} was %{best} (%{name}). The median of the ten best is %{median}.",
      where: where,
      metric: metric,
      best: number(best),
      name: name,
      median: number(median)
    )
  end

  defp threshold_hint(_preview, _draft), do: nil

  defp delivered(%{simulated: true}), do: gettext("simulated · nothing sent")

  defp delivered(unlock) do
    achievement = unlock.achievement
    server = (unlock.server && unlock.server.name) || ""

    cond do
      achievement.reward_vip_hours > 0 ->
        gettext("%{vip} of VIP delivered",
          vip: String.trim_leading(Dashboard.vip_words(achievement.reward_vip_hours), "+")
        )

      achievement.announce ->
        gettext("%{server} · announced in game", server: server)

      true ->
        server
    end
  end

  defp delivered_tone(%{simulated: true}), do: "text-accent"

  defp delivered_tone(%{achievement: %{reward_vip_hours: hours}}) when hours > 0,
    do: "text-accent"

  defp delivered_tone(_unlock), do: "text-muted"

  defp when_label(at, server) do
    local = local(at, server)
    today = DateTime.to_date(local(DateTime.utc_now(), server))
    date = DateTime.to_date(local)

    cond do
      date == today -> clock(local)
      date == Date.add(today, -1) -> gettext("yesterday")
      true -> short_date(date)
    end
  end
end
