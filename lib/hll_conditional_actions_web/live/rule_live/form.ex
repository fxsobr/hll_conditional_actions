defmodule HllConditionalActionsWeb.RuleLive.Form do
  @moduledoc """
  The rule builder.

  A rule reads as *when TRIGGER happens, if CONDITIONS hold, run ACTIONS*, and
  the form is laid out in that order. Two things make it adapt as you type:

    * the trigger decides which condition fields are offered, because event
      fields such as the weapon only exist on the event that carried them
    * the game decides the *values* of role, team and game mode fields, which
      is where Hell Let Loose and Hell Let Loose: Vietnam differ

  Conditions and actions are `inputs_for` over embedded schemas, so adding,
  removing, reordering and duplicating rows are plain changeset operations
  with no client side state.

  The pieces the page is drawn with live in
  `HllConditionalActionsWeb.RuleBuilder`; this module owns state and events.

  ## Trying a rule before trusting it

  The "try it" panel (`HllConditionalActionsWeb.RuleLive.TryIt`) evaluates the rule *as currently typed* - unsaved edits
  included - against a player who is connected right now, and shows which
  conditions hold and which do not. Combined with the simulation switch, which
  makes a saved rule record what it would have done without touching the game,
  it means a rule that kicks or bans can be proven before it ever fires.
  On narrow screens the panel folds into a bottom sheet behind the
  "Preview and test" button, so it is reachable at every width.
  """

  use HllConditionalActionsWeb, :live_view

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_rules}}

  import HllConditionalActionsWeb.RuleBuilder

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Discord
  alias HllConditionalActions.Engine.Samples
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Action
  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActions.Rules.Condition
  alias HllConditionalActions.Rules.RecipeAnswers
  alias HllConditionalActions.Rules.Recipes
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Servers
  alias Phoenix.HTML.Form, as: HtmlForm

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:servers, Servers.list_servers_for(socket.assigns[:current_user]))
     |> assign(:groups, Rules.list_groups(socket.assigns[:current_user]))
     |> assign(:discord_webhooks, Discord.webhook_options())
     # The field picker leads with what this install actually uses, and ids
     # and names autocomplete from the players it has seen.
     |> assign(:popular_fields, Rules.most_used_fields())
     |> assign(:known_players, Rules.known_players())
     |> assign(:wizard, nil)
     # The replay runs from the start: what the rule would have done is the
     # first thing to know about it, not something to go looking for.
     |> assign(:replay_on?, true)
     |> assign(:replay, nil)
     # Set by the first edit; the form hook then asks before a link click or
     # a closing tab throws the edits away.
     |> assign(:dirty?, false)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    if Accounts.can?(socket.assigns.current_user, :manage_rules) do
      {:noreply, apply_action(socket, socket.assigns.live_action, params)}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("You do not have access to that page."))
       |> push_navigate(to: ~p"/rules")}
    end
  end

  # A rule runs on a server; with none connected there is nothing it could
  # ever do, so the builder sends the admin to the step that is missing.
  defp apply_action(%{assigns: %{servers: []}} = socket, :new, _params) do
    socket
    |> put_flash(:error, gettext("Connect a server first: a rule needs somewhere to run."))
    |> push_navigate(to: ~p"/")
  end

  defp apply_action(socket, :new, params) do
    game = default_game(socket, params)
    server_id = parse_id(params["server_id"])

    case Recipes.fetch(params["recipe"] || "") do
      nil ->
        rule = %Rule{
          game: game,
          server_id: server_id,
          conditions: [%Condition{field: :always_true, operator: :equal, value: ""}],
          actions: [%Action{type: :message_player, parameters: %{"message" => ""}}]
        }

        socket
        |> assign(:page_title, gettext("New rule"))
        |> assign(:recipe, nil)
        |> assign(:wizard, nil)
        |> assign(:rule, rule)
        |> assign_rule_form(Rules.change_rule(rule))

      recipe ->
        # A recipe is a filled-in starting point, not a saved rule: it lands
        # in the same form, already in simulation, and is only written when
        # the admin presses save.
        attrs =
          Recipes.to_attrs(recipe,
            name: Labels.recipe_name(recipe.id),
            description: Labels.recipe_description(recipe.id),
            game: game,
            server_id: server_id
          )
          |> HllConditionalActionsWeb.RecipeText.translate_attrs()

        # A recipe with questions asks them first; "customize" (or the
        # `customize` param) goes straight to the full form.
        wizard =
          if RecipeAnswers.questions(recipe) != [] and params["customize"] != "1",
            do: %{recipe: recipe, attrs: attrs}

        socket
        |> assign(:page_title, Labels.recipe_name(recipe.id))
        |> assign(:recipe, recipe)
        |> assign(:wizard, wizard)
        |> assign(:rule, %Rule{game: game, server_id: server_id})
        |> assign_rule_form(Rules.change_rule(%Rule{}, attrs))
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    rule = Rules.get_rule!(id)

    socket
    |> assign(:page_title, rule.name)
    |> assign(:recipe, nil)
    |> assign(:wizard, nil)
    |> assign(:rule, rule)
    # A pending draft is what the admin was working on, so editing resumes it.
    |> assign_rule_form(Rules.change_rule(rule, rule.draft || %{}))
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"rule" => params}, socket) do
    changeset = Rules.change_rule(socket.assigns.rule, params)

    {:noreply,
     socket |> assign(:dirty?, true) |> assign_rule_form(Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"rule" => params} = event, socket) do
    rule = socket.assigns.rule

    if socket.assigns.live_action == :edit and Rules.draft_required?(rule) do
      save_live_rule(socket, rule, params, event["intent"])
    else
      save_rule(socket, socket.assigns.live_action, params)
    end
  end

  def handle_event("add_condition", _params, socket) do
    {:noreply,
     update_embed(socket, :conditions, fn conditions ->
       conditions ++ [%{"field" => "always_true", "operator" => "equal", "value" => ""}]
     end)}
  end

  def handle_event("remove_condition", %{"index" => index}, socket) do
    {:noreply, update_embed(socket, :conditions, &delete_at(&1, index))}
  end

  def handle_event("move_condition", %{"index" => index, "dir" => dir}, socket) do
    {:noreply, update_embed(socket, :conditions, &move_at(&1, index, dir))}
  end

  def handle_event("duplicate_condition", %{"index" => index}, socket) do
    {:noreply, update_embed(socket, :conditions, &duplicate_at(&1, index))}
  end

  def handle_event("add_action", _params, socket) do
    {:noreply,
     update_embed(socket, :actions, fn actions ->
       actions ++ [%{"type" => "message_player", "parameters" => %{"message" => ""}}]
     end)}
  end

  # From the node library: an action of a given type, straight onto the canvas.
  def handle_event("add_action_type", %{"type" => type}, socket) do
    if type in Enum.map(Catalog.action_types(), &to_string/1) do
      {:noreply,
       update_embed(socket, :actions, fn actions ->
         actions ++ [%{"type" => type, "parameters" => %{}}]
       end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_action", %{"index" => index}, socket) do
    {:noreply, update_embed(socket, :actions, &delete_at(&1, index))}
  end

  def handle_event("move_action", %{"index" => index, "dir" => dir}, socket) do
    {:noreply, update_embed(socket, :actions, &move_at(&1, index, dir))}
  end

  def handle_event("duplicate_action", %{"index" => index}, socket) do
    {:noreply, update_embed(socket, :actions, &duplicate_at(&1, index))}
  end

  # ── Replaying the rule ─────────────────────────────────────────────────────

  # Once asked for, the replay stays live: every edit re-judges the samples,
  # so the numbers move as the conditions are typed.
  def handle_event("replay", _params, socket) do
    {:noreply, socket |> assign(:replay_on?, true) |> assign_replay()}
  end

  # The wizard's "customize": the answered recipe, in the full form.
  @impl Phoenix.LiveView
  def handle_info({:customize_recipe, attrs}, socket) do
    {:noreply,
     socket
     |> assign(:wizard, nil)
     |> assign_rule_form(Rules.change_rule(%Rule{}, attrs))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp save_rule(socket, :new, params) do
    case Rules.create_rule(params, actor: socket.assigns.current_user) do
      {:ok, rule} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Rule \"%{name}\" created.", name: rule.name))
         |> push_navigate(to: ~p"/rules")}

      {:error, changeset} ->
        {:noreply, assign_rule_form(socket, changeset)}
    end
  end

  defp save_rule(socket, :edit, params) do
    case Rules.update_rule(socket.assigns.rule, params, actor: socket.assigns.current_user) do
      {:ok, rule} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Rule \"%{name}\" saved.", name: rule.name))
         |> push_navigate(to: ~p"/rules")}

      {:error, changeset} ->
        {:noreply, assign_rule_form(socket, changeset)}
    end
  end

  # A live rule: "Publish" goes straight to the engine, anything else is kept
  # as a draft the engine does not see.
  defp save_live_rule(socket, rule, params, "publish") do
    case Rules.publish(rule, params, actor: socket.assigns.current_user) do
      {:ok, rule} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Rule \"%{name}\" published.", name: rule.name))
         |> push_navigate(to: ~p"/rules/#{rule}")}

      {:error, changeset} ->
        {:noreply, assign_rule_form(socket, changeset)}
    end
  end

  # The enabled switch is state, not definition: a draft never carries it.
  defp save_live_rule(socket, rule, params, _draft) do
    case Rules.save_draft(rule, Map.delete(params, "enabled"), actor: socket.assigns.current_user) do
      {:ok, rule} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Draft saved. The engine keeps running the published rule.")
         )
         |> push_navigate(to: ~p"/rules/#{rule}")}

      {:error, changeset} ->
        {:noreply, assign_rule_form(socket, changeset)}
    end
  end

  # Rebuilds the changeset from the parameters currently in the form, with one
  # embedded list transformed. Going through params (rather than through the
  # changeset's embeds) keeps unsaved edits in the other fields.
  #
  # Before the first `phx-change`, the form has no params at all - opening an
  # existing rule and clicking "add condition" straight away is the common
  # case - so the rule's stored rows are what we add to.
  defp update_embed(socket, key, fun) do
    params = socket.assigns.form.params

    current =
      case Map.fetch(params, to_string(key)) do
        {:ok, value} -> normalize_embed_params(value)
        :error -> stored_embed_params(socket.assigns.rule, key)
      end

    params = Map.put(params, to_string(key), fun.(current))
    changeset = Rules.change_rule(socket.assigns.rule, params)

    socket |> assign(:dirty?, true) |> assign_rule_form(changeset)
  end

  defp stored_embed_params(rule, :conditions) do
    Enum.map(rule.conditions, fn condition ->
      %{
        "field" => to_string(condition.field),
        "operator" => to_string(condition.operator),
        "value" => condition.value
      }
    end)
  end

  defp stored_embed_params(rule, :actions) do
    Enum.map(rule.actions, fn action ->
      %{"type" => to_string(action.type), "parameters" => action.parameters}
    end)
  end

  # `inputs_for` posts embeds as %{"0" => %{...}, "1" => %{...}}; everywhere
  # else we work with a plain list.
  defp normalize_embed_params(params) when is_map(params) do
    params
    |> Enum.sort_by(fn {index, _value} -> to_integer(index) end)
    |> Enum.map(fn {_index, value} -> value end)
  end

  defp normalize_embed_params(params) when is_list(params), do: params
  defp normalize_embed_params(_params), do: []

  defp delete_at(list, index) do
    case to_integer(index) do
      nil -> list
      position -> List.delete_at(list, position)
    end
  end

  defp move_at(list, index, dir) do
    with position when is_integer(position) <- to_integer(index),
         target = if(dir == "up", do: position - 1, else: position + 1),
         true <- target >= 0 and target < length(list),
         {value, rest} <- List.pop_at(list, position) do
      List.insert_at(rest, target, value)
    else
      _out_of_range -> list
    end
  end

  defp duplicate_at(list, index) do
    case to_integer(index) do
      nil ->
        list

      position ->
        case Enum.at(list, position) do
          nil -> list
          value -> List.insert_at(list, position + 1, value)
        end
    end
  end

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp to_integer(_value), do: nil

  defp assign_rule_form(socket, changeset) do
    form = to_form(changeset)
    preview = Ecto.Changeset.apply_changes(changeset)

    socket
    |> assign(:form, form)
    |> assign(:trigger, Ecto.Changeset.get_field(changeset, :trigger_event) || :player_connected)
    |> assign(:game, Ecto.Changeset.get_field(changeset, :game) || :hll)
    |> assign(
      :logical_operator,
      Ecto.Changeset.get_field(changeset, :logical_operator) || :and
    )
    # The rule as typed, for the plain language summary beside the form. The
    # same value the "Try it" panel judges, so the two can never disagree.
    |> assign(:preview, preview)
    |> assign(:overlaps, Rules.overlapping_rules(preview))
    |> assign(
      :example,
      Samples.example_context(
        replay_servers(socket.assigns.servers, preview),
        preview.trigger_event
      )
    )
    |> assign_replay()
  end

  defp assign_replay(socket) do
    if socket.assigns[:replay_on?] do
      rule = socket.assigns.preview
      saved = socket.assigns.rule

      assign(
        socket,
        :replay,
        Samples.replay(rule, replay_servers(socket.assigns.servers, rule),
          compare_to: if(saved.id && saved.trigger_event == rule.trigger_event, do: saved)
        )
      )
    else
      socket
    end
  end

  # The servers the rule would run on, among the ones this admin can see.
  defp replay_servers(servers, rule) do
    Enum.filter(servers, fn server ->
      server.game == rule.game and (is_nil(rule.server_id) or server.id == rule.server_id)
    end)
  end

  defp default_game(socket, %{"server_id" => id}) do
    case Enum.find(socket.assigns.servers, &(to_string(&1.id) == id)) do
      nil -> :hll
      server -> server.game
    end
  end

  defp default_game(_socket, _params), do: :hll

  defp parse_id(nil), do: nil
  defp parse_id(value), do: to_integer(value)

  defp server_options(servers, game) do
    [{gettext("Every server running this game"), ""}] ++
      (servers
       |> Enum.filter(&(&1.game == game))
       |> Enum.map(&{&1.name, &1.id}))
  end

  # ── Validation summary ─────────────────────────────────────────────────────

  # Which steps still have problems, as {anchor id, label, count}. Only once
  # the user has actually tried something - never on a form that has simply
  # not been filled in yet.
  defp step_issues(form) do
    changeset = form.source

    if changeset.action == nil do
      []
    else
      [
        {"rule-step-1", gettext("The rule"),
         field_error_count(changeset, [:name, :priority, :description, :group, :game, :server_id])},
        {"rule-step-2", gettext("When"),
         field_error_count(changeset, [:trigger_event, :trigger_interval_seconds])},
        {"rule-step-3", gettext("If"), embed_error_count(changeset, :conditions)},
        {"rule-step-4", gettext("Then"),
         embed_error_count(changeset, :actions) +
           field_error_count(changeset, [:escalation_window_seconds])},
        {"rule-step-limits", gettext("Limits"),
         field_error_count(changeset, [
           :cooldown_seconds,
           :cooldown_value,
           :max_executions_per_player
         ]) + embed_error_count(changeset, :exemptions)}
      ]
      |> Enum.filter(fn {_id, _label, count} -> count > 0 end)
    end
  end

  defp field_error_count(changeset, fields) do
    Enum.count(changeset.errors, fn {field, _error} -> field in fields end)
  end

  defp embed_error_count(changeset, key) do
    own = Enum.count(changeset.errors, fn {field, _error} -> field == key end)

    nested =
      case Map.get(changeset.changes, key) do
        rows when is_list(rows) ->
          Enum.count(rows, &match?(%Ecto.Changeset{valid?: false}, &1))

        %Ecto.Changeset{valid?: false} ->
          1

        _unchanged ->
          0
      end

    own + nested
  end

  defp errors_on(form, field) do
    for {^field, {message, opts}} <- form.errors, do: translate_error({message, opts})
  end

  @impl Phoenix.LiveView
  def render(%{wizard: %{}} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      page_subtitle={gettext("A few questions, and the rule is ready.")}
    >
      <.live_component
        module={HllConditionalActionsWeb.RuleLive.RecipeWizard}
        id="recipe-wizard"
        recipe={@wizard.recipe}
        attrs={@wizard.attrs}
        current_user={@current_user}
      />
    </Layouts.app>
    """
  end

  def render(assigns) do
    assigns = assign(assigns, :issues, step_issues(assigns.form))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      page_subtitle={gettext("When something happens, if it matches, do this.")}
    >
      <:actions>
        <span
          :if={@preview.simulation}
          class="hidden items-center gap-1.5 rounded-pill bg-warning/15 px-2.5 py-1 text-xs font-medium text-warning sm:inline-flex"
        >
          <span class="size-1.5 rounded-full bg-warning"></span>{gettext("Simulation")}
        </span>

        <.button
          link_type="live_redirect"
          to={~p"/rules"}
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-arrow-left"
        >
          <span class="hidden sm:inline">{gettext("Back to rules")}</span>
        </.button>
      </:actions>

      <.alert
        :if={@recipe}
        color="info"
        variant="soft"
        with_icon
        class="mb-4"
        heading={gettext("Started from a recipe")}
        label={
          gettext(
            "Everything below is filled in and set to simulation, so it records what it would have done without touching the game. Read the history, then turn simulation off."
          )
        }
      />
      <.alert
        :if={@overlaps != []}
        color="warning"
        variant="soft"
        with_icon
        class="mb-4"
        heading={
          ngettext(
            "%{count} other rule reacts to the same event",
            "%{count} other rules react to the same event",
            length(@overlaps),
            count: length(@overlaps)
          )
        }
        label={
          gettext("Both will run: %{rules}. That is fine if you meant it.",
            rules: Enum.map_join(@overlaps, ", ", & &1.name)
          )
        }
      />
      <%!-- The workbench: node library, canvas, inspector. Which node is
            selected and which inspector tab is open are pure view state, so
            Alpine owns them; every input stays rendered (only hidden), so a
            phx-change always posts the whole rule. --%>
      <div
        id="rule-workbench"
        class="workbench"
        data-sel="trigger"
        data-tab="configure"
        data-keep-attrs="data-sel data-tab"
        x-data="{ sel: 'trigger', tab: 'configure', q: '' }"
        x-bind:data-sel="sel"
        x-bind:data-tab="tab"
      >
        <.form
          for={@form}
          id="rule-form"
          class="contents"
          phx-change="validate"
          phx-submit="save"
          phx-hook=".UnsavedGuard"
          data-dirty={to_string(@dirty?)}
          data-confirm-leave={gettext("You have unsaved changes to this rule. Leave without saving?")}
        >
          <script :type={Phoenix.LiveView.ColocatedHook} name=".UnsavedGuard">
            // Two things a builder owes the person using it: not losing their
            // work to a stray click, and saving from the keyboard.
            //
            // Dirty state comes from the server (data-dirty), since most edits
            // are button clicks that never fire an input event here.
            export default {
              mounted() {
                this.submitting = false
                this.dirty = () => this.el.dataset.dirty === "true" && !this.submitting

                this.onBeforeUnload = e => {
                  if (!this.dirty()) return
                  e.preventDefault()
                  e.returnValue = ""
                }

                // Capture phase, so LiveView's own link handling never sees a
                // click the person chose to cancel.
                this.onClick = e => {
                  const link = e.target.closest("a[href]")
                  if (!link || !this.dirty()) return
                  if (link.target === "_blank" || link.hasAttribute("download")) return
                  if (link.getAttribute("href").startsWith("#")) return
                  if (!window.confirm(this.el.dataset.confirmLeave)) {
                    e.preventDefault()
                    e.stopImmediatePropagation()
                  }
                }

                // Ctrl+S / Cmd+S saves. Without a submitter the form posts no
                // intent, which for a live rule means "save draft": the safe
                // choice for a shortcut.
                this.onKeydown = e => {
                  if (!(e.ctrlKey || e.metaKey) || e.key.toLowerCase() !== "s") return
                  e.preventDefault()
                  this.el.requestSubmit()
                }

                this.onSubmit = () => { this.submitting = true }

                window.addEventListener("beforeunload", this.onBeforeUnload)
                document.addEventListener("click", this.onClick, true)
                window.addEventListener("keydown", this.onKeydown)
                this.el.addEventListener("submit", this.onSubmit)
              },

              updated() {
                // A save that came back with errors leaves the page: guard again.
                this.submitting = false
              },

              destroyed() {
                window.removeEventListener("beforeunload", this.onBeforeUnload)
                document.removeEventListener("click", this.onClick, true)
                window.removeEventListener("keydown", this.onKeydown)
              }
            }
          </script>
          <%!-- ── Node library ─────────────────────────────────────────── --%>
          <aside class="workbench-palette" aria-label={gettext("Node library")}>
            <label class="relative block">
              <span class="sr-only">{gettext("Find a node")}</span>
              <.icon
                name="hero-magnifying-glass"
                class="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted"
              />
              <input
                type="search"
                x-model="q"
                placeholder={gettext("Find a node")}
                autocomplete="off"
                class="w-full rounded-field border border-base-300 bg-base-100 py-2 pr-3 pl-9 text-sm placeholder:text-muted focus:border-primary focus:outline-none"
              />
            </label>

            <.palette_group title={gettext("Triggers")} count={length(Catalog.triggers())} open>
              <label
                :for={trigger <- Catalog.triggers()}
                data-name={fold(Labels.trigger(trigger))}
                x-show="!q || $el.dataset.name.includes($fold(q))"
                class="palette-item has-[:checked]:border-primary has-[:checked]:bg-primary/5"
                x-on:click="sel = 'trigger'; tab = 'configure'"
              >
                <input
                  type="radio"
                  name={@form[:trigger_event].name}
                  value={to_string(trigger)}
                  checked={@trigger == trigger}
                  class="peer sr-only"
                />
                <span class="palette-icon bg-primary/10 text-primary">
                  <.icon name={Icons.trigger(trigger)} class="size-4" />
                </span>
                <span class="min-w-0 flex-1 text-sm leading-tight">{Labels.trigger(trigger)}</span>
                <.icon
                  name="hero-check-circle-solid"
                  class="size-4 shrink-0 text-primary opacity-0 peer-checked:opacity-100"
                />
              </label>
            </.palette_group>

            <.palette_group title={gettext("Logic")} count={1} open>
              <button
                type="button"
                id="palette-add-condition"
                class="palette-item w-full text-left"
                phx-click={JS.push("add_condition")}
                data-name={fold(gettext("Condition"))}
                x-show="!q || $el.dataset.name.includes($fold(q))"
                x-on:click="sel = 'conditions'; tab = 'configure'"
              >
                <span class="palette-icon bg-warning/15 text-warning">
                  <.icon name="hero-arrows-pointing-out" class="size-4" />
                </span>

                <span class="min-w-0 flex-1">
                  <span class="block text-sm leading-tight">{gettext("Condition")}</span>
                  <span class="block truncate text-xs text-muted">
                    {gettext("Only continue when it holds")}
                  </span>
                </span>
                <.icon name="hero-plus" class="size-4 shrink-0 text-muted" />
              </button>
            </.palette_group>

            <.palette_group
              :for={group <- Catalog.action_groups()}
              title={Labels.action_group(group)}
              count={length(Catalog.actions_in_group(group))}
              open={group == :messaging}
            >
              <button
                :for={type <- Catalog.actions_in_group(group)}
                type="button"
                class="palette-item w-full text-left"
                phx-click="add_action_type"
                phx-value-type={type}
                data-name={fold(Labels.action(type))}
                x-show="!q || $el.dataset.name.includes($fold(q))"
                x-on:click="sel = 'actions'; tab = 'configure'"
              >
                <span class={["palette-icon", Icons.chip(Icons.action_tone(type))]}>
                  <.icon name={Icons.action(type)} class="size-4" />
                </span>
                <span class="min-w-0 flex-1 text-sm leading-tight">{Labels.action(type)}</span>
                <.icon name="hero-plus" class="size-4 shrink-0 text-muted" />
              </button>
            </.palette_group>
          </aside>

          <%!-- ── Canvas ───────────────────────────────────────────────── --%>
          <section class="workbench-canvas" aria-label={gettext("Rule flow")}>
            <div class="canvas-stats">
              <.icon name="hero-share" class="size-4 text-muted" />
              <span>
                {ngettext("1 condition", "%{count} conditions", length(conditions_to_show(@preview)))}
              </span>
              <span class="h-3 w-px bg-base-300"></span>
              <span>{ngettext("1 action", "%{count} actions", length(@preview.actions))}</span>
              <span class="h-3 w-px bg-base-300"></span>
              <span class={[if(@preview.enabled, do: "text-primary", else: "text-muted")]}>
                {if @preview.enabled, do: gettext("Enabled"), else: gettext("Disabled")}
              </span>
            </div>

            <div class="canvas-flow">
              <span class="canvas-start">
                <.icon name="hero-play-solid" class="size-3.5" />{gettext("Start")}
              </span>
              <span class="canvas-edge"></span>
              <.canvas_node
                id="rule-step-2"
                key="trigger"
                icon={Icons.trigger(@trigger)}
                chip="bg-primary/10 text-primary"
                title={Labels.trigger(@trigger)}
                subtitle={gettext("Trigger")}
                errors={issue_count(@issues, "rule-step-2")}
              >
                {Labels.trigger_hint(@trigger)}
              </.canvas_node>
              <span class="canvas-edge"></span>
              <%!-- The decision: every condition folded into one pill, with the
                    rule simply ending on the "No" side. --%>
              <div class="canvas-decision">
                <button
                  type="button"
                  id="rule-step-3"
                  class="canvas-pill"
                  data-node="conditions"
                  x-on:click="sel = 'conditions'; tab = 'configure'"
                >
                  <.icon name="hero-arrows-pointing-out" class="size-4" />
                  <span class="truncate">{decision_title(@preview)}</span>
                  <span
                    :if={@replay && @replay.total > 0}
                    class="rounded-pill bg-base-100/80 px-1.5 text-xs font-normal"
                    title={gettext("Would have matched, of the recent events replayed")}
                  >
                    {@replay.matched}/{@replay.total}
                  </span>
                  <span
                    :if={issue_count(@issues, "rule-step-3") > 0}
                    class="rounded-pill bg-error px-1.5 text-xs text-white"
                  >
                    {issue_count(@issues, "rule-step-3")}
                  </span>
                </button>

                <span class="canvas-branch-no">
                  <span class="canvas-edge-h"></span> <span class="canvas-tag">{gettext("No")}</span>
                  <span class="text-xs text-muted">{gettext("nothing happens")}</span>
                </span>
              </div>

              <ul :if={conditions_to_show(@preview) != []} class="canvas-conditions">
                <li :for={{condition, index} <- Enum.with_index(conditions_to_show(@preview))}>
                  <span :if={index > 0} class="font-medium text-warning">
                    {Labels.logical_joiner(@logical_operator)}
                  </span>
                  {condition_text(condition)}
                </li>
              </ul>
              <span class="canvas-edge"><span class="canvas-tag">{gettext("Yes")}</span></span>
              <div id="rule-step-4" class="w-full">
                <p :if={@preview.actions == []} class="canvas-empty">
                  {gettext("Add an action from the library")}
                </p>

                <div
                  :for={{action, index} <- Enum.with_index(@preview.actions)}
                  class="flex flex-col items-center"
                >
                  <span :if={index > 0} class="canvas-edge canvas-edge-short"></span>
                  <.canvas_node
                    id={"canvas-action-#{index}"}
                    key="actions"
                    icon={Icons.action(action.type)}
                    chip={Icons.chip(Icons.action_tone(action.type))}
                    title={Labels.action(action.type)}
                    subtitle={
                      if escalating?(@form),
                        do: gettext("Offence %{number}", number: index + 1),
                        else: gettext("Action")
                    }
                    errors={0}
                  >
                    {action_excerpt(action)}
                  </.canvas_node>
                </div>
              </div>
              <span class="canvas-edge"></span>
              <button
                type="button"
                id="rule-step-limits"
                class="canvas-end"
                data-node="limits"
                x-on:click="sel = 'limits'; tab = 'configure'"
              >
                <.icon name="hero-adjustments-horizontal" class="size-4" /> {limits_summary(@form)}
              </button>
            </div>
          </section>

          <%!-- ── Inspector ────────────────────────────────────────────── --%>
          <div class="workbench-tabs" role="tablist">
            <button
              :for={
                {key, label} <- [
                  {"setup", gettext("Setup")},
                  {"configure", gettext("Configure")},
                  {"test", gettext("Test")}
                ]
              }
              type="button"
              role="tab"
              class="workbench-tab"
              data-tab-key={key}
              x-on:click={"tab = '#{key}'"}
            >
              {label}
              <span
                :if={key == "setup" and issue_count(@issues, "rule-step-1") > 0}
                class="ml-1 rounded-pill bg-error px-1.5 text-xs text-white"
              >
                {issue_count(@issues, "rule-step-1")}
              </span>
            </button>
          </div>

          <div class="workbench-panel" data-pane="setup" id="rule-step-1">
            <.panel_section title={gettext("Rule")}>
              <.input
                field={@form[:name]}
                type="text"
                label={gettext("Name")}
                placeholder={gettext("Warn players who team kill")}
                required
              />
              <.input
                field={@form[:description]}
                type="textarea"
                label={gettext("Description")}
                placeholder={gettext("What is this rule for? Your fellow admins will thank you.")}
                rows="3"
              />
              <div class="grid grid-cols-2 gap-3">
                <.input
                  field={@form[:group]}
                  type="text"
                  label={gettext("Group")}
                  placeholder={gettext("Seeding, anti-cheat, events…")}
                  list="rule-groups"
                  autocomplete="off"
                  help_text={group_hint(@form[:group].value, @groups)}
                />
                <.input field={@form[:priority]} type="number" label={gettext("Priority")} min="0" />
              </div>

              <datalist id="rule-groups">
                <option :for={group <- @groups} value={group}></option>
              </datalist>
            </.panel_section>

            <.panel_section title={gettext("Where it runs")}>
              <.input
                field={@form[:game]}
                type="select"
                label={gettext("Game")}
                options={Labels.game_options()}
              />
              <.input
                field={@form[:server_id]}
                type="select"
                label={gettext("Applies to")}
                options={server_options(@servers, @game)}
                help_text={
                  gettext(
                    "A rule left on \"every server\" runs on all enabled servers of that game, so one rule can cover a whole fleet."
                  )
                }
              />
            </.panel_section>

            <.panel_section title={gettext("Behaviour")}>
              <.switch_card
                field={@form[:enabled]}
                icon="hero-power"
                title={gettext("Enabled")}
                hint={gettext("Off means the engine ignores this rule entirely.")}
              />
              <.switch_card
                field={@form[:simulation]}
                icon="hero-beaker"
                tone="warning"
                title={gettext("Simulation only")}
                hint={
                  gettext(
                    "Everything is evaluated and recorded in the history, with the messages it would have sent, but nothing reaches the game."
                  )
                }
              />
            </.panel_section>
          </div>

          <div class="workbench-panel" data-pane="configure">
            <%!-- Trigger --%>
            <div data-section="trigger">
              <.inspector_head
                icon={Icons.trigger(@trigger)}
                chip="bg-primary/10 text-primary"
                title={Labels.trigger(@trigger)}
                subtitle={gettext("Trigger")}
              />
              <.panel_section title={gettext("When it fires")}>
                <p class="text-sm text-subtle">{Labels.trigger_hint(@trigger)}</p>

                <p class="flex items-start gap-1.5 text-xs text-muted">
                  <.icon name="hero-information-circle" class="mt-px size-3.5 shrink-0" /> {gettext(
                    "Pick another trigger from the library on the left."
                  )}
                </p>

                <div :if={@trigger == :periodic} class="max-w-xs">
                  <.input
                    field={@form[:trigger_interval_seconds]}
                    type="number"
                    label={gettext("Every (seconds)")}
                    min="10"
                  />
                </div>
              </.panel_section>
            </div>
            <%!-- Conditions --%>
            <div data-section="conditions">
              <.inspector_head
                icon="hero-arrows-pointing-out"
                chip="bg-warning/15 text-warning"
                title={decision_title(@preview)}
                subtitle={gettext("Condition")}
              />
              <.panel_section title={gettext("If")}>
                <:aside>
                  <div
                    role="radiogroup"
                    aria-label={gettext("How conditions combine")}
                    class="flex items-center gap-0.5 rounded-pill bg-base-200 p-0.5"
                  >
                    <label :for={operator <- Catalog.logical_operators()} class="cursor-pointer">
                      <input
                        type="radio"
                        name={@form[:logical_operator].name}
                        value={to_string(operator)}
                        checked={@logical_operator == operator}
                        class="peer sr-only"
                      />
                      <span class="block rounded-pill px-2.5 py-0.5 text-xs text-muted transition-colors peer-checked:bg-base-100 peer-checked:font-medium peer-checked:text-base-content peer-checked:shadow-sm">
                        {Labels.logical_operator_short(operator)}
                      </span>
                    </label>
                  </div>
                </:aside>

                <div class="rounded-box bg-warning/5 p-2.5 ring-1 ring-warning/20">
                  <p class="mb-2 flex items-center gap-2 text-xs text-subtle">
                    <span class="rounded-pill bg-base-content px-1.5 py-0.5 text-[0.625rem] font-semibold text-base-100">
                      {gettext("IF")}
                    </span>
                    {Labels.logical_operator(@logical_operator)}
                  </p>

                  <div class="space-y-2">
                    <.inputs_for :let={condition} field={@form[:conditions]}>
                      <div class="rise-in">
                        <div :if={condition.index > 0} class="py-1" aria-hidden="true">
                          <span class="rounded-pill border border-base-300 bg-base-100 px-2 py-0.5 text-[0.625rem] font-medium text-subtle uppercase">
                            {Labels.logical_joiner(@logical_operator)}
                          </span>
                        </div>

                        <.condition_row
                          condition={condition}
                          trigger={@trigger}
                          game={@game}
                          total={length(@preview.conditions)}
                          popular={@popular_fields}
                        />
                      </div>
                    </.inputs_for>
                  </div>
                </div>

                <p
                  :for={message <- errors_on(@form, :conditions)}
                  class="flex items-center gap-1.5 text-sm text-error"
                >
                  <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />{message}
                </p>

                <div class="flex items-center gap-2">
                  <.button
                    type="button"
                    size="sm"
                    variant="outline"
                    color="gray"
                    icon="hero-plus"
                    phx-click="add_condition"
                    label={gettext("Add condition")}
                  />
                </div>

                <div class="flex gap-2 text-xs">
                  <span class="rounded-pill bg-primary/10 px-2 py-0.5 font-medium text-primary">
                    {gettext("Then")}
                  </span>

                  <span class="text-subtle">
                    {ngettext("runs 1 action", "runs %{count} actions", length(@preview.actions))}
                  </span>
                </div>
              </.panel_section>

              <.panel_section title={gettext("Replay")}>
                <.replay_panel replay={@replay} trigger={@trigger} />
              </.panel_section>
            </div>
            <%!-- Actions --%>
            <div data-section="actions">
              <.inspector_head
                icon="hero-play"
                chip="bg-info/15 text-info"
                title={gettext("Run these actions")}
                subtitle={ngettext("1 action", "%{count} actions", length(@preview.actions))}
              />
              <.panel_section title={gettext("Order")}>
                <.switch_card
                  field={@form[:escalate]}
                  icon="hero-bars-arrow-up"
                  title={gettext("Escalate repeat offenders")}
                  hint={
                    gettext(
                      "Off, every action runs every time. On, the actions become steps: the first offence runs the first action, the next one the second, and so on."
                    )
                  }
                />
                <div :if={escalating?(@form)} class="rise-in">
                  <.input
                    field={@form[:escalation_window_seconds]}
                    type="select"
                    label={gettext("Forget an offence after")}
                    options={escalation_windows(@form)}
                    class="pc-text-input w-full"
                  />
                </div>
              </.panel_section>

              <.panel_section title={gettext("Actions")}>
                <div class="space-y-3">
                  <.inputs_for :let={action} field={@form[:actions]}>
                    <.action_node
                      action={action}
                      total={length(@preview.actions)}
                      step={escalating?(@form) && action.index + 1}
                      webhooks={@discord_webhooks}
                      batch?={@trigger in Catalog.batch_triggers()}
                      example={@example}
                    />
                  </.inputs_for>
                </div>

                <p
                  :for={message <- errors_on(@form, :actions)}
                  class="flex items-center gap-1.5 text-sm text-error"
                >
                  <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />{message}
                </p>

                <div>
                  <.button
                    type="button"
                    size="sm"
                    variant="outline"
                    color="gray"
                    icon="hero-plus"
                    phx-click="add_action"
                    label={gettext("Add action")}
                  />
                </div>
                <.placeholders trigger={@trigger} />
              </.panel_section>
            </div>
            <%!-- Limits --%>
            <div data-section="limits">
              <.inspector_head
                icon="hero-adjustments-horizontal"
                chip="bg-base-200 text-subtle"
                title={gettext("Limits")}
                subtitle={limits_summary(@form)}
              />
              <.panel_section title={gettext("Per player")}>
                <.switch_card
                  field={@form[:cooldown_enabled]}
                  icon="hero-clock"
                  title={gettext("Cooldown")}
                  hint={
                    gettext("Make the same player wait before this rule can fire for them again.")
                  }
                />
                <div :if={switched_on?(@form, :cooldown_enabled)} class="rise-in flex items-end gap-2">
                  <div class="w-32">
                    <.input
                      field={@form[:cooldown_value]}
                      type="number"
                      min="1"
                      label={gettext("Wait at least")}
                      no_margin
                    />
                  </div>
                  <div class="w-28">
                    <.input
                      field={@form[:cooldown_unit]}
                      type="select"
                      options={duration_units()}
                      label={gettext("Unit")}
                      label_class="sr-only"
                      no_margin
                    />
                  </div>
                </div>

                <.switch_card
                  field={@form[:cap_enabled]}
                  icon="hero-hand-raised"
                  title={gettext("Daily cap")}
                  hint={gettext("Stop after a number of firings per player in 24 hours.")}
                />
                <div :if={switched_on?(@form, :cap_enabled)} class="rise-in w-48">
                  <.input
                    field={@form[:max_executions_per_player]}
                    type="number"
                    min="1"
                    label={gettext("Times per player per day")}
                    no_margin
                  />
                </div>

                <p
                  id="rule-limits-sentence"
                  class="flex items-start gap-2 rounded-box bg-base-200 p-3 text-sm text-subtle"
                  aria-live="polite"
                >
                  <.icon name="hero-chat-bubble-bottom-center-text" class="mt-0.5 size-4 shrink-0" />
                  <span>{limits_sentence(@preview)}</span>
                </p>
              </.panel_section>

              <.panel_section title={gettext("Doesn't apply to")}>
                <p class="text-xs text-muted">
                  {gettext(
                    "These players are skipped before any condition is checked. CRCON does not say who is an admin, so exempt your staff by the flag you give them."
                  )}
                </p>
                <.inputs_for :let={exemptions} field={@form[:exemptions]}>
                  <div id="rule-exemptions" class="space-y-3">
                    <.switch_card
                      field={exemptions[:exempt_vip]}
                      icon="hero-star"
                      title={gettext("VIPs")}
                      hint={gettext("Players who hold VIP on the server.")}
                    />
                    <.chip_input
                      field={exemptions[:exempt_flags]}
                      label={gettext("Players with any of these flags")}
                      label_class="text-xs"
                      placeholder={gettext("Type a flag, then Enter")}
                    />
                    <.chip_input
                      field={exemptions[:exempt_player_ids]}
                      label={gettext("These players")}
                      label_class="text-xs"
                      placeholder={gettext("Type a player ID, then Enter")}
                      list="known-player-ids"
                    />
                  </div>
                </.inputs_for>
                <.player_datalists players={@known_players} />
              </.panel_section>
            </div>
          </div>

          <div class="workbench-save">
            <div :if={@issues != []} class="mb-2 flex flex-wrap items-center gap-1.5" role="alert">
              <span class="flex items-center gap-1.5 text-sm text-error">
                <.icon name="hero-exclamation-circle" class="size-4 shrink-0" /> {gettext(
                  "Still needs your attention:"
                )}
              </span>

              <button
                :for={{anchor, label, count} <- @issues}
                type="button"
                class="rounded-pill border border-error/40 bg-error/10 px-2 py-0.5 text-xs text-error transition-colors hover:bg-error/20"
                x-on:click={issue_jump(anchor)}
              >
                {label} ({count})
              </button>
            </div>

            <p class="mb-2 flex items-center gap-1.5 text-xs text-muted">
              <.icon name="hero-information-circle" class="size-3.5 shrink-0" /> {gettext(
                "Nothing reaches the game until you save."
              )}
              <span class="ml-auto hidden items-center gap-1 sm:inline-flex">
                <kbd class="rounded border border-base-300 px-1 font-mono text-[0.625rem]">
                  Ctrl S
                </kbd>
                {gettext("to save")}
              </span>
            </p>

            <%!-- Wraps: Cancel, Save draft and Publish do not fit one row
                  of a phone. --%>
            <div class="flex flex-wrap items-center gap-2">
              <.button
                id="rule-cancel"
                link_type="live_redirect"
                to={if @live_action == :edit, do: ~p"/rules/#{@rule}", else: ~p"/rules"}
                variant="outline"
                color="gray"
                label={gettext("Cancel")}
              />
              <.button
                :if={@live_action == :edit and Rules.draft_required?(@rule)}
                id="rule-save-draft"
                type="submit"
                name="intent"
                value="draft"
                variant="outline"
                color="primary"
                icon="hero-pencil"
                class="flex-1"
                phx-disable-with={gettext("Saving...")}
                label={gettext("Save draft")}
              />
              <.button
                :if={@live_action == :edit and Rules.draft_required?(@rule)}
                id="rule-publish"
                type="submit"
                name="intent"
                value="publish"
                color="primary"
                icon="hero-rocket-launch"
                class="flex-1"
                phx-disable-with={gettext("Publishing...")}
                label={gettext("Publish")}
              />
              <.button
                :if={not (@live_action == :edit and Rules.draft_required?(@rule))}
                type="submit"
                color="primary"
                icon="hero-check"
                class="flex-1"
                phx-disable-with={gettext("Saving...")}
                label={gettext("Save rule")}
              />
            </div>
          </div>
        </.form>

        <%!-- Outside the rule form on purpose: the pickers below are forms of
              their own, and a form inside a form is a parse error that detaches
              everything after it - including the save button - from the outer
              form. The grid still places it in the inspector column. --%>
        <div class="workbench-panel space-y-4" data-pane="test">
          <.live_component
            module={HllConditionalActionsWeb.RuleLive.TryIt}
            id="try-it"
            rule={@preview}
            servers={@servers}
            game={@game}
          />
          <.rule_summary rule={@preview} game={@game} servers={@servers} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # How the rule as typed would have decided the recent events of its trigger.
  attr :replay, :map, default: nil
  attr :trigger, :atom, required: true

  defp replay_panel(%{replay: nil} = assigns) do
    ~H"""
    <div id="rule-replay" class="space-y-2">
      <p class="text-sm text-subtle">
        {gettext(
          "Judge this rule, as typed, against the recent events of its trigger - before it ever fires."
        )}
      </p>
      <.button
        type="button"
        size="sm"
        variant="outline"
        color="gray"
        icon="hero-arrow-path"
        phx-click="replay"
        label={gettext("Replay recent events")}
      />
    </div>
    """
  end

  defp replay_panel(%{replay: %{total: 0}} = assigns) do
    ~H"""
    <div id="rule-replay" class="rounded-box bg-base-200 p-3 text-sm text-subtle">
      <p class="flex items-start gap-2">
        <.icon name="hero-inbox" class="mt-0.5 size-4 shrink-0" />
        {gettext(
          "No \"%{trigger}\" event has been seen on these servers since the service started. Come back once there has been some activity.",
          trigger: Labels.trigger(@trigger)
        )}
      </p>
    </div>
    """
  end

  defp replay_panel(assigns) do
    assigns =
      assign(assigns,
        percent: round(assigns.replay.matched * 100 / assigns.replay.total),
        blockers:
          assigns.replay.conditions
          |> Enum.filter(&(&1.failed > 0))
          |> Enum.sort_by(& &1.failed, :desc)
      )

    ~H"""
    <div id="rule-replay" class="space-y-3 rounded-box bg-primary/5 p-3 ring-1 ring-primary/15">
      <p class="flex items-start gap-2 text-sm">
        <.icon name="hero-chart-bar" class="mt-0.5 size-4 shrink-0 text-primary" />
        <span>
          {gettext(
            "Of the last %{total} \"%{trigger}\" events, %{matched} would take Then and %{missed} would not.",
            total: @replay.total,
            trigger: Labels.trigger(@trigger),
            matched: @replay.matched,
            missed: @replay.total - @replay.matched
          )}
        </span>
      </p>

      <div class="h-1.5 overflow-hidden rounded-pill bg-base-300" aria-hidden="true">
        <div class="h-full rounded-pill bg-primary transition-all" style={"width: #{@percent}%"}>
        </div>
      </div>

      <p :if={@replay.changed} class="text-xs text-subtle">
        {ngettext(
          "This edit changes the outcome of 1 event compared to the saved rule.",
          "This edit changes the outcome of %{count} events compared to the saved rule.",
          @replay.changed
        )}
      </p>

      <div :if={@blockers != []} class="space-y-1">
        <p class="text-xs font-medium text-subtle">{gettext("What held events back")}</p>
        <p :for={blocker <- @blockers} class="flex items-center justify-between gap-2 text-xs">
          <span class="truncate">{Labels.field(blocker.field)}</span>
          <span class="shrink-0 text-muted">
            {ngettext("failed on 1", "failed on %{count}", blocker.failed)}
          </span>
        </p>
      </div>

      <ul class="space-y-1 border-t border-primary/10 pt-2">
        <li
          :for={example <- @replay.examples}
          class="flex items-center gap-2 text-xs"
        >
          <.icon
            name={if example.result, do: "hero-check-circle-solid", else: "hero-minus-circle"}
            class={["size-4 shrink-0", if(example.result, do: "text-primary", else: "text-muted")]}
          />
          <span class="min-w-0 flex-1 truncate">
            {example.player_name || gettext("Unknown player")}
          </span>
          <span class="shrink-0 text-muted">{example.server_name}</span>
        </li>
      </ul>

      <p class="text-xs text-muted">
        {gettext(
          "Limits and escalation are not applied here, and only events seen since the service started are kept."
        )}
      </p>
    </div>
    """
  end

  # Says whether the typed group joins an existing one (matched ignoring
  # case and spacing, the way it will be saved) or starts a new one.
  defp group_hint(value, groups) do
    case Rules.canonical_group(value, groups) do
      nil ->
        if groups == [], do: nil, else: gettext("Pick an existing group or type a new one.")

      name ->
        if name in groups,
          do: gettext("Joins the group %{group}.", group: name),
          else: gettext("Creates a new group %{group}.", group: name)
    end
  end

  # A collapsible group of the node library.
  attr :title, :string, required: true
  attr :count, :integer, required: true
  attr :open, :boolean, default: false
  slot :inner_block, required: true

  defp palette_group(assigns) do
    ~H"""
    <details class="group/palette" open={@open} data-keep-attrs="open">
      <summary class="flex cursor-pointer list-none items-center gap-2 py-2 text-sm font-medium [&::-webkit-details-marker]:hidden">
        {@title} <span class="ml-auto text-xs font-normal text-muted">{@count}</span>
        <.icon
          name="hero-chevron-down"
          class="size-4 text-muted transition-transform group-open/palette:rotate-180"
        />
      </summary>

      <div class="space-y-1.5 pb-2">{render_slot(@inner_block)}</div>
    </details>
    """
  end

  # One card on the canvas; clicking it opens it in the inspector.
  attr :id, :string, required: true
  attr :key, :string, required: true
  attr :icon, :string, required: true
  attr :chip, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :errors, :integer, default: 0
  slot :inner_block

  defp canvas_node(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      class="canvas-node rise-in"
      data-node={@key}
      data-invalid={@errors > 0}
      x-on:click={"sel = '#{@key}'; tab = 'configure'"}
    >
      <span class="flex items-center gap-3">
        <span class={["palette-icon size-9", @chip]}>
          <.icon name={@icon} class="size-4.5" />
        </span>

        <span class="min-w-0 flex-1">
          <span class="block truncate font-medium">{@title}</span>
          <span class="block truncate text-xs text-muted">{@subtitle}</span>
        </span>

        <span :if={@errors > 0} class="rounded-pill bg-error px-1.5 text-xs text-white">
          {@errors}
        </span>
      </span>

      <span :if={@inner_block != []} class="mt-2 line-clamp-2 block text-sm text-subtle">
        {render_slot(@inner_block)}
      </span>
    </button>
    """
  end

  attr :icon, :string, required: true
  attr :chip, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true

  defp inspector_head(assigns) do
    ~H"""
    <div class="flex items-center gap-3 border-b border-base-300 pb-4">
      <span class={["palette-icon size-10", @chip]}>
        <.icon name={@icon} class="size-5" />
      </span>

      <div class="min-w-0">
        <p class="truncate text-lg font-medium">{@title}</p>

        <p class="truncate text-xs text-muted">{@subtitle}</p>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  slot :aside
  slot :inner_block, required: true

  defp panel_section(assigns) do
    ~H"""
    <section class="space-y-3 border-b border-base-300 py-4 last:border-b-0">
      <div class="flex items-center justify-between gap-2">
        <h3 class="text-xs font-medium tracking-wide text-muted uppercase">{@title}</h3>
        {render_slot(@aside)}
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  # "Always" is how a rule says it has no condition; the canvas leaves it out.
  defp conditions_to_show(rule) do
    Enum.reject(rule.conditions, &(&1.field in [nil, :always_true]))
  end

  defp decision_title(rule) do
    case conditions_to_show(rule) do
      [] -> gettext("Always")
      [condition] -> Labels.field(condition.field) <> "?"
      conditions -> ngettext("1 check", "%{count} checks", length(conditions))
    end
  end

  defp condition_text(condition) do
    [
      Labels.field(condition.field),
      condition.operator && Labels.operator(condition.operator),
      condition.value
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  # The first thing an admin would recognise the action by: its message or
  # reason, when it has one.
  defp action_excerpt(action) do
    parameters = action.parameters || %{}

    Enum.find_value(["message", "reason", "flag", "url"], fn key ->
      case Map.get(parameters, key) do
        value when is_binary(value) and value != "" -> value
        _missing -> nil
      end
    end)
  end

  defp issue_jump("rule-step-1"), do: "tab = 'setup'"
  defp issue_jump("rule-step-2"), do: "sel = 'trigger'; tab = 'configure'"
  defp issue_jump("rule-step-3"), do: "sel = 'conditions'; tab = 'configure'"
  defp issue_jump("rule-step-4"), do: "sel = 'actions'; tab = 'configure'"
  defp issue_jump(_anchor), do: "sel = 'limits'; tab = 'configure'"

  defp issue_count(issues, anchor) do
    Enum.find_value(issues, 0, fn {id, _label, count} -> id == anchor && count end)
  end

  defp limits_summary(form) do
    preview = form.source |> Ecto.Changeset.apply_changes()
    cooldown = preview.cooldown_seconds
    maximum = preview.max_executions_per_player

    limits =
      case {blank_or_zero?(cooldown), blank_or_zero?(maximum)} do
        {true, true} -> gettext("no limits")
        {false, true} -> gettext("cooldown set")
        {true, false} -> gettext("daily cap set")
        {false, false} -> gettext("cooldown and daily cap set")
      end

    limits
  end

  defp switched_on?(form, field) do
    HtmlForm.normalize_value("checkbox", HtmlForm.input_value(form, field))
  end

  defp duration_units do
    [{gettext("seconds"), "s"}, {gettext("minutes"), "min"}, {gettext("hours"), "h"}]
  end

  @doc """
  The limits of a rule as one sentence an admin can check against intent:
  "Each player can trigger this at most 3× per day, at least 60 s apart;
  repeat offences within 10 min escalate to the next action."
  """
  @spec limits_sentence(Rule.t()) :: String.t()
  def limits_sentence(rule) do
    cooldown = rule.cooldown_seconds || 0
    cap = rule.max_executions_per_player || 0
    window = rule.escalation_window_seconds || 0

    base =
      case {cap > 0, cooldown > 0} do
        {true, true} ->
          gettext("Each player can trigger this at most %{count}× per day, at least %{gap} apart",
            count: cap,
            gap: format_duration(cooldown)
          )

        {true, false} ->
          gettext("Each player can trigger this at most %{count}× per day", count: cap)

        {false, true} ->
          gettext("Each player can trigger this at most once every %{gap}",
            gap: format_duration(cooldown)
          )

        {false, false} ->
          gettext("No limits: this fires every time its conditions hold")
      end

    if window > 0 do
      base <>
        gettext("; repeat offences within %{window} escalate to the next action.",
          window: format_duration(window)
        )
    else
      base <> "."
    end
  end

  @doc """
  Seconds in the largest unit that holds them exactly: "45 s", "10 min", "2 h".
  """
  @spec format_duration(non_neg_integer()) :: String.t()
  def format_duration(seconds) do
    case Rule.split_duration(seconds) do
      {value, "h"} -> gettext("%{count} h", count: value)
      {value, "min"} -> gettext("%{count} min", count: value)
      {value, _seconds} -> gettext("%{count} s", count: value)
    end
  end

  # An escalating rule turns its action list into a ladder; the builder says
  # so in the step header and numbers each action. The switch is the source of
  # truth, and falls back to the window for a rule loaded straight from the
  # database, where the virtual field has not been derived yet.
  defp escalating?(form) do
    case HtmlForm.input_value(form, :escalate) do
      nil -> not blank_or_zero?(HtmlForm.input_value(form, :escalation_window_seconds))
      value -> HtmlForm.normalize_value("checkbox", value)
    end
  end

  # Windows an admin can reason about, instead of a seconds box where zero
  # secretly meant "off". A rule that arrived from an import or the API may
  # carry any number of seconds, so its own value joins the list rather than
  # being silently rounded to the nearest option.
  defp escalation_windows(form) do
    options = [
      {gettext("15 minutes"), 900},
      {gettext("1 hour"), 3600},
      {gettext("6 hours"), 21_600},
      {gettext("24 hours"), 86_400},
      {gettext("1 week"), 604_800}
    ]

    current = to_seconds(HtmlForm.input_value(form, :escalation_window_seconds))

    if current in [nil, 0] or Enum.any?(options, fn {_label, value} -> value == current end) do
      options
    else
      Enum.sort_by(
        [{gettext("%{count} seconds", count: current), current} | options],
        fn {_label, value} -> value end
      )
    end
  end

  defp to_seconds(value) when is_integer(value), do: value

  defp to_seconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, _rest} -> seconds
      :error -> nil
    end
  end

  defp to_seconds(_value), do: nil

  defp blank_or_zero?(value) when value in [nil, "", 0, "0"], do: true
  defp blank_or_zero?(_value), do: false
end
