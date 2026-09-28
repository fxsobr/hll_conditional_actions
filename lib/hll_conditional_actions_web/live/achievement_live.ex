defmodule HllConditionalActionsWeb.AchievementLive do
  @moduledoc """
  The achievements gallery: every achievement with what it asks for, what it
  gives and how many players have it, the latest unlocks, and the form to
  create or change one.

  Achievements are counted at the end of every match by
  `HllConditionalActions.Progression`; this page only defines them. They
  belong to a server, so the page lives under `/servers/:server_id`; the old
  `/achievements` address sends to the first server.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_progression}}

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Progression
  alias HllConditionalActions.Progression.Achievement
  alias HllConditionalActions.Progression.Metrics
  alias HllConditionalActions.Progression.Preview
  alias HllConditionalActions.Servers

  @icons ~w(hero-trophy hero-fire hero-viewfinder-circle hero-heart hero-truck hero-shield-check
            hero-bolt hero-megaphone hero-user-group hero-clock hero-star hero-flag hero-sparkles)

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
         |> assign(:page_title, gettext("Achievements"))
         |> assign(:server, server)
         |> assign(:base, base(server))
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
    params = Map.put(params, "server_id", socket.assigns.server.id)

    result =
      if socket.assigns.achievement.id,
        do: Progression.update_achievement(socket.assigns.achievement, params),
        else: Progression.create_achievement(params)

    case result do
      {:ok, achievement} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Achievement \"%{name}\" saved.", name: achievement.name))
         |> load()
         |> push_patch(to: socket.assigns.base)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

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

  defp load(socket) do
    server_id = socket.assigns.server.id
    achievements = Progression.list_achievements(server_id)

    socket
    |> assign(:achievements, achievements)
    |> assign(:recent, Progression.recent_unlocks(server_id))
    |> assign(:players, Progression.players_with_achievements(server_id))
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

  @impl Phoenix.LiveView
  def render(assigns) do
    render_page(assigns)
  end

  attr :draft, :any, required: true
  attr :preview, :any, required: true

  defp achievement_preview(assigns) do
    ~H"""
    <div id="achievement-preview" class="preview-panel space-y-3">
      <p class="preview-eyebrow"><span class="live-dot"></span>{gettext("Live preview")}</p>

      <div class="achievement-card" data-tier={@draft.tier}>
        <span class="achievement-medal">
          <.icon name={@draft.icon || "hero-trophy"} class="size-5" />
        </span>
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-1.5">
            <p class="truncate font-medium">{blank(@draft.name, gettext("Achievement name"))}</p>
            <span class="achievement-tier">{Labels.tier(@draft.tier)}</span>
          </div>
          <p :if={@draft.metric && @draft.threshold} class="text-xs text-subtle">
            {Labels.achievement_goal(@draft)}
          </p>
        </div>
      </div>

      <%= case @preview do %>
        <% :incomplete -> %>
          <p class="text-sm text-muted">
            {gettext("Pick a metric and a goal to see who reaches it.")}
          </p>
        <% :loading -> %>
          <p class="text-xs text-muted">{gettext("Reading the last matches from CRCON...")}</p>
          <div class="h-2 animate-pulse rounded-pill bg-base-200"></div>
        <% %{seen: 0} = preview -> %>
          <p class="text-sm text-muted">
            {if preview.source == :career,
              do: gettext("No career recorded on this server yet."),
              else: gettext("No finished match in CRCON's history yet.")}
          </p>
        <% preview -> %>
          <div>
            <p class="text-2xl font-semibold tabular-nums">
              {preview.count}
              <span class="text-sm font-normal text-muted">
                / {ngettext("1 player", "%{count} players", preview.seen)}
              </span>
            </p>
            <p class="text-xs text-muted">
              {if preview.source == :career,
                do: gettext("would already have it, from their career on the server"),
                else:
                  ngettext(
                    "would have unlocked it in the last match",
                    "would have unlocked it in the last %{count} matches",
                    preview.matches
                  )}
            </p>
          </div>
          <div class="preview-meter" role="img" aria-label={difficulty(preview.share)}>
            <span style={"width: #{max(round(preview.share * 100), 1)}%"}></span>
          </div>
          <p class="flex items-center gap-1.5 text-xs font-medium">
            <.icon name={difficulty_icon(preview.share)} class="size-4 text-primary" />
            {difficulty(preview.share)}
          </p>
          <p :if={preview.names != []} class="text-xs text-subtle">
            {Enum.join(preview.names, ", ")}{if preview.count > length(preview.names), do: "..."}
          </p>
          <p class="text-xs text-muted">
            {gettext("Best seen: %{value}", value: preview.best)}
          </p>
      <% end %>

      <div :if={@draft.name not in [nil, ""]}>
        <p class="mb-1 text-xs font-medium text-muted">{gettext("What the player gets in game")}</p>
        <p class="message-preview">
          {HllConditionalActions.Crcon.GameText.clean(Progression.unlock_message(@draft))}
        </p>
        <p
          :if={HllConditionalActions.Crcon.GameText.changes?(Progression.unlock_message(@draft))}
          class="mt-1 flex items-center gap-1 text-xs text-warning"
        >
          <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0" />
          {gettext("The game cannot show emoji or special symbols: they are removed.")}
        </p>
      </div>
    </div>
    """
  end

  defp blank(value, fallback) when value in [nil, ""], do: fallback
  defp blank(value, _fallback), do: value

  defp difficulty(share) when share == 0, do: gettext("Nobody reached it: maybe out of reach")
  defp difficulty(share) when share < 0.02, do: gettext("Very rare")
  defp difficulty(share) when share < 0.1, do: gettext("Rare")
  defp difficulty(share) when share < 0.35, do: gettext("Within reach of the good ones")
  defp difficulty(_share), do: gettext("Common: most players get it")

  defp difficulty_icon(share) when share < 0.02, do: "hero-fire"
  defp difficulty_icon(share) when share < 0.35, do: "hero-star"
  defp difficulty_icon(_share), do: "hero-user-group"

  defp render_page(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      page_subtitle={gettext("Goals players reach by playing, counted at the end of every match")}
    >
      <:actions>
        <.button
          :if={Accounts.can?(@current_user, :manage_progression)}
          link_type="live_patch"
          to={@base <> "/new"}
          size="sm"
          color="primary"
          icon="hero-plus"
          label={gettext("New achievement")}
        />
      </:actions>

      <div id="achievement-kpis" class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <.stat
          icon="hero-trophy"
          tone="primary"
          label={gettext("Achievements")}
          value={Enum.count(@achievements, & &1.enabled)}
          hint={gettext("enabled")}
        />
        <.stat
          icon="hero-sparkles"
          tone="warning"
          label={gettext("Unlocks")}
          value={Enum.sum_by(@achievements, & &1.unlocked_count)}
          hint={gettext("since the first match counted")}
        />
        <.stat
          icon="hero-users"
          label={gettext("Players")}
          value={@players}
          hint={gettext("with at least one achievement")}
        />
        <.stat
          icon="hero-beaker"
          tone="info"
          label={gettext("In simulation")}
          value={Enum.count(@achievements, & &1.simulation)}
          hint={gettext("recorded, no reward sent")}
        />
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
        <:action>
          <.button
            :if={Accounts.can?(@current_user, :manage_progression)}
            type="button"
            size="sm"
            color="primary"
            icon="hero-sparkles"
            phx-click="starter_set"
            label={gettext("Add the starter set")}
          />
        </:action>
      </.empty_state>

      <div :if={@achievements != []} class="grid gap-4 xl:grid-cols-3">
        <div class="xl:col-span-2">
          <.card title={gettext("Gallery")} icon="hero-trophy">
            <ul id="achievements" class="grid gap-3 sm:grid-cols-2">
              <li
                :for={achievement <- @achievements}
                id={"achievement-#{achievement.id}"}
                class={["achievement-card", not achievement.enabled && "opacity-60"]}
                data-tier={achievement.tier}
              >
                <span class="achievement-medal">
                  <.icon name={achievement.icon} class="size-5" />
                </span>
                <div class="min-w-0 flex-1">
                  <div class="flex flex-wrap items-center gap-1.5">
                    <p class="truncate font-medium">{achievement.name}</p>
                    <span class="achievement-tier">{Labels.tier(achievement.tier)}</span>
                  </div>
                  <p class="text-xs text-subtle">{Labels.achievement_goal(achievement)}</p>
                  <p :if={achievement.description} class="mt-1 line-clamp-2 text-xs text-muted">
                    {achievement.description}
                  </p>
                  <div class="mt-2 flex flex-wrap items-center gap-1.5 text-[0.6875rem]">
                    <span
                      :if={achievement.reward_vip_hours > 0}
                      class="rounded-pill bg-primary/10 px-2 py-0.5 font-medium text-primary"
                    >
                      VIP {achievement.reward_vip_hours}h
                    </span>
                    <span
                      :if={achievement.reward_flag not in [nil, ""]}
                      class="rounded-pill bg-base-200 px-2 py-0.5"
                    >
                      {achievement.reward_flag}
                    </span>
                    <span
                      :if={achievement.simulation}
                      class="rounded-pill bg-warning/15 px-2 py-0.5 text-warning"
                    >
                      {gettext("Simulation")}
                    </span>
                    <span :if={not achievement.enabled} class="rounded-pill bg-base-200 px-2 py-0.5">
                      {gettext("Off")}
                    </span>
                    <span class="ml-auto text-muted">
                      {ngettext("1 player", "%{count} players", achievement.unlocked_count)}
                    </span>
                  </div>
                </div>

                <.row_menu
                  :if={Accounts.can?(@current_user, :manage_progression)}
                  id={"achievement-menu-#{achievement.id}"}
                >
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
              </li>
            </ul>
          </.card>
        </div>

        <.card title={gettext("Latest unlocks")} icon="hero-sparkles" id="achievement-unlocks">
          <p :if={@recent == []} class="py-6 text-center text-sm text-muted">
            {gettext("Nothing unlocked yet. Achievements are counted when a match ends.")}
          </p>
          <ul :if={@recent != []} class="-my-1 divide-y divide-base-300">
            <li :for={unlock <- @recent} class="flex items-center gap-2.5 py-2">
              <span class="text-lg" aria-hidden="true">
                {Progression.tier_mark(unlock.achievement.tier)}
              </span>
              <div class="min-w-0 flex-1">
                <.link
                  navigate={~p"/players/#{unlock.player_id}"}
                  class="block truncate text-sm font-medium hover:underline"
                >
                  {unlock.player_name || unlock.player_id}
                </.link>
                <p class="truncate text-xs text-muted">
                  {unlock.achievement.name}
                  <span :if={unlock.simulated}>· {gettext("simulated")}</span>
                </p>
              </div>
              <.local_time
                id={"unlock-#{unlock.id}-at"}
                at={unlock.unlocked_at}
                class="shrink-0 text-xs text-muted"
              />
            </li>
          </ul>
        </.card>
      </div>

      <.modal
        :if={@form}
        id="achievement-modal"
        title={if @achievement.id, do: gettext("Edit achievement"), else: gettext("New achievement")}
        subtitle={
          gettext("Counted at the end of every match. Start in simulation to see who would get it.")
        }
        on_cancel={JS.patch(@base)}
        class="max-w-4xl"
      >
        <.form for={@form} id="achievement-form" phx-change="validate" phx-submit="save">
          <div class="form-with-preview">
            <div class="min-w-0 space-y-3">
              <.input field={@form[:name]} type="text" label={gettext("Name")} required />
              <.input
                field={@form[:description]}
                type="textarea"
                rows="2"
                label={gettext("Description")}
                help_text={gettext("Shown to the player in game, in your server's language.")}
              />

              <div class="grid gap-3 sm:grid-cols-2">
                <.input
                  field={@form[:scope]}
                  type="select"
                  label={gettext("Counted")}
                  options={Enum.map([:match, :career], &{Labels.achievement_scope(&1), &1})}
                />
                <.input
                  field={@form[:metric]}
                  type="select"
                  label={gettext("Metric")}
                  options={Labels.metric_options(metrics_for(@form))}
                />
                <.input
                  field={@form[:threshold]}
                  type="number"
                  min="1"
                  label={gettext("Goal")}
                  required
                />
                <.input
                  field={@form[:tier]}
                  type="select"
                  label={gettext("Tier")}
                  options={Enum.map(Achievement.tiers(), &{Labels.tier(&1), &1})}
                />
              </div>

              <fieldset>
                <legend class="mb-1.5 text-sm font-medium">{gettext("Icon")}</legend>
                <div class="flex flex-wrap gap-1.5">
                  <label :for={icon <- icons()} class="cursor-pointer">
                    <input
                      type="radio"
                      name={@form[:icon].name}
                      value={icon}
                      checked={to_string(@form[:icon].value || "hero-trophy") == icon}
                      class="peer sr-only"
                    />
                    <span class="flex size-9 items-center justify-center rounded-field border border-base-300 text-subtle transition-colors peer-checked:border-primary peer-checked:bg-primary/10 peer-checked:text-primary">
                      <.icon name={icon} class="size-4" />
                    </span>
                  </label>
                </div>
              </fieldset>

              <p class="border-t border-base-300 pt-3 text-xs font-medium tracking-wide text-muted uppercase">
                {gettext("Reward")}
              </p>
              <div class="grid gap-3 sm:grid-cols-2">
                <.input
                  field={@form[:reward_vip_hours]}
                  type="number"
                  min="0"
                  label={gettext("VIP (hours)")}
                  help_text={gettext("Zero gives no VIP.")}
                />
                <.input
                  field={@form[:reward_flag]}
                  type="text"
                  label={gettext("Flag on the CRCON profile")}
                  placeholder="🏅"
                  help_text={gettext("Only on the CRCON profile: the game itself never shows it.")}
                />
              </div>

              <div class="space-y-2">
                <.input
                  field={@form[:announce]}
                  type="checkbox"
                  label={gettext("Announce to everybody in game")}
                />
                <.input
                  field={@form[:simulation]}
                  type="checkbox"
                  label={gettext("Simulation: record who unlocks it, send nothing")}
                />
                <.input field={@form[:enabled]} type="checkbox" label={gettext("Enabled")} />
              </div>

              <div class="flex justify-end gap-2 pt-2">
                <.button
                  link_type="live_patch"
                  to={@base}
                  variant="outline"
                  color="gray"
                  label={gettext("Cancel")}
                />
                <.button
                  type="submit"
                  color="primary"
                  icon="hero-check"
                  phx-disable-with={gettext("Saving...")}
                  label={gettext("Save")}
                />
              </div>
            </div>
            <aside class="form-preview-aside">
              <.achievement_preview draft={@draft} preview={@preview} />
            </aside>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end

  defp icons, do: @icons

  # A match can only reach the match metrics; a career can count them all.
  defp metrics_for(form) do
    case to_string(form[:scope].value) do
      "career" -> Metrics.all()
      _match -> Metrics.match()
    end
  end
end
