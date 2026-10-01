defmodule HllConditionalActionsWeb.RuleLive.Form do
  @moduledoc """
  The rule builder, drawn as a test bench ("bancada de testes").

  A rule reads as a sentence - *when* TRIGGER happens *in* SCOPE, *if* these
  groups of conditions hold, *then* run these actions (a ladder when the rule
  escalates), with these *protections* - and every part of the sentence is a
  real control of one form, `#rule-form`. Conditions and actions are
  embedded lists; adding, removing, reordering and duplicating rows are
  plain changeset operations with no client side state, and every input
  stays rendered (the action drawer only hides the ones not being edited) so
  a change always posts the whole rule.

  Around the sentence, the bench tests it without touching the game:

    * **the run strip** - the latest events of the rule's trigger and what
      the saved rule did with each. A click overlays that event on the rule:
      every condition shows what it read and whether it held, each group
      whether it matched, and the ladder which rung ran. "Run again with the
      edits" judges the same event with the rule as typed.
    * **the 7-day replay** - the rule as typed, run over the real events of
      the last week with a virtual history (limits and ladder included), side
      by side with the published version: how often it would fire, on whom,
      which rung, and who changed fate with the edits
      (`HllConditionalActions.Rules.Bench`).
    * **try it** - a saved event or a player connected right now
      (`HllConditionalActionsWeb.RuleLive.TryIt`).

  The state switch - off, simulating, live - sets `enabled` and `simulation`;
  live stays locked until the rule has simulated for a few days.
  """

  use HllConditionalActionsWeb, :live_view

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_rules}}

  import HllConditionalActionsWeb.RuleBuilder
  import HllConditionalActionsWeb.BenchComponents

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Discord
  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Diagnosis
  alias HllConditionalActions.Engine.Escalation
  alias HllConditionalActions.Engine.Evaluator
  alias HllConditionalActions.Engine.Samples
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Action
  alias HllConditionalActions.Rules.Bench
  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActions.Rules.Condition
  alias HllConditionalActions.Rules.ConditionGroups
  alias HllConditionalActions.Rules.RecipeAnswers
  alias HllConditionalActions.Rules.Recipes
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Rules.Snapshot
  alias HllConditionalActions.Rules.Transfer
  alias HllConditionalActions.Servers
  alias Phoenix.HTML.Form, as: HtmlForm
  alias Phoenix.HTML.FormData

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:servers, Servers.list_servers_for(socket.assigns[:current_user]))
     |> assign(:groups, Rules.list_groups(socket.assigns[:current_user]))
     |> assign_webhooks()
     # The field picker leads with what this install actually uses, and ids
     # and names autocomplete from the players it has seen.
     |> assign(:popular_fields, Rules.most_used_fields())
     |> assign(:known_players, Rules.known_players())
     |> assign(:wizard, nil)
     # Set by the first edit; the form hook then asks before a link click or
     # a closing tab throws the edits away.
     |> assign(:dirty?, false)
     |> assign(:query, "")
     |> assign(:editing_action, nil)
     |> assign(:action_backup, nil)
     |> assign(:overlay, nil)
     |> assign(:rerun, nil)
     |> assign(:events_open?, false)
     |> assign(:expression_open?, false)
     |> assign(:expression, nil)
     |> assign(:expression_error, nil)
     |> assign(:bench_key, nil)
     |> assign(:bench_events, [])
     |> assign(:baseline, nil)
     |> assign(:runs, [])
     |> assign(:deliveries, %{})
     |> assign(:discord_testing?, false)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, url, socket) do
    if Accounts.can?(socket.assigns.current_user, :manage_rules) do
      query = URI.parse(url).query || ""

      {:noreply,
       socket
       |> assign(
         :query,
         Map.drop(URI.decode_query(query), ["recipe", "customize"]) |> URI.encode_query()
       )
       |> apply_action(socket.assigns.live_action, params)}
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
        # A new rule starts in simulation: it records what it would do until
        # it has earned going live.
        rule = %Rule{
          game: game,
          server_id: server_id,
          simulation: true,
          conditions: [%Condition{field: :always_true, operator: :equal, value: ""}],
          actions: [%Action{type: :message_player, parameters: %{"message" => ""}}]
        }

        socket
        |> assign(:page_title, gettext("New rule"))
        |> assign(:recipe, nil)
        |> assign(:wizard, nil)
        |> assign(:rule, rule)
        |> assign(:live_in, Bench.unlock_days())
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

        rule = %Rule{game: game, server_id: server_id}

        socket
        |> assign(:page_title, Labels.recipe_name(recipe.id))
        |> assign(:recipe, recipe)
        |> assign(:wizard, wizard)
        |> assign(:rule, rule)
        |> assign(:live_in, Bench.unlock_days())
        |> assign_rule_form(Rules.change_rule(rule, attrs))
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    rule = Rules.get_rule!(id)
    runs = Bench.recent_runs(rule, socket.assigns.servers)

    socket
    |> assign(:page_title, rule.name)
    |> assign(:recipe, nil)
    |> assign(:wizard, nil)
    |> assign(:rule, rule)
    |> assign(:runs, runs)
    |> assign(:live_in, Bench.live_in_days(rule))
    |> assign(:deliveries, Bench.last_deliveries(rule.id))
    # A pending draft is what the admin was working on, so editing resumes it.
    |> assign_rule_form(Rules.change_rule(rule, rule.draft || %{}))
    # The latest run that did something is overlaid from the start: the
    # bench opens on a real case, not on an abstract rule.
    |> overlay_run(default_run(runs))
  end

  defp default_run(runs) do
    runs
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {run, index} -> run.execution && index end)
  end

  # The webhooks for the Discord action: `{name, id}` options, and how each
  # last went - delivered, or failing since its last error.
  defp assign_webhooks(socket) do
    webhooks = Discord.list_webhooks()

    socket
    |> assign(:discord_webhooks, Enum.map(webhooks, &{&1.name, &1.id}))
    |> assign(
      :webhook_statuses,
      Map.new(webhooks, fn webhook ->
        failing? =
          not is_nil(webhook.last_error_at) and
            (is_nil(webhook.last_delivered_at) or
               DateTime.compare(webhook.last_error_at, webhook.last_delivered_at) == :gt)

        {webhook.id,
         %{
           remote: webhook.remote_name,
           status:
             cond do
               failing? -> :failing
               webhook.last_delivered_at -> :verified
               true -> :unused
             end,
           error: webhook.last_error
         }}
      end)
    )
  end

  # ── Events: the form ───────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("validate", %{"rule" => params} = event, socket) do
    changeset = Rules.change_rule(socket.assigns.rule, normalize_groups(params))

    {:noreply,
     socket
     |> assign(:dirty?, true)
     |> assign(:expression, event["expression"] || socket.assigns.expression)
     |> assign_rule_form(Map.put(changeset, :action, :validate))}
  end

  # The expression text alone changed.
  def handle_event("validate", event, socket) do
    {:noreply, assign(socket, :expression, event["expression"] || socket.assigns.expression)}
  end

  def handle_event("save", %{"rule" => params} = event, socket) do
    rule = socket.assigns.rule
    params = normalize_groups(params)

    cond do
      socket.assigns.live_action == :edit and Rules.draft_required?(rule) ->
        save_live_rule(socket, rule, params, event["intent"])

      socket.assigns.live_action == :new and event["intent"] == "draft" ->
        # A new rule saved as a draft is a rule that does not run yet.
        save_rule(socket, :new, Map.put(params, "enabled", "false"))

      true ->
        save_rule(socket, socket.assigns.live_action, params)
    end
  end

  def handle_event("set_state", %{"state" => state}, socket) do
    {enabled, simulation} = state_flags(state)

    cond do
      is_nil(enabled) ->
        {:noreply, socket}

      state == "live" and socket.assigns.live_in > 0 ->
        {:noreply, socket}

      true ->
        params =
          socket
          |> current_params()
          |> Map.put("enabled", enabled)
          |> then(&if(simulation, do: Map.put(&1, "simulation", simulation), else: &1))

        {:noreply, rebuild(socket, params)}
    end
  end

  # ── Events: conditions ─────────────────────────────────────────────────────

  def handle_event("add_condition", params, socket) do
    {:noreply,
     update_embed(socket, :conditions, fn conditions ->
       trigger = socket.assigns.trigger

       case conditions do
         # "Always" is how a rule says it has no condition: the first real
         # one takes its place.
         [%{"field" => "always_true"} = only] ->
           [Map.merge(only, %{"field" => first_field(trigger), "operator" => "equal"})]

         conditions ->
           group = parse_id(params["group"]) || last_group(conditions)
           operator = group_operator_of(conditions, group)

           conditions ++
             [
               %{
                 "field" => first_field(trigger),
                 "operator" => "equal",
                 "value" => "",
                 "group" => to_string(group),
                 "group_operator" => operator
               }
             ]
       end
     end)}
  end

  # A second group turns the rule into "any of these groups": the existing
  # conditions keep their own "all / any" as their group's, and the rule's
  # operator now combines the groups.
  def handle_event("add_group", _params, socket) do
    params = current_params(socket)
    conditions = embed_params(socket, params, :conditions)
    grouped? = conditions |> Enum.map(&(&1["group"] || "0")) |> Enum.uniq() |> length() > 1
    logical = params["logical_operator"] || to_string(socket.assigns.logical_operator)

    conditions =
      if grouped?,
        do: conditions,
        else: Enum.map(conditions, &Map.merge(&1, %{"group" => "0", "group_operator" => logical}))

    next = (conditions |> Enum.map(&to_integer(&1["group"] || "0")) |> Enum.max(fn -> 0 end)) + 1

    conditions =
      conditions ++
        [
          %{
            "field" => first_field(socket.assigns.trigger),
            "operator" => "equal",
            "value" => "",
            "group" => to_string(next),
            "group_operator" => "and"
          }
        ]

    params =
      params
      |> Map.put("conditions", conditions)
      |> then(&if(grouped?, do: &1, else: Map.put(&1, "logical_operator", "or")))

    {:noreply, rebuild(socket, params)}
  end

  # When the last condition of the second-to-last group goes, the rule is
  # flat again: the remaining group's "all / any" becomes the rule's own, so
  # the conditions keep meaning what they meant.
  def handle_event("remove_condition", %{"index" => index}, socket) do
    params = current_params(socket)

    conditions =
      case socket |> embed_params(params, :conditions) |> delete_at(index) do
        [] -> [%{"field" => "always_true", "operator" => "equal", "value" => ""}]
        rest -> rest
      end

    groups = conditions |> Enum.map(&to_string(&1["group"] || "0")) |> Enum.uniq()

    params =
      case {groups, conditions} do
        {[_single], [%{"group_operator" => operator} | _rest]}
        when is_binary(operator) and operator != "" ->
          params
          |> Map.put("logical_operator", operator)
          |> Map.put(
            "conditions",
            Enum.map(conditions, &Map.merge(&1, %{"group" => "0", "group_operator" => nil}))
          )

        _other ->
          Map.put(params, "conditions", conditions)
      end

    {:noreply, rebuild(socket, params)}
  end

  # Moves stay inside the condition's group: the neighbour it swaps with is
  # the previous or next condition of the same group.
  def handle_event("move_condition", %{"index" => index, "dir" => dir}, socket) do
    {:noreply,
     update_embed(socket, :conditions, fn conditions ->
       with position when is_integer(position) <- to_integer(index),
            %{} = condition <- Enum.at(conditions, position),
            target when is_integer(target) <- neighbour(conditions, position, condition, dir) do
         conditions
         |> List.replace_at(position, Enum.at(conditions, target))
         |> List.replace_at(target, condition)
       else
         _no_move -> conditions
       end
     end)}
  end

  def handle_event("duplicate_condition", %{"index" => index}, socket) do
    {:noreply, update_embed(socket, :conditions, &duplicate_at(&1, index))}
  end

  # ── Events: actions ────────────────────────────────────────────────────────

  def handle_event("add_action", _params, socket) do
    socket =
      update_embed(socket, :actions, fn actions ->
        actions ++ [%{"type" => "message_player", "parameters" => %{"message" => ""}}]
      end)

    {:noreply, open_action(socket, length(socket.assigns.preview.actions) - 1)}
  end

  def handle_event("add_action_type", %{"type" => type}, socket) do
    if type in Enum.map(Catalog.action_types(), &to_string/1) do
      socket =
        update_embed(socket, :actions, fn actions ->
          actions ++ [%{"type" => type, "parameters" => %{}}]
        end)

      {:noreply, open_action(socket, length(socket.assigns.preview.actions) - 1)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_action", %{"index" => index}, socket) do
    {:noreply,
     socket
     |> update_embed(:actions, &delete_at(&1, index))
     |> assign(:editing_action, nil)
     |> assign(:action_backup, nil)}
  end

  def handle_event("move_action", %{"index" => index, "dir" => dir}, socket) do
    target =
      case {to_integer(index), dir} do
        {nil, _dir} -> nil
        {position, "up"} -> position - 1
        {position, _down} -> position + 1
      end

    socket = update_embed(socket, :actions, &move_at(&1, index, dir))
    count = length(socket.assigns.preview.actions)

    socket =
      if socket.assigns.editing_action && target && target >= 0 && target < count,
        do: assign(socket, :editing_action, target),
        else: socket

    {:noreply, socket}
  end

  def handle_event("duplicate_action", %{"index" => index}, socket) do
    socket = update_embed(socket, :actions, &duplicate_at(&1, index))

    case to_integer(index) do
      nil -> {:noreply, socket}
      position -> {:noreply, assign(socket, :editing_action, position + 1)}
    end
  end

  def handle_event("edit_action", %{"index" => index}, socket) do
    {:noreply, open_action(socket, to_integer(index))}
  end

  def handle_event("close_action", _params, socket) do
    {:noreply, socket |> assign(:editing_action, nil) |> assign(:action_backup, nil)}
  end

  # Puts the actions back as they were when the drawer opened.
  def handle_event("cancel_action", _params, socket) do
    socket =
      case socket.assigns.action_backup do
        nil -> socket
        actions -> rebuild(socket, Map.put(current_params(socket), "actions", actions))
      end

    {:noreply, socket |> assign(:editing_action, nil) |> assign(:action_backup, nil)}
  end

  def handle_event("discord_test", %{"index" => index}, socket) do
    case Enum.at(socket.assigns.preview.actions, to_integer(index) || -1) do
      %Action{type: :send_discord_webhook, parameters: parameters} ->
        example = socket.assigns.example

        {:noreply,
         socket
         |> assign(:discord_testing?, true)
         |> start_async(:discord_test, fn -> Bench.send_discord_test(parameters, example) end)}

      _other ->
        {:noreply, socket}
    end
  end

  # ── Events: overlay and replay ─────────────────────────────────────────────

  def handle_event("overlay", %{"index" => index}, socket) do
    {:noreply, overlay_run(socket, to_integer(index))}
  end

  def handle_event("overlay_event", %{"key" => key}, socket) do
    case Enum.find(socket.assigns.bench_events, &(event_key(&1) == key)) do
      nil -> {:noreply, socket}
      event -> {:noreply, overlay_event(socket, event, nil, nil)}
    end
  end

  def handle_event("close_overlay", _params, socket) do
    {:noreply, socket |> assign(:overlay, nil) |> assign(:rerun, nil)}
  end

  # The overlaid event judged the way the engine would, with the rule as
  # typed: exemptions, the limits as they stood then, conditions, rung.
  def handle_event("rerun", _params, socket) do
    case socket.assigns.overlay do
      %{context: %Context{} = context} = overlay ->
        # Judged as if the rule were running: the bench asks what the rule
        # would do, whatever its switch says today. The limits are the ones
        # that stood when the event arrived (an unsaved rule has no history
        # to judge them by).
        preview = %{
          socket.assigns.preview
          | id: socket.assigns.rule.id,
            enabled: true,
            paused_until: nil
        }

        diagnosis = Diagnosis.diagnose(preview, context, at: overlay.at)

        step =
          if diagnosis.outcome == :fires and Escalation.escalating?(preview),
            do: Bench.step_at(preview, overlay.event.sample.player_id, overlay.at) || 0

        {:noreply, assign(socket, :rerun, %{outcome: diagnosis.outcome, step: step})}

      _no_event ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_events", _params, socket) do
    {:noreply, assign(socket, :events_open?, not socket.assigns.events_open?)}
  end

  # ── Events: the expression view ────────────────────────────────────────────

  def handle_event("open_expression", _params, socket) do
    json =
      socket.assigns.preview
      |> Transfer.dump_rule()
      |> Map.drop(["enabled"])
      |> Jason.encode!(pretty: true)

    {:noreply,
     socket
     |> assign(:expression_open?, true)
     |> assign(:expression, json)
     |> assign(:expression_error, nil)}
  end

  def handle_event("close_expression", _params, socket) do
    {:noreply, socket |> assign(:expression_open?, false) |> assign(:expression_error, nil)}
  end

  # Back to the visual view only when the text reads as a rule; otherwise
  # the way back is blocked, with the reason.
  def handle_event("apply_expression", _params, socket) do
    case Transfer.decode_rule(socket.assigns.expression || "") do
      {:ok, attrs} ->
        current = current_params(socket)

        params =
          attrs
          |> Map.put("enabled", current["enabled"] || to_string(socket.assigns.preview.enabled))
          |> Map.put("server_id", current["server_id"] || socket.assigns.preview.server_id)

        {:noreply,
         socket
         |> rebuild(params)
         |> assign(:expression_open?, false)
         |> assign(:expression_error, nil)}

      {:error, message} ->
        {:noreply, assign(socket, :expression_error, message)}
    end
  end

  # ── Async and messages ─────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_async(:discord_test, {:ok, :ok}, socket) do
    {:noreply,
     socket
     |> assign(:discord_testing?, false)
     |> put_flash(:info, gettext("Test sent to the channel."))}
  end

  def handle_async(:discord_test, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:discord_testing?, false)
     |> put_flash(:error, gettext("Discord refused the test: %{reason}", reason: reason))}
  end

  def handle_async(:discord_test, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:discord_testing?, false)
     |> put_flash(:error, gettext("Discord did not answer. Try again in a moment."))}
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

  # ── Saving ─────────────────────────────────────────────────────────────────

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

  # ── Params ─────────────────────────────────────────────────────────────────

  # The params the form last posted, or - before the first change event -
  # the rule as loaded.
  defp current_params(socket) do
    params = socket.assigns.form.params

    if params == %{} do
      socket.assigns.preview
      |> Snapshot.take()
      |> Map.put("enabled", socket.assigns.preview.enabled)
    else
      params
    end
  end

  defp rebuild(socket, params) do
    changeset = Rules.change_rule(socket.assigns.rule, normalize_groups(params))
    socket |> assign(:dirty?, true) |> assign_rule_form(changeset)
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
    current = embed_params(socket, params, key)
    params = Map.put(params, to_string(key), fun.(current))
    changeset = Rules.change_rule(socket.assigns.rule, normalize_groups(params))

    socket |> assign(:dirty?, true) |> assign_rule_form(changeset)
  end

  defp embed_params(socket, params, key) do
    case Map.fetch(params, to_string(key)) do
      {:ok, value} -> normalize_embed_params(value)
      :error -> stored_embed_params(socket.assigns.preview, key)
    end
  end

  defp stored_embed_params(rule, :conditions) do
    Enum.map(rule.conditions, fn condition ->
      %{
        "field" => to_string(condition.field),
        "operator" => to_string(condition.operator),
        "value" => condition.value,
        "group" => to_string(condition.group || 0),
        "group_operator" => condition.group_operator && to_string(condition.group_operator)
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
    |> Enum.sort_by(fn {index, _value} -> to_integer(index) || 0 end)
    |> Enum.map(fn {_index, value} -> value end)
  end

  defp normalize_embed_params(params) when is_list(params), do: params
  defp normalize_embed_params(_params), do: []

  # A group's "all / any" is posted with its first condition; every other
  # condition of the group takes the same, so the stored rule tells one
  # story whichever row is read.
  defp normalize_groups(%{"conditions" => conditions} = params) do
    list = normalize_embed_params(conditions)

    operators =
      Enum.reduce(list, %{}, fn condition, acc ->
        group = to_string(condition["group"] || "0")

        case condition["group_operator"] do
          operator when is_binary(operator) and operator != "" ->
            Map.put_new(acc, group, operator)

          _none ->
            acc
        end
      end)

    list =
      Enum.map(list, fn condition ->
        group = to_string(condition["group"] || "0")

        case Map.fetch(operators, group) do
          {:ok, operator} -> Map.put(condition, "group_operator", operator)
          :error -> condition
        end
      end)

    Map.put(params, "conditions", list)
  end

  defp normalize_groups(params), do: params

  defp first_field(trigger) do
    trigger
    |> Catalog.fields_for_trigger()
    |> Enum.reject(&(&1 == :always_true))
    |> List.first()
    |> to_string()
  end

  defp last_group(conditions) do
    case List.last(conditions) do
      nil -> 0
      condition -> to_integer(condition["group"] || "0") || 0
    end
  end

  defp group_operator_of(conditions, group) do
    Enum.find_value(conditions, fn condition ->
      to_integer(condition["group"] || "0") == group && condition["group_operator"]
    end)
  end

  defp neighbour(conditions, position, condition, dir) do
    group = condition["group"] || "0"

    indexed =
      conditions
      |> Enum.with_index()
      |> Enum.filter(fn {other, _index} -> (other["group"] || "0") == group end)
      |> Enum.map(&elem(&1, 1))

    case {dir, Enum.split_while(indexed, &(&1 != position))} do
      {"up", {before, _rest}} -> List.last(before)
      {_down, {_before, [_self, next | _rest]}} -> next
      _none -> nil
    end
  end

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

  defp open_action(socket, nil), do: socket

  defp open_action(socket, index) do
    if index >= 0 and index < length(socket.assigns.preview.actions) do
      socket
      |> assign(:editing_action, index)
      |> assign(:action_backup, embed_params(socket, socket.assigns.form.params, :actions))
    else
      socket
    end
  end

  # ── Assigns ────────────────────────────────────────────────────────────────

  defp assign_rule_form(socket, changeset) do
    form = to_form(changeset)
    preview = Ecto.Changeset.apply_changes(changeset)

    socket
    |> assign(:form, form)
    |> assign(:trigger, Ecto.Changeset.get_field(changeset, :trigger_event) || :player_connected)
    |> assign(:game, Ecto.Changeset.get_field(changeset, :game) || :hll)
    |> assign(:logical_operator, Ecto.Changeset.get_field(changeset, :logical_operator) || :and)
    # The rule as typed: what the replay, the overlay and "try it" judge, so
    # none of them can disagree with what is on the screen.
    |> assign(:preview, preview)
    |> assign(:overlaps, Rules.overlapping_rules(preview))
    |> assign(
      :example,
      Samples.example_context(
        replay_servers(socket.assigns.servers, preview),
        preview.trigger_event
      )
    )
    |> assign_bench()
  end

  # The events are loaded once per trigger and scope, the published rule is
  # replayed once over them; every edit replays only the draft.
  defp assign_bench(socket) do
    preview = socket.assigns.preview
    saved = socket.assigns.rule
    servers = replay_servers(socket.assigns.servers, preview)
    key = {preview.trigger_event, Enum.map(servers, & &1.id)}

    socket =
      if socket.assigns.bench_key == key do
        socket
      else
        events = Bench.events(servers, preview.trigger_event)

        baseline =
          if saved.id && saved.trigger_event == preview.trigger_event,
            do: Bench.replay(saved, events)

        socket
        |> assign(:bench_key, key)
        |> assign(:bench_events, events)
        |> assign(:baseline, baseline)
      end

    replay = Bench.replay(preview, socket.assigns.bench_events)

    socket
    |> assign(:replay, replay)
    |> assign(
      :comparison,
      socket.assigns.baseline && Bench.compare(replay, socket.assigns.baseline)
    )
  end

  defp overlay_run(socket, nil), do: socket

  defp overlay_run(socket, index) do
    case Enum.at(socket.assigns.runs, index) do
      nil -> socket
      %{event: nil} = run -> overlay_execution(socket, run, index)
      run -> overlay_event(socket, run.event, run, index)
    end
  end

  # A run whose event is no longer kept: what its trace recorded.
  defp overlay_execution(socket, run, index) do
    execution = run.execution
    server = Enum.find(socket.assigns.servers, &(&1.id == execution.server_id))

    overlay = %{
      index: index,
      key: "execution-#{execution.id}",
      event: nil,
      run: run,
      context: nil,
      step: run.step,
      fired?: true,
      player_name: execution.player_name,
      at: execution.executed_at,
      details:
        Enum.filter([server && length(socket.assigns.servers) > 1 && server.name], &is_binary/1)
    }

    socket |> assign(:overlay, overlay) |> assign(:rerun, nil)
  end

  defp overlay_event(socket, event, run, index) do
    rule = socket.assigns.rule
    sample = event.sample

    step =
      cond do
        run && run.step -> run.step
        run && run.execution -> Bench.step_at(rule, sample.player_id, sample.at)
        true -> nil
      end

    context = Bench.context(event, socket.assigns.preview.trigger_event)
    context = %{context | extra: Map.put(context.extra, :strikes, step || 0)}

    overlay = %{
      index: index,
      key: event_key(event),
      event: event,
      run: run,
      context: context,
      step: step,
      fired?: run && run.outcome in [:simulated, :fired, :error],
      player_name: sample.player_name,
      at: sample.at,
      details: overlay_details(context, event, socket.assigns.servers)
    }

    socket |> assign(:overlay, overlay) |> assign(:rerun, nil)
  end

  defp overlay_details(context, event, servers) do
    team_kills = Context.player_field(context.player, "team_kills")

    [
      length(servers) > 1 && event.server.name,
      Context.map_name(context),
      (event.sample.trigger == :player_team_kill and is_integer(team_kills) and team_kills > 0) &&
        gettext("team kill number %{count}", count: team_kills)
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
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
  defp parse_id(""), do: nil
  defp parse_id(value), do: to_integer(value)

  # ── Validation summary ─────────────────────────────────────────────────────

  # Which parts of the sentence still have problems, as {anchor, label,
  # count}. Only once the user has actually tried something - never on a
  # form that has simply not been filled in yet.
  defp step_issues(form) do
    changeset = form.source

    if changeset.action == nil do
      []
    else
      [
        {"bench-when", gettext("When"),
         field_error_count(changeset, [:trigger_event, :trigger_interval_seconds, :server_id])},
        {"bench-if", gettext("If"), embed_error_count(changeset, :conditions)},
        {"bench-then", gettext("Then"),
         embed_error_count(changeset, :actions) +
           field_error_count(changeset, [:escalation_window_seconds])},
        {"bench-guards", gettext("Protections"),
         field_error_count(changeset, [
           :cooldown_seconds,
           :cooldown_value,
           :max_executions_per_player
         ]) + embed_error_count(changeset, :exemptions)},
        {"bench-details", gettext("Details"),
         field_error_count(changeset, [:name, :priority, :description, :group, :game])}
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

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(%{wizard: %{}} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Ready-made recipes")}
      crumb={gettext("Rules / Recipes")}
      back={~p"/rules"}
      global_search={false}
      scope={false}
      bell={false}
    >
      <:actions>
        <.link
          navigate={~p"/rules/new"}
          class="flex h-12 items-center rounded-full border border-base-300 bg-base-100 px-5 text-sm font-medium transition-colors hover:border-primary/50"
        >
          {gettext("Start from scratch")}
        </.link>
      </:actions>
      <.live_component
        module={HllConditionalActionsWeb.RuleLive.RecipeWizard}
        id="recipe-wizard"
        recipe={@wizard.recipe}
        attrs={@wizard.attrs}
        servers={@servers}
        current_user={@current_user}
      />
    </Layouts.app>
    """
  end

  def render(assigns) do
    assigns =
      assigns
      |> assign(:issues, step_issues(assigns.form))
      |> assign(:state, bench_state(assigns.preview))
      |> assign(:draft?, assigns.live_action == :edit and Rules.draft_required?(assigns.rule))
      |> assign(:escalating?, escalating?(assigns.form))
      |> assign(:condition_forms, condition_forms(assigns.form))
      |> assign(:action_forms, action_forms(assigns.form))
      |> assign(:trace, overlay_trace(assigns.overlay, assigns.preview))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={page_heading(@live_action, @preview, @page_title)}
      crumb={breadcrumb(assigns)}
      back={if @live_action == :edit, do: ~p"/rules/#{@rule}", else: ~p"/rules"}
      back_label={gettext("Back")}
      global_search={false}
      scope={false}
      bell={false}
    >
      <:actions>
        <div class="hidden md:block">
          <.state_switch
            id="bench-state"
            state={@state}
            live_in={@live_in}
            unlock_days={Bench.unlock_days()}
          />
        </div>
        <.submit_buttons
          draft?={@draft?}
          new?={@live_action == :new}
          state={@state}
          form_id="rule-form"
        />
      </:actions>

      <div id="bench" class="flex flex-col gap-4">
        <div class="md:hidden">
          <.state_switch
            id="bench-state-phone"
            state={@state}
            live_in={@live_in}
            unlock_days={Bench.unlock_days()}
          />
        </div>
        <.recipe_row
          :if={@live_action == :new and is_nil(@recipe)}
          recipes={Enum.take(Recipes.all(), 4)}
          total={length(Recipes.all())}
          query={@query}
        />
        <.run_strip :if={@runs != []} runs={@runs} selected={@overlay && @overlay.index} />

        <div class="grid items-start gap-5 xl:grid-cols-[minmax(0,1fr)_25rem]">
          <.form
            for={@form}
            id="rule-form"
            class="flex min-w-0 flex-col overflow-hidden rounded-[1.75rem] bg-base-100 shadow-card"
            novalidate
            phx-change="validate"
            phx-submit="save"
            phx-hook=".UnsavedGuard"
            data-dirty={to_string(@dirty?)}
            data-confirm-leave={
              gettext("You have unsaved changes to this rule. Leave without saving?")
            }
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
                  // choice for a shortcut. "/" outside a field adds a condition.
                  this.onKeydown = e => {
                    const typing = e.target.closest("input, textarea, select, [contenteditable]")
                    if (e.key === "/" && !typing && !e.ctrlKey && !e.metaKey && !e.altKey) {
                      const add = document.getElementById("bench-add-condition")
                      if (add) { e.preventDefault(); add.click() }
                      return
                    }
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

            <.overlay_banner
              :if={@overlay}
              overlay={@overlay}
              rerun={@rerun}
              actions={@preview.actions}
            />

            <div class="flex flex-col gap-[1.125rem] px-5 py-5 sm:px-[1.625rem] sm:py-[1.375rem]">
              <div
                :if={@issues != []}
                id="bench-issues"
                role="alert"
                class="flex flex-wrap items-center gap-1.5 rounded-2xl bg-error/10 px-4 py-3"
              >
                <span class="flex items-center gap-1.5 text-[0.8125rem] text-error">
                  <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
                  {gettext("Still needs your attention:")}
                </span>
                <a
                  :for={{anchor, label, count} <- @issues}
                  href={"##{anchor}"}
                  class="rounded-full border border-error/40 px-2.5 py-0.5 text-xs text-error hover:bg-error/10"
                >
                  {label} ({count})
                </a>
              </div>

              <%!-- ── Quando ─────────────────────────────────────────────── --%>
              <.bench_row id="bench-when" label={gettext("When")} center>
                <div class="flex flex-wrap items-center gap-2.5 text-[1.0625rem] text-subtle">
                  <label class="min-w-0 max-w-full">
                    <span class="sr-only">{gettext("Trigger")}</span>
                    <select
                      id={@form[:trigger_event].id}
                      name={@form[:trigger_event].name}
                      class="bench-chip bench-chip--signal max-w-full"
                    >
                      <option
                        :for={trigger <- Catalog.triggers()}
                        value={trigger}
                        selected={@trigger == trigger}
                      >
                        {trigger_phrase(trigger)}
                      </option>
                    </select>
                  </label>
                  <span :if={@trigger == :periodic} class="flex items-center gap-2">
                    {gettext("every")}
                    <input
                      type="number"
                      id={@form[:trigger_interval_seconds].id}
                      name={@form[:trigger_interval_seconds].name}
                      value={@form[:trigger_interval_seconds].value}
                      min="10"
                      class="bench-chip w-24 text-center"
                      aria-label={gettext("Every (seconds)")}
                    /> s
                  </span>
                  <span>{gettext("in")}</span>
                  <label class="min-w-0 max-w-full">
                    <span class="sr-only">{gettext("Applies to")}</span>
                    <select
                      id={@form[:server_id].id}
                      name={@form[:server_id].name}
                      class="bench-chip max-w-full"
                    >
                      {Phoenix.HTML.Form.options_for_select(
                        server_options(@servers, @game),
                        to_string(@form[:server_id].value)
                      )}
                    </select>
                  </label>
                  <span
                    :if={@overlay}
                    class="bench-ok ml-auto flex items-center gap-1.5 text-xs font-semibold"
                  >
                    <.icon name="hero-check" class="size-3.5" />{gettext("happened")}
                  </span>
                </div>
                <p :for={message <- errors_on(@form, :server_id)} class="text-[0.8125rem] text-error">
                  {message}
                </p>
              </.bench_row>

              <%!-- ── Se ─────────────────────────────────────────────────── --%>
              <.bench_row id="bench-if" label={gettext("If")}>
                <.conditions_editor
                  form={@form}
                  condition_forms={@condition_forms}
                  preview={@preview}
                  trigger={@trigger}
                  game={@game}
                  popular={@popular_fields}
                  logical_operator={@logical_operator}
                  trace={@trace}
                  expression_open?={@expression_open?}
                  expression={@expression}
                  expression_error={@expression_error}
                />
              </.bench_row>

              <%!-- ── Então ──────────────────────────────────────────────── --%>
              <.bench_row id="bench-then" label={gettext("Then")}>
                <.actions_ladder
                  form={@form}
                  preview={@preview}
                  rule={@rule}
                  escalating?={@escalating?}
                  overlay={@overlay}
                  action_forms={@action_forms}
                />
              </.bench_row>

              <%!-- ── Proteções ──────────────────────────────────────────── --%>
              <.bench_row id="bench-guards" label={gettext("Protections")}>
                <.protections form={@form} preview={@preview} known_players={@known_players} />
              </.bench_row>

              <%!-- ── Detalhes ───────────────────────────────────────────── --%>
              <.bench_row id="bench-details" label={gettext("Details")}>
                <.details
                  form={@form}
                  groups={@groups}
                  preview={@preview}
                  open?={@live_action == :new or errors_on(@form, :name) != []}
                />
              </.bench_row>

              <div class="flex flex-wrap gap-2 border-t border-base-300 pt-4 xl:hidden">
                <.submit_buttons
                  draft?={@draft?}
                  new?={@live_action == :new}
                  state={@state}
                  mobile
                />
              </div>
            </div>

            <.action_drawer
              actions={@action_forms}
              editing={@editing_action}
              trigger={@trigger}
              webhooks={@discord_webhooks}
              webhook_statuses={@webhook_statuses}
              example={@example}
              escalating?={@escalating?}
              deliveries={@deliveries}
              testing?={@discord_testing?}
            />
          </.form>

          <%!-- Outside the rule form on purpose: "try it" has forms of its
                own, and a form inside a form is a parse error that detaches
                everything after it from the outer form. --%>
          <div class="grid min-w-0 items-start gap-5 lg:grid-cols-2 xl:grid-cols-1">
            <.replay_panel
              replay={@replay}
              comparison={@comparison}
              trigger={@trigger}
              days={Bench.days()}
              actions={@preview.actions}
              events_open?={@events_open?}
              overlaps={@overlaps}
            />
            <%!-- A new rule has no history yet: "try it" leads (Builder
                  board), the replay follows. --%>
            <div class={["min-w-0", @live_action == :new && "order-first"]}>
              <.live_component
                module={HllConditionalActionsWeb.RuleLive.TryIt}
                id="try-it"
                rule={@preview}
                servers={@servers}
                game={@game}
              />
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Pieces of the page ─────────────────────────────────────────────────────

  attr :draft?, :boolean, required: true
  attr :new?, :boolean, required: true
  attr :state, :atom, required: true
  attr :form_id, :string, default: nil
  attr :mobile, :boolean, default: false

  # The save buttons: in the header (outside the form, joined to it by the
  # `form` attribute) and at the end of the form on phones.
  defp submit_buttons(assigns) do
    suffix = if assigns.mobile, do: "-mobile", else: ""
    assigns = assign(assigns, :suffix, suffix)

    ~H"""
    <div class={[
      "items-center gap-2",
      if(@mobile, do: "flex w-full flex-wrap", else: "hidden xl:flex")
    ]}>
      <button
        :if={@draft? or @new?}
        id={"rule-save-draft" <> @suffix}
        type="submit"
        form={@form_id}
        name="intent"
        value="draft"
        phx-disable-with={gettext("Saving...")}
        class={[
          "h-12 cursor-pointer rounded-full border border-base-300 bg-base-100 px-5 text-sm font-medium transition-colors hover:border-primary/50",
          @mobile && "flex-1"
        ]}
      >
        {gettext("Save draft")}
      </button>
      <button
        id={if(@draft?, do: "rule-publish", else: "rule-save") <> @suffix}
        type="submit"
        form={@form_id}
        name="intent"
        value="publish"
        phx-disable-with={gettext("Saving...")}
        class={[
          "bench-publish flex h-12 cursor-pointer items-center justify-center gap-2 rounded-full px-[1.375rem] text-sm font-semibold transition-opacity hover:opacity-90",
          @mobile && "flex-1"
        ]}
      >
        <.icon :if={@new? and @state == :simulating} name="hero-beaker" class="size-4" />
        {publish_label(@draft?, @new?, @state)}
      </button>
    </div>
    """
  end

  defp publish_label(true, _new?, _state), do: gettext("Publish edits")
  defp publish_label(false, true, :simulating), do: gettext("Publish in simulation")
  defp publish_label(false, true, :live), do: gettext("Publish")
  defp publish_label(false, true, :off), do: gettext("Save rule")
  defp publish_label(false, false, _state), do: gettext("Save rule")

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :center, :boolean, default: false
  slot :inner_block, required: true

  # One line of the sentence: the mono label on the left, the parts on the
  # right. On a phone the label sits above.
  defp bench_row(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        "grid scroll-mt-28 gap-2 sm:grid-cols-[5.75rem_minmax(0,1fr)] sm:gap-3.5",
        @center && "sm:items-center"
      ]}
    >
      <h2 class={[
        "font-mono text-[0.6875rem] tracking-[0.1em] text-muted uppercase",
        not @center && "sm:pt-2.5"
      ]}>
        {@label}
      </h2>
      <div class="flex min-w-0 flex-col gap-2.5">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :condition_forms, :list, required: true
  attr :preview, :map, required: true
  attr :trigger, :atom, required: true
  attr :game, :atom, required: true
  attr :popular, :list, required: true
  attr :logical_operator, :atom, required: true
  attr :trace, :any, required: true
  attr :expression_open?, :boolean, required: true
  attr :expression, :any, required: true
  attr :expression_error, :any, required: true

  # "If": groups of conditions, each with its colour bar and its own "all /
  # any"; over them, how the groups combine.
  defp conditions_editor(assigns) do
    conditions = assigns.preview.conditions
    grouped? = ConditionGroups.grouped?(conditions)

    groups =
      conditions
      |> ConditionGroups.groups()
      |> Enum.with_index()
      |> Enum.map(fn {group, hue} ->
        indexes = Enum.map(group.conditions, &elem(&1, 1))

        %{
          id: group.id,
          hue: rem(hue, 5),
          operator: if(grouped?, do: group.operator, else: assigns.logical_operator),
          forms:
            Enum.map(indexes, &Enum.at(assigns.condition_forms, &1)) |> Enum.reject(&is_nil/1),
          result: group_result(assigns.trace, group.id)
        }
      end)

    always? = match?([%{field: :always_true}], conditions)

    assigns =
      assign(assigns, groups: groups, grouped?: grouped?, always?: always?)

    ~H"""
    <div :if={@expression_open?} id="bench-expression" class="flex flex-col gap-2.5">
      <textarea
        id="bench-expression-text"
        name="expression"
        rows="16"
        spellcheck="false"
        phx-debounce="300"
        class="bench-tile h-auto py-3 font-mono text-[0.8125rem] leading-relaxed"
      >{@expression}</textarea>
      <p
        :if={@expression_error}
        id="bench-expression-error"
        class="flex items-start gap-2 rounded-2xl bg-warning/10 px-4 py-3 text-[0.8125rem] text-warning"
        role="alert"
      >
        <.icon name="hero-exclamation-triangle" class="mt-px size-4 shrink-0" />
        {gettext("This text cannot go back to the visual view: %{reason}", reason: @expression_error)}
      </p>
      <div class="flex flex-wrap items-center gap-2.5">
        <button
          id="bench-expression-apply"
          type="button"
          phx-click="apply_expression"
          class="h-[2.125rem] cursor-pointer rounded-full bg-primary px-4 text-[0.8125rem] font-semibold text-primary-content"
        >
          {gettext("Apply and go back to visual")}
        </button>
        <button
          type="button"
          phx-click="close_expression"
          class="h-[2.125rem] cursor-pointer rounded-full px-3 text-[0.8125rem] text-subtle hover:text-base-content"
        >
          {gettext("Discard")}
        </button>
      </div>
    </div>

    <div class={["flex flex-col gap-2.5", @expression_open? && "hidden"]}>
      <div :if={@grouped?} class="flex items-center gap-2 text-sm text-subtle">
        <label>
          <span class="sr-only">{gettext("How the groups combine")}</span>
          <select
            id={@form[:logical_operator].id}
            name={@form[:logical_operator].name}
            class="bench-pill"
          >
            <option
              :for={operator <- Catalog.logical_operators()}
              value={operator}
              selected={@logical_operator == operator}
            >
              {groups_operator_label(operator)}
            </option>
          </select>
        </label>
        {gettext("these groups hold")}
      </div>

      <div :if={@always?} class="flex flex-col gap-1">
        <p class="text-base text-subtle">{gettext("always, no conditions")}</p>
        <%!-- The "always" condition still travels with the form. --%>
        <div class="hidden">
          <.condition_row
            :for={condition <- @condition_forms}
            condition={condition}
            trigger={@trigger}
            game={@game}
            popular={@popular}
          />
        </div>
        <input
          :if={not @grouped?}
          type="hidden"
          name={@form[:logical_operator].name}
          value={@logical_operator}
        />
      </div>

      <div
        :for={group <- @groups}
        :if={not @always?}
        id={"bench-group-#{group.id}"}
        class="bench-group flex gap-3"
        data-hue={group.hue}
      >
        <span class="bench-group-bar w-1 shrink-0 rounded-sm"></span>
        <div class="flex min-w-0 flex-1 flex-col gap-2">
          <div class="flex flex-wrap items-center gap-2 text-[0.8125rem] text-subtle">
            <label>
              <span class="sr-only">{gettext("How this group's conditions combine")}</span>
              <select
                :if={not @grouped?}
                id={@form[:logical_operator].id}
                name={@form[:logical_operator].name}
                class="bench-group-pill"
              >
                <option
                  :for={operator <- Catalog.logical_operators()}
                  value={operator}
                  selected={group.operator == operator}
                >
                  {group_operator_label(operator)}
                </option>
              </select>
              <select
                :if={@grouped?}
                id={"bench-group-#{group.id}-operator"}
                name={hd(group.forms)[:group_operator].name}
                class="bench-group-pill"
              >
                <option
                  :for={operator <- Catalog.logical_operators()}
                  value={operator}
                  selected={group.operator == operator}
                >
                  {group_operator_label(operator)}
                </option>
              </select>
            </label>
            {group_suffix(group.operator)}
            <span
              :if={group.result != :none}
              class={[
                "ml-auto text-xs font-semibold",
                if(group.result, do: "bench-ok", else: "bench-bad")
              ]}
            >
              {if group.result, do: gettext("group matched"), else: gettext("group did not match")}
            </span>
          </div>
          <.condition_row
            :for={{condition, position} <- Enum.with_index(group.forms)}
            condition={condition}
            trigger={@trigger}
            game={@game}
            popular={@popular}
            group={group.id}
            group_operator={(@grouped? and position > 0) && to_string(group.operator)}
            first?={position == 0}
            last?={position == length(group.forms) - 1}
            trace={condition_trace(@trace, condition.index)}
          />
          <button
            :if={@grouped?}
            type="button"
            phx-click="add_condition"
            phx-value-group={group.id}
            class="self-start text-xs font-medium text-subtle hover:text-primary"
          >
            + {gettext("condition in this group")}
          </button>
        </div>
      </div>

      <p
        :for={message <- errors_on(@form, :conditions)}
        class="flex items-center gap-1.5 text-[0.8125rem] text-error"
      >
        <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />{message}
      </p>

      <div class="flex flex-wrap items-center gap-2.5">
        <button id="bench-add-condition" type="button" class="bench-add" phx-click="add_condition">
          + {gettext("Condition")}
          <kbd class="rounded-md bg-secondary px-1.5 py-0.5 font-mono text-[0.6875rem] text-muted">
            /
          </kbd>
        </button>
        <button id="bench-add-group" type="button" class="bench-add" phx-click="add_group">
          + {gettext("Group")}
        </button>
        <span class="grow"></span>
        <button
          id="bench-open-expression"
          type="button"
          phx-click="open_expression"
          class="h-[2.125rem] cursor-pointer rounded-full px-3 font-mono text-xs text-subtle hover:text-base-content"
        >
          &lt;/&gt; {gettext("see as an expression")}
        </button>
      </div>
    </div>
    """
  end

  # "[any of ▾] these groups hold".
  defp groups_operator_label(:and), do: gettext("all of")
  defp groups_operator_label(:or), do: gettext("any of")
  defp groups_operator_label(:nand), do: gettext("not all of")
  defp groups_operator_label(:nor), do: gettext("none of")

  # "[every one ▾] of these hold". Own msgids, not the bare "all"/"none"
  # shared with other screens: languages agree them with "conditions".
  defp group_operator_label(:and), do: gettext("every one")
  defp group_operator_label(:or), do: gettext("at least one")
  defp group_operator_label(:nand), do: gettext("not every one")
  defp group_operator_label(:nor), do: gettext("not one")

  defp group_suffix(_operator), do: gettext("of these hold")

  attr :form, :any, required: true
  attr :preview, :map, required: true
  attr :rule, :map, required: true
  attr :escalating?, :boolean, required: true
  attr :overlay, :any, required: true
  attr :action_forms, :list, required: true

  # "Then": the actions as rungs. An escalating rule reads "each offence
  # climbs a rung"; one that is not runs them all, in order.
  defp actions_ladder(assigns) do
    assigns =
      assign(assigns,
        windows: escalation_windows(assigns.form),
        states:
          step_states(assigns.overlay, assigns.escalating?, length(assigns.preview.actions)),
        invalid: invalid_actions(assigns.form)
      )

    ~H"""
    <div class="flex flex-wrap items-center gap-x-1.5 gap-y-1 text-[0.8125rem] text-subtle">
      <input type="hidden" name={@form[:escalate].name} value="false" />
      <input
        type="checkbox"
        id={@form[:escalate].id}
        name={@form[:escalate].name}
        value="true"
        checked={@escalating?}
        class="peer sr-only"
      />
      <%= if @escalating? do %>
        <span>{gettext("each offence climbs a step · the count resets after")}</span>
        <label>
          <span class="sr-only">{gettext("Forget an offence after")}</span>
          <select
            id={@form[:escalation_window_seconds].id}
            name={@form[:escalation_window_seconds].name}
            class="bench-pill h-7 text-[0.8125rem]"
          >
            {Phoenix.HTML.Form.options_for_select(
              @windows,
              to_string(@form[:escalation_window_seconds].value)
            )}
          </select>
        </label>
        <span>{gettext("clean")}</span>
        <label
          for={@form[:escalate].id}
          class="ml-auto cursor-pointer text-xs text-muted hover:text-primary"
        >
          {gettext("run every action instead")}
        </label>
      <% else %>
        <span>{gettext("runs these actions, in order")}</span>
        <input
          type="hidden"
          name={@form[:escalation_window_seconds].name}
          value={@form[:escalation_window_seconds].value}
        />
        <label
          for={@form[:escalate].id}
          class="ml-auto cursor-pointer text-xs text-muted hover:text-primary"
        >
          {gettext("turn into a ladder")}
        </label>
      <% end %>
    </div>

    <div id="bench-ladder" class="flex flex-col gap-1.5">
      <.ladder_step
        :for={{action, index} <- Enum.with_index(@preview.actions)}
        index={index}
        action={action}
        state={Enum.at(@states, index)}
        edited?={edited?(@rule, action, index)}
        errors?={index in @invalid}
      />
    </div>

    <p
      :for={message <- errors_on(@form, :actions)}
      class="flex items-center gap-1.5 text-[0.8125rem] text-error"
    >
      <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />{message}
    </p>

    <div class="flex flex-wrap items-center gap-2.5">
      <button id="bench-add-action" type="button" class="bench-add" phx-click="add_action">
        + {if @escalating?, do: gettext("Step"), else: gettext("Action")}
      </button>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :preview, :map, required: true
  attr :known_players, :list, required: true

  # "Protections": wait, per-player cap and exemptions as chips; a click
  # opens their settings.
  defp protections(assigns) do
    assigns =
      assign(assigns,
        open?: assigns.form.source.action != nil and limit_errors?(assigns.form),
        cooldown?: switched_on?(assigns.form, :cooldown_enabled),
        cap?: switched_on?(assigns.form, :cap_enabled),
        exemptions: assigns.preview.exemptions
      )

    ~H"""
    <div x-data={"{ open: #{@open?} }"} class="flex flex-col gap-3">
      <div class="flex flex-wrap gap-2">
        <button
          :if={@cooldown?}
          type="button"
          class="bench-guard"
          x-on:click="open = !open"
          x-bind:aria-expanded="open ? 'true' : 'false'"
        >
          {gettext("wait %{gap}", gap: format_duration(@preview.cooldown_seconds))}
        </button>
        <button
          :if={@cap?}
          type="button"
          class="bench-guard"
          x-on:click="open = !open"
          x-bind:aria-expanded="open ? 'true' : 'false'"
        >
          {gettext("up to %{count} per player in 24 h", count: @preview.max_executions_per_player)}
        </button>
        <button
          :if={@exemptions && @exemptions.exempt_vip}
          type="button"
          class="bench-guard"
          x-on:click="open = !open"
        >
          {gettext("never: VIP")}
        </button>
        <button
          :for={flag <- (@exemptions && @exemptions.exempt_flags) || []}
          type="button"
          class="bench-guard"
          x-on:click="open = !open"
        >
          {gettext("never: flag “%{flag}”", flag: flag)}
        </button>
        <button
          :if={@exemptions && @exemptions.exempt_player_ids != []}
          type="button"
          class="bench-guard"
          x-on:click="open = !open"
        >
          {ngettext(
            "never: 1 player",
            "never: %{count} players",
            length(@exemptions.exempt_player_ids)
          )}
        </button>
        <button
          id="bench-add-protection"
          type="button"
          class="bench-add text-subtle"
          x-on:click="open = !open"
        >
          + {gettext("protection")}
        </button>
      </div>

      <div
        id="bench-protections"
        x-show="open"
        x-cloak={not @open?}
        class="grid gap-3 rounded-[1.25rem] bg-secondary p-4 sm:grid-cols-2"
      >
        <div class="flex flex-col gap-2.5">
          <.guard_switch
            field={@form[:cooldown_enabled]}
            title={gettext("Wait between firings")}
            hint={gettext("Make the same player wait before this rule can fire for them again.")}
          />
          <div class="flex items-center gap-2">
            <input
              type="number"
              id={@form[:cooldown_value].id}
              name={@form[:cooldown_value].name}
              value={@form[:cooldown_value].value}
              min="1"
              aria-label={gettext("Wait at least")}
              class="bench-tile w-24"
            />
            <select
              id={@form[:cooldown_unit].id}
              name={@form[:cooldown_unit].name}
              aria-label={gettext("Unit")}
              class="bench-tile w-32"
            >
              {Phoenix.HTML.Form.options_for_select(
                duration_units(),
                to_string(@form[:cooldown_unit].value)
              )}
            </select>
          </div>
          <p :for={message <- errors_on(@form, :cooldown_value)} class="text-xs text-error">
            {message}
          </p>

          <.guard_switch
            field={@form[:cap_enabled]}
            title={gettext("Daily cap")}
            hint={gettext("Stop after a number of firings per player in 24 hours.")}
          />
          <input
            type="number"
            id={@form[:max_executions_per_player].id}
            name={@form[:max_executions_per_player].name}
            value={@form[:max_executions_per_player].value}
            min="1"
            aria-label={gettext("Times per player per day")}
            class="bench-tile w-24"
          />
        </div>

        <.inputs_for :let={exempt} field={@form[:exemptions]}>
          <div id="rule-exemptions" class="flex flex-col gap-2.5">
            <.guard_switch
              field={exempt[:exempt_vip]}
              title={gettext("Never VIPs")}
              hint={gettext("Players who hold VIP on the server.")}
            />
            <.chip_input
              field={exempt[:exempt_flags]}
              label={gettext("Never players with any of these flags")}
              label_class="text-xs text-muted"
              placeholder={gettext("Type a flag, then Enter")}
            />
            <.chip_input
              field={exempt[:exempt_player_ids]}
              label={gettext("Never these players")}
              label_class="text-xs text-muted"
              placeholder={gettext("Type a player ID, then Enter")}
              list="known-player-ids"
            />
            <p class="text-xs leading-snug text-muted">
              {gettext(
                "These players are skipped before any condition is checked. CRCON does not say who is an admin, so exempt your staff by the flag you give them."
              )}
            </p>
          </div>
        </.inputs_for>
        <.player_datalists players={@known_players} />

        <p
          id="rule-limits-sentence"
          class="flex items-start gap-2 text-[0.8125rem] text-subtle sm:col-span-2"
          aria-live="polite"
        >
          <.icon name="hero-chat-bubble-bottom-center-text" class="mt-0.5 size-4 shrink-0" />
          <span>{limits_sentence(@preview)}</span>
        </p>
      </div>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :title, :string, required: true
  attr :hint, :string, required: true

  defp guard_switch(assigns) do
    ~H"""
    <label class="flex cursor-pointer items-start gap-3">
      <input type="hidden" name={@field.name} value="false" />
      <span class="pc-switch pc-switch--sm mt-0.5 shrink-0">
        <input
          type="checkbox"
          id={@field.id}
          name={@field.name}
          value="true"
          checked={HtmlForm.normalize_value("checkbox", @field.value)}
          class="peer sr-only"
        /> <span class="pc-switch__fake-input pc-switch__fake-input--sm"></span>
        <span class="pc-switch__fake-input-bg pc-switch__fake-input-bg--sm"></span>
      </span>
      <span class="flex min-w-0 flex-col gap-0.5">
        <span class="text-sm font-medium">{@title}</span>
        <span class="text-xs text-muted">{@hint}</span>
      </span>
    </label>
    """
  end

  attr :form, :any, required: true
  attr :groups, :list, required: true
  attr :preview, :map, required: true
  attr :open?, :boolean, default: false

  # Name, folder, priority, game and description, folded into one line once
  # they are set; and the state switch's two inputs, which the header's radio
  # group sets.
  defp details(assigns) do
    ~H"""
    <details id="bench-details-fields" class="group" open={@open?} data-keep-attrs="open">
      <summary class="flex min-h-[2.125rem] cursor-pointer list-none flex-wrap items-center gap-2 text-[0.8125rem] text-subtle [&::-webkit-details-marker]:hidden">
        <span class="font-medium text-base-content">
          {blank_to(@preview.name, gettext("No name yet"))}
        </span>
        <span>· {Labels.game(@preview.game)}</span>
        <span>· {gettext("priority %{count}", count: @preview.priority || 0)}</span>
        <span :if={@preview.group}>· {@preview.group}</span>
        <span class="ml-auto flex items-center gap-1 text-xs text-muted group-open:hidden">
          {gettext("edit")} <.icon name="hero-chevron-down" class="size-3.5" />
        </span>
      </summary>
      <div class="mt-2.5 grid gap-2.5 sm:grid-cols-[minmax(0,1.6fr)_minmax(0,1fr)]">
        <label class="flex flex-col gap-1.5">
          <span class="text-xs text-muted">{gettext("Name")}</span>
          <input
            type="text"
            id={@form[:name].id}
            name={@form[:name].name}
            value={@form[:name].value}
            required
            placeholder={gettext("Warn players who team kill")}
            class="bench-tile"
            aria-invalid={errors_on(@form, :name) != [] && "true"}
          />
          <span :for={message <- errors_on(@form, :name)} class="text-xs text-error">{message}</span>
        </label>
        <label class="flex flex-col gap-1.5">
          <span class="text-xs text-muted">{gettext("Group")}</span>
          <input
            type="text"
            id={@form[:group].id}
            name={@form[:group].name}
            value={@form[:group].value}
            list="rule-groups"
            autocomplete="off"
            placeholder={gettext("Seeding, anti-cheat, events…")}
            class="bench-tile"
          />
          <span :if={group_hint(@form[:group].value, @groups)} class="text-xs text-muted">
            {group_hint(@form[:group].value, @groups)}
          </span>
        </label>
        <datalist id="rule-groups">
          <option :for={group <- @groups} value={group}></option>
        </datalist>
        <label class="flex flex-col gap-1.5">
          <span class="text-xs text-muted">{gettext("Game")}</span>
          <select id={@form[:game].id} name={@form[:game].name} class="bench-tile">
            {Phoenix.HTML.Form.options_for_select(
              Labels.game_options(),
              to_string(@form[:game].value)
            )}
          </select>
        </label>
        <label class="flex flex-col gap-1.5">
          <span class="text-xs text-muted">{gettext("Priority")}</span>
          <input
            type="number"
            id={@form[:priority].id}
            name={@form[:priority].name}
            value={@form[:priority].value}
            min="0"
            class="bench-tile"
          />
        </label>
        <label class="flex flex-col gap-1.5 sm:col-span-2">
          <span class="text-xs text-muted">{gettext("Description")}</span>
          <textarea
            id={@form[:description].id}
            name={@form[:description].name}
            rows="2"
            placeholder={gettext("What is this rule for? Your fellow admins will thank you.")}
            class="bench-tile h-auto py-2.5"
          >{@form[:description].value}</textarea>
        </label>
      </div>
    </details>
    <div class="sr-only">
      <input type="hidden" name={@form[:enabled].name} value="false" />
      <input
        type="checkbox"
        id={@form[:enabled].id}
        name={@form[:enabled].name}
        value="true"
        checked={HtmlForm.normalize_value("checkbox", @form[:enabled].value)}
        tabindex="-1"
      />
      <input type="hidden" name={@form[:simulation].name} value="false" />
      <input
        type="checkbox"
        id={@form[:simulation].id}
        name={@form[:simulation].name}
        value="true"
        checked={HtmlForm.normalize_value("checkbox", @form[:simulation].value)}
        tabindex="-1"
      />
    </div>
    """
  end

  # ── Render helpers ─────────────────────────────────────────────────────────

  defp short_game(game) do
    case HllConditionalActions.Games.fetch_profile(game) do
      {:ok, profile} -> profile.short_label
      _unknown -> Labels.game(game)
    end
  end

  defp blank_to(value, fallback) when value in [nil, ""], do: fallback
  defp blank_to(value, _fallback), do: value

  defp page_heading(:new, preview, title) do
    case preview.name do
      name when is_binary(name) and name != "" -> name
      _blank -> title
    end
  end

  defp page_heading(_action, _preview, title), do: title

  # "Rules / Punishment · draft with 2 unpublished edits".
  defp breadcrumb(assigns) do
    trail =
      cond do
        assigns.live_action == :new -> gettext("Rules / New")
        assigns.preview.group -> gettext("Rules / %{group}", group: assigns.preview.group)
        true -> gettext("Rules")
      end

    Enum.join(Enum.reject([trail, breadcrumb_status(assigns)], &is_nil/1), " · ")
  end

  defp breadcrumb_status(%{live_action: :new, recipe: recipe}) when recipe not in [nil, false],
    do: gettext("from the recipe %{name}", name: Labels.recipe_name(recipe.id))

  defp breadcrumb_status(%{live_action: :new}), do: nil

  defp breadcrumb_status(assigns) do
    case edit_count(assigns.rule, assigns.preview) do
      0 ->
        nil

      count ->
        ngettext(
          "draft with 1 unpublished edit",
          "draft with %{count} unpublished edits",
          count
        )
    end
  end

  # How many parts of the definition differ from the published rule: each
  # top-level setting, each condition, each action.
  defp edit_count(rule, preview) do
    before = Snapshot.take(rule)
    now = Snapshot.take(preview)

    top =
      Enum.count(Map.keys(now) -- ["conditions", "actions"], fn key ->
        Map.get(before, key) != Map.get(now, key)
      end)

    top + list_changes(before["conditions"], now["conditions"]) +
      list_changes(before["actions"], now["actions"])
  end

  defp list_changes(before, now) do
    before = before || []
    now = now || []
    changed = Enum.zip(before, now) |> Enum.count(fn {a, b} -> a != b end)
    changed + abs(length(before) - length(now))
  end

  defp bench_state(%{enabled: false}), do: :off
  defp bench_state(%{simulation: true}), do: :simulating
  defp bench_state(_rule), do: :live

  # The enabled and simulation params a state button sets.
  defp state_flags("off"), do: {"false", nil}
  defp state_flags("simulating"), do: {"true", "true"}
  defp state_flags("live"), do: {"true", "false"}
  defp state_flags(_other), do: {nil, nil}

  defp condition_forms(form) do
    FormData.to_form(form.source, form, :conditions, [])
  end

  defp action_forms(form) do
    FormData.to_form(form.source, form, :actions, [])
  end

  # What the overlaid event read for each condition, and each group's
  # verdict, with the rule as typed.
  defp overlay_trace(nil, _preview), do: nil

  # Without the event, the trace the run recorded: each condition matched to
  # the recorded one at the same place when it checks the same field.
  defp overlay_trace(%{context: nil, run: %{execution: execution}}, preview) do
    recorded = (execution.trace || %{})["conditions"] || []

    conditions =
      preview.conditions
      |> Enum.with_index()
      |> Map.new(fn {condition, index} ->
        field = to_string(condition.field)

        case Enum.at(recorded, index) do
          %{"field" => ^field} = entry ->
            {index, %{result: entry["result"] == true, actual: entry["actual"]}}

          _other ->
            {index, nil}
        end
      end)

    results =
      Enum.map(0..(length(preview.conditions) - 1)//1, &match?(%{result: true}, conditions[&1]))

    groups =
      preview.conditions
      |> ConditionGroups.group_results(results, preview.logical_operator)
      |> Map.new(&{&1.id, &1.result})

    %{conditions: conditions, groups: groups}
  end

  defp overlay_trace(overlay, preview) do
    explained = Evaluator.explain(preview, overlay.context)
    results = Enum.map(explained.conditions, & &1.result)

    groups =
      preview.conditions
      |> ConditionGroups.group_results(results, preview.logical_operator)
      |> Map.new(&{&1.id, &1.result})

    %{
      conditions: explained.conditions |> Enum.with_index() |> Map.new(fn {c, i} -> {i, c} end),
      groups: groups
    }
  end

  defp condition_trace(nil, _index), do: :none
  defp condition_trace(trace, index), do: Map.get(trace.conditions, index)

  defp group_result(nil, _group), do: :none
  defp group_result(trace, group), do: Map.get(trace.groups, group, :none)

  # Where the overlaid event stands on the ladder.
  defp step_states(nil, _escalating?, count), do: List.duplicate(nil, count)

  defp step_states(%{step: step}, true, count) when is_integer(step) do
    for index <- 0..(count - 1)//1 do
      cond do
        index < step -> :ran
        index == step -> :current
        index == step + 1 -> :next
        true -> nil
      end
    end
  end

  defp step_states(%{fired?: true}, false, count), do: List.duplicate(:current, count)
  defp step_states(_overlay, _escalating?, count), do: List.duplicate(nil, count)

  defp edited?(%Rule{id: nil}, _action, _index), do: false

  defp edited?(rule, action, index) do
    case Enum.at(rule.actions, index) do
      nil ->
        true

      saved ->
        saved.type != action.type or (saved.parameters || %{}) != (action.parameters || %{})
    end
  end

  defp invalid_actions(form) do
    case Map.get(form.source.changes, :actions) do
      rows when is_list(rows) ->
        rows
        |> Enum.with_index()
        |> Enum.filter(fn {row, _index} -> match?(%Ecto.Changeset{valid?: false}, row) end)
        |> Enum.map(&elem(&1, 1))

      _unchanged ->
        []
    end
  end

  defp limit_errors?(form) do
    Enum.any?(form.source.errors, fn {field, _error} ->
      field in [:cooldown_seconds, :cooldown_value, :max_executions_per_player]
    end)
  end

  defp server_options(servers, game) do
    [{gettext("every %{game} server", game: short_game(game)), ""}] ++
      (servers
       |> Enum.filter(&(&1.game == game))
       |> Enum.map(&{&1.name, &1.id}))
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

  # An escalating rule turns its action list into a ladder. The switch is
  # the source of truth, and falls back to the window for a rule loaded
  # straight from the database, where the virtual field has not been
  # derived yet.
  defp escalating?(form) do
    case HtmlForm.input_value(form, :escalate) do
      nil -> not blank_or_zero?(HtmlForm.input_value(form, :escalation_window_seconds))
      value -> HtmlForm.normalize_value("checkbox", value)
    end
  end

  # Windows an admin can reason about. A rule that arrived from an import or
  # the API may carry any number of seconds, so its own value joins the list
  # rather than being silently rounded to the nearest option.
  defp escalation_windows(form) do
    options = [
      {gettext("15 min"), 900},
      {gettext("30 min"), 1800},
      {gettext("1 h"), 3600},
      {gettext("6 h"), 21_600},
      {gettext("24 h"), 86_400},
      {gettext("1 week"), 604_800}
    ]

    current = to_seconds(HtmlForm.input_value(form, :escalation_window_seconds))

    if current in [nil, 0] or Enum.any?(options, fn {_label, value} -> value == current end) do
      options
    else
      Enum.sort_by([{format_duration(current), current} | options], fn {_label, value} ->
        value
      end)
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
