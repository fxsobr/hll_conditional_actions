defmodule HllConditionalActionsWeb.RuleLive.Simulate do
  @moduledoc """
  The event simulator: compose an event - from scratch, with players the
  server really saw, or from a real recent event - and see every enabled
  rule of the server that would answer it, in the order the engine runs
  them, with the actions each would take and the conflicts between them
  (`HllConditionalActions.Engine.Simulator`).

  A composed event can be saved as a test and run again later
  (`HllConditionalActions.Rules.SimulatorTests`). Nothing is ever recorded
  as an execution or sent to the game or to Discord.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_rules}}

  import HllConditionalActionsWeb.DiagnosisComponents
  import HllConditionalActionsWeb.RuleComponents

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Engine.Evaluator
  alias HllConditionalActions.Engine.SavedEvents
  alias HllConditionalActions.Engine.Simulator
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActions.Rules.SimulatorTests
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.EventEditor

  @kills [:player_kill, :player_death, :player_team_kill]
  @chats [:player_chat, :chat_command]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    servers = Servers.list_servers_for(socket.assigns[:current_user])

    {:ok,
     socket
     |> assign(:page_title, gettext("Event simulator"))
     |> assign(:servers, servers)
     |> assign(:zone, zone(servers))
     |> assign(:triggers, Catalog.triggers())
     |> assign(:server, List.first(servers))
     |> assign(:trigger, :player_team_kill)
     |> assign(:source, "scratch")
     |> assign(:player_id, nil)
     |> assign(:target_id, nil)
     |> assign(:weapon, nil)
     |> assign(:message, nil)
     |> assign(:show_all?, false)
     |> assign(:saving?, false)
     |> assign(:context, nil)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    server =
      Enum.find(
        socket.assigns.servers,
        socket.assigns.server,
        &(to_string(&1.id) == params["server_id"])
      )

    trigger =
      Enum.find(
        socket.assigns.triggers,
        socket.assigns.trigger,
        &(to_string(&1) == params["trigger"])
      )

    socket = socket |> assign(server: server, trigger: trigger) |> reset()

    socket =
      case params["event_id"] &&
             Enum.find(socket.assigns.events, &(to_string(&1.id) == params["event_id"])) do
        nil ->
          socket

        saved ->
          socket |> assign(:source, "recent") |> assign(:sample, saved.sample) |> simulate()
      end

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("setup", params, socket) do
    server =
      Enum.find(
        socket.assigns.servers,
        socket.assigns.server,
        &(to_string(&1.id) == params["server_id"])
      )

    trigger =
      Enum.find(
        socket.assigns.triggers,
        socket.assigns.trigger,
        &(to_string(&1) == params["trigger"])
      )

    changed? = server != socket.assigns.server or trigger != socket.assigns.trigger

    socket =
      socket
      |> assign(server: server, trigger: trigger)
      |> assign(:player_id, blank(params["player_id"]) || socket.assigns.player_id)
      |> assign(:target_id, blank(params["target_id"]) || socket.assigns.target_id)
      |> assign(:weapon, blank(params["weapon"]))
      |> assign(:message, blank(params["message"]))

    {:noreply, if(changed?, do: reset(socket), else: compose(socket))}
  end

  def handle_event("source", %{"source" => source}, socket)
      when source in ["scratch", "recent"] do
    socket = assign(socket, :source, source)

    socket =
      case {source, socket.assigns.events} do
        {"recent", [first | _rest]} -> socket |> assign(:sample, first.sample) |> simulate()
        _other -> compose(socket)
      end

    {:noreply, socket}
  end

  def handle_event("pick_event", %{"event_id" => id}, socket) do
    case Enum.find(socket.assigns.events ++ socket.assigns.recent, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      saved ->
        {:noreply,
         socket
         |> assign(:source, "recent")
         |> assign(:trigger, saved.sample.trigger)
         |> assign(:events, events(socket.assigns.server, saved.sample.trigger))
         |> assign(:sample, saved.sample)
         |> simulate()}
    end
  end

  def handle_event("pick_test", %{"test_id" => id}, socket) do
    case Enum.find(socket.assigns.tests, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      test ->
        {:noreply,
         socket
         |> assign(:source, "recent")
         |> assign(:trigger, test.sample.trigger)
         |> assign(:events, events(socket.assigns.server, test.sample.trigger))
         |> assign(:sample, test.sample)
         |> simulate()}
    end
  end

  def handle_event("edit_event", params, socket) do
    {:noreply,
     socket
     |> assign(:sample, EventEditor.apply_edits(socket.assigns.sample, params))
     |> simulate()}
  end

  def handle_event("run", _params, socket), do: {:noreply, simulate(socket)}

  def handle_event("clear", _params, socket) do
    {:noreply,
     socket
     |> assign(player_id: nil, target_id: nil, weapon: nil, message: nil, source: "scratch")
     |> reset()}
  end

  def handle_event("toggle_all", _params, socket),
    do: {:noreply, update(socket, :show_all?, &(!&1))}

  def handle_event("open_save", _params, socket), do: {:noreply, assign(socket, :saving?, true)}
  def handle_event("close_save", _params, socket), do: {:noreply, assign(socket, :saving?, false)}

  def handle_event("save_test", %{"name" => name}, socket) do
    user = socket.assigns.current_user

    cond do
      not Accounts.can?(user, :manage_rules) ->
        {:noreply,
         put_flash(socket, :error, gettext("You do not have permission to change rules."))}

      String.trim(name) == "" ->
        {:noreply, put_flash(socket, :error, gettext("Give the test a name."))}

      true ->
        case SimulatorTests.create(
               socket.assigns.sample,
               name,
               Map.get(user, :name) || Map.get(user, :username)
             ) do
          {:ok, _test} ->
            {:noreply,
             socket
             |> assign(:saving?, false)
             |> assign(:tests, SimulatorTests.list([socket.assigns.server.id]))
             |> put_flash(:info, gettext("Test saved. Run it again from the list on the left."))}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Could not save the test."))}
        end
    end
  end

  def handle_event("delete_test", %{"test_id" => id}, socket) do
    if Accounts.can?(socket.assigns.current_user, :manage_rules) do
      SimulatorTests.delete(Enum.map(socket.assigns.servers, & &1.id), id)
      {:noreply, assign(socket, :tests, SimulatorTests.list([socket.assigns.server.id]))}
    else
      {:noreply, socket}
    end
  end

  # ── Building the event ─────────────────────────────────────────────────────

  defp reset(%{assigns: %{server: nil}} = socket) do
    assign(socket,
      events: [],
      recent: [],
      people: [],
      tests: [],
      sample: nil,
      result: nil,
      rules: [],
      context: nil
    )
  end

  defp reset(socket) do
    server = socket.assigns.server
    recent = SavedEvents.list([server.id], limit: 200)

    socket
    |> assign(:events, events(server, socket.assigns.trigger))
    |> assign(:recent, Enum.take(recent, 5))
    |> assign(:people, people(recent))
    |> assign(:tests, SimulatorTests.list([server.id]))
    |> assign(:rules, Rules.list_active_rules_for(server))
    |> compose()
  end

  defp events(nil, _trigger), do: []
  defp events(server, trigger), do: SavedEvents.list([server.id], trigger: trigger, limit: 50)

  # The players the server really saw, each with their latest sample:
  # `[%{id, name, player, gamestate}]`, most recent first.
  defp people(recent) do
    recent
    |> Enum.filter(&(&1.sample.player_id && is_map(&1.sample.player)))
    |> Enum.uniq_by(& &1.sample.player_id)
    |> Enum.map(fn saved ->
      %{
        id: saved.sample.player_id,
        name: saved.sample.player_name || saved.sample.player_id,
        player: saved.sample.player,
        gamestate: saved.sample.gamestate
      }
    end)
  end

  # A made-up event from the choices on the left: the chosen player (as the
  # server last saw them), the target, the weapon and the chat text.
  defp compose(%{assigns: %{source: "recent", sample: %{}}} = socket), do: simulate(socket)

  defp compose(socket) do
    %{server: server, trigger: trigger, people: people} = socket.assigns
    person = Enum.find(people, &(&1.id == socket.assigns.player_id)) || List.first(people)
    target = Enum.find(people, &(&1.id == socket.assigns.target_id)) || Enum.at(people, 1)

    sample =
      EventEditor.apply_edits(base_sample(server, trigger, person), %{
        "event" => event_edits(socket.assigns, trigger, target)
      })

    socket
    |> assign(:player_id, person && person.id)
    |> assign(:target_id, target && target.id)
    |> assign(:sample, sample)
    |> simulate()
  end

  defp base_sample(server, trigger, nil), do: EventEditor.blank_sample(server.id, trigger)

  defp base_sample(server, trigger, person) do
    player = Map.put(person.player, "player_id", person.id)
    EventEditor.live_sample(server.id, trigger, player, person.gamestate)
  end

  defp event_edits(assigns, trigger, target) do
    kill? = trigger in @kills

    %{}
    |> put_edit("target_player_name", kill? && target && target.name)
    |> put_edit("weapon", kill? && assigns.weapon)
    |> put_edit("chat_message", trigger in @chats && assigns.message)
  end

  defp put_edit(edits, _key, value) when value in [nil, false, ""], do: edits
  defp put_edit(edits, key, value), do: Map.put(edits, key, value)

  defp simulate(%{assigns: %{server: nil}} = socket), do: assign(socket, :result, nil)

  defp simulate(socket) do
    %{server: server, sample: sample, trigger: trigger} = socket.assigns
    context = EventEditor.to_context(%{sample | trigger: trigger}, server)

    socket
    |> assign(:context, context)
    |> assign(:result, Simulator.simulate(socket.assigns.rules, context))
  end

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value

  # ── What the page says ─────────────────────────────────────────────────────

  defp conflict_text(%{kind: :double_punishment, rules: rules}) do
    gettext("%{rules} would all punish the same player for this one event.",
      rules: rule_names(rules)
    )
  end

  defp conflict_text(%{kind: :message_then_removed, rules: rules}) do
    gettext(
      "%{rules}: one messages the player while another kicks or bans them, so the message is likely never read.",
      rules: rule_names(rules)
    )
  end

  defp rule_names(rules), do: Enum.map_join(rules, ", ", &"“#{&1.name}”")

  defp conflicting_ids(conflicts) do
    conflicts |> Enum.flat_map(& &1.rules) |> MapSet.new(& &1.id)
  end

  # Each firing rule's actions, flattened in the order the engine would run
  # them, for the "if it were real" recap.
  defp run_order(firing) do
    for entry <- firing, action <- entry.diagnosis.actions do
      %{rule: entry.rule, action: action}
    end
  end

  # The values the rules of this trigger read, as short chips.
  defp engine_reads(rules, trigger, context) do
    rules
    |> Enum.filter(&(&1.trigger_event == trigger))
    |> Enum.flat_map(& &1.conditions)
    |> Enum.map(& &1.field)
    |> Enum.reject(&(&1 == :always_true))
    |> Enum.uniq()
    |> Enum.take(8)
    |> Enum.map(fn field ->
      "#{String.downcase(Labels.field(field))}: #{read_value(Evaluator.field_value(field, context))}"
    end)
  end

  defp person_line(nil), do: gettext("pick a player")

  defp person_line(person) do
    team =
      case person.player["team"] do
        "allies" -> gettext("Allies")
        "axis" -> gettext("Axis")
        _other -> nil
      end

    [team, person.player["is_vip"] in [true, "true"] && "VIP"]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp team_tone(%{player: %{"team" => "axis"}}), do: "bg-axis/16 text-axis"
  defp team_tone(%{player: %{"team" => "allies"}}), do: "bg-allies/14 text-allies"
  defp team_tone(_person), do: "bg-secondary text-subtle"

  defp person_team_text(%{player: %{"team" => "axis"}}), do: "text-axis"
  defp person_team_text(%{player: %{"team" => "allies"}}), do: "text-allies"
  defp person_team_text(_person), do: "text-muted"

  defp initials(nil), do: "?"

  defp initials(name) do
    name
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split()
    |> case do
      [one] -> String.slice(one, 0, 2)
      [a, b | _rest] -> String.first(a) <> String.first(b)
      [] -> String.slice(name, 0, 2)
    end
    |> String.upcase()
  end

  # Why a firing rule fires, in one line: the conditions that held.
  defp fired_because(%{rule: rule, diagnosis: diagnosis}) do
    held =
      diagnosis.conditions
      |> Enum.reject(&(&1.field == :always_true))
      |> Enum.filter(& &1.result)

    case held do
      [] ->
        gettext("No conditions · answers every “%{trigger}”",
          trigger: String.downcase(Labels.trigger(rule.trigger_event))
        )

      [%{operator: :equal} = condition | _rest] ->
        gettext("Matched: %{field} %{actual}",
          field: Labels.field(condition.field),
          actual: read_value(condition.actual)
        )

      [condition | _rest] ->
        gettext("Matched: %{field} %{actual} %{operator} %{expected}",
          field: Labels.field(condition.field),
          actual: read_value(condition.actual),
          operator: operator_mark(condition.operator),
          expected: read_value(condition.expected)
        )
    end
  end

  # Comparisons read as symbols in these tight lines ("kills 4 ≥ 3").
  defp operator_mark(:equal), do: "="
  defp operator_mark(:not_equal), do: "≠"
  defp operator_mark(:greater_than), do: ">"
  defp operator_mark(:greater_than_or_equal), do: "≥"
  defp operator_mark(:less_than), do: "<"
  defp operator_mark(:less_than_or_equal), do: "≤"
  defp operator_mark(operator), do: Labels.operator(operator)

  # Discord text is stored escaped for Discord's markdown ("BR \#1"); the
  # preview shows it the way Discord renders it.
  defp shown_detail(:send_discord_webhook, detail),
    do: String.replace(detail, ~r/\\([\\`*_{}\[\]()#+\-.!|>~<])/, "\\1")

  defp shown_detail(_type, detail), do: detail

  defp failed_condition(%{diagnosis: diagnosis}) do
    Enum.find(diagnosis.conditions, &(not &1.result and &1.field != :always_true))
  end

  defp detail_label(type) when type in [:message_player, :message_all_players],
    do: gettext("Message the player would read")

  defp detail_label(type)
       when type in [:kick_player, :temp_ban_player, :perma_ban_player, :punish_player],
       do: gettext("Reason the player would see")

  defp detail_label(:send_discord_webhook), do: gettext("Message on Discord")
  defp detail_label(_type), do: gettext("What it would do")

  defp step_of(%{rule: rule} = entry) do
    if rule.escalation_window_seconds > 0 and length(rule.actions) > 1 do
      case entry.diagnosis.actions do
        [_ | _] = actions ->
          index = Enum.find_index(rule.actions, &(&1.type == hd(actions).type)) || 0
          {index + 1, length(rule.actions)}

        _none ->
          nil
      end
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    results = (assigns[:result] && assigns.result.results) || []

    assigns =
      assign(assigns,
        conflicting: conflicting_ids((assigns[:result] && assigns.result.conflicts) || []),
        firing: Enum.filter(results, &(&1.diagnosis.outcome == :fires)),
        quiet: Enum.reject(results, &(&1.diagnosis.outcome == :fires)),
        person: Enum.find(assigns[:people] || [], &(&1.id == assigns.player_id)),
        target: Enum.find(assigns[:people] || [], &(&1.id == assigns.target_id)),
        can_save?: Accounts.can?(assigns.current_user, :manage_rules)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Event simulator")}
      crumb={gettext("Rules") <> " / " <> gettext("Simulator")}
      back={~p"/rules"}
      back_label={gettext("Back to rules")}
      badges={[
        %{
          id: "simulate-safe",
          label: gettext("Nothing goes to the game or to Discord"),
          tone: "simulating"
        }
      ]}
      global_search={false}
      scope={false}
      bell={false}
    >
      <:actions>
        <.header_button :if={@server} type="button" phx-click="clear">
          {gettext("Clear")}
        </.header_button>
        <.header_button
          :if={@server && @can_save?}
          id="simulate-save"
          type="button"
          icon="hero-pencil"
          phx-click="open_save"
        >
          {gettext("Save as a test")}
        </.header_button>
      </:actions>

      <.empty_state
        :if={@servers == []}
        icon="hero-server-stack"
        title={gettext("Connect a server first")}
      />

      <form
        :if={@saving?}
        id="simulate-save-form"
        phx-submit="save_test"
        class="flex flex-wrap items-center gap-2.5 rounded-[1.25rem] bg-base-100 px-4 py-3 ring-1 ring-primary/35"
      >
        <label for="simulate-test-name" class="text-sm font-medium">{gettext("Name of the test")}</label>
        <input
          id="simulate-test-name"
          type="text"
          name="name"
          maxlength="120"
          required
          value={@sample && "#{@sample.player_name} · #{Labels.trigger(@trigger)}"}
          class="pc-text-input h-10 min-w-0 flex-1"
        />
        <.button type="submit" size="sm" color="primary" label={gettext("Save")} />
        <.button
          type="button"
          size="sm"
          variant="ghost"
          color="gray"
          phx-click="close_save"
          label={gettext("Cancel")}
        />
      </form>

      <div :if={@server} class="grid items-start gap-5 xl:grid-cols-[28.75rem_minmax(0,1fr)]">
        <section
          id="simulate-event"
          aria-label={gettext("Build an event")}
          class="flex min-w-0 flex-col gap-3.5 rounded-[1.75rem] bg-base-100 px-6 py-[1.375rem]"
        >
          <div class="flex items-baseline gap-3">
            <h2 class="shrink-0 font-display text-xl font-semibold">{gettext("Build an event")}</h2>
            <span class="ml-auto min-w-0 truncate text-xs text-muted">
              {gettext("reads the current CRCON data")}
            </span>
          </div>

          <div
            role="tablist"
            aria-label={gettext("Where the event comes from")}
            class="grid grid-cols-2 gap-1 rounded-full border border-base-300 bg-secondary p-1"
          >
            <button
              :for={
                {value, label} <- [
                  {"scratch", gettext("Build from scratch")},
                  {"recent", gettext("Use a recent real event")}
                ]
              }
              type="button"
              role="tab"
              aria-selected={to_string(@source == value)}
              phx-click="source"
              phx-value-source={value}
              class={[
                "h-9 cursor-pointer rounded-full text-[0.8125rem] transition-colors",
                if(@source == value,
                  do: "bg-base-content font-semibold text-base-100",
                  else: "text-subtle hover:text-base-content"
                )
              ]}
            >
              {label}
            </button>
          </div>

          <form id="simulate-setup" phx-change="setup" class="flex flex-col gap-3.5">
            <label class="flex flex-col gap-1.5">
              <span class="text-xs text-muted">{gettext("Kind of event")}</span>
              <span class="relative">
                <select
                  name="trigger"
                  class="h-[2.875rem] w-full cursor-pointer appearance-none rounded-[0.875rem] border border-primary/50 bg-primary/6 pr-10 pl-3.5 text-[0.9375rem] font-semibold focus:ring-0"
                >
                  <option :for={trigger <- @triggers} value={trigger} selected={trigger == @trigger}>
                    {Labels.trigger(trigger)}
                  </option>
                </select>
                <.icon
                  name="hero-chevron-down"
                  class="pointer-events-none absolute top-1/2 right-3.5 size-4 -translate-y-1/2"
                />
              </span>
            </label>

            <div class="grid grid-cols-2 gap-3">
              <label class="flex flex-col gap-1.5">
                <span class="text-xs text-muted">{gettext("Server")}</span>
                <span class="relative flex items-center">
                  <span
                    class="pointer-events-none absolute left-3.5 size-[7px] rounded-full bg-primary"
                    aria-hidden="true"
                  ></span>
                  <select
                    name="server_id"
                    class="h-[2.875rem] w-full cursor-pointer appearance-none truncate rounded-[0.875rem] border border-base-300 bg-secondary pr-9 pl-7 text-sm focus:ring-0"
                  >
                    <option
                      :for={server <- @servers}
                      value={server.id}
                      selected={server.id == @server.id}
                    >
                      {server.name}
                    </option>
                  </select>
                  <.icon
                    name="hero-chevron-down"
                    class="pointer-events-none absolute right-3.5 size-4 text-muted"
                  />
                </span>
              </label>
              <label
                :if={
                  @trigger in [:player_kill, :player_death, :player_team_kill] and
                    @source == "scratch"
                }
                class="flex flex-col gap-1.5"
              >
                <span class="text-xs text-muted">{gettext("Weapon")}</span>
                <input
                  type="text"
                  name="weapon"
                  value={@weapon || event_weapon(@sample)}
                  list="simulate-weapons"
                  phx-debounce="300"
                  class="h-[2.875rem] rounded-[0.875rem] border border-base-300 bg-secondary px-3.5 text-sm focus:border-primary/50 focus:ring-0"
                />
                <datalist id="simulate-weapons">
                  <option
                    :for={
                      weapon <-
                        @recent
                        |> Enum.map(&event_weapon(&1.sample))
                        |> Enum.reject(&is_nil/1)
                        |> Enum.uniq()
                    }
                    value={weapon}
                  />
                </datalist>
              </label>
            </div>

            <div :if={@source == "scratch" and @people != []} class="grid grid-cols-2 gap-3">
              <.person_picker
                name="player_id"
                label={gettext("Player")}
                person={@person}
                people={@people}
              />
              <.person_picker
                :if={@trigger in [:player_kill, :player_death, :player_team_kill]}
                name="target_id"
                label={gettext("Target")}
                person={@target}
                people={@people}
                other={@person}
              />
            </div>

            <label :if={@source == "scratch"} class="flex flex-col gap-1.5">
              <span class="text-xs text-muted">
                {gettext("Chat message")}
                <span>· {gettext("only for “writes in chat” and commands")}</span>
              </span>
              <textarea
                name="message"
                rows="2"
                disabled={@trigger not in [:player_chat, :chat_command]}
                phx-debounce="300"
                placeholder={
                  if @trigger in [:player_chat, :chat_command],
                    do: gettext("What the player writes"),
                    else: gettext("This kind of event has no message")
                }
                class="rounded-[0.875rem] border border-dashed border-base-300 bg-transparent px-3.5 py-2.5 text-sm disabled:text-muted"
              >{@message}</textarea>
            </label>
          </form>

          <form :if={@source == "recent"} id="simulate-pick" phx-change="pick_event">
            <label class="flex flex-col gap-1.5">
              <span class="text-xs text-muted">{gettext("Real event")}</span>
              <select name="event_id" class="pc-text-input w-full">
                <option :if={@events == []} value="">
                  {gettext("No real event of this kind kept")}
                </option>
                <option :for={event <- @events} value={event.id}>
                  {sample_label(event.sample)}
                </option>
              </select>
            </label>
          </form>
          <.event_fields :if={@source == "recent" and @sample} id="simulate-fields" sample={@sample} />

          <div
            :if={@context && engine_reads(@rules, @trigger, @context) != []}
            class="flex flex-col gap-1.5 rounded-2xl bg-secondary px-3.5 py-3"
          >
            <span class="text-xs text-muted">{gettext(
              "What the engine will read, counting this event"
            )}</span>
            <div class="flex flex-wrap gap-1.5">
              <span
                :for={chip <- engine_reads(@rules, @trigger, @context)}
                class="rounded-full bg-base-100 px-2.5 py-1 font-mono text-xs"
              >
                {chip}
              </span>
            </div>
          </div>

          <button
            id="simulate-run"
            type="button"
            phx-click="run"
            class="flex h-12 cursor-pointer items-center justify-center gap-2 rounded-full bg-primary text-sm font-semibold text-primary-content transition-opacity hover:opacity-90"
          >
            <.icon name="hero-play-solid" class="size-4" /> {gettext("Simulate this event")}
          </button>

          <div :if={@recent != []} class="flex flex-col gap-1 border-t border-base-300 pt-3">
            <span class="text-xs text-muted">{gettext("Or start from a recent real event")}</span>
            <button
              :for={event <- @recent}
              id={"simulate-recent-#{event.id}"}
              type="button"
              phx-click="pick_event"
              phx-value-event_id={event.id}
              class="grid cursor-pointer grid-cols-[3.875rem_minmax(0,1fr)] items-baseline gap-2.5 rounded-xl px-2 py-[7px] text-left text-[0.8125rem] transition-colors hover:bg-secondary"
            >
              <span class="font-mono text-xs text-muted">{clock(event.occurred_at, @zone)}</span>
              <span class="truncate">
                <strong class={[
                  "font-semibold",
                  event.sample.player && person_team_text(%{player: event.sample.player})
                ]}>
                  {event.sample.player_name || gettext("Unknown player")}
                </strong>
                {event_text(event.sample, event.sample.trigger)} · {@server.name}
              </span>
            </button>
          </div>

          <div :if={@tests != []} class="flex flex-col gap-1 border-t border-base-300 pt-3">
            <span class="text-xs text-muted">{gettext("Saved tests")}</span>
            <div :for={test <- @tests} id={"simulate-test-#{test.id}"} class="flex items-center gap-2">
              <button
                type="button"
                phx-click="pick_test"
                phx-value-test_id={test.id}
                class="min-w-0 flex-1 cursor-pointer truncate rounded-xl px-2 py-[7px] text-left text-[0.8125rem] transition-colors hover:bg-secondary"
              >
                {test.name}
                <span class="text-xs text-muted">· {Labels.trigger(test.sample.trigger)}</span>
              </button>
              <button
                :if={@can_save?}
                type="button"
                phx-click="delete_test"
                phx-value-test_id={test.id}
                aria-label={gettext("Delete the test %{name}", name: test.name)}
                class="flex size-7 cursor-pointer items-center justify-center rounded-full text-muted hover:bg-secondary hover:text-error"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
          </div>
        </section>

        <section
          id="simulate-results"
          aria-label={gettext("Rules that would answer")}
          class="flex min-w-0 flex-col gap-3.5 rounded-[1.75rem] bg-base-100 px-5 py-[1.375rem] sm:px-[1.625rem]"
        >
          <div class="flex flex-wrap items-start gap-4">
            <div class="flex min-w-0 flex-1 flex-col gap-1">
              <h2 class="font-display text-xl font-semibold">{gettext("Who would answer")}</h2>
              <p class="text-[0.8125rem] text-muted">
                <span :if={@sample}>
                  {@sample.player_name} {event_text(@sample, @trigger)} · {@server.name} · {gettext(
                    "now"
                  )} ·
                </span>
                {ngettext(
                  "1 rule listens for this trigger",
                  "%{count} rules listen for this trigger",
                  length(@firing) + length(@quiet)
                )}
              </p>
            </div>
            <div class="flex gap-2">
              <span class="flex h-[1.875rem] items-center rounded-full bg-primary/12 px-3 text-xs font-semibold text-primary">
                {ngettext("1 would fire", "%{count} would fire", length(@firing))}
              </span>
              <span
                :if={@quiet != []}
                class="flex h-[1.875rem] items-center rounded-full bg-secondary px-3 text-xs font-semibold text-subtle"
              >
                {ngettext("1 would not", "%{count} would not", length(@quiet))}
              </span>
            </div>
          </div>

          <p
            :for={conflict <- (@result && @result.conflicts) || []}
            class="flex items-start gap-2.5 rounded-2xl bg-error/10 px-4 py-3 text-[0.8125rem] text-error ring-1 ring-error/35"
            role="alert"
          >
            <.icon name="hero-exclamation-triangle" class="mt-px size-4 shrink-0" />
            {conflict_text(conflict)}
          </p>

          <p
            :if={@firing == [] and @quiet == []}
            class="rounded-2xl bg-secondary px-4 py-3 text-[0.8125rem] text-subtle"
          >
            {gettext("No enabled rule on this server listens for this event.")}
          </p>

          <article
            :for={entry <- @firing}
            id={"sim-rule-#{entry.rule.id}"}
            class={[
              "flex flex-col gap-3 rounded-[1.25rem] border bg-secondary px-[1.125rem] py-4",
              if(MapSet.member?(@conflicting, entry.rule.id),
                do: "border-error/50",
                else: "border-base-300"
              )
            ]}
          >
            <div class="flex flex-wrap items-center gap-3">
              <span class="flex size-[1.875rem] shrink-0 items-center justify-center rounded-full bg-primary text-primary-content">
                <.icon name="hero-check" class="size-4" />
                <span class="sr-only">{gettext("would fire")}</span>
              </span>
              <.link
                navigate={~p"/rules/#{entry.rule}"}
                class="text-base font-semibold hover:text-primary"
              >
                {entry.rule.name}
              </.link>
              <.state_pill state={state(entry.rule, true)} size="sm" />
              <span class="grow"></span>
              <span class="text-[0.8125rem] text-subtle">{fired_because(entry)}</span>
            </div>
            <div class="grid gap-3.5 sm:grid-cols-[9.375rem_minmax(0,1fr)]">
              <div class="flex flex-col gap-1.5">
                <%= case step_of(entry) do %>
                  <% {step, steps} -> %>
                    <span class="text-xs text-muted">{gettext("Step")}</span>
                    <strong class="font-display text-lg font-semibold">
                      {gettext("Offence %{number} of %{total}", number: step, total: steps)}
                    </strong>
                    <.ladder_meter step={step} steps={steps} />
                  <% nil -> %>
                    <span class="text-xs text-muted">{gettext("Cooldown")}</span>
                    <strong class="font-display text-lg font-semibold">{gettext("free")}</strong>
                    <span class="text-xs text-muted">
                      {if entry.rule.cooldown_seconds > 0,
                        do:
                          gettext("cooldown of %{time}",
                            time: duration_text(entry.rule.cooldown_seconds)
                          ),
                        else: gettext("no cooldown")}
                    </span>
                <% end %>
              </div>
              <div class="flex min-w-0 flex-col gap-2">
                <div :for={action <- entry.diagnosis.actions} class="flex flex-col gap-2">
                  <span class="flex flex-wrap items-center gap-2.5">
                    <span class="text-sm font-semibold">{Labels.action(action.type)}</span>
                    <span class={[
                      "rounded-full px-2 py-[3px] text-[0.6875rem] font-semibold",
                      if(entry.rule.simulation,
                        do: "bg-accent/13 text-accent",
                        else: "bg-warning/13 text-warning"
                      )
                    ]}>
                      {if entry.rule.simulation,
                        do: gettext("would only record"),
                        else: gettext("would really send")}
                    </span>
                  </span>
                  <div
                    :if={is_binary(action.detail) and action.detail != ""}
                    class="flex flex-col gap-1 rounded-[0.875rem] bg-base-100 px-3.5 py-2.5"
                  >
                    <span class="text-[0.6875rem] text-muted">{detail_label(action.type)}</span>
                    <span class="whitespace-pre-line font-mono text-[0.8125rem] leading-normal">{shown_detail(
                      action.type,
                      action.detail
                    )}</span>
                  </div>
                </div>
              </div>
            </div>
          </article>

          <article
            :for={entry <- @quiet}
            id={"sim-quiet-#{entry.rule.id}"}
            class="rounded-[1.25rem] border border-dashed border-base-300 px-[1.125rem] py-3.5"
          >
            <details class="group/quiet">
              <summary class="flex cursor-pointer list-none flex-wrap items-center gap-3 [&::-webkit-details-marker]:hidden">
                <span class="flex size-[1.875rem] shrink-0 items-center justify-center rounded-full bg-error/14 text-error">
                  <.icon name="hero-x-mark" class="size-4" />
                  <span class="sr-only">{gettext("would not fire")}</span>
                </span>
                <span class="text-[0.9375rem] font-semibold">{entry.rule.name}</span>
                <.state_pill state={state(entry.rule, true)} size="sm" />
                <span class="grow"></span>
                <%= case failed_condition(entry) do %>
                  <% nil -> %>
                    <.outcome_badge outcome={entry.diagnosis.outcome} />
                  <% condition -> %>
                    <span class="text-[0.8125rem] text-subtle">
                      {Labels.field(condition.field)}
                      <span class="text-muted">{gettext("needed")}</span>
                      <span class="font-mono text-xs">{operator_mark(condition.operator)} {read_value(
                        condition.expected
                      )}</span>
                    </span>
                    <span class="rounded-full bg-error/14 px-2.5 py-[3px] font-mono text-xs text-error">
                      ✗ {gettext("read %{value}", value: read_value(condition.actual))}
                    </span>
                <% end %>
                <.icon
                  name="hero-chevron-down"
                  class="size-4 text-muted transition-transform group-open/quiet:rotate-180"
                />
              </summary>
              <div class="pt-3 sm:pl-[2.625rem]">
                <.diagnosis
                  diagnosis={entry.diagnosis}
                  player={@sample && @sample.player_name}
                  compact
                />
              </div>
            </details>
          </article>

          <div
            :if={run_order(@firing) != []}
            class="flex flex-col gap-2.5 rounded-[1.25rem] bg-accent/8 px-[1.125rem] py-4 ring-1 ring-accent/25"
          >
            <span class="text-xs uppercase tracking-[0.06em] text-accent/80">
              {gettext("If it were real, in this order")}
            </span>
            <ol class="flex flex-col gap-2">
              <li
                :for={{step, index} <- Enum.with_index(run_order(@firing), 1)}
                class="grid grid-cols-[1.75rem_minmax(0,1fr)_auto] items-center gap-2.5 text-sm"
              >
                <span class="flex size-6 items-center justify-center rounded-full bg-accent/20 font-mono text-xs">
                  {index}
                </span>
                <span class="min-w-0">
                  {Labels.action(step.action.type)}
                  <span class="text-muted">· {step.rule.name}</span>
                  <span :if={step.rule.simulation} class="text-accent">
                    · {gettext("only recorded today, the rule is simulating")}
                  </span>
                </span>
                <span class="font-mono text-xs text-muted">
                  {gettext("priority %{value}", value: step.rule.priority)}
                </span>
              </li>
            </ol>
          </div>

          <span class="grow"></span>

          <div class="flex flex-wrap items-center gap-3 border-t border-base-300 pt-3">
            <span class="flex-1 text-[0.8125rem] text-muted">
              {ngettext(
                "1 rule does not listen for “%{trigger}”",
                "%{count} rules do not listen for “%{trigger}”",
                length(@rules) - length(@firing) - length(@quiet),
                trigger: String.downcase(Labels.trigger(@trigger))
              )} · {gettext("evaluated in order of priority")}
            </span>
            <button
              :if={@rules != []}
              type="button"
              phx-click="toggle_all"
              class="h-9 cursor-pointer rounded-full px-3.5 text-[0.8125rem] text-subtle hover:text-base-content"
            >
              {if @show_all?,
                do: gettext("Hide the others"),
                else: gettext("Show all %{count}", count: length(@rules))}
            </button>
          </div>
          <ul :if={@show_all?} id="simulate-all-rules" class="flex flex-col gap-1">
            <li
              :for={rule <- @rules}
              class="flex items-center gap-3 rounded-xl px-2 py-1.5 text-[0.8125rem]"
            >
              <.link
                navigate={~p"/rules/#{rule}"}
                class="min-w-0 flex-1 truncate font-medium hover:text-primary"
              >
                {rule.name}
              </.link>
              <span class="truncate text-muted">{Labels.trigger(rule.trigger_event)}</span>
              <span class="font-mono text-xs text-muted">{gettext("priority %{value}",
                value: rule.priority
              )}</span>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :person, :map, default: nil
  attr :people, :list, required: true
  attr :other, :map, default: nil

  # A player as a card, the whole card a select over the players the server
  # saw lately.
  defp person_picker(assigns) do
    ~H"""
    <label class="flex min-w-0 flex-col gap-1.5">
      <span class="text-xs text-muted">{@label}</span>
      <span class="relative flex h-14 items-center gap-2.5 rounded-[0.875rem] border border-base-300 bg-secondary px-3 focus-within:border-primary/50">
        <span class={[
          "flex size-8 shrink-0 items-center justify-center rounded-[0.625rem] text-xs font-bold",
          team_tone(@person)
        ]}>
          {initials(@person && @person.name)}
        </span>
        <span class="flex min-w-0 flex-col gap-px">
          <strong class="truncate text-sm font-semibold">{(@person && @person.name) ||
            gettext("Nobody")}</strong>
          <span class={["truncate text-xs", person_team_text(@person)]}>
            {person_line(@person)}{if @other && @person &&
                                        @other.player["team"] == @person.player["team"] &&
                                        @person.player["team"],
                                      do: " · " <> gettext("same team")}
          </span>
        </span>
        <select
          name={@name}
          aria-label={@label}
          class="absolute inset-0 cursor-pointer opacity-0"
        >
          <option
            :for={person <- @people}
            value={person.id}
            selected={@person && person.id == @person.id}
          >
            {person.name}
          </option>
        </select>
      </span>
    </label>
    """
  end
end
