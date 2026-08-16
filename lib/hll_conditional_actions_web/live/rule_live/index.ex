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
  alias HllConditionalActionsWeb.Ui

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Rules"))
     |> assign(:servers, Servers.list_servers_for(socket.assigns[:current_user]))
     |> assign(:filters, %{game: nil, server_id: nil, enabled: nil, search: "", group: ""})
     |> assign(:import_open?, false)
     |> assign(:import_json, "")
     |> assign(:import_preview, nil)
     |> assign(:import_error, nil)
     |> assign(:import_server_id, "")
     |> assign(:recipes_open?, false)
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

    {:noreply, socket |> assign(:filters, filters) |> load_rules()}
  end

  def handle_event("clear_filters", _params, socket) do
    filters = %{game: nil, server_id: nil, enabled: nil, search: "", group: ""}
    {:noreply, socket |> assign(:filters, filters) |> load_rules()}
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
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field} #{inspect(errors)}" end)
  end

  defp load_rules(socket) do
    user = socket.assigns[:current_user]
    rules = Rules.list_rules_for(user, Enum.to_list(socket.assigns.filters))
    servers = socket.assigns.servers

    socket
    |> assign(:rules, rules)
    |> assign(:editable, Map.new(rules, &{&1.id, Rules.editable_by?(&1, user)}))
    |> assign(:health, Health.for_rules(rules, servers))
    |> assign(:groups, Rules.list_groups(user))
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
          :if={Accounts.can?(@current_user, :manage_rules)}
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
          :if={Accounts.can?(@current_user, :manage_rules)}
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
          :if={Accounts.can?(@current_user, :manage_rules)}
          link_type="live_redirect"
          to={~p"/rules/new"}
          size="sm"
          color="primary"
          icon="hero-plus"
          label={gettext("New rule")}
        />
      </:actions>

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
          name="game"
          label={gettext("Game")}
          value={@filters.game}
          prompt={gettext("Every game")}
          options={Labels.game_options()}
        />
        <.filter_select
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

      <.empty_state
        :if={@rules == []}
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

      <%!-- One row per rule, purpose built rather than a generic table: a rule
            is a sentence (when / if / then) plus a state, and a table turned
            that into four disconnected columns that collapsed badly on a
            phone. --%>
      <ul :if={@rules != []} class="space-y-2">
        <li
          :for={rule <- @rules}
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
                </div>

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
                "flex size-9 shrink-0 items-center justify-center rounded-box",
                recipe_tone(recipe.tone)
              ]}>
                <.icon name={recipe.icon} class="size-5" />
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

      <.import_modal
        :if={@import_open?}
        json={@import_json}
        preview={@import_preview}
        error={@import_error}
        servers={@servers}
        server_id={@import_server_id}
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
      "warning" -> "border-l-warning"
      _neutral -> "border-l-base-300"
    end
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

  defp filtered?(filters) do
    filters.game != nil or filters.server_id != nil or filters.enabled != nil or
      filters.search not in [nil, ""] or filters.group not in [nil, ""]
  end

  attr :json, :string, required: true
  attr :preview, :any, default: nil
  attr :error, :any, default: nil
  attr :servers, :list, required: true
  attr :server_id, :string, default: ""

  defp import_modal(assigns) do
    ~H"""
    <.modal
      id="import-modal"
      title={gettext("Import rules")}
      subtitle={
        gettext(
          "Paste a rules export. Imported rules always arrive disabled, so you can read them over before switching them on."
        )
      }
      on_cancel={JS.push("close_import")}
      class="max-w-2xl"
    >
      <form phx-change="preview_import" id="import-form" class="space-y-3">
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
