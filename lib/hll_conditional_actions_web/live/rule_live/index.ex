defmodule HllConditionalActionsWeb.RuleLive.Index do
  @moduledoc """
  Lists rules with filters for game, server and state, and hosts import and
  export.

  A user restricted to certain servers sees their own rules plus the
  fleet-wide rules that reach their servers; the latter are marked read only,
  since changing one would affect servers they do not administer.
  """

  use HllConditionalActionsWeb, :live_view

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_rules}}

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Games
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Health
  alias HllConditionalActions.Rules.Recipes
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.RuleBuilder
  alias HllConditionalActionsWeb.RulePause
  alias HllConditionalActionsWeb.Ui

  import HllConditionalActionsWeb.RulePause,
    only: [pause_menu_items: 1, pause_note: 1, pause_modal: 1]

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    servers = Servers.list_servers_for(socket.assigns[:current_user])

    {:ok,
     socket
     |> assign(:page_title, gettext("Rules"))
     |> assign(:servers, servers)
     # Under /servers/:id the list is that server's: its own rules and the
     # fleet wide ones of its game.
     |> assign(:scope, Enum.find(servers, &(to_string(&1.id) == params["server_id"])))
     |> assign(:filters, %{game: nil, server_id: nil, enabled: nil, search: "", group: ""})
     |> assign(:import_open?, false)
     |> assign(:import_json, "")
     |> assign(:import_preview, nil)
     |> assign(:import_error, nil)
     |> assign(:import_server_id, "")
     |> allow_upload(:import_file,
       accept: ~w(.json),
       max_entries: 1,
       max_file_size: 2_000_000,
       auto_upload: true,
       progress: &handle_import_file/3
     )
     |> assign(:recipes_open?, false)
     |> assign(:pause_rule, nil)
     |> assign(:sort, "priority")
     |> assign(:selected, MapSet.new())
     |> load_rules()}
  end

  @impl Phoenix.LiveView
  def handle_event("filter", params, socket) do
    filters = %{
      game: cast_game(params["game"]),
      server_id: cast_integer(params["server_id"]),
      enabled: cast_enabled(params["enabled"]),
      search: String.trim(params["search"] || ""),
      group: params["group"] || ""
    }

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:sort, cast_sort(params["sort"]))
     |> load_rules()}
  end

  def handle_event("clear_filters", _params, socket) do
    filters = %{game: nil, server_id: nil, enabled: nil, search: "", group: ""}
    {:noreply, socket |> assign(:filters, filters) |> load_rules()}
  end

  # ── Selection and bulk actions ─────────────────────────────────────────────

  def handle_event("select", %{"id" => id}, socket) do
    id = cast_integer(id)
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("select_all", _params, socket) do
    selectable = selectable_ids(socket.assigns)

    selected =
      if MapSet.subset?(selectable, socket.assigns.selected) and selectable != MapSet.new(),
        do: MapSet.new(),
        else: selectable

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected, MapSet.new())}
  end

  def handle_event("bulk", %{"op" => op} = params, socket) do
    operation =
      case op do
        "enable" -> {:enabled, true}
        "disable" -> {:enabled, false}
        "group" -> {:group, params["group"] || ""}
        "delete" -> :delete
        _other -> nil
      end

    with :ok <- authorize(socket), true <- not is_nil(operation) do
      rules = selected_rules(socket)
      count = Rules.bulk_update(rules, operation, actor: socket.assigns.current_user)

      {:noreply,
       socket
       |> assign(:selected, MapSet.new())
       |> put_flash(:info, bulk_message(operation, count))
       |> load_rules()}
    else
      _denied -> {:noreply, deny(socket)}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with :ok <- authorize(socket, id) do
      {:ok, _rule} =
        id |> Rules.get_rule!() |> Rules.toggle_rule(actor: socket.assigns.current_user)

      {:noreply, load_rules(socket)}
    else
      _denied -> {:noreply, deny(socket)}
    end
  end

  def handle_event("duplicate", %{"id" => id}, socket) do
    with :ok <- authorize(socket, id) do
      case id
           |> Rules.get_rule!()
           |> Rules.duplicate_rule(gettext("(copy)"), actor: socket.assigns.current_user) do
        {:ok, _rule} ->
          {:noreply, socket |> put_flash(:info, gettext("Rule duplicated.")) |> load_rules()}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Could not duplicate that rule."))}
      end
    else
      _denied -> {:noreply, deny(socket)}
    end
  end

  def handle_event("toggle_group", %{"group" => group, "enabled" => enabled}, socket) do
    with :ok <- authorize(socket) do
      moved =
        Rules.set_group_enabled(group, enabled == "true", actor: socket.assigns.current_user)

      {:noreply,
       socket
       |> put_flash(
         :info,
         ngettext("%{count} rule updated.", "%{count} rules updated.", moved, count: moved)
       )
       |> load_rules()}
    else
      _denied -> {:noreply, deny(socket)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with :ok <- authorize(socket, id) do
      {:ok, _rule} =
        id |> Rules.get_rule!() |> Rules.delete_rule(actor: socket.assigns.current_user)

      {:noreply, socket |> put_flash(:info, gettext("Rule removed.")) |> load_rules()}
    else
      _denied -> {:noreply, deny(socket)}
    end
  end

  def handle_event("pause", params, socket) do
    id = params["id"] || params["rule_id"]

    with :ok <- authorize(socket, id) do
      case id |> Rules.get_rule!() |> RulePause.run(params, socket.assigns.current_user) do
        {:ok, _rule, message} ->
          {:noreply,
           socket |> assign(:pause_rule, nil) |> put_flash(:info, message) |> load_rules()}

        {:error, message} ->
          {:noreply, put_flash(socket, :error, message)}
      end
    else
      _denied -> {:noreply, deny(socket)}
    end
  end

  def handle_event("open_pause", %{"id" => id}, socket) do
    {:noreply,
     assign(socket, :pause_rule, Enum.find(socket.assigns.rules, &(to_string(&1.id) == id)))}
  end

  def handle_event("close_pause", _params, socket) do
    {:noreply, assign(socket, :pause_rule, nil)}
  end

  def handle_event("open_recipes", _params, socket) do
    {:noreply, assign(socket, :recipes_open?, true)}
  end

  def handle_event("close_recipes", _params, socket) do
    {:noreply, assign(socket, :recipes_open?, false)}
  end

  # ── Import ─────────────────────────────────────────────────────────────────

  def handle_event("open_import", _params, socket) do
    {:noreply, assign(socket, :import_open?, true)}
  end

  def handle_event("close_import", _params, socket) do
    {:noreply,
     socket
     |> assign(:import_open?, false)
     |> assign(:import_json, "")
     |> assign(:import_preview, nil)
     |> assign(:import_error, nil)}
  end

  def handle_event("preview_import", %{"json" => json} = params, socket) do
    socket =
      socket |> assign(:import_json, json) |> assign(:import_server_id, params["server_id"] || "")

    preview_json(socket, json)
  end

  def handle_event("confirm_import", _params, socket) do
    with :ok <- authorize(socket) do
      opts =
        [enabled: false] ++
          case socket.assigns.import_server_id do
            "" -> []
            id -> [server_id: id]
          end

      case Rules.import_rules(socket.assigns.import_json, opts) do
        {:ok, rules} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             ngettext(
               "Imported %{count} rule, disabled so you can review it.",
               "Imported %{count} rules, disabled so you can review them.",
               length(rules),
               count: length(rules)
             )
           )
           |> assign(:import_open?, false)
           |> assign(:import_json, "")
           |> assign(:import_preview, nil)
           |> load_rules()}

        {:error, index, changeset} ->
          {:noreply,
           assign(
             socket,
             :import_error,
             gettext("Rule %{number} is not valid: %{errors}",
               number: index + 1,
               errors: describe_errors(changeset)
             )
           )}

        {:error, message} ->
          {:noreply, assign(socket, :import_error, message)}
      end
    else
      _denied -> {:noreply, deny(socket)}
    end
  end

  defp describe_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&HllConditionalActionsWeb.CoreComponents.translate_error/1)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{join_errors(errors)}" end)
  end

  defp join_errors(errors) when is_list(errors) do
    if Enum.all?(errors, &is_binary/1), do: Enum.join(errors, ", "), else: inspect(errors)
  end

  defp join_errors(errors), do: inspect(errors)

  defp load_rules(socket) do
    user = socket.assigns[:current_user]
    scope = if socket.assigns.scope, do: [applies_to: socket.assigns.scope], else: []
    rules = Rules.list_rules_for(user, Enum.to_list(socket.assigns.filters) ++ scope)
    servers = socket.assigns.servers
    activity = Rules.activity_for_rules(Enum.map(rules, & &1.id))
    editable = Map.new(rules, &{&1.id, Rules.editable_by?(&1, user)})

    socket
    |> assign(:rules, sort_rules(rules, socket.assigns.sort, activity))
    |> assign(:editable, editable)
    |> assign(:health, Health.for_rules(rules, servers))
    |> assign(:activity, activity)
    |> assign(:groups, Rules.list_groups(user))
    # A selection only ever holds rules that are on screen and editable, so a
    # filter change can never leave a hidden rule in the next bulk action.
    |> update(:selected, fn selected ->
      MapSet.filter(selected, &Map.get(editable, &1, false))
    end)
  end

  @sorts ~w(priority name last_fired failures activity)

  defp cast_sort(sort) when sort in @sorts, do: sort
  defp cast_sort(_sort), do: "priority"

  defp sort_options do
    [
      {gettext("Priority"), "priority"},
      {gettext("Name"), "name"},
      {gettext("Last fired"), "last_fired"},
      {gettext("Most failures (24h)"), "failures"},
      {gettext("Most active (24h)"), "activity"}
    ]
  end

  # The query already orders by priority then name, which every other sort
  # keeps as its tie breaker (Enum.sort_by is stable).
  defp sort_rules(rules, "priority", _activity), do: rules

  defp sort_rules(rules, "name", _activity),
    do: Enum.sort_by(rules, &String.downcase(&1.name))

  defp sort_rules(rules, "last_fired", activity) do
    # Never fired sorts last, not first.
    Enum.sort_by(
      rules,
      fn rule ->
        case activity[rule.id] do
          %{last_executed_at: %DateTime{} = at} -> -DateTime.to_unix(at, :microsecond)
          _never -> 0
        end
      end
    )
  end

  defp sort_rules(rules, "failures", activity),
    do: Enum.sort_by(rules, &(-(get_in(activity, [&1.id, :failed_24h]) || 0)))

  defp sort_rules(rules, "activity", activity),
    do: Enum.sort_by(rules, &(-(get_in(activity, [&1.id, :last_24h]) || 0)))

  defp selectable_ids(assigns) do
    if Accounts.can?(assigns.current_user, :manage_rules) do
      for rule <- assigns.rules, assigns.editable[rule.id], into: MapSet.new(), do: rule.id
    else
      MapSet.new()
    end
  end

  # Re-checked against the database: the selection came from the browser.
  defp selected_rules(socket) do
    user = socket.assigns.current_user
    ids = MapSet.to_list(socket.assigns.selected)

    user
    |> Rules.list_rules_for(ids: ids)
    |> Enum.filter(&Rules.editable_by?(&1, user))
  end

  defp bulk_message({:enabled, true}, count),
    do: ngettext("%{count} rule enabled.", "%{count} rules enabled.", count, count: count)

  defp bulk_message({:enabled, false}, count),
    do: ngettext("%{count} rule disabled.", "%{count} rules disabled.", count, count: count)

  defp bulk_message({:group, _group}, count),
    do: ngettext("%{count} rule moved.", "%{count} rules moved.", count, count: count)

  defp bulk_message(:delete, count),
    do: ngettext("%{count} rule removed.", "%{count} rules removed.", count, count: count)

  defp selection_export_path(selected) do
    "/rules/export?" <> URI.encode_query(ids: Enum.map_join(selected, ",", &to_string/1))
  end

  defp authorize(socket) do
    if Accounts.can?(socket.assigns.current_user, :manage_rules), do: :ok, else: :error
  end

  # Changing a specific rule also requires it to be within the user's servers.
  defp authorize(socket, rule_id) do
    with :ok <- authorize(socket) do
      rule = Rules.get_rule!(rule_id)
      if Rules.editable_by?(rule, socket.assigns.current_user), do: :ok, else: :error
    end
  end

  defp deny(socket) do
    put_flash(socket, :error, gettext("You do not have permission to change rules."))
  end

  defp cast_game(""), do: nil

  defp cast_game(value) do
    case Games.cast(value) do
      {:ok, game} -> game
      :error -> nil
    end
  end

  defp cast_integer(nil), do: nil
  defp cast_integer(""), do: nil

  defp cast_integer(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp cast_enabled("true"), do: true
  defp cast_enabled("false"), do: false
  defp cast_enabled(_value), do: nil

  defp scope_label(%{server: %{name: name}}), do: name
  defp scope_label(_rule), do: gettext("Every server")

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Rules")}
      page_subtitle={
        ngettext("%{count} rule", "%{count} rules", length(@rules), count: length(@rules))
      }
    >
      <:actions>
        <.button
          link_type="a"
          to={export_path(@filters)}
          download
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-arrow-down-tray"
        >
          <span class="hidden sm:inline">{gettext("Export")}</span>
        </.button>

        <.button
          :if={Accounts.can?(@current_user, :manage_rules) and @servers != []}
          type="button"
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-arrow-up-tray"
          phx-click="open_import"
        >
          <span class="hidden sm:inline">{gettext("Import")}</span>
        </.button>

        <.button
          :if={@servers != []}
          link_type="live_redirect"
          to={~p"/rules/simulate"}
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-beaker"
        >
          <span class="hidden sm:inline">{gettext("Simulate an event")}</span>
        </.button>

        <.button
          :if={Accounts.can?(@current_user, :manage_rules) and @servers != []}
          type="button"
          size="sm"
          variant="outline"
          color="gray"
          icon="hero-sparkles"
          phx-click="open_recipes"
        >
          <span class="hidden sm:inline">{gettext("Recipes")}</span>
        </.button>

        <.button
          :if={Accounts.can?(@current_user, :manage_rules) and @servers != []}
          link_type="live_redirect"
          to={if @scope, do: ~p"/rules/new?#{[server_id: @scope.id]}", else: ~p"/rules/new"}
          size="sm"
          color="primary"
          icon="hero-plus"
          aria-label={gettext("New rule")}
        >
          <span class="hidden sm:inline">{gettext("New rule")}</span>
        </.button>
      </:actions>

      <div
        :if={@rules != [] or filtered?(@filters)}
        id="rule-kpis"
        class="grid grid-cols-2 gap-3 sm:gap-4 xl:grid-cols-4"
      >
        <.stat
          icon="hero-bolt"
          label={gettext("Rules")}
          value={length(@rules)}
          hint={gettext("matching the filters")}
        />
        <.stat
          icon="hero-play"
          tone="success"
          label={gettext("Live")}
          value={Enum.count(@rules, &(&1.enabled and not &1.simulation))}
          hint={gettext("acting on the game")}
        />
        <.stat
          icon="hero-beaker"
          tone="warning"
          label={gettext("Simulating")}
          value={Enum.count(@rules, &(&1.enabled and &1.simulation))}
          hint={gettext("recording only")}
        />
        <.stat
          icon="hero-heart"
          tone={
            if Enum.any?(@health, fn {_id, issues} -> issues != [] end), do: "error", else: "neutral"
          }
          label={gettext("Need attention")}
          value={Enum.count(@health, fn {_id, issues} -> issues != [] end)}
          hint={gettext("see the notes on each rule")}
        />
      </div>

      <.filter_bar id="rule-filters" on_change="filter">
        <label class="max-sm:grow">
          <span class="sr-only">{gettext("Search rules")}</span>
          <input
            type="search"
            name="search"
            value={@filters.search}
            placeholder={gettext("Search by name")}
            class="pc-text-input w-full sm:w-56"
            phx-debounce="300"
          />
        </label>

        <.filter_select
          :if={is_nil(@scope)}
          name="game"
          label={gettext("Game")}
          value={@filters.game}
          prompt={gettext("Every game")}
          options={Labels.game_options()}
        />
        <.filter_select
          :if={is_nil(@scope)}
          name="server_id"
          label={gettext("Server")}
          value={@filters.server_id}
          prompt={gettext("Every server")}
          options={Enum.map(@servers, &{&1.name, &1.id})}
        />
        <.filter_select
          :if={@groups != []}
          name="group"
          label={gettext("Group")}
          value={@filters.group}
          prompt={gettext("Every group")}
          options={Enum.map(@groups, &{&1, &1})}
        />
        <.filter_select
          name="enabled"
          label={gettext("State")}
          value={@filters.enabled}
          prompt={gettext("Any state")}
          options={[{gettext("Enabled"), "true"}, {gettext("Disabled"), "false"}]}
        />
        <label>
          <span class="sr-only">{gettext("Sort by")}</span>
          <select id="rule-sort" name="sort" class="pc-select max-sm:w-full">
            {Phoenix.HTML.Form.options_for_select(sort_options(), @sort)}
          </select>
        </label>

        <:clear>
          <.button
            :if={filtered?(@filters)}
            type="button"
            size="sm"
            variant="ghost"
            color="gray"
            icon="hero-x-mark"
            phx-click="clear_filters"
            label={gettext("Clear")}
          />
        </:clear>
      </.filter_bar>

      <div
        :if={@filters.group not in [nil, ""] and Accounts.can?(@current_user, :manage_rules)}
        class="flex flex-wrap items-center justify-between gap-2 rounded-box bg-base-100 p-3 shadow-figma-card"
      >
        <p class="text-body-small text-muted">
          {gettext("Acting on the whole group %{group}.", group: @filters.group)}
        </p>

        <div class="flex items-center gap-2">
          <.button
            type="button"
            size="xs"
            variant="outline"
            color="gray"
            phx-click="toggle_group"
            phx-value-group={@filters.group}
            phx-value-enabled="true"
            label={gettext("Enable all")}
          />
          <.button
            type="button"
            size="xs"
            variant="outline"
            color="gray"
            phx-click="toggle_group"
            phx-value-group={@filters.group}
            phx-value-enabled="false"
            data-confirm={gettext("Disable every rule in %{group}?", group: @filters.group)}
            label={gettext("Disable all")}
          />
        </div>
      </div>

      <%!-- Without a server a rule has nowhere to run, so the page points at
            the step that is actually missing instead of offering recipes. --%>
      <.empty_state
        :if={@rules == [] and @servers == []}
        icon="hero-server-stack"
        title={gettext("Connect a server first")}
        description={
          gettext(
            "Rules run on a CRCON server. Once one is connected, you can start from a recipe that is already filled in for it."
          )
        }
      >
        <:action>
          <.button
            :if={Accounts.can?(@current_user, :manage_servers)}
            link_type="live_redirect"
            to={~p"/servers/new?from=onboarding"}
            size="sm"
            color="primary"
            icon="hero-plus"
            label={gettext("Connect a server")}
          />
        </:action>
      </.empty_state>

      <.empty_state
        :if={@rules == [] and @servers != []}
        icon="hero-bolt-slash"
        title={
          if filtered?(@filters),
            do: gettext("No rules match these filters."),
            else: gettext("No rules yet")
        }
        description={
          gettext(
            "A rule watches for something happening on your server and answers it: a warning, a switch, a kick."
          )
        }
      >
        <:action>
          <.button
            :if={Accounts.can?(@current_user, :manage_rules) and not filtered?(@filters)}
            type="button"
            size="sm"
            color="primary"
            icon="hero-sparkles"
            phx-click="open_recipes"
            label={gettext("Start from a recipe")}
          />
        </:action>
      </.empty_state>

      <%!-- The first rule is the hardest to write, so the empty page leads with
            the recipes most communities start from, each opening its short
            wizard. --%>
      <section
        :if={
          @rules == [] and @servers != [] and not filtered?(@filters) and
            Accounts.can?(@current_user, :manage_rules)
        }
        id="empty-recipes"
        class="space-y-3"
      >
        <h2 class="text-title-medium">{gettext("Popular starting points")}</h2>
        <ul class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
          <li :for={recipe <- featured_recipes()}>
            <.link
              navigate={~p"/rules/new?recipe=#{recipe.id}"}
              class="flex h-full items-start gap-3 rounded-box border border-base-300 bg-base-100 p-4 transition hover:-translate-y-0.5 hover:border-primary/50 hover:shadow-sm"
            >
              <span class={[
                "flex size-14 shrink-0 items-center justify-center rounded-box",
                recipe_tone(recipe.tone)
              ]}>
                <.recipe_art id={recipe.id} class="size-10" />
              </span>
              <span class="min-w-0">
                <span class="block text-title-medium">{Labels.recipe_name(recipe.id)}</span>
                <span class="mt-0.5 block text-body-small text-muted">
                  {Labels.recipe_description(recipe.id)}
                </span>
              </span>
            </.link>
          </li>
        </ul>
      </section>

      <%!-- One row per rule, purpose built rather than a generic table: a rule
            is a sentence (when / if / then) plus a state, and a table turned
            that into four disconnected columns that collapsed badly on a
            phone. --%>
      <div
        :if={@rules != [] and MapSet.size(selectable_ids(assigns)) > 0}
        class="flex items-center gap-2 px-1"
      >
        <input
          id="rule-select-all"
          type="checkbox"
          class="pc-checkbox"
          checked={MapSet.size(@selected) > 0 and MapSet.subset?(selectable_ids(assigns), @selected)}
          phx-click="select_all"
          aria-label={gettext("Select every rule shown")}
        />
        <label for="rule-select-all" class="cursor-pointer text-label-small text-muted">
          {gettext("Select all")}
        </label>
      </div>

      <%!-- The bulk bar floats over the list while something is selected: a
            power admin tidying thirty rules should not have to open thirty
            menus. It sits above the phone's bottom navigation. --%>
      <div
        :if={MapSet.size(@selected) > 0}
        id="rule-bulk-bar"
        role="region"
        aria-label={gettext("Bulk actions")}
        class="sticky bottom-20 z-20 flex flex-wrap items-center gap-2 rounded-box border border-primary/30 bg-base-100 p-3 shadow-lg lg:bottom-4"
      >
        <span class="text-body-small font-medium">
          {ngettext("%{count} selected", "%{count} selected", MapSet.size(@selected),
            count: MapSet.size(@selected)
          )}
        </span>

        <.button
          id="bulk-enable"
          type="button"
          size="xs"
          variant="outline"
          color="gray"
          icon="hero-play"
          phx-click="bulk"
          phx-value-op="enable"
          label={gettext("Enable")}
        />
        <.button
          id="bulk-disable"
          type="button"
          size="xs"
          variant="outline"
          color="gray"
          icon="hero-stop"
          phx-click="bulk"
          phx-value-op="disable"
          data-confirm={
            ngettext("Disable %{count} rule?", "Disable %{count} rules?", MapSet.size(@selected),
              count: MapSet.size(@selected)
            )
          }
          label={gettext("Disable")}
        />

        <form id="bulk-group-form" phx-submit="bulk" class="flex items-center gap-1">
          <input type="hidden" name="op" value="group" />
          <label for="bulk-group" class="sr-only">{gettext("Move to group")}</label>
          <input
            id="bulk-group"
            type="text"
            name="group"
            list="bulk-group-options"
            placeholder={gettext("Group")}
            autocomplete="off"
            class="pc-text-input h-8 min-h-8 w-32 py-1"
          />
          <datalist id="bulk-group-options">
            <option :for={group <- @groups} value={group} />
          </datalist>
          <.button
            type="submit"
            size="xs"
            variant="outline"
            color="gray"
            icon="hero-folder-arrow-down"
            label={gettext("Move")}
          />
        </form>

        <.button
          id="bulk-export"
          link_type="a"
          to={selection_export_path(@selected)}
          download
          size="xs"
          variant="outline"
          color="gray"
          icon="hero-arrow-down-tray"
          label={gettext("Export")}
        />
        <.button
          id="bulk-delete"
          type="button"
          size="xs"
          variant="outline"
          color="danger"
          icon="hero-trash"
          phx-click="bulk"
          phx-value-op="delete"
          data-confirm={
            ngettext(
              "Remove %{count} rule and its history? This cannot be undone.",
              "Remove %{count} rules and their history? This cannot be undone.",
              MapSet.size(@selected),
              count: MapSet.size(@selected)
            )
          }
          label={gettext("Remove")}
        />

        <.button
          id="bulk-clear"
          type="button"
          size="xs"
          variant="ghost"
          color="gray"
          icon="hero-x-mark"
          class="ml-auto"
          phx-click="clear_selection"
          label={gettext("Clear")}
        />
      </div>

      <ul :if={@rules != []} id="rule-list" class="space-y-2">
        <li
          :for={rule <- @rules}
          id={"rule-#{rule.id}"}
          class={[
            "rounded-box bg-base-100 shadow-figma-card transition-shadow hover:shadow-figma-card-medium",
            "border-l-4",
            rule_rail(rule)
          ]}
        >
          <div class={[
            "flex flex-wrap items-start gap-x-4 gap-y-3 p-4",
            not rule.enabled && "opacity-70"
          ]}>
            <div class="flex min-w-0 flex-1 items-start gap-3">
              <input
                :if={Accounts.can?(@current_user, :manage_rules) and @editable[rule.id]}
                id={"rule-select-#{rule.id}"}
                type="checkbox"
                class="pc-checkbox mt-1 shrink-0"
                checked={MapSet.member?(@selected, rule.id)}
                phx-click="select"
                phx-value-id={rule.id}
                aria-label={gettext("Select %{name}", name: rule.name)}
              />
              <div class="min-w-0 flex-1 space-y-1.5">
                <div class="flex flex-wrap items-center gap-1.5">
                  <.link
                    navigate={~p"/rules/#{rule}"}
                    class="text-title-medium hover:text-primary hover:underline"
                  >
                    {rule.name}
                  </.link>

                  <.rule_state rule={rule} />

                  <.tone_badge
                    :if={rule.draft}
                    tone="warning"
                    size="xs"
                    icon="hero-pencil"
                  >
                    {gettext("Draft")}
                  </.tone_badge>

                  <.tone_badge
                    :if={rule.escalation_window_seconds > 0}
                    tone="info"
                    size="xs"
                    icon="hero-bars-arrow-up"
                  >
                    {gettext("Escalates")}
                  </.tone_badge>

                  <.tone_badge
                    :if={not @editable[rule.id]}
                    tone="ghost"
                    size="xs"
                    icon="hero-lock-closed"
                  >
                    {gettext("Read only")}
                  </.tone_badge>

                  <%!-- A rule that cannot work fails quietly; this is where
                        that silence becomes visible. --%>
                  <.tone_badge
                    :for={issue <- Map.get(@health, rule.id, [])}
                    tone={issue.tone}
                    size="xs"
                    icon="hero-exclamation-triangle"
                    title={Labels.health_explanation(issue.id)}
                  >
                    {Labels.health_issue(issue.id)}
                  </.tone_badge>

                  <.tone_badge
                    :for={{tone, icon, label} <- activity_badges(rule, @activity, @health)}
                    tone={tone}
                    size="xs"
                    icon={icon}
                  >
                    {label}
                  </.tone_badge>
                </div>

                <p class="text-body-small">{RuleBuilder.rule_sentence(rule)}</p>

                <.pause_note rule={rule} id={"rule-paused-#{rule.id}"} />

                <%!-- The rule as one line: when it fires, how many conditions
                      it checks, and what it then does. --%>
                <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-body-small text-muted">
                  <span class="inline-flex items-center gap-1.5">
                    <.icon
                      name={Icons.trigger(rule.trigger_event)}
                      class="size-4 shrink-0 text-muted"
                    />
                    {Labels.trigger(rule.trigger_event)}
                  </span>

                  <span aria-hidden="true">·</span>
                  <span>{rule_shape(rule)}</span>
                  <span aria-hidden="true">·</span>

                  <span class="inline-flex flex-wrap items-center gap-1">
                    <.tone_badge
                      :for={action <- rule.actions}
                      tone={to_string(Icons.action_tone(action.type))}
                      size="xs"
                      title={Labels.action(action.type)}
                    >
                      <.icon name={Icons.action(action.type)} class="size-3" />
                      <span class="hidden xl:inline">{Labels.action(action.type)}</span>
                    </.tone_badge>
                  </span>
                </div>

                <p class="flex flex-wrap items-center gap-x-2 text-label-small text-muted">
                  <span :if={rule.group not in [nil, ""]} class="inline-flex items-center gap-1">
                    <.icon name="hero-folder" class="size-3.5" />{rule.group}
                  </span>
                  <span :if={rule.group not in [nil, ""]} aria-hidden="true">·</span>
                  <span>{Labels.game(rule.game)}</span>
                  <span aria-hidden="true">·</span>
                  <span>{scope_label(rule)}</span>
                  <span :if={rule.priority > 0} aria-hidden="true">·</span>
                  <span :if={rule.priority > 0}>
                    {gettext("priority %{value}", value: rule.priority)}
                  </span>
                </p>

                <.rule_activity rule={rule} stats={Map.get(@activity, rule.id)} />
              </div>
            </div>

            <div class="flex shrink-0 items-center gap-1">
              <%!-- Switching a rule on or off is the move an admin makes most,
                    so it is one click here rather than three in the menu. --%>
              <label
                :if={Accounts.can?(@current_user, :manage_rules) and @editable[rule.id]}
                class="pc-switch pc-switch--sm mr-1 cursor-pointer"
              >
                <input
                  type="checkbox"
                  checked={rule.enabled}
                  phx-click="toggle"
                  phx-value-id={rule.id}
                  class="peer sr-only"
                  aria-label={
                    if(rule.enabled,
                      do: gettext("Turn off %{name}", name: rule.name),
                      else: gettext("Turn on %{name}", name: rule.name)
                    )
                  }
                />
                <span class="pc-switch__fake-input pc-switch__fake-input--sm"></span>
                <span class="pc-switch__fake-input-bg pc-switch__fake-input-bg--sm"></span>
              </label>

              <.button
                link_type="live_redirect"
                to={~p"/rules/#{rule}"}
                size="xs"
                variant="ghost"
                color="gray"
                label={gettext("Open")}
              />

              <.row_menu
                :if={Accounts.can?(@current_user, :manage_rules) and @editable[rule.id]}
                id={"rule-menu-#{rule.id}"}
              >
                <.menu_item icon="hero-pencil-square" navigate={~p"/rules/#{rule}/edit"}>
                  {gettext("Edit")}
                </.menu_item>

                <.menu_item icon="hero-power" phx-click="toggle" phx-value-id={rule.id}>
                  {if rule.enabled, do: gettext("Disable"), else: gettext("Enable")}
                </.menu_item>

                <.pause_menu_items rule={rule} on_custom="open_pause" />

                <.menu_item
                  icon="hero-document-duplicate"
                  phx-click="duplicate"
                  phx-value-id={rule.id}
                >
                  {gettext("Duplicate")}
                </.menu_item>

                <.menu_item
                  tone="error"
                  icon="hero-trash"
                  phx-click="delete"
                  phx-value-id={rule.id}
                  data-confirm={gettext("Remove the rule \"%{name}\"?", name: rule.name)}
                >
                  {gettext("Remove")}
                </.menu_item>
              </.row_menu>
            </div>
          </div>
        </li>
      </ul>

      <.modal
        :if={@recipes_open?}
        id="recipes-modal"
        title={gettext("Start from a recipe")}
        subtitle={
          gettext(
            "Ready-made rules for the situations every community runs into. Each one opens in the builder already filled in and set to simulation."
          )
        }
        on_cancel={JS.push("close_recipes")}
        class="max-w-3xl"
      >
        <ul class="grid gap-3 sm:grid-cols-2">
          <li :for={recipe <- Recipes.all()}>
            <.link
              navigate={~p"/rules/new?recipe=#{recipe.id}"}
              class="flex h-full items-start gap-3 rounded-box border border-base-300 p-3 transition-colors hover:border-primary/50 hover:bg-base-200/60"
            >
              <span class={[
                "flex size-14 shrink-0 items-center justify-center rounded-box",
                recipe_tone(recipe.tone)
              ]}>
                <.recipe_art id={recipe.id} class="size-10" />
              </span>

              <span class="min-w-0">
                <span class="block text-title-medium">{Labels.recipe_name(recipe.id)}</span>
                <span class="mt-0.5 block text-body-small text-muted">
                  {Labels.recipe_description(recipe.id)}
                </span>
              </span>
            </.link>
          </li>
        </ul>
      </.modal>

      <.pause_modal :if={@pause_rule} rule={@pause_rule} on_cancel={JS.push("close_pause")} />

      <.import_modal
        :if={@import_open?}
        json={@import_json}
        preview={@import_preview}
        error={@import_error}
        servers={@servers}
        server_id={@import_server_id}
        upload={@uploads.import_file}
      />
    </Layouts.app>
    """
  end

  # "3 conditions, all must hold" - enough to tell two similar rules apart
  # without opening either.
  # The coloured edge of a row: green while the rule is live, amber while it
  # is only simulating, flat while it is off. Read together with the chip
  # next to the name, state survives a glance down a long list.
  defp rule_rail(rule) do
    case Ui.rule_state_tone(rule) do
      "success" -> "border-l-success"
      "info" -> "border-l-info"
      "warning" -> "border-l-warning"
      _neutral -> "border-l-base-300"
    end
  end

  attr :rule, :map, required: true
  attr :stats, :map, default: nil

  # Last fired, runs in the last day and how many of those failed: whether
  # the rule is doing anything, and whether it works when it does.
  defp rule_activity(assigns) do
    ~H"""
    <p
      :if={@stats}
      class="flex flex-wrap items-center gap-x-2 text-label-small text-muted"
      id={"rule-activity-#{@rule.id}"}
    >
      <span class="inline-flex items-center gap-1">
        <.icon name="hero-bolt" class="size-3.5" />
        {gettext("Last fired")}
        <.local_time id={"rule-last-fired-#{@rule.id}"} at={@stats.last_executed_at} />
      </span>
      <span aria-hidden="true">·</span>
      <span>
        {ngettext("%{count} run in 24h", "%{count} runs in 24h", @stats.last_24h,
          count: @stats.last_24h
        )}
      </span>
      <span :if={@stats.last_24h > 0} aria-hidden="true">·</span>
      <span :if={@stats.last_24h > 0} class={@stats.failed_24h > 0 && "text-error"}>
        {gettext("%{percent}% failed", percent: failure_percent(@stats))}
      </span>
    </p>
    """
  end

  defp failure_percent(%{last_24h: 0}), do: 0
  defp failure_percent(%{last_24h: total, failed_24h: failed}), do: round(failed * 100 / total)

  # Extra state chips from the activity numbers. Health already reports
  # "never fired" after a grace period and "always failing"; these cover the
  # rest without saying the same thing twice.
  defp activity_badges(rule, activity, health) do
    issues = health |> Map.get(rule.id, []) |> Enum.map(& &1.id)
    stats = Map.get(activity, rule.id)

    [
      (is_nil(stats) and :never_fired not in issues) &&
        {"ghost", "hero-moon", gettext("Never fired")},
      (stats != nil and stats.last_24h > 0 and failure_percent(stats) >= 50 and
         :always_failing not in issues) && {"error", "hero-x-circle", gettext("Failing")},
      (rule.simulation and Ui.rule_paused?(rule)) &&
        {"warning", "hero-beaker", gettext("Simulation")}
    ]
    |> Enum.filter(& &1)
  end

  defp rule_shape(rule) do
    conditions =
      ngettext("%{count} condition", "%{count} conditions", length(rule.conditions),
        count: length(rule.conditions)
      )

    if length(rule.conditions) > 1 do
      "#{conditions} · #{Labels.logical_operator(rule.logical_operator)}"
    else
      conditions
    end
  end

  defp recipe_tone("info"), do: "bg-gradient-info text-info"
  defp recipe_tone("success"), do: "bg-gradient-success text-success"
  defp recipe_tone("warning"), do: "bg-gradient-warning text-warning"
  defp recipe_tone("error"), do: "bg-gradient-destructive text-error"
  defp recipe_tone(_primary), do: "bg-gradient-primary text-primary"

  # The recipes with a wizard are the ones most communities start with.
  defp featured_recipes do
    Enum.filter(Recipes.all(), &(Map.get(&1, :questions, []) != []))
  end

  defp filtered?(filters) do
    filters.game != nil or filters.server_id != nil or filters.enabled != nil or
      filters.search not in [nil, ""] or filters.group not in [nil, ""]
  end

  attr :json, :string, required: true
  attr :preview, :any, default: nil
  attr :error, :any, default: nil
  attr :servers, :list, required: true
  attr :server_id, :string, default: ""
  attr :upload, :any, required: true

  defp import_modal(assigns) do
    ~H"""
    <.modal
      id="import-modal"
      title={gettext("Import rules")}
      subtitle={
        gettext(
          "Paste a rules export or upload the file. Imported rules always arrive disabled, so you can read them over before switching them on."
        )
      }
      on_cancel={JS.push("close_import")}
      class="max-w-2xl"
    >
      <form phx-change="preview_import" id="import-form" class="space-y-3">
        <label class="block">
          <span class="mb-1 block text-sm font-medium">{gettext("Upload a .json file")}</span>
          <.live_file_input upload={@upload} class="pc-text-input w-full text-sm" />
        </label>

        <p :for={error <- upload_errors(@upload)} class="text-label-small text-error">
          {upload_error_text(error)}
        </p>

        <label>
          <span class="sr-only">{gettext("Rules export")}</span>
          <textarea
            name="json"
            rows="8"
            class="pc-text-input w-full font-mono text-xs"
            placeholder={~s({"format": "hll_conditional_actions.rules", ...})}
            phx-debounce="400"
          >{@json}</textarea>
        </label>

        <label class="block">
          <span class="mb-1 block text-sm font-medium">{gettext("Pin the imported rules to")}</span>
          <select name="server_id" class="pc-text-input w-full">
            <option value="">{gettext("Every server running their game")}</option>

            <option
              :for={server <- @servers}
              value={server.id}
              selected={@server_id == to_string(server.id)}
            >
              {server.name}
            </option>
          </select>
        </label>
      </form>

      <.alert :if={@error} color="danger" variant="soft" with_icon class="mt-3" label={@error} />

      <div :if={@preview} class="mt-3">
        <p class="mb-2 text-sm font-medium">
          {ngettext("%{count} rule found", "%{count} rules found", length(@preview),
            count: length(@preview)
          )}
        </p>

        <ul class="max-h-48 space-y-1 overflow-y-auto rounded-field bg-base-200 p-2 text-sm">
          <li :for={rule <- @preview} class="flex items-center justify-between gap-2">
            <span class="truncate">{rule["name"] || gettext("(unnamed)")}</span>
            <.tone_badge tone="ghost" size="xs">{rule["game"]}</.tone_badge>
          </li>
        </ul>
      </div>

      <div class="mt-4 flex flex-wrap items-center justify-end gap-2">
        <.button
          type="button"
          size="sm"
          variant="ghost"
          color="gray"
          phx-click="close_import"
          label={gettext("Cancel")}
        />
        <.button
          type="button"
          size="sm"
          color="primary"
          phx-click="confirm_import"
          disabled={is_nil(@preview) or @preview == []}
          phx-disable-with={gettext("Importing...")}
          label={gettext("Import")}
        />
      </div>
    </.modal>
    """
  end

  # A chosen .json file lands in the same textarea as a paste, so the preview
  # and the import work the same way for both.
  defp handle_import_file(:import_file, entry, socket) do
    if entry.done? do
      json =
        consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read!(path)} end)

      socket |> assign(:import_json, json) |> preview_json(json)
    else
      {:noreply, socket}
    end
  end

  defp preview_json(socket, json) do
    case String.trim(json) do
      "" ->
        {:noreply, socket |> assign(:import_preview, nil) |> assign(:import_error, nil)}

      trimmed ->
        case Rules.preview_import(trimmed) do
          {:ok, rules} ->
            {:noreply, socket |> assign(:import_preview, rules) |> assign(:import_error, nil)}

          {:error, message} ->
            {:noreply, socket |> assign(:import_preview, nil) |> assign(:import_error, message)}
        end
    end
  end

  defp upload_error_text(:too_large), do: gettext("That file is too large.")
  defp upload_error_text(:not_accepted), do: gettext("Only .json files can be imported.")
  defp upload_error_text(_error), do: gettext("That file could not be read.")

  # The export mirrors whatever the list is currently filtered to, so what you
  # see is what you get.
  defp export_path(filters) do
    query =
      filters
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map(fn {key, value} -> {key, to_string(value)} end)
      |> Enum.reject(fn {key, _value} -> key == :enabled end)

    "/rules/export?" <> URI.encode_query(query)
  end
end
