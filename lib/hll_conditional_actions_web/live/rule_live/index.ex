defmodule HllConditionalActionsWeb.RuleLive.Index do
  @moduledoc """
  Lists rules grouped by folder, each with its state, a short sentence, a
  week of activity and its switch, and hosts the recipe gallery, bulk
  actions, import and export.

  A user restricted to certain servers sees their own rules plus the
  fleet-wide rules that reach their servers; the latter are marked read only,
  since changing one would affect servers they do not administer.

  The numbers (a week of runs per rule, what failed, the week against the
  one before) come from `HllConditionalActions.Rules.Insights`.
  """

  use HllConditionalActionsWeb, :live_view

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_rules}}

  import HllConditionalActionsWeb.RuleComponents

  import HllConditionalActionsWeb.RulePause,
    only: [pause_menu_items: 1, pause_note: 1, pause_modal: 1]

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Features
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Audit
  alias HllConditionalActions.Rules.Health
  alias HllConditionalActions.Rules.Insights
  alias HllConditionalActions.Rules.Recipes
  alias HllConditionalActions.Servers

  @states ~w(all live simulating draft paused failing)

  @sorts ~w(week priority name last_fired failures)

  # Past this many rules the calm folders start closed, so the ones that
  # need a look are what the page opens on.
  @open_everything 10

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    servers = Servers.list_servers_for(socket.assigns[:current_user])

    {:ok,
     socket
     |> assign(:page_title, gettext("Rules"))
     |> assign(:servers, servers)
     |> assign(:zone, zone(servers))
     # Under /servers/:id the list is that server's: its own rules and the
     # fleet wide ones of its game.
     |> assign(:scope, Enum.find(servers, &(to_string(&1.id) == params["server_id"])))
     |> assign(:search, "")
     |> assign(:state, "all")
     |> assign(:sort, "week")
     |> assign(:view, "list")
     |> assign(:recipe_search, "")
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
     |> assign(:pause_rule, nil)
     |> assign(:selected, MapSet.new())
     |> load_rules()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    # `?recipes=1` is how the builder links to the gallery.
    view =
      if params["view"] == "recipes" or params["recipes"] in ["1", "true"],
        do: "recipes",
        else: "list"

    {:noreply,
     socket
     |> assign(:view, view)
     |> assign(
       :page_title,
       if(view == "recipes", do: gettext("Ready-made recipes"), else: gettext("Rules"))
     )}
  end

  @impl Phoenix.LiveView
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:search, String.trim(params["search"] || socket.assigns.search))
     |> assign(:state, cast_state(params["state"] || socket.assigns.state))
     |> assign(:sort, cast_sort(params["sort"] || socket.assigns.sort))
     |> load_rules()}
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, socket |> assign(:search, String.trim(search)) |> load_rules()}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, socket |> assign(:search, "") |> assign(:state, "all") |> load_rules()}
  end

  def handle_event("recipe_search", %{"search" => search}, socket) do
    {:noreply, assign(socket, :recipe_search, String.trim(search))}
  end

  # ── Selection and bulk actions ─────────────────────────────────────────────

  def handle_event("select", %{"id" => id}, socket) do
    id = cast_integer(id)
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    # Only what is on screen and editable can be selected, so a crafted
    # event cannot slip a hidden rule into the next bulk action.
    {:noreply,
     assign(socket, :selected, MapSet.intersection(selected, selectable_ids(socket.assigns)))}
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
      case id
           |> Rules.get_rule!()
           |> HllConditionalActionsWeb.RulePause.run(params, socket.assigns.current_user) do
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
     assign(socket, :pause_rule, Enum.find(socket.assigns.all_rules, &(to_string(&1.id) == id)))}
  end

  def handle_event("close_pause", _params, socket) do
    {:noreply, assign(socket, :pause_rule, nil)}
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

  # ── Loading ────────────────────────────────────────────────────────────────

  defp load_rules(socket) do
    user = socket.assigns[:current_user]
    scope = if socket.assigns.scope, do: [applies_to: socket.assigns.scope], else: []
    search = if socket.assigns.search == "", do: [], else: [search: socket.assigns.search]
    all_rules = Rules.list_rules_for(user, search ++ scope)
    ids = Enum.map(all_rules, & &1.id)
    activity = Rules.activity_for_rules(ids)
    week = Insights.week_activity(user, ids)
    failures = Insights.failures(user, ids)
    health = Health.for_rules(all_rules, socket.assigns.servers)
    editable = Map.new(all_rules, &{&1.id, Rules.editable_by?(&1, user)})
    states = Map.new(all_rules, &{&1.id, state(&1, Map.has_key?(activity, &1.id))})
    ready = ready_rules(all_rules, states, week, health)
    context = %{states: states, failures: failures, health: health}

    rules =
      all_rules
      |> Enum.filter(&in_state?(&1, socket.assigns.state, context))
      |> sort_rules(socket.assigns.sort, activity, week, failures)

    socket
    |> assign(:all_rules, all_rules)
    |> assign(:rules, rules)
    |> assign(:folders, folders(rules))
    |> assign(
      :state_counts,
      Map.new(@states, &{&1, Enum.count(all_rules, fn rule -> in_state?(rule, &1, context) end)})
    )
    |> assign(:editable, editable)
    |> assign(:health, health)
    |> assign(:activity, activity)
    |> assign(:week, week)
    |> assign(:failures, failures)
    |> assign(:states, states)
    |> assign(:ready, ready)
    |> assign(:summary, Insights.week_summary(user, ids))
    |> assign(:groups, Rules.list_groups(user))
    |> assign(:usage, recipe_usage(all_rules, socket.assigns.servers))
    |> then(&assign(&1, :attention, attention_items(&1.assigns)))
    # A selection only ever holds rules that are on screen and editable, so a
    # filter change can never leave a hidden rule in the next bulk action.
    |> update(:selected, fn selected ->
      visible = MapSet.new(rules, & &1.id)
      MapSet.filter(selected, &(Map.get(editable, &1, false) and MapSet.member?(visible, &1)))
    end)
  end

  # A simulating rule that ran for at least three days without a failure or
  # a health warning is ready to act for real: `%{rule_id => simulation}`.
  defp ready_rules(rules, states, week, health) do
    for rule <- rules,
        states[rule.id] == :simulating,
        Map.get(health, rule.id, []) == [],
        stats = Map.get(week, rule.id),
        (stats && stats.total > 0) and stats.failed == 0,
        simulation = Insights.simulation(rule),
        simulation.failures == 0 and simulation.days >= 3,
        into: %{},
        do: {rule.id, simulation}
  end

  # The folders in name order, loose rules last; rules keep the chosen sort
  # inside each folder.
  defp folders(rules) do
    rules
    |> Enum.group_by(&(&1.group || ""))
    |> Enum.sort_by(fn {group, _rules} -> {group == "", String.downcase(group)} end)
  end

  # ── States ─────────────────────────────────────────────────────────────────

  defp cast_state(state) when state in @states, do: state
  defp cast_state("off"), do: "paused"
  defp cast_state(_state), do: "all"

  defp in_state?(_rule, "all", _context), do: true
  defp in_state?(rule, "live", context), do: context.states[rule.id] == :live
  defp in_state?(rule, "simulating", context), do: context.states[rule.id] == :simulating
  defp in_state?(rule, "paused", context), do: context.states[rule.id] == :paused

  defp in_state?(rule, "draft", context),
    do: context.states[rule.id] == :draft or rule.draft != nil

  defp in_state?(rule, "failing", context), do: failing?(rule, context.failures, context.health)

  defp failing?(rule, failures, health) do
    Map.has_key?(failures, rule.id) or
      Enum.any?(Map.get(health, rule.id, []), &(&1.tone == "error"))
  end

  defp state_options(counts) do
    [
      {"all", gettext("All"), nil},
      {"live", gettext("Live"), :live},
      {"simulating", gettext("Simulating"), :simulating},
      {"draft", gettext("Draft"), nil},
      {"paused", gettext("Paused"), nil},
      {"failing", gettext("Failing"), nil}
    ]
    |> Enum.map(fn {value, label, mark} -> {value, label, mark, Map.get(counts, value, 0)} end)
  end

  # ── Sorting ────────────────────────────────────────────────────────────────

  defp cast_sort(sort) when sort in @sorts, do: sort
  defp cast_sort("activity"), do: "week"
  defp cast_sort(_sort), do: "week"

  defp sort_options do
    [
      {gettext("runs in 7 days"), "week"},
      {gettext("priority"), "priority"},
      {gettext("name"), "name"},
      {gettext("last run"), "last_fired"},
      {gettext("failures in 24 h"), "failures"}
    ]
  end

  # The query already orders by priority then name, which every other sort
  # keeps as its tie breaker (Enum.sort_by is stable).
  defp sort_rules(rules, "priority", _activity, _week, _failures), do: rules

  defp sort_rules(rules, "name", _activity, _week, _failures),
    do: Enum.sort_by(rules, &String.downcase(&1.name))

  defp sort_rules(rules, "last_fired", activity, _week, _failures) do
    # Never fired sorts last, not first.
    Enum.sort_by(rules, fn rule ->
      case activity[rule.id] do
        %{last_executed_at: %DateTime{} = at} -> -DateTime.to_unix(at, :microsecond)
        _never -> 0
      end
    end)
  end

  defp sort_rules(rules, "failures", _activity, _week, failures),
    do: Enum.sort_by(rules, &(-(get_in(failures, [&1.id, :count]) || 0)))

  defp sort_rules(rules, _week, _activity, week, _failures),
    do: Enum.sort_by(rules, &(-(get_in(week, [&1.id, :total]) || 0)))

  # ── Selection ──────────────────────────────────────────────────────────────

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

  defp cast_integer(nil), do: nil
  defp cast_integer(""), do: nil

  defp cast_integer(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  # ── What the page says ─────────────────────────────────────────────────────

  defp page_subtitle(rules, servers) do
    groups = rules |> Enum.map(& &1.group) |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()

    [
      ngettext("%{count} rule", "%{count} rules", length(rules), count: length(rules)) <>
        if(groups != [],
          do:
            " " <>
              ngettext("in %{count} folder", "in %{count} folders", length(groups),
                count: length(groups)
              ),
          else: ""
        ),
      servers != [] &&
        ngettext("%{count} server", "%{count} servers", length(servers), count: length(servers))
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  # What deserves a look, most urgent first: failures, health warnings,
  # simulations that are ready, and drafts nobody finished.
  defp attention_items(assigns) do
    rules = assigns.all_rules

    Enum.take(
      failing_items(rules, assigns.failures) ++
        issue_items(rules, assigns.failures, assigns.health) ++
        ready_items(rules, assigns.ready) ++ draft_items(rules, assigns.states),
      5
    )
  end

  defp failing_items(rules, failures) do
    for rule <- rules, failure = Map.get(failures, rule.id) do
      %{
        id: "failing-#{rule.id}",
        icon: "hero-exclamation-triangle",
        tone: "warning",
        title:
          ngettext("%{name} failed once", "%{name} failed %{count}×", failure.count,
            name: rule.name
          ),
        meta: failure.error || gettext("See the failed runs"),
        to: ~p"/rules/#{rule}?#{[tab: "executions", outcome: "failed"]}"
      }
    end
  end

  defp issue_items(rules, failures, health) do
    for rule <- rules,
        not Map.has_key?(failures, rule.id),
        issue <- Enum.take(Enum.filter(Map.get(health, rule.id, []), &(&1.tone == "error")), 1) do
      %{
        id: "health-#{rule.id}",
        icon: "hero-heart",
        tone: "error",
        title: "#{rule.name}: #{Labels.health_issue(issue.id)}",
        meta: Labels.health_explanation(issue.id),
        to: ~p"/rules/#{rule}"
      }
    end
  end

  defp ready_items(rules, ready) do
    for rule <- rules, simulation = Map.get(ready, rule.id) do
      %{
        id: "ready-#{rule.id}",
        icon: "hero-check",
        tone: "primary",
        title: gettext("%{name} ready to act", name: rule.name),
        meta:
          ngettext(
            "1 day in simulation, 0 failures",
            "%{count} days in simulation, 0 failures",
            simulation.days
          ),
        to: ~p"/rules/#{rule}"
      }
    end
  end

  defp draft_items(rules, states) do
    for rule <- rules, states[rule.id] == :draft or rule.draft do
      %{
        id: "draft-#{rule.id}",
        icon: "hero-pencil",
        tone: "neutral",
        title: draft_title(stale_days(rule)),
        meta: Enum.join(Enum.reject([rule.name, draft_author(rule)], &is_nil/1), " · "),
        to: if(rule.draft, do: ~p"/rules/#{rule}/edit", else: ~p"/rules/#{rule}")
      }
    end
  end

  defp draft_title(0), do: gettext("Draft waiting")

  defp draft_title(days),
    do: ngettext("Draft idle for 1 day", "Draft idle for %{count} days", days)

  defp stale_days(rule) do
    at = rule.draft_updated_at || rule.updated_at

    case at do
      %DateTime{} -> div(DateTime.diff(DateTime.utc_now(), at, :second), 86_400)
      %NaiveDateTime{} -> div(NaiveDateTime.diff(NaiveDateTime.utc_now(), at, :second), 86_400)
      _other -> 0
    end
  end

  defp draft_author(%{draft_user_name: name}) when is_binary(name), do: name

  defp draft_author(rule) do
    case Audit.list_versions(rule.id, limit: 1) do
      [%{user_name: name} | _rest] -> name
      _none -> nil
    end
  end

  # Folders open when they hold something worth a look (a failure, a
  # simulation, a draft), or when the list is short enough to show whole.
  defp open_folder?(rules, assigns) do
    length(assigns.rules) <= @open_everything or assigns.search != "" or
      assigns.state != "all" or
      Enum.any?(rules, fn rule ->
        assigns.states[rule.id] != :live or failing?(rule, assigns.failures, assigns.health) or
          rule.draft != nil
      end)
  end

  defp folder_names(rules) do
    case Enum.map(rules, & &1.name) do
      [a] -> a
      [a, b] -> gettext("%{a} and %{b}", a: a, b: b)
      [a, b | rest] -> gettext("%{a}, %{b} and %{count} more", a: a, b: b, count: length(rest))
    end
  end

  defp week_total(week, rule), do: get_in(week, [rule.id, :total]) || 0

  @impl Phoenix.LiveView
  def render(%{view: "recipes"} = assigns) do
    assigns =
      assigns
      |> assign(:can_manage?, Accounts.can?(assigns.current_user, :manage_rules))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Ready-made recipes")}
      crumb={gettext("Rules") <> " / " <> gettext("Recipes")}
      back={list_path(@scope)}
      back_label={gettext("Back to rules")}
      scope={false}
      bell={false}
    >
      <:search>
        <form id="recipe-search" phx-change="recipe_search" phx-submit="recipe_search">
          <label class="flex h-12 w-[17.5rem] max-w-full items-center gap-2.5 rounded-full border border-base-300 bg-base-100 px-[1.125rem] text-muted">
            <.icon name="hero-magnifying-glass" class="size-[1.125rem] shrink-0" />
            <span class="sr-only">{gettext("Search recipes")}</span>
            <input
              type="search"
              name="search"
              value={@recipe_search}
              phx-debounce="200"
              placeholder={gettext("Search: VIP, chat, Discord…")}
              class="w-full border-0 bg-transparent p-0 text-sm text-base-content placeholder:text-muted focus:ring-0"
            />
          </label>
        </form>
      </:search>
      <:actions>
        <.header_button :if={@can_manage?} navigate={~p"/rules/new"}>
          {gettext("Start from scratch")}
        </.header_button>
      </:actions>

      <div class="flex flex-wrap items-center gap-2.5 rounded-[1.25rem] border border-dashed border-accent/35 bg-accent/8 px-5 py-3.5">
        <span
          class="size-2 shrink-0 rounded-full border-[1.5px] border-dashed border-accent"
          aria-hidden="true"
        ></span>
        <span class="min-w-0 flex-1 text-sm text-base-content/90">
          {gettext(
            "Every recipe starts in simulation: the rule watches the real game, but nothing is sent to players until you switch it on."
          )}
        </span>
        <span class="text-[0.8125rem] text-subtle">
          {ngettext("1 recipe", "%{count} recipes", length(Recipes.all()))} · {ngettext(
            "1 already in use",
            "%{count} already in use",
            Enum.count(@usage, fn {_id, use} -> use.rules > 0 end)
          )}
        </span>
      </div>

      <div id="recipe-gallery" class="grid items-start gap-4 sm:grid-cols-2 xl:grid-cols-6">
        <section
          :for={{category, recipes} <- recipe_categories(@recipe_search)}
          id={"recipe-category-#{category}"}
          class={[
            "flex flex-col gap-2.5 rounded-[1.5rem] bg-base-100 p-4",
            category == :reward && "sm:col-span-2"
          ]}
        >
          <div class="flex items-baseline gap-2 px-1 pb-0.5">
            <h2 class="flex-1 font-display text-[1.0625rem] font-semibold">
              {category_name(category)}
            </h2>
            <span class="font-mono text-xs text-muted">{length(recipes)}</span>
          </div>
          <div class={["grid gap-2.5", category == :reward && "sm:grid-cols-2"]}>
            <.link
              :for={recipe <- recipes}
              id={"recipe-#{recipe.id}"}
              navigate={~p"/rules/new?recipe=#{recipe.id}"}
              class="flex flex-col items-start gap-2 rounded-[1.125rem] bg-secondary p-3.5 ring-1 ring-transparent transition hover:-translate-y-0.5 hover:ring-primary/40"
            >
              <span class={[
                "flex size-8 items-center justify-center rounded-[0.625rem]",
                category_tone(category, recipe)
              ]}>
                <span :if={category == :commands} class="font-mono text-[0.9375rem] font-medium">
                  !
                </span>
                <.icon :if={category != :commands} name={recipe.icon} class="size-4" />
              </span>
              <strong class="text-sm font-semibold">{Labels.recipe_name(recipe.id)}</strong>
              <span class="text-xs leading-snug text-muted">
                {Labels.recipe_description(recipe.id)}
              </span>
              <.recipe_tag usage={Map.get(@usage, recipe.id)} />
            </.link>
          </div>
        </section>
      </div>

      <p
        :if={recipe_categories(@recipe_search) == []}
        class="rounded-[1.5rem] bg-base-100 px-6 py-8 text-center text-sm text-muted"
      >
        {gettext("No recipe matches that search.")}
      </p>
    </Layouts.app>
    """
  end

  def render(assigns) do
    assigns =
      assigns
      |> assign(:can_manage?, Accounts.can?(assigns.current_user, :manage_rules))
      |> assign(:selectable, selectable_ids(assigns))
      |> assign(
        :open_folders,
        for(
          {group, rules} <- assigns.folders,
          open_folder?(rules, assigns),
          into: MapSet.new(),
          do: group
        )
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Rules")}
      page_subtitle={page_subtitle(@all_rules, @servers)}
    >
      <:search>
        <form id="rule-search" phx-change="search" phx-submit="search" class="max-md:hidden">
          <label class="flex h-12 w-[16.25rem] items-center gap-2.5 rounded-full border border-base-300 bg-base-100 px-[1.125rem] text-muted">
            <.icon name="hero-magnifying-glass" class="size-[1.125rem] shrink-0" />
            <span class="sr-only">{gettext("Search rules")}</span>
            <input
              type="search"
              name="search"
              value={@search}
              phx-debounce="300"
              placeholder={gettext("Search by name or action")}
              class="w-full border-0 bg-transparent p-0 text-sm text-base-content placeholder:text-muted focus:ring-0"
            />
          </label>
        </form>
      </:search>
      <:actions>
        <%!-- Phone: the search hides behind a round button (MobileRules). --%>
        <button
          id="rule-search-toggle"
          type="button"
          phx-click={JS.toggle(to: "#rule-search-m") |> JS.focus(to: "#rule-search-m input")}
          aria-label={gettext("Search rules")}
          class="flex size-11 shrink-0 cursor-pointer items-center justify-center rounded-full border border-base-300 bg-base-100 md:hidden"
        >
          <.icon name="hero-magnifying-glass" class="size-[1.125rem]" />
        </button>
        <.header_button
          :if={@can_manage? and @servers != []}
          type="button"
          icon="hero-arrow-down-tray"
          phx-click="open_import"
          compact
          class="max-md:hidden"
        >
          {gettext("Import")}
        </.header_button>

        <.header_button
          href={export_path(@search)}
          download
          icon="hero-arrow-up-tray"
          compact
          class="max-md:hidden"
        >
          {gettext("Export JSON")}
        </.header_button>

        <.header_button
          :if={@can_manage? and @servers != []}
          primary
          navigate={if @scope, do: ~p"/rules/new?#{[server_id: @scope.id]}", else: ~p"/rules/new"}
          icon="hero-plus"
          aria-label={gettext("New rule")}
        >
          {gettext("New rule")}
        </.header_button>
      </:actions>

      <form
        id="rule-search-m"
        phx-change="search"
        phx-submit="search"
        class={["md:hidden", @search == "" && "hidden"]}
      >
        <label class="flex h-11 items-center gap-2.5 rounded-full border border-base-300 bg-base-100 px-4 text-muted">
          <.icon name="hero-magnifying-glass" class="size-4 shrink-0" />
          <span class="sr-only">{gettext("Search rules")}</span>
          <input
            type="search"
            name="search"
            value={@search}
            phx-debounce="300"
            placeholder={gettext("Search by name or action")}
            class="w-full border-0 bg-transparent p-0 text-sm text-base-content placeholder:text-muted focus:ring-0"
          />
        </label>
      </form>

      <%!-- The state tabs and the sort are one form, so the list always
            agrees with what the tabs say. The tabs are radios. --%>
      <form
        :if={@all_rules != [] or @search != ""}
        id="rule-filters"
        phx-change="filter"
        class="flex flex-wrap items-center gap-3"
      >
        <fieldset
          id="rule-state-tabs"
          class="-mx-1 flex max-w-full gap-1.5 overflow-x-auto px-1 lg:mx-0 lg:gap-1 lg:overflow-visible lg:rounded-full lg:bg-base-100 lg:p-1"
        >
          <legend class="sr-only">{gettext("Filter by state")}</legend>
          <label
            :for={{value, label, mark, count} <- state_options(@state_counts)}
            class={[
              "shrink-0",
              cond do
                value == "all" -> "max-lg:order-1"
                value == "failing" -> "max-lg:order-2"
                true -> "max-lg:order-3"
              end
            ]}
          >
            <input
              type="radio"
              name="state"
              value={value}
              checked={@state == value}
              class="peer sr-only"
            />
            <span class={[
              "flex h-10 cursor-pointer items-center gap-[7px] whitespace-nowrap rounded-full px-3.5 text-[0.8125rem] transition-colors lg:h-9",
              "peer-focus-visible:ring-2 peer-focus-visible:ring-primary/50",
              cond do
                @state == value ->
                  "bg-base-content px-4 font-semibold text-base-100"

                value == "failing" and count > 0 ->
                  "bg-warning/10 font-semibold text-warning ring-1 ring-inset ring-warning/35"

                true ->
                  "font-medium text-subtle ring-1 ring-inset ring-base-300 hover:text-base-content max-lg:bg-base-100 max-lg:text-base-content lg:ring-0"
              end
            ]}>
              <.state_mark :if={mark && @state != value} state={mark} />
              {label}
              <span class={[
                "font-mono text-xs",
                (@state != value and not (value == "failing" and count > 0)) && "text-muted"
              ]}>
                {count}
              </span>
            </span>
          </label>
        </fieldset>

        <span class="grow max-lg:hidden"></span>

        <.link
          :if={@servers != []}
          navigate={~p"/rules/simulate"}
          class="flex h-10 items-center gap-2 rounded-full border border-base-300 bg-base-100 pr-4 pl-3.5 text-[0.8125rem] transition-colors hover:bg-secondary max-lg:hidden"
        >
          <.icon name="hero-beaker" class="size-4" />
          {gettext("Simulate an event")}
        </.link>

        <label class="relative flex h-10 items-center gap-1.5 rounded-full pl-3.5 text-[0.8125rem] text-subtle max-lg:hidden">
          <span>{gettext("Sort:")}</span>
          <select
            id="rule-sort"
            name="sort"
            class="h-full cursor-pointer appearance-none border-0 bg-transparent py-0 pr-7 pl-0 text-[0.8125rem] text-subtle focus:ring-0"
          >
            {Phoenix.HTML.Form.options_for_select(sort_options(), @sort)}
          </select>
          <.icon
            name="hero-chevron-down"
            class="pointer-events-none absolute right-2.5 size-3.5 text-subtle"
          />
        </label>
      </form>

      <%!-- Without a server a rule has nowhere to run, so the page points at
            the step that is actually missing instead of offering recipes. --%>
      <.empty_state
        :if={@all_rules == [] and @servers == []}
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
          if @search != "" or @state != "all",
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
            :if={@can_manage? and @search == "" and @state == "all"}
            link_type="live_patch"
            to={list_path(@scope, view: "recipes")}
            size="sm"
            color="primary"
            icon="hero-sparkles"
            label={gettext("Start from a recipe")}
          />
          <.button
            :if={@search != "" or @state != "all"}
            type="button"
            size="sm"
            variant="outline"
            color="gray"
            icon="hero-x-mark"
            phx-click="clear_filters"
            label={gettext("Clear")}
          />
        </:action>
      </.empty_state>

      <%!-- The first rule is the hardest to write, so the empty page leads with
            the recipes most communities start from, each opening its short
            wizard. --%>
      <section
        :if={
          @all_rules == [] and @servers != [] and @search == "" and @state == "all" and @can_manage?
        }
        id="empty-recipes"
        class="flex flex-col gap-3"
      >
        <h2 class="font-display text-xl font-semibold">{gettext("Popular starting points")}</h2>
        <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
          <.link
            :for={recipe <- Enum.filter(Recipes.all(), &(Map.get(&1, :questions, []) != []))}
            navigate={~p"/rules/new?recipe=#{recipe.id}"}
            class="flex items-start gap-3 rounded-[1.125rem] bg-base-100 p-3.5 ring-1 ring-transparent transition hover:-translate-y-0.5 hover:ring-primary/40"
          >
            <span class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-primary/12 text-primary">
              <.icon name={recipe.icon} class="size-5" />
            </span>
            <span class="flex min-w-0 flex-col gap-1">
              <strong class="text-sm font-semibold">{Labels.recipe_name(recipe.id)}</strong>
              <span class="text-xs leading-snug text-muted">{Labels.recipe_description(recipe.id)}</span>
            </span>
          </.link>
        </div>
      </section>

      <div
        :if={@rules != [] or (@all_rules != [] and @can_manage?)}
        class="grid items-start gap-5 xl:grid-cols-[minmax(0,1fr)_19.875rem]"
      >
        <section
          :if={@rules != []}
          aria-label={gettext("Rule list")}
          class="relative min-w-0 rounded-3xl bg-base-100 px-3 pt-1 pb-1.5 lg:rounded-[1.75rem] lg:px-3.5 lg:pt-2.5 lg:pb-3"
        >
          <div class="relative hidden grid-cols-[6.75rem_minmax(0,1fr)_6.5rem_8.25rem_4rem_5rem] items-center gap-3 border-b border-base-300 px-3 pt-2 pb-2.5 text-[0.6875rem] uppercase tracking-[0.08em] text-muted lg:grid">
            <input
              :if={MapSet.size(@selectable) > 0}
              id="rule-select-all"
              type="checkbox"
              class={[
                "pc-checkbox absolute top-1/2 -left-2.5 size-3.5 -translate-y-1/2 transition-opacity",
                if(MapSet.size(@selected) > 0,
                  do: "opacity-100",
                  else: "opacity-0 hover:opacity-100 focus:opacity-100"
                )
              ]}
              checked={MapSet.size(@selected) > 0 and MapSet.subset?(@selectable, @selected)}
              phx-click="select_all"
              aria-label={gettext("Select every rule shown")}
            />
            <span>{gettext("State")}</span>
            <span>{gettext("Rule")}</span>
            <span>{gettext("Scope")}</span>
            <span>{gettext("Runs · 7 days")}</span>
            <span>{gettext("Last")}</span>
            <span>{gettext("On")}</span>
          </div>

          <div id="rule-list" class="flex flex-col">
            <details
              :for={{group, rules} <- @folders}
              id={"rule-folder-#{folder_id(group)}"}
              open={MapSet.member?(@open_folders, group)}
              phx-mounted={JS.ignore_attributes("open")}
              class="group/folder border-base-300 [&:not(:first-child)]:border-t lg:border-t-0 lg:[&:not(:first-child)[open]]:border-t-0 lg:[&:not(:first-child):not([open])]:border-t"
            >
              <summary class="flex min-h-10 cursor-pointer list-none items-center gap-2.5 rounded-2xl px-0.5 text-subtle hover:text-base-content lg:px-3 lg:pt-3.5 lg:pb-1.5 lg:group-[:not([open])]/folder:py-3 [&::-webkit-details-marker]:hidden">
                <.icon
                  name="hero-chevron-right"
                  class="size-4 shrink-0 transition-transform group-open/folder:rotate-90 max-lg:hidden"
                />
                <.icon
                  name={if group == "", do: "hero-inbox", else: "hero-folder"}
                  class="size-4 shrink-0"
                />
                <h2 class="shrink-0 text-sm font-semibold text-base-content">
                  {if group == "", do: gettext("Without a folder"), else: group}
                </h2>
                <span class="font-mono text-xs text-muted">{length(rules)}</span>
                <span class="hidden min-w-0 flex-1 truncate text-[0.8125rem] text-muted lg:group-[:not([open])]/folder:block">
                  {folder_names(rules)}
                </span>
                <span class="grow lg:group-[:not([open])]/folder:hidden"></span>
                <span class="text-xs text-muted lg:hidden">
                  {gettext("%{live} of %{total}",
                    live: Enum.count(rules, &(@states[&1.id] == :live)),
                    total: length(rules)
                  )}
                </span>
                <span class="hidden shrink-0 text-xs text-primary lg:group-[:not([open])]/folder:inline">
                  {gettext("%{count} live", count: Enum.count(rules, &(@states[&1.id] == :live)))}
                </span>
                <span class="hidden w-16 shrink-0 font-mono text-xs text-subtle lg:group-[:not([open])]/folder:inline">
                  {number(Enum.sum(Enum.map(rules, &week_total(@week, &1))))}
                </span>
                <span :if={group != "" and @can_manage?} class="max-lg:hidden">
                  <.rule_menu
                    id={"rule-folder-menu-#{folder_id(group)}"}
                    label={gettext("Actions for the folder %{group}", group: group)}
                    class="size-7 opacity-0 transition-opacity group-hover/folder:opacity-100 focus:opacity-100"
                  >
                    <.menu_item
                      icon="hero-play"
                      phx-click="toggle_group"
                      phx-value-group={group}
                      phx-value-enabled="true"
                    >
                      {gettext("Turn on every rule")}
                    </.menu_item>
                    <.menu_item
                      icon="hero-stop"
                      phx-click="toggle_group"
                      phx-value-group={group}
                      phx-value-enabled="false"
                      data-confirm={gettext("Disable every rule in %{group}?", group: group)}
                    >
                      {gettext("Turn off every rule")}
                    </.menu_item>
                  </.rule_menu>
                </span>
              </summary>

              <ul class="flex flex-col lg:gap-0">
                <li
                  :for={rule <- rules}
                  id={"rule-#{rule.id}"}
                  data-rule
                  class={[
                    "group/row relative rounded-2xl transition-colors lg:rounded-[0.875rem]",
                    if(failing?(rule, @failures, @health),
                      do: "bg-warning/7 ring-1 ring-inset ring-warning/35 max-lg:my-0.5",
                      else: "border-t border-base-300 lg:border-t-0 lg:hover:bg-secondary/60"
                    )
                  ]}
                >
                  <input
                    :if={@can_manage? and @editable[rule.id]}
                    id={"rule-select-#{rule.id}"}
                    type="checkbox"
                    class={[
                      "pc-checkbox absolute top-1/2 -left-2.5 z-10 size-3.5 -translate-y-1/2 transition-opacity max-lg:hidden",
                      if(MapSet.size(@selected) > 0,
                        do: "opacity-100",
                        else: "opacity-0 group-hover/row:opacity-100 focus:opacity-100"
                      )
                    ]}
                    checked={MapSet.member?(@selected, rule.id)}
                    phx-click="select"
                    phx-value-id={rule.id}
                    aria-label={gettext("Select %{name}", name: rule.name)}
                  />

                  <%!-- Desktop: the columns of the board. --%>
                  <div class="hidden grid-cols-[6.75rem_minmax(0,1fr)_6.5rem_8.25rem_4rem_5rem] items-center gap-3 px-3 py-[7px] lg:grid">
                    <span><.state_pill state={@states[rule.id]} /></span>

                    <div class="flex min-w-0 flex-col gap-0.5">
                      <div class="flex min-w-0 items-center gap-2">
                        <.link
                          navigate={~p"/rules/#{rule}"}
                          class="truncate text-sm font-semibold hover:text-primary"
                        >
                          {rule.name}
                        </.link>
                        <.row_badges
                          rule={rule}
                          ready={Map.has_key?(@ready, rule.id)}
                          editable={@editable[rule.id]}
                          health={Map.get(@health, rule.id, [])}
                        />
                      </div>
                      <p class="truncate text-[0.8125rem] text-muted" title={short_sentence(rule)}>
                        {short_sentence(rule)}
                      </p>
                      <.failure_line rule={rule} failure={Map.get(@failures, rule.id)} />
                      <.pause_note rule={rule} id={"rule-paused-#{rule.id}"} class="text-xs" />
                    </div>

                    <span class="truncate text-[0.8125rem] text-subtle" title={scope_text(rule)}>
                      {scope_short(rule)}
                    </span>

                    <span :if={@states[rule.id] == :draft} class="text-xs text-muted">
                      {gettext("not running yet")}
                    </span>
                    <span
                      :if={@states[rule.id] != :draft}
                      id={"rule-activity-#{rule.id}"}
                      class="flex items-center gap-2.5"
                    >
                      <.week_bars
                        values={get_in(@week, [rule.id, :days]) || List.duplicate(0, 7)}
                        tone={activity_tone(rule)}
                        alert_last={Map.has_key?(@failures, rule.id)}
                        label={
                          ngettext(
                            "1 run in the last 7 days",
                            "%{count} runs in the last 7 days",
                            week_total(@week, rule)
                          )
                        }
                      />
                      <span class={[
                        "font-mono text-[0.8125rem]",
                        week_total(@week, rule) == 0 && "text-muted"
                      ]}>
                        {number(week_total(@week, rule))}
                      </span>
                    </span>

                    <span class={[
                      "font-mono text-xs",
                      cond do
                        Map.has_key?(@failures, rule.id) -> "text-warning"
                        get_in(@activity, [rule.id, :last_executed_at]) -> "text-subtle"
                        true -> "text-muted"
                      end
                    ]}>
                      {when_text(get_in(@activity, [rule.id, :last_executed_at]), @zone)}
                    </span>

                    <span class="flex items-center gap-1">
                      <.rule_switch
                        :if={@can_manage? and @editable[rule.id]}
                        id={"rule-switch-#{rule.id}"}
                        rule={rule}
                        state={@states[rule.id]}
                        phx-click="toggle"
                        phx-value-id={rule.id}
                      />
                      <.rule_actions :if={@can_manage? and @editable[rule.id]} rule={rule} />
                      <.link
                        :if={not (@can_manage? and @editable[rule.id])}
                        navigate={~p"/rules/#{rule}"}
                        class="flex size-8 items-center justify-center rounded-full text-muted hover:bg-secondary hover:text-base-content"
                        aria-label={gettext("Open %{name}", name: rule.name)}
                      >
                        <.icon name="hero-chevron-right" class="size-4" />
                      </.link>
                    </span>
                  </div>

                  <%!-- Phone: name, one line of state and context, the switch. --%>
                  <div class="grid grid-cols-[minmax(0,1fr)_3rem] items-center gap-1 px-1.5 lg:hidden">
                    <.link
                      navigate={~p"/rules/#{rule}"}
                      class="flex min-w-0 flex-col gap-[3px] py-2.5"
                    >
                      <span class="flex min-w-0 items-center gap-2">
                        <strong class="truncate text-[0.9375rem] font-semibold">{rule.name}</strong>
                        <span
                          :if={Map.has_key?(@ready, rule.id)}
                          class="shrink-0 rounded-full bg-primary/12 px-2 py-0.5 text-[0.6875rem] font-semibold text-primary"
                        >
                          {gettext("ready to act")}
                        </span>
                      </span>
                      <span class="flex min-w-0 items-center gap-1.5 text-xs text-muted">
                        <span class={[
                          "flex shrink-0 items-center gap-[5px] font-semibold",
                          state_text(@states[rule.id])
                        ]}>
                          <.state_mark state={@states[rule.id]} />
                          {state_label(@states[rule.id])}
                        </span>
                        <span class="truncate">
                          · {mobile_context(rule, @states[rule.id], @week, @failures)}
                        </span>
                      </span>
                      <.failure_line
                        rule={rule}
                        failure={Map.get(@failures, rule.id)}
                        link={false}
                      />
                    </.link>
                    <.rule_switch
                      :if={@can_manage? and @editable[rule.id]}
                      id={"rule-switch-m-#{rule.id}"}
                      rule={rule}
                      state={@states[rule.id]}
                      size="lg"
                      phx-click="toggle"
                      phx-value-id={rule.id}
                    />
                  </div>
                </li>
              </ul>
            </details>
          </div>
        </section>

        <aside :if={@all_rules != []} class="flex min-w-0 flex-col gap-5 max-sm:hidden">
          <section
            :if={@can_manage? and @servers != []}
            id="rule-recipes"
            class="flex flex-col gap-3 rounded-[1.75rem] bg-base-100 p-[1.375rem]"
          >
            <div class="flex items-center gap-2.5">
              <span class="flex size-[2.625rem] shrink-0 items-center justify-center rounded-[0.875rem] bg-primary/12 text-primary">
                <.icon name="hero-document-text" class="size-5" />
              </span>
              <span class="flex min-w-0 flex-col gap-0.5">
                <h2 class="font-display text-lg font-semibold leading-tight">
                  {gettext("Start from a recipe")}
                </h2>
                <span class="text-xs text-muted">
                  {ngettext(
                    "1 ready, it starts in simulation",
                    "%{count} ready, all start in simulation",
                    length(Recipes.all())
                  )}
                </span>
              </span>
            </div>
            <.link
              :for={recipe <- suggested_recipes(@usage)}
              navigate={~p"/rules/new?recipe=#{recipe.id}"}
              class="flex items-center gap-3 rounded-2xl bg-secondary px-3 py-2.5 transition-colors hover:bg-base-300/60"
            >
              <span class="flex min-w-0 flex-1 flex-col gap-0.5">
                <strong class="truncate text-sm font-semibold">
                  {Labels.recipe_name(recipe.id)}
                </strong>
                <span class="line-clamp-2 text-xs text-muted">
                  {Labels.recipe_description(recipe.id)}
                </span>
              </span>
              <.icon name="hero-chevron-right" class="size-4 shrink-0 text-muted" />
            </.link>
            <.link
              id="rule-recipes-all"
              patch={list_path(@scope, view: "recipes")}
              class="flex h-11 items-center justify-center rounded-full border border-base-300 bg-secondary text-sm font-medium transition-colors hover:bg-base-200"
            >
              {gettext("See all %{count} recipes", count: length(Recipes.all()))}
            </.link>
          </section>

          <section
            id="rule-attention"
            class="flex flex-col gap-2.5 rounded-[1.75rem] bg-base-100 p-[1.375rem]"
          >
            <h2 class="font-display text-xl font-semibold">{gettext("Needs attention")}</h2>
            <p :if={@attention == []} class="text-[0.8125rem] text-muted">
              {gettext("Nothing here: no failures, warnings or pending drafts.")}
            </p>
            <.link
              :for={item <- @attention}
              id={"rule-attention-#{item.id}"}
              navigate={item.to}
              class="-mx-1 flex items-center gap-3 rounded-2xl px-1 py-1.5 transition-colors hover:bg-secondary"
            >
              <span class={[
                "flex size-[2.125rem] shrink-0 items-center justify-center rounded-[0.6875rem]",
                attention_tint(item.tone)
              ]}>
                <.icon name={item.icon} class="size-4" />
              </span>
              <span class="flex min-w-0 flex-col gap-0.5">
                <strong class="truncate text-sm font-semibold">{item.title}</strong>
                <span class="line-clamp-2 text-xs text-muted">{item.meta}</span>
              </span>
            </.link>
          </section>

          <section
            id="rule-week"
            class="flex flex-col gap-2.5 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-[1.125rem]"
          >
            <div class="flex items-baseline gap-2">
              <h2 class="flex-1 font-display text-xl font-semibold">{gettext("Last 7 days")}</h2>
              <span class="text-xs text-muted">
                {if @search != "", do: gettext("the rules found"), else: gettext("every rule")}
              </span>
            </div>
            <div class="grid grid-cols-2 gap-2.5">
              <div class="flex flex-col gap-0.5 rounded-[1.125rem] bg-secondary px-3.5 py-3">
                <span class="text-xs text-subtle">{gettext("Runs")}</span>
                <strong class="font-display text-2xl font-semibold tabular-nums">
                  {number(@summary.runs)}
                </strong>
                <span
                  :if={Insights.delta(@summary.runs, @summary.previous)}
                  class={[
                    "text-xs",
                    if(Insights.delta(@summary.runs, @summary.previous) >= 0,
                      do: "text-primary",
                      else: "text-warning"
                    )
                  ]}
                >
                  {gettext("%{delta}% on the week",
                    delta: signed(Insights.delta(@summary.runs, @summary.previous))
                  )}
                </span>
                <span
                  :if={is_nil(Insights.delta(@summary.runs, @summary.previous))}
                  class="text-xs text-muted"
                >
                  {gettext("nothing the week before")}
                </span>
              </div>
              <div class="flex flex-col gap-0.5 rounded-[1.125rem] bg-secondary px-3.5 py-3">
                <span class="text-xs text-subtle">{gettext("Failures")}</span>
                <strong class="font-display text-2xl font-semibold tabular-nums">
                  {number(@summary.failures)}
                </strong>
                <span class={[
                  "text-xs",
                  if(@summary.failures > 0, do: "text-warning", else: "text-muted")
                ]}>
                  {failures_hint(@summary)}
                </span>
              </div>
            </div>
          </section>
        </aside>
      </div>

      <%!-- The bulk bar floats over the list while something is selected: a
            power admin tidying thirty rules should not have to open thirty
            menus. It sits above the phone's bottom navigation. --%>
      <div
        :if={MapSet.size(@selected) > 0}
        id="rule-bulk-bar"
        role="region"
        aria-label={gettext("Bulk actions")}
        class="sticky bottom-20 z-20 flex flex-wrap items-center gap-2 rounded-[1.5rem] bg-base-100 p-3 shadow-figma-card-large ring-1 ring-primary/35 lg:bottom-4"
      >
        <span class="flex items-center gap-2 pl-1 text-[0.8125rem] font-semibold">
          <span class="flex size-7 items-center justify-center rounded-full bg-primary font-mono text-xs text-primary-content">
            {MapSet.size(@selected)}
          </span>
          {ngettext("rule selected", "rules selected", MapSet.size(@selected))}
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
          <label for="bulk-group" class="sr-only">{gettext("Move to folder")}</label>
          <input
            id="bulk-group"
            type="text"
            name="group"
            list="bulk-group-options"
            placeholder={gettext("Folder")}
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

  defp signed(delta) when delta > 0, do: "+#{delta}"
  defp signed(delta), do: to_string(delta)

  defp failures_hint(%{failures: 0}), do: gettext("none this week")

  defp failures_hint(%{failing_rules: rules}),
    do: ngettext("all in 1 rule", "across %{count} rules", rules)

  defp attention_tint("warning"), do: "bg-warning/13 text-warning"
  defp attention_tint("error"), do: "bg-error/14 text-error"
  defp attention_tint("primary"), do: "bg-primary/12 text-primary"
  defp attention_tint(_neutral), do: "bg-secondary text-subtle"

  defp mobile_context(rule, state, week, failures) do
    trigger =
      if rule.trigger_event == :periodic,
        do: gettext("Periodically"),
        else: Labels.trigger(rule.trigger_event)

    tail =
      cond do
        Map.has_key?(failures, rule.id) or state == :paused ->
          scope_text(rule)

        state == :draft ->
          gettext("not running yet")

        true ->
          gettext("%{count} in 7 days", count: number(get_in(week, [rule.id, :total]) || 0))
      end

    trigger <> " · " <> tail
  end

  attr :rule, :map, required: true
  attr :ready, :boolean, required: true
  attr :editable, :boolean, required: true
  attr :health, :list, required: true

  defp row_badges(assigns) do
    ~H"""
    <span
      :if={@ready}
      class="shrink-0 rounded-full bg-primary/12 px-2 py-0.5 text-[0.6875rem] font-semibold text-primary"
    >
      {gettext("ready to act")}
    </span>
    <span
      :if={@rule.draft}
      class="shrink-0 rounded-full bg-secondary px-2 py-0.5 text-[0.6875rem] font-semibold text-subtle"
    >
      {gettext("draft pending")}
    </span>
    <span
      :if={not @editable}
      class="inline-flex shrink-0 items-center gap-1 rounded-full bg-secondary px-2 py-0.5 text-[0.6875rem] font-semibold text-subtle"
    >
      <.icon name="hero-lock-closed" class="size-3" /> {gettext("read only")}
    </span>
    <span
      :for={issue <- @health}
      :if={issue.tone == "error" and issue.id != :always_failing}
      title={Labels.health_explanation(issue.id)}
      class={[
        "inline-flex shrink-0 items-center gap-1 rounded-full px-2 py-0.5 text-[0.6875rem] font-semibold",
        if(issue.tone == "error", do: "bg-error/14 text-error", else: "bg-warning/13 text-warning")
      ]}
    >
      {Labels.health_issue(issue.id)}
    </span>
    """
  end

  attr :rule, :map, required: true
  attr :failure, :map, default: nil
  attr :link, :boolean, default: true

  defp failure_line(assigns) do
    ~H"""
    <span
      :if={@failure}
      class="flex min-w-0 items-center gap-1.5 text-xs font-semibold text-warning"
    >
      <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0" />
      <span class="truncate">
        {ngettext("Failed once", "Failed %{count}×", @failure.count)}{if @failure.error,
          do: " · " <> @failure.error}{if @link, do: " ·"}
      </span>
      <.link
        :if={@link}
        navigate={~p"/rules/#{@rule}?#{[tab: "executions", outcome: "failed"]}"}
        class="shrink-0 underline underline-offset-2"
      >
        {gettext("see failures")}
      </.link>
    </span>
    """
  end

  attr :rule, :map, required: true

  defp rule_actions(assigns) do
    ~H"""
    <.rule_menu
      id={"rule-menu-#{@rule.id}"}
      label={gettext("More actions for %{name}", name: @rule.name)}
    >
      <.menu_item icon="hero-pencil-square" navigate={~p"/rules/#{@rule}/edit"}>
        {gettext("Edit")}
      </.menu_item>
      <.menu_item icon="hero-power" phx-click="toggle" phx-value-id={@rule.id}>
        {if @rule.enabled, do: gettext("Disable"), else: gettext("Enable")}
      </.menu_item>
      <.pause_menu_items rule={@rule} on_custom="open_pause" />
      <.menu_item icon="hero-document-duplicate" phx-click="duplicate" phx-value-id={@rule.id}>
        {gettext("Duplicate")}
      </.menu_item>
      <.menu_item
        tone="error"
        icon="hero-trash"
        phx-click="delete"
        phx-value-id={@rule.id}
        data-confirm={gettext("Remove the rule \"%{name}\"?", name: @rule.name)}
      >
        {gettext("Remove")}
      </.menu_item>
    </.rule_menu>
    """
  end

  # The list the page is on: the fleet's, or one server's.
  defp list_path(scope, query \\ [])
  defp list_path(nil, []), do: ~p"/rules"
  defp list_path(nil, query), do: ~p"/rules?#{query}"
  defp list_path(scope, []), do: ~p"/servers/#{scope.id}/rules"
  defp list_path(scope, query), do: ~p"/servers/#{scope.id}/rules?#{query}"

  # A folder name made safe for a DOM id.
  defp folder_id(""), do: "none"

  defp folder_id(group) do
    :crypto.hash(:md5, group) |> Base.encode16(case: :lower) |> binary_part(0, 10)
  end

  # ── Recipes ────────────────────────────────────────────────────────────────

  @categories [
    guide: [:welcome, :no_squad_leader, :solo_tank],
    protect: [:team_kill_ladder, :new_player_watch],
    reward: [
      :seeding_reward,
      :mvp_vip,
      :top_support_vip,
      :best_squad_vip,
      :commander_reward,
      :squad_leader_reward,
      :melee_kill
    ],
    commands: [:top_command, :achievements_command, :season_command],
    discord: [:chat_command_discord, :match_end_leaderboard]
  ]

  # The gallery's shelves; a recipe the list above does not place lands on
  # the last shelf rather than disappearing.
  defp recipe_categories(search) do
    recipes = Recipes.all()
    placed = @categories |> Keyword.values() |> List.flatten()
    loose = Enum.reject(recipes, &(&1.id in placed))

    @categories
    |> Enum.map(fn {category, ids} ->
      shelf = for id <- ids, recipe = Enum.find(recipes, &(&1.id == id)), do: recipe
      {category, if(category == :discord, do: shelf ++ loose, else: shelf)}
    end)
    |> Enum.map(fn {category, shelf} ->
      {category, Enum.filter(shelf, &recipe_matches?(&1, search))}
    end)
    |> Enum.reject(fn {_category, shelf} -> shelf == [] end)
  end

  defp recipe_matches?(_recipe, ""), do: true

  defp recipe_matches?(recipe, search) do
    haystack =
      normalize(Labels.recipe_name(recipe.id) <> " " <> Labels.recipe_description(recipe.id))

    String.contains?(haystack, normalize(search))
  end

  defp normalize(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
  end

  defp category_name(:guide), do: gettext("Welcome and guide")
  defp category_name(:protect), do: gettext("Punish and protect")
  defp category_name(:reward), do: gettext("Reward")
  defp category_name(:commands), do: gettext("Chat commands")
  defp category_name(:discord), do: gettext("Discord")

  # Recipe icons are named in lib/hll_conditional_actions/rules/recipes.ex,
  # outside Tailwind's sources; the ones used nowhere else in the web layer
  # are listed here so their classes get generated: hero-calendar-days
  # hero-scissors
  defp category_tone(:guide, _recipe), do: "bg-primary/12 text-primary"
  defp category_tone(:protect, _recipe), do: "bg-axis/14 text-axis"
  defp category_tone(:reward, %{id: :seeding_reward}), do: "bg-accent/13 text-accent"
  defp category_tone(:reward, _recipe), do: "bg-warning/13 text-warning"
  defp category_tone(:commands, _recipe), do: "rules-teal-tile"
  defp category_tone(_discord, _recipe), do: "bg-allies/14 text-allies"

  attr :usage, :map, default: nil

  defp recipe_tag(assigns) do
    ~H"""
    <span class={[
      "rounded-full px-2 py-[3px] text-[0.6875rem] font-semibold",
      cond do
        @usage && @usage.rules > 0 -> "bg-primary/12 text-primary"
        @usage && @usage.requires -> "bg-warning/13 text-warning"
        true -> "bg-accent/13 text-accent"
      end
    ]}>
      <%= cond do %>
        <% @usage && @usage.rules > 0 && @usage.servers == 1 -> %>
          {gettext("in use on 1 server")}
        <% @usage && @usage.rules > 0 -> %>
          {gettext("in use")}
        <% @usage && @usage.requires -> %>
          {gettext("needs %{module}", module: Labels.feature(@usage.requires))}
        <% true -> %>
          {gettext("starts in simulation")}
      <% end %>
    </span>
    """
  end

  # Which recipes the rules already follow: the same trigger, the same kinds
  # of action and the same fields checked. `%{recipe_id => %{rules, servers,
  # requires}}`.
  defp recipe_usage(rules, servers) do
    installed =
      servers
      |> Enum.map(& &1.id)
      |> Features.installed_by_server()
      |> Map.values()
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    Map.new(Recipes.all(), fn recipe ->
      matching = Enum.filter(rules, &follows?(&1, recipe_fingerprint(recipe)))

      requires =
        if recipe.id in [:achievements_command, :season_command] and
             not MapSet.member?(installed, :progression),
           do: :progression

      {recipe.id,
       %{
         rules: length(matching),
         servers: matching |> Enum.map(& &1.server_id) |> Enum.uniq() |> length(),
         requires: requires
       }}
    end)
  end

  # A rule follows a recipe when it listens for the same trigger and still
  # does every kind of action and checks every field the recipe does; an
  # admin who added a condition or a step is still running that recipe.
  defp follows?(rule, {trigger, actions, fields}) do
    {rule_trigger, rule_actions, rule_fields} = rule_fingerprint(rule)

    rule_trigger == trigger and actions != [] and
      MapSet.subset?(MapSet.new(actions), MapSet.new(rule_actions)) and
      MapSet.subset?(MapSet.new(fields), MapSet.new(rule_fields))
  end

  defp rule_fingerprint(rule) do
    {rule.trigger_event, rule.actions |> Enum.map(& &1.type) |> Enum.sort(),
     rule.conditions
     |> Enum.map(& &1.field)
     |> Enum.reject(&(&1 == :always_true))
     |> Enum.sort()}
  end

  defp recipe_fingerprint(%{attrs: attrs}) do
    {attrs[:trigger_event],
     attrs |> Map.get(:actions, []) |> Enum.map(&(&1[:type] || &1["type"])) |> Enum.sort(),
     attrs
     |> Map.get(:conditions, [])
     |> Enum.map(&(&1[:field] || &1["field"]))
     |> Enum.reject(&(&1 == :always_true))
     |> Enum.sort()}
  end

  # The side panel suggests what the community does not run yet, the ones
  # with a short wizard first.
  defp suggested_recipes(usage) do
    Recipes.all()
    |> Enum.sort_by(fn recipe ->
      {get_in(usage, [recipe.id, :rules]) || 0, Map.get(recipe, :questions, []) == []}
    end)
    |> Enum.take(3)
  end

  # ── Import ─────────────────────────────────────────────────────────────────

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

      <div :if={@preview} class="mt-4">
        <p class="mb-2 text-sm font-medium">
          {ngettext("%{count} rule found", "%{count} rules found", length(@preview),
            count: length(@preview)
          )}
        </p>

        <ul class="max-h-48 space-y-1 overflow-y-auto rounded-2xl bg-secondary p-2 text-sm">
          <li
            :for={rule <- @preview}
            class="flex items-center justify-between gap-2 rounded-xl px-2 py-1"
          >
            <span class="truncate">{rule["name"] || gettext("(unnamed)")}</span>
            <.pill tone="neutral" dot={false} class="h-5 px-2 text-[0.6875rem]">
              {rule["game"]}
            </.pill>
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

  # The export holds what the list shows: the search narrows it.
  defp export_path(""), do: "/rules/export"
  defp export_path(search), do: "/rules/export?" <> URI.encode_query(search: search)
end
