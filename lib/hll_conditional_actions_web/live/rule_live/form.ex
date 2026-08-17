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

  The "try it" panel evaluates the rule *as currently typed* - unsaved edits
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
  alias HllConditionalActions.Engine
  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Snapshot
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Action
  alias HllConditionalActions.Rules.Condition
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
     |> assign(:test_server_id, nil)
     |> assign(:test_players, [])
     |> assign(:test_loading?, false)
     |> assign(:test_result, nil)
     |> assign(:test_error, nil)}
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

        socket
        |> assign(:page_title, Labels.recipe_name(recipe.id))
        |> assign(:recipe, recipe)
        |> assign(:rule, %Rule{game: game, server_id: server_id})
        |> assign_rule_form(Rules.change_rule(%Rule{}, attrs))
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    rule = Rules.get_rule!(id)

    socket
    |> assign(:page_title, rule.name)
    |> assign(:recipe, nil)
    |> assign(:rule, rule)
    |> assign_rule_form(Rules.change_rule(rule))
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"rule" => params}, socket) do
    changeset = Rules.change_rule(socket.assigns.rule, params)
    {:noreply, assign_rule_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"rule" => params}, socket) do
    save_rule(socket, socket.assigns.live_action, params)
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

  def handle_event("remove_action", %{"index" => index}, socket) do
    {:noreply, update_embed(socket, :actions, &delete_at(&1, index))}
  end

  def handle_event("move_action", %{"index" => index, "dir" => dir}, socket) do
    {:noreply, update_embed(socket, :actions, &move_at(&1, index, dir))}
  end

  def handle_event("duplicate_action", %{"index" => index}, socket) do
    {:noreply, update_embed(socket, :actions, &duplicate_at(&1, index))}
  end

  # ── Trying the rule ────────────────────────────────────────────────────────

  def handle_event("load_test_players", %{"server_id" => ""}, socket) do
    {:noreply, socket |> assign(:test_server_id, nil) |> clear_test()}
  end

  def handle_event("load_test_players", %{"server_id" => id}, socket) do
    # The snapshot is a CRCON round trip; do it after this render so the
    # panel can show a loading state instead of freezing.
    send(self(), :fetch_test_players)

    {:noreply,
     socket
     |> assign(:test_server_id, id)
     |> clear_test()
     |> assign(:test_loading?, true)}
  end

  def handle_event("run_test", %{"player_id" => player_id}, socket) do
    server =
      Enum.find(socket.assigns.servers, &(to_string(&1.id) == socket.assigns.test_server_id))

    snapshot = socket.assigns[:test_snapshot]
    player = Snapshot.player(snapshot, player_id)

    if server && player do
      # The rule as typed, not as saved: that is the version being judged.
      rule = Ecto.Changeset.apply_changes(socket.assigns.form.source)

      context =
        Context.build(server, rule.trigger_event,
          player_id: player_id,
          player_name: player["name"],
          player: player,
          player_profile: player["profile"],
          gamestate: snapshot.gamestate
        )

      {:noreply,
       socket
       |> assign(:test_result, Engine.explain(rule, context))
       |> assign(:test_player_name, player["name"])
       |> assign(:test_error, nil)}
    else
      {:noreply, assign(socket, :test_error, gettext("That player is no longer connected."))}
    end
  end

  @impl Phoenix.LiveView
  def handle_info(:fetch_test_players, socket) do
    socket = assign(socket, :test_loading?, false)

    case Enum.find(socket.assigns.servers, &(to_string(&1.id) == socket.assigns.test_server_id)) do
      nil ->
        {:noreply, socket}

      server ->
        snapshot = Snapshot.refresh(server)

        players =
          snapshot
          |> Snapshot.players()
          |> Enum.map(fn {player_id, player} -> {player["name"] || player_id, player_id} end)
          |> Enum.sort()

        socket = assign(socket, :test_players, players)

        if players == [] do
          {:noreply,
           assign(
             socket,
             :test_error,
             gettext("Nobody is connected to that server right now, or CRCON did not answer.")
           )}
        else
          {:noreply, assign(socket, :test_snapshot, snapshot)}
        end
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp clear_test(socket) do
    socket
    |> assign(:test_players, [])
    |> assign(:test_loading?, false)
    |> assign(:test_result, nil)
    |> assign(:test_error, nil)
  end

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

    assign_rule_form(socket, changeset)
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
         field_error_count(changeset, [:cooldown_seconds, :max_executions_per_player])}
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

        _unchanged ->
          0
      end

    own + nested
  end

  defp errors_on(form, field) do
    for {^field, {message, _opts}} <- form.errors, do: message
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns = assign(assigns, :issues, step_issues(assigns.form))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      page_title={@page_title}
      page_subtitle={gettext("When something happens, if it matches, do this.")}
    >
      <:actions>
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

      <div
        class="grid items-start gap-6 xl:grid-cols-[minmax(0,1fr)_22rem]"
        x-data="{ preview: false }"
        x-bind:data-preview-open="preview"
        x-on:keydown.escape.window="preview = false"
      >
        <.alert
          :if={@recipe}
          color="info"
          variant="soft"
          with_icon
          class="col-span-full mb-4"
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
          class="col-span-full mb-4"
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

        <%!-- A grid item defaults to `min-width: auto`, so without this the
              form widens to fit the step nav instead of letting it scroll,
              and the whole page overflows sideways on a phone. --%>
        <.form for={@form} id="rule-form" class="min-w-0" phx-change="validate" phx-submit="save">
          <.step_nav steps={steps(@issues, @trigger)} />

          <div class="flow-spine mt-2 space-y-4 pl-10">
            <.flow_node
              id="rule-step-1"
              eyebrow={gettext("Setup")}
              icon="hero-identification"
              title={gettext("The rule")}
              error_count={issue_count(@issues, "rule-step-1")}
            >
              <div class="grid gap-3 md:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]">
                <.input
                  field={@form[:name]}
                  type="text"
                  label={gettext("Name")}
                  placeholder={gettext("Warn players who team kill")}
                  required
                />
                <.input
                  field={@form[:priority]}
                  type="number"
                  label={gettext("Priority")}
                  min="0"
                  class="input w-full"
                />
              </div>

              <.input
                field={@form[:description]}
                type="textarea"
                label={gettext("Description")}
                placeholder={gettext("What is this rule for? Your fellow admins will thank you.")}
                rows="2"
              />

              <%!-- Free text rather than a select: the first rule of a group has
                    to be able to invent it. The datalist offers the names
                    already in use so nobody ends up with "Seeding" and
                    "seeding" side by side. --%>
              <.input
                field={@form[:group]}
                type="text"
                label={gettext("Group")}
                placeholder={gettext("Seeding, anti-cheat, events…")}
                list="rule-groups"
                autocomplete="off"
              />

              <datalist id="rule-groups">
                <option :for={group <- @groups} value={group}></option>
              </datalist>

              <p class="-mt-1 flex items-start gap-1.5 text-xs text-muted">
                <.icon name="hero-information-circle" class="mt-px size-3.5 shrink-0" />
                {gettext(
                  "Rules in a group can be filtered together, and switched on or off in one go."
                )}
              </p>

              <div class="grid gap-3 md:grid-cols-2">
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
                />
              </div>

              <p class="-mt-1 flex items-start gap-1.5 text-xs text-muted">
                <.icon name="hero-information-circle" class="mt-px size-3.5 shrink-0" />
                {gettext(
                  "A rule left on \"every server\" runs on all enabled servers of that game, so one rule can cover a whole fleet."
                )}
              </p>

              <div class="grid gap-2 sm:grid-cols-2">
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
              </div>
            </.flow_node>

            <.flow_node
              id="rule-step-2"
              eyebrow={gettext("When")}
              tone="primary"
              icon="hero-bolt"
              title={Labels.trigger(@trigger)}
              hint={Labels.trigger_hint(@trigger)}
              error_count={issue_count(@issues, "rule-step-2")}
            >
              <fieldset class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
                <legend class="sr-only">{gettext("Trigger")}</legend>
                <label
                  :for={trigger <- HllConditionalActions.Rules.Catalog.triggers()}
                  class={[
                    "flex cursor-pointer items-center gap-2.5 rounded-field border border-base-300 p-2.5",
                    "transition-colors hover:border-primary/50 hover:bg-base-200",
                    "has-[:checked]:border-primary has-[:checked]:bg-primary/10"
                  ]}
                >
                  <input
                    type="radio"
                    name={@form[:trigger_event].name}
                    value={to_string(trigger)}
                    checked={@trigger == trigger}
                    class="pc-radio shrink-0"
                  />
                  <.icon name={Icons.trigger(trigger)} class="size-4 shrink-0 text-muted" />
                  <span class="text-sm leading-tight">{Labels.trigger(trigger)}</span>
                </label>
              </fieldset>

              <div :if={@trigger == :periodic} class="max-w-xs">
                <.input
                  field={@form[:trigger_interval_seconds]}
                  type="number"
                  label={gettext("Every (seconds)")}
                  min="10"
                />
              </div>
            </.flow_node>

            <.flow_node
              id="rule-step-3"
              eyebrow={gettext("If")}
              tone="info"
              icon="hero-funnel"
              title={gettext("These conditions hold")}
              error_count={issue_count(@issues, "rule-step-3")}
            >
              <:aside>
                <div
                  role="radiogroup"
                  aria-label={gettext("How conditions combine")}
                  class="flex items-center gap-0.5 rounded-field border border-base-300 bg-base-100 p-0.5"
                >
                  <label
                    :for={operator <- HllConditionalActions.Rules.Catalog.logical_operators()}
                    class="cursor-pointer"
                  >
                    <input
                      type="radio"
                      name={@form[:logical_operator].name}
                      value={to_string(operator)}
                      checked={@logical_operator == operator}
                      class="peer sr-only"
                    />
                    <span class="block rounded-selector px-2.5 py-1 text-xs text-muted transition-colors hover:text-base-content peer-checked:bg-primary/10 peer-checked:font-medium peer-checked:text-primary peer-focus-visible:ring-2 peer-focus-visible:ring-primary/50">
                      {Labels.logical_operator_short(operator)}
                    </span>
                  </label>
                </div>
              </:aside>

              <p class="-mt-1 text-xs text-muted">
                {Labels.logical_operator(@logical_operator)}
              </p>

              <div class="space-y-2">
                <.inputs_for :let={condition} field={@form[:conditions]}>
                  <div class="rise-in">
                    <div :if={condition.index > 0} class="flex items-center py-1" aria-hidden="true">
                      <span class="eyebrow rounded-selector bg-info/10 px-2 py-0.5 text-info">
                        {Labels.logical_joiner(@logical_operator)}
                      </span>
                    </div>

                    <.condition_row
                      condition={condition}
                      trigger={@trigger}
                      game={@game}
                      total={length(@preview.conditions)}
                    />
                  </div>
                </.inputs_for>
              </div>

              <div>
                <.button
                  type="button"
                  size="sm"
                  variant="soft"
                  color="info"
                  icon="hero-plus"
                  phx-click="add_condition"
                  label={gettext("Add condition")}
                />
              </div>

              <p
                :for={message <- errors_on(@form, :conditions)}
                class="flex items-center gap-1.5 text-sm text-error"
              >
                <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />{message}
              </p>
            </.flow_node>

            <.flow_node
              id="rule-step-4"
              eyebrow={gettext("Then")}
              tone="warning"
              icon="hero-play"
              title={gettext("Run these actions")}
              error_count={issue_count(@issues, "rule-step-4")}
            >
              <%!-- Escalation belongs here, not under "limits": it decides
                    whether the list below is a batch or a ladder, and that is
                    something you should see while writing the actions. --%>
              <div class="space-y-2">
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

                <div :if={escalating?(@form)} class="rise-in pl-3">
                  <.input
                    field={@form[:escalation_window_seconds]}
                    type="select"
                    label={gettext("Forget an offence after")}
                    options={escalation_windows(@form)}
                    class="pc-text-input w-full max-w-xs"
                  />
                </div>
              </div>

              <div class="space-y-3">
                <.inputs_for :let={action} field={@form[:actions]}>
                  <.action_node
                    action={action}
                    total={length(@preview.actions)}
                    step={escalating?(@form) && action.index + 1}
                  />
                </.inputs_for>
              </div>

              <div>
                <.button
                  type="button"
                  size="sm"
                  variant="soft"
                  color="warning"
                  icon="hero-plus"
                  phx-click="add_action"
                  label={gettext("Add action")}
                />
              </div>

              <p
                :for={message <- errors_on(@form, :actions)}
                class="flex items-center gap-1.5 text-sm text-error"
              >
                <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />{message}
              </p>

              <.placeholders />
            </.flow_node>

            <details
              id="rule-step-limits"
              class="group flow-node scroll-mt-24 rounded-box border border-base-300 bg-base-100"
            >
              <summary class="flex cursor-pointer list-none items-center gap-2 p-4 font-medium sm:p-5 [&::-webkit-details-marker]:hidden">
                <.icon name="hero-adjustments-horizontal" class="size-4 text-muted" />
                {gettext("Limits")}
                <span class="text-xs font-normal text-muted">
                  {limits_summary(@form)}
                </span>
                <.icon
                  name="hero-chevron-down"
                  class="ml-auto size-4 text-muted transition-transform group-open:rotate-180"
                />
              </summary>

              <div class="space-y-3 px-4 pb-4 sm:px-5 sm:pb-5">
                <div class="grid gap-3 md:grid-cols-2">
                  <.input
                    field={@form[:cooldown_seconds]}
                    type="number"
                    label={gettext("Cooldown per player (seconds)")}
                    min="0"
                  />
                  <.input
                    field={@form[:max_executions_per_player]}
                    type="number"
                    label={gettext("Maximum times per player per day")}
                    min="0"
                  />
                </div>

                <p class="text-xs text-muted">{gettext("Zero disables the limit.")}</p>
              </div>
            </details>
          </div>

          <div class="sticky bottom-0 z-20 mt-4 space-y-2 rounded-box border border-base-300 bg-base-100/90 p-3 backdrop-blur">
            <div :if={@issues != []} class="flex flex-wrap items-center gap-1.5" role="alert">
              <span class="flex items-center gap-1.5 text-sm text-error">
                <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
                {gettext("Still needs your attention:")}
              </span>
              <a
                :for={{anchor, label, count} <- @issues}
                href={"##{anchor}"}
                class="rounded-selector border border-error/40 bg-error/10 px-2 py-0.5 text-xs text-error transition-colors hover:bg-error/20"
              >
                {label} ({count})
              </a>
            </div>

            <div class="flex flex-wrap items-center justify-end gap-2">
              <button
                type="button"
                class="mr-auto flex cursor-pointer items-center gap-1.5 rounded-field border border-base-300 bg-base-200 px-3 py-1.5 text-sm font-medium transition-colors hover:bg-base-300 xl:hidden"
                aria-controls="rule-aside"
                x-on:click="preview = !preview"
                x-bind:aria-expanded="preview"
              >
                <.icon name="hero-eye" class="size-4" />{gettext("Preview and test")}
              </button>

              <.button
                link_type="live_redirect"
                to={~p"/rules"}
                size="sm"
                variant="ghost"
                color="gray"
                label={gettext("Cancel")}
              />
              <.button
                type="submit"
                size="sm"
                color="primary"
                icon="hero-check"
                phx-disable-with={gettext("Saving...")}
                label={gettext("Save rule")}
              />
            </div>
          </div>
        </.form>

        <%!-- Outside the rule form on purpose: the pickers below are forms of
              their own, and a form inside a form is a parse error that detaches
              everything after it - including the save button - from the outer
              form. --%>
        <div class="rule-aside-backdrop" x-on:click="preview = false" aria-hidden="true"></div>

        <aside id="rule-aside" class="rule-aside space-y-4 xl:sticky xl:top-24">
          <div class="flex items-center justify-between gap-2 xl:hidden">
            <p class="eyebrow text-muted">{gettext("Preview and test")}</p>

            <button
              type="button"
              class="flex size-8 cursor-pointer items-center justify-center rounded-field text-muted transition-colors hover:bg-base-200 hover:text-base-content"
              aria-label={gettext("Close the preview")}
              x-on:click="preview = false"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>

          <.rule_summary rule={@preview} game={@game} servers={@servers} />
          <.test_panel
            servers={@servers}
            game={@game}
            test_server_id={@test_server_id}
            test_players={@test_players}
            test_loading?={@test_loading?}
            test_result={@test_result}
            test_error={@test_error}
            test_player_name={assigns[:test_player_name]}
          />
        </aside>
      </div>
    </Layouts.app>
    """
  end

  # The builder's table of contents. Labels repeat the node headings on
  # purpose: the chip and the section it lands on should read the same.
  defp steps(issues, trigger) do
    [
      %{id: "rule-step-1", label: gettext("Setup"), icon: "hero-identification"},
      %{id: "rule-step-2", label: gettext("When"), icon: Icons.trigger(trigger)},
      %{id: "rule-step-3", label: gettext("If"), icon: "hero-funnel"},
      %{id: "rule-step-4", label: gettext("Then"), icon: "hero-play"},
      %{id: "rule-step-limits", label: gettext("Limits"), icon: "hero-adjustments-horizontal"}
    ]
    |> Enum.map(&Map.put(&1, :errors, issue_count(issues, &1.id)))
  end

  defp issue_count(issues, anchor) do
    Enum.find_value(issues, 0, fn {id, _label, count} -> id == anchor && count end)
  end

  defp limits_summary(form) do
    cooldown = HtmlForm.input_value(form, :cooldown_seconds)
    maximum = HtmlForm.input_value(form, :max_executions_per_player)

    limits =
      case {blank_or_zero?(cooldown), blank_or_zero?(maximum)} do
        {true, true} -> gettext("no limits")
        {false, true} -> gettext("cooldown set")
        {true, false} -> gettext("daily cap set")
        {false, false} -> gettext("cooldown and daily cap set")
      end

    limits
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
