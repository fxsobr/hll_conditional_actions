defmodule HllConditionalActionsWeb.BenchComponents do
  @moduledoc """
  The pieces of the rule builder's test bench (the Bench, BenchLight and
  ActionDiscord boards): the state switch, the run strip, the overlay
  banner, the ladder, the 7-day replay and the action drawer.

  `HllConditionalActionsWeb.RuleLive.Form` owns the state and the events;
  the condition rows and the shared inputs live in
  `HllConditionalActionsWeb.RuleBuilder`.
  """

  use HllConditionalActionsWeb, :html

  import HllConditionalActionsWeb.RuleBuilder,
    only: [
      chip_input: 1,
      message_preview: 1,
      param_input: 1,
      preview_text: 2,
      placeholders: 1,
      existing_action: 1,
      current_parameters: 1,
      parameter_value: 3,
      action_errors: 1
    ]

  alias HllConditionalActions.Discord.Message
  alias HllConditionalActions.Engine.SavedEvents
  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActionsWeb.LiveComponents
  alias Phoenix.HTML.Form

  # ── Words ──────────────────────────────────────────────────────────────────

  @doc """
  A trigger as the start of a sentence: "the player team kills".
  """
  @spec trigger_phrase(atom()) :: String.t()
  def trigger_phrase(:player_connected), do: gettext("the player connects")
  def trigger_phrase(:player_disconnected), do: gettext("the player disconnects")
  def trigger_phrase(:player_kill), do: gettext("the player kills someone")
  def trigger_phrase(:player_death), do: gettext("the player dies")
  def trigger_phrase(:player_team_kill), do: gettext("the player kills a teammate")
  def trigger_phrase(:player_chat), do: gettext("the player writes in chat")
  def trigger_phrase(:chat_command), do: gettext("the player types a command")
  def trigger_phrase(:team_switch), do: gettext("the player switches team")
  def trigger_phrase(:vehicle_destroyed), do: gettext("the player destroys a vehicle")
  def trigger_phrase(:match_start), do: gettext("a match starts")
  def trigger_phrase(:match_end), do: gettext("a match ends")
  def trigger_phrase(:periodic), do: gettext("every few seconds")

  @doc """
  A short name for an action with its main setting, for the replay bars and
  the "who changed" list: "Message", "Punish", "Kick", "Ban 2 h".
  """
  @spec short_action(map() | nil) :: String.t()
  def short_action(nil), do: "–"

  def short_action(%{type: type} = action) do
    short_name(type, Map.get(action, :parameters) || %{})
  end

  defp short_name(:message_player, _parameters), do: gettext("Message")
  defp short_name(:message_all_players, _parameters), do: gettext("Message all")
  defp short_name(:broadcast_message, _parameters), do: gettext("Broadcast")
  defp short_name(:temporary_broadcast, _parameters), do: gettext("Broadcast")
  defp short_name(:set_welcome_message, _parameters), do: gettext("Welcome text")
  defp short_name(:punish_player, _parameters), do: gettext("Punish")
  defp short_name(:kick_player, _parameters), do: gettext("Kick")

  defp short_name(:temp_ban_player, parameters),
    do: gettext("Ban %{count} h", count: hours(parameters, 2))

  defp short_name(:perma_ban_player, _parameters), do: gettext("Permanent ban")
  defp short_name(:blacklist_player, _parameters), do: gettext("Blacklist")

  defp short_name(:grant_vip, parameters),
    do: gettext("VIP %{count} h", count: hours(parameters, 24))

  defp short_name(:send_discord_webhook, _parameters), do: "Discord"
  defp short_name(other, _parameters), do: Labels.action(other)

  defp hours(parameters, default) do
    case Integer.parse(to_string(Map.get(parameters, "duration_hours") || default)) do
      {value, _rest} -> value
      :error -> default
    end
  end

  # Which colour an action's bar takes: removals are orange, bans red.
  defp action_bar_tone(%{type: :kick_player}), do: "axis"

  defp action_bar_tone(%{type: type})
       when type in [:temp_ban_player, :perma_ban_player, :blacklist_player],
       do: "error"

  defp action_bar_tone(_action), do: nil

  @doc """
  An action as a rung of the ladder: its name, the setting worth reading
  (underlined when edited), and the text it sends.
  """
  @spec action_parts(map()) :: %{
          label: String.t(),
          emphasis: String.t() | nil,
          text: String.t() | nil
        }
  def action_parts(%{type: type} = action) do
    parameters = action.parameters || %{}

    case type do
      :temp_ban_player ->
        %{
          label: gettext("Ban for"),
          emphasis: ngettext("1 hour", "%{count} hours", hours(parameters, 2)),
          text: nil
        }

      :grant_vip ->
        %{
          label: gettext("VIP for"),
          emphasis: ngettext("1 hour", "%{count} hours", hours(parameters, 24)),
          text: nil
        }

      :add_player_flag ->
        %{label: Labels.action(type), emphasis: nil, text: blank_to_nil(parameters["flag"])}

      _other ->
        %{label: Labels.action(type), emphasis: nil, text: message_of(type, parameters)}
    end
  end

  defp message_of(type, parameters)
       when type in [
              :message_player,
              :message_all_players,
              :broadcast_message,
              :temporary_broadcast,
              :set_welcome_message
            ],
       do: blank_to_nil(parameters["message"])

  defp message_of(:send_discord_webhook, parameters),
    do: blank_to_nil(parameters["embed_title"]) || blank_to_nil(parameters["message"])

  defp message_of(_type, _parameters), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank_to_nil(_value), do: nil

  # ── State switch ───────────────────────────────────────────────────────────

  @doc """
  Off · Simulating · Live, as the header's radio group. Live stays locked
  until the rule has simulated for `Bench.unlock_days/0` days.
  """
  attr :id, :string, default: "bench-state"
  attr :state, :atom, required: true, values: [:off, :simulating, :live]
  attr :live_in, :integer, default: 0, doc: "days left before Live unlocks; 0 when open"
  attr :unlock_days, :integer, default: 3

  def state_switch(assigns) do
    ~H"""
    <div id={@id} role="radiogroup" aria-label={gettext("Rule state")} class="bench-state">
      <button
        id={@id <> "-off"}
        type="button"
        role="radio"
        data-state="off"
        aria-checked={to_string(@state == :off)}
        phx-click="set_state"
        phx-value-state="off"
      >
        {gettext("Switched off")}
      </button>
      <button
        id={@id <> "-simulating"}
        type="button"
        role="radio"
        data-state="simulating"
        aria-checked={to_string(@state == :simulating)}
        phx-click="set_state"
        phx-value-state="simulating"
      >
        <span class="bench-dash-dot"></span>{gettext("Simulating")}
      </button>
      <button
        id={@id <> "-live"}
        type="button"
        role="radio"
        data-state="live"
        aria-checked={to_string(@state == :live)}
        aria-disabled={@live_in > 0 && "true"}
        title={
          @live_in > 0 &&
            ngettext(
              "Unlocks after 1 day simulating",
              "Unlocks after %{count} days simulating",
              @unlock_days
            )
        }
        phx-click={@live_in == 0 && "set_state"}
        phx-value-state="live"
      >
        <.icon :if={@live_in > 0} name="hero-lock-closed" class="size-3.5" />
        {if @live_in > 0,
          do: ngettext("Live in 1 day", "Live in %{count} days", @live_in),
          else: gettext("Live")}
      </button>
    </div>
    """
  end

  # ── Recipes (a new rule) ───────────────────────────────────────────────────

  @doc """
  "Start from a recipe": the popular recipes as pills, over a new rule.
  """
  attr :recipes, :list, required: true
  attr :total, :integer, required: true
  attr :query, :string, default: ""

  def recipe_row(assigns) do
    ~H"""
    <nav
      id="bench-recipes"
      aria-label={gettext("Start from a recipe")}
      class="flex items-center gap-2 overflow-x-auto pb-1"
    >
      <span class="mr-1 shrink-0 text-[0.8125rem] text-muted">{gettext("Start from a recipe")}</span>
      <.link
        :for={recipe <- @recipes}
        navigate={"/rules/new?" <> URI.encode_query(Map.put(query_params(@query), "recipe", recipe.id))}
        class="flex h-9 shrink-0 items-center rounded-full border border-base-300 bg-base-100 px-3.5 text-[0.8125rem] transition-colors hover:border-primary/60"
      >
        {Labels.recipe_name(recipe.id)}
      </.link>
      <.link
        navigate={~p"/rules"}
        class="flex h-9 shrink-0 items-center px-3.5 text-[0.8125rem] font-medium text-primary hover:underline"
      >
        {ngettext("See the recipe", "See all %{count}", @total)}
      </.link>
    </nav>
    """
  end

  defp query_params(""), do: %{}
  defp query_params(query), do: URI.decode_query(query)

  # ── Run strip ──────────────────────────────────────────────────────────────

  @doc """
  The latest evaluations of the saved rule, one cell each; a click overlays
  that event on the rule.
  """
  attr :runs, :list, required: true
  attr :selected, :any, default: nil

  def run_strip(assigns) do
    present = assigns.runs |> Enum.map(& &1.outcome) |> MapSet.new()
    assigns = assign(assigns, :present, present)

    ~H"""
    <section
      id="bench-runs"
      aria-label={gettext("Recent runs")}
      class="flex flex-col gap-3 rounded-[1.375rem] bg-base-100 px-5 py-3.5 shadow-card lg:flex-row lg:items-center lg:gap-[1.125rem]"
    >
      <div class="flex shrink-0 flex-col gap-0.5 lg:w-[9.375rem]">
        <strong class="text-[0.8125rem] font-semibold">
          {ngettext("The last time", "The last %{count} times", length(@runs))}
        </strong>
        <span class="text-xs text-muted">{gettext("click to overlay")}</span>
      </div>
      <div class="bench-strip min-w-0 flex-1" style={"--cells: #{length(@runs)}"}>
        <button
          :for={{run, index} <- Enum.with_index(@runs)}
          id={"bench-run-#{index}"}
          type="button"
          class="bench-cell"
          data-outcome={run.outcome}
          aria-pressed={to_string(@selected == index)}
          aria-label={run_label(run)}
          title={run_label(run)}
          phx-click="overlay"
          phx-value-index={index}
        ></button>
      </div>
      <div class="flex shrink-0 flex-wrap gap-x-5 gap-y-1 text-[0.6875rem] text-subtle lg:flex-nowrap">
        <div class="flex flex-col gap-1">
          <.legend_key outcome="simulated" label={gettext("simulated run")} />
          <.legend_key
            :if={MapSet.member?(@present, :fired)}
            outcome="fired"
            label={gettext("fired")}
          />
          <.legend_key outcome="miss" label={gettext("did not match")} />
          <.legend_key outcome="held" label={gettext("on hold")} />
        </div>
        <div class="flex flex-col gap-1">
          <.legend_key outcome="exempt" label={gettext("exempt")} />
          <.legend_key outcome="error" label={gettext("error")} />
          <.legend_key
            :if={MapSet.member?(@present, :idle)}
            outcome="idle"
            label={gettext("not running")}
          />
        </div>
      </div>
    </section>
    """
  end

  attr :outcome, :string, required: true
  attr :label, :string, required: true

  defp legend_key(assigns) do
    ~H"""
    <span class="flex items-center gap-1.5">
      <span class="bench-cell bench-key pointer-events-none" data-outcome={@outcome}></span>
      {@label}
    </span>
    """
  end

  defp run_label(run) do
    name =
      (run.event && run.event.sample.player_name) ||
        (run.execution && run.execution.player_name) || gettext("Unknown player")

    "#{name} · #{outcome_label(run.outcome)}"
  end

  @doc "An outcome of the run strip in words."
  @spec outcome_label(atom()) :: String.t()
  def outcome_label(:simulated), do: gettext("simulated run")
  def outcome_label(:fired), do: gettext("fired")
  def outcome_label(:error), do: gettext("error")
  def outcome_label(:held), do: gettext("on hold")
  def outcome_label(:exempt), do: gettext("exempt")
  def outcome_label(:miss), do: gettext("did not match")
  def outcome_label(:idle), do: gettext("not running")
  def outcome_label(_other), do: "–"

  # ── Overlay banner ─────────────────────────────────────────────────────────

  @doc """
  The banner over the rule while a past event is overlaid: whose event, when,
  where; "run again with the edits"; close.
  """
  attr :overlay, :map, required: true
  attr :rerun, :any, default: nil
  attr :actions, :list, default: []

  def overlay_banner(assigns) do
    ~H"""
    <div
      id="bench-overlay"
      class="bench-overlay flex flex-wrap items-center gap-3 px-5 py-3.5 sm:px-6"
    >
      <.icon name="hero-clock" class="size-4 shrink-0 text-accent" />
      <span class="min-w-0 flex-1 basis-60 text-[0.8125rem]">
        {if @overlay.run && @overlay.run.execution,
          do: gettext("Overlaying the run of"),
          else: gettext("Overlaying the event of")}
        <strong class="font-semibold">{@overlay.player_name || gettext("Unknown player")}</strong>
        {gettext("at")}
        <.local_time id="bench-overlay-at" at={@overlay.at} format="time" />
        <span :for={detail <- @overlay.details}>{" · " <> detail}</span>
      </span>
      <button
        :if={@overlay.context}
        id="bench-rerun"
        type="button"
        class="bench-overlay-button"
        phx-click="rerun"
      >
        {gettext("Run again with the edits")}
      </button>
      <span :if={is_nil(@overlay.context)} class="text-xs opacity-80">
        {gettext("event no longer kept: showing what the run recorded")}
      </span>
      <button
        id="bench-overlay-close"
        type="button"
        class="flex size-8 shrink-0 cursor-pointer items-center justify-center rounded-full text-[1rem] opacity-70 hover:opacity-100"
        aria-label={gettext("Close the overlay")}
        phx-click="close_overlay"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
      <p
        :if={@rerun}
        id="bench-rerun-result"
        class="flex basis-full items-center gap-2 text-[0.8125rem] font-semibold"
      >
        <.icon
          name={if @rerun.outcome == :fires, do: "hero-bolt", else: "hero-minus-circle"}
          class="size-4 shrink-0"
        />
        {rerun_text(@rerun, @actions)}
      </p>
    </div>
    """
  end

  defp rerun_text(%{outcome: :fires, step: step}, actions) when is_integer(step) do
    gettext("With the edits: would fire step %{step} · %{action}",
      step: step + 1,
      action: short_action(Enum.at(actions, step))
    )
  end

  defp rerun_text(%{outcome: :fires}, actions) do
    gettext("With the edits: would fire · %{actions}",
      actions: Enum.map_join(actions, ", ", &short_action/1)
    )
  end

  defp rerun_text(%{outcome: :exempt}, _actions),
    do: gettext("With the edits: would not fire, the player is exempt")

  defp rerun_text(%{outcome: outcome}, _actions) when outcome in [:cooldown, :max_executions],
    do: gettext("With the edits: a limit would hold it back")

  defp rerun_text(_rerun, _actions),
    do: gettext("With the edits: would not fire, the conditions do not hold")

  # ── Ladder ─────────────────────────────────────────────────────────────────

  @doc """
  One rung of "Then": number, action, and where the overlaid event stands
  on it (ran, this run, next) or whether the draft edited it.
  """
  attr :index, :integer, required: true
  attr :action, :map, required: true
  attr :state, :atom, default: nil, values: [nil, :ran, :current, :next]
  attr :edited?, :boolean, default: false
  attr :errors?, :boolean, default: false

  def ladder_step(assigns) do
    assigns = assign(assigns, :parts, action_parts(assigns.action))

    ~H"""
    <button
      id={"bench-step-#{@index}"}
      type="button"
      class={["bench-step", @errors? && "!border-error"]}
      data-state={@state}
      phx-click="edit_action"
      phx-value-index={@index}
      aria-label={gettext("Edit step %{number}", number: @index + 1)}
    >
      <span class="bench-step-number">{@index + 1}</span>
      <span class={["min-w-0 truncate text-sm", @state == :current && "font-semibold"]}>
        {@parts.label}
        <span :if={@parts.emphasis} class={@edited? && "bench-edited"}>{@parts.emphasis}</span>
        <span :if={@parts.text} class="font-mono text-xs text-muted">“{@parts.text}”</span>
      </span>
      <span :if={@errors?} class="text-xs font-semibold text-error">
        {gettext("needs attention")}
      </span>
      <span
        :if={not @errors? and @state == :current}
        class="text-xs font-semibold text-accent"
      >
        {gettext("this run")}
      </span>
      <span
        :if={not @errors? and @state != :current and @edited?}
        class="rounded-full bg-primary/12 px-2 py-[0.1875rem] text-[0.6875rem] font-semibold text-primary"
      >
        {gettext("changed")}
      </span>
      <span
        :if={not @errors? and not @edited? and @state == :ran}
        class="text-xs text-muted"
      >
        {gettext("already ran")}
      </span>
      <span
        :if={not @errors? and not @edited? and @state == :next}
        class="text-xs text-muted"
      >
        {gettext("next")}
      </span>
    </button>
    """
  end

  # ── Replay ─────────────────────────────────────────────────────────────────

  @doc """
  "Replay de 7 dias": the rule as typed over the real events of the last
  days - how often it would fire, on how many players, which rung, and who
  changed fate with the edits.
  """
  attr :replay, :map, default: nil
  attr :comparison, :map, default: nil
  attr :trigger, :atom, required: true
  attr :days, :integer, required: true
  attr :actions, :list, required: true
  attr :events_open?, :boolean, default: false
  attr :overlaps, :list, default: []

  def replay_panel(assigns) do
    assigns =
      assign(assigns,
        max:
          max(
            Enum.max([0 | Enum.map((assigns.replay && assigns.replay.steps) || [], & &1.count)]),
            1
          ),
        fired:
          if(assigns.replay,
            do:
              assigns.replay.judged
              |> Enum.filter(&(&1.outcome == :fires))
              |> Enum.reverse(),
            else: []
          )
      )

    ~H"""
    <section
      id="rule-replay"
      aria-label={gettext("%{count}-day replay", count: @days)}
      class="flex flex-col gap-3.5 rounded-[1.75rem] bg-base-100 p-5 shadow-card sm:p-[1.375rem]"
    >
      <div class="flex items-baseline gap-3">
        <h2 class="flex-1 font-display text-[1.25rem] font-semibold">
          {gettext("%{count}-day replay", count: @days)}
        </h2>
        <span :if={@comparison} class="text-xs text-muted">{gettext("with your edits")}</span>
      </div>

      <p :if={@replay && @replay.events > 0} class="text-[0.8125rem] leading-normal text-subtle">
        {gettext("Last week's real events went through the draft. Nothing reached the game.")}
        <span
          :if={@replay.since && @replay.short?}
          id="rule-replay-coverage"
          class="block pt-1 text-xs text-muted"
        >
          <%= if @replay.capped? do %>
            {gettext(
              "Events are kept for %{days} days, up to %{kept} per trigger and server. This one is busier: the replay covers its newest %{count}, since",
              days: @days,
              kept: LiveComponents.format_number(SavedEvents.keep()),
              count: LiveComponents.format_number(@replay.events)
            )}
          <% else %>
            {ngettext(
              "Recorded so far: 1 event, since",
              "Recorded so far: %{count} events, since",
              @replay.events
            )}
          <% end %>
          <.local_time id="rule-replay-since" at={@replay.since} format="datetime" />
        </span>
      </p>
      <p
        :if={is_nil(@replay) or @replay.events == 0}
        id="rule-replay-empty"
        class="rounded-2xl bg-secondary px-4 py-3 text-[0.8125rem] leading-normal text-subtle"
      >
        {gettext(
          "No \"%{trigger}\" event was recorded on these servers in the last %{count} days. The replay fills in as the engine sees them.",
          trigger: Labels.trigger(@trigger),
          count: @days
        )}
      </p>

      <div :if={@replay && @replay.events > 0} class="grid grid-cols-2 gap-2.5">
        <div class="flex flex-col gap-0.5 rounded-[1.125rem] bg-secondary px-4 py-3.5">
          <span class="text-xs text-subtle">{gettext("Would fire")}</span>
          <strong
            id="rule-replay-fires"
            class="font-display text-[1.75rem] font-semibold leading-tight"
          >
            {@replay.fires}×
          </strong>
          <span :if={@comparison} class={["text-xs", delta_class(@comparison.delta)]}>
            {delta_text(@comparison.delta)}
          </span>
          <span :if={is_nil(@comparison)} class="text-xs text-muted">
            {ngettext("in 1 event", "in %{count} events", @replay.events)}
          </span>
        </div>
        <div class="flex flex-col gap-0.5 rounded-[1.125rem] bg-secondary px-4 py-3.5">
          <span class="text-xs text-subtle">{gettext("Players")}</span>
          <strong class="font-display text-[1.75rem] font-semibold leading-tight">
            {@replay.players}
          </strong>
          <span class="text-xs text-muted">
            {ngettext("1 of them VIP", "%{count} of them VIP", @replay.vip_players)}
          </span>
        </div>
      </div>

      <div
        :if={(@replay && @replay.events > 0) and @replay.steps != []}
        id="rule-replay-steps"
        class="flex flex-col gap-2"
      >
        <div
          :for={step <- @replay.steps}
          class="grid grid-cols-[6.25rem_minmax(0,1fr)_2.25rem] items-center gap-2.5 text-[0.8125rem]"
        >
          <span class="truncate text-subtle">{short_action(step.action)}</span>
          <span class="bench-bar" data-tone={action_bar_tone(step.action)}>
            <span style={"width: #{bar_width(step.count, @max)}%"}></span>
          </span>
          <span class="text-right font-mono">{step.count}</span>
        </div>
      </div>

      <div
        :if={@comparison && @comparison.changes != []}
        id="rule-replay-changes"
        class="flex flex-col gap-1 border-t border-base-300 pt-3"
      >
        <span class="mb-1 text-xs text-muted">{gettext("Who changed fate with the edits")}</span>
        <.link
          :for={change <- Enum.take(@comparison.changes, 4)}
          navigate={~p"/players/#{change.player_id}"}
          class="flex items-center gap-2.5 rounded-xl px-1.5 py-2 transition-colors hover:bg-secondary"
        >
          <span class="min-w-0 flex-1 truncate text-[0.8125rem]">
            <strong class="font-semibold">{change.player_name || change.player_id}</strong>
            <span class="text-muted">{change_detail(change)}</span>
          </span>
          <span class={["shrink-0 text-[0.6875rem] font-semibold", change_class(change)]}>
            {change_text(change)}
          </span>
        </.link>
      </div>

      <div
        :if={@overlaps != []}
        class="flex items-start gap-2.5 rounded-2xl bg-warning/10 px-3.5 py-3 text-[0.8125rem] leading-snug"
      >
        <.icon name="hero-exclamation-triangle" class="mt-px size-4 shrink-0 text-warning" />
        <span>
          {ngettext(
            "Another rule listens to the same event:",
            "Other rules listen to the same event:",
            length(@overlaps)
          )}
          <strong class="font-semibold">{Enum.map_join(@overlaps, ", ", & &1.name)}</strong>. {gettext(
            "They will all run."
          )}
        </span>
      </div>

      <span class="grow"></span>

      <div :if={@events_open? and @fired != []} id="rule-replay-events" class="flex flex-col gap-0.5">
        <button
          :for={{judgement, position} <- @fired |> Enum.take(60) |> Enum.with_index()}
          type="button"
          phx-click="overlay_event"
          phx-value-key={event_key(judgement.event)}
          class="flex cursor-pointer items-center gap-2.5 rounded-xl px-2 py-1.5 text-left text-[0.8125rem] hover:bg-secondary"
        >
          <span class="min-w-0 flex-1 truncate">
            {judgement.event.sample.player_name || gettext("Unknown player")}
            <span class="text-muted">· {judgement.event.server.name}</span>
          </span>
          <span :if={judgement.step} class="font-mono text-xs text-subtle">
            {gettext("rung %{number}", number: judgement.step + 1)}
          </span>
          <.local_time
            id={"replay-event-#{position}"}
            at={judgement.event.sample.at}
            format="relative"
            class="text-xs text-muted"
          />
        </button>
      </div>

      <button
        :if={@replay && @replay.fires > 0}
        id="rule-replay-toggle"
        type="button"
        phx-click="toggle_events"
        class="h-11 cursor-pointer rounded-full border border-base-300 bg-secondary text-sm transition-colors hover:border-primary/50"
      >
        {if @events_open?,
          do: gettext("Hide the events"),
          else: ngettext("See the event", "See the %{count} events", @replay.fires)}
      </button>
    </section>
    """
  end

  @doc "A stable key for a replayed event, for links back to it."
  @spec event_key(map()) :: String.t()
  def event_key(%{sample: sample}) do
    at = Map.get(sample, :at_us) || DateTime.to_unix(sample.at, :microsecond)
    "#{sample.server_id}-#{at}-#{sample.player_id}"
  end

  defp bar_width(0, _max), do: 0
  defp bar_width(count, max), do: max(round(count * 100 / max), 2)

  defp delta_class(delta) when delta > 0, do: "font-semibold bench-hold"
  defp delta_class(delta) when delta < 0, do: "font-semibold bench-ok"
  defp delta_class(_delta), do: "text-muted"

  defp delta_text(0), do: gettext("same as the current version")

  defp delta_text(delta) when delta > 0,
    do: gettext("+%{count} vs the current version", count: delta)

  defp delta_text(delta), do: gettext("−%{count} vs the current version", count: abs(delta))

  defp change_detail(change) do
    [
      change.vip? && "VIP",
      change.step && gettext("rung %{number}", number: change.step + 1),
      ngettext("1 event", "%{count} events", change.events)
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp change_text(%{kind: :action, from: from, to: to}),
    do: "#{short_actions(from)} → #{short_actions(to)}"

  defp change_text(%{kind: :now_fires, from: :exempt}), do: gettext("was exempt")

  defp change_text(%{kind: :now_fires, from: from}) when from in [:cooldown, :max_executions],
    do: gettext("was on hold")

  defp change_text(%{kind: :now_fires}), do: gettext("now fires")
  defp change_text(%{kind: :no_longer_fires, to: :exempt}), do: gettext("now exempt")
  defp change_text(%{kind: :no_longer_fires}), do: gettext("no longer fires")

  defp change_class(%{kind: :action}), do: "bench-bad"
  defp change_class(%{kind: :now_fires}), do: "bench-hold"
  defp change_class(_change), do: "bench-ok"

  defp short_actions(actions) when is_list(actions),
    do: actions |> Enum.map_join(", ", &short_action/1) |> String.downcase()

  defp short_actions(_actions), do: "–"

  # ── Action drawer ──────────────────────────────────────────────────────────

  @doc """
  The action drawer (ActionDiscord board): one editor per action, all
  rendered so every change posts the whole rule, only the one being edited
  shown. A click outside, Esc or "Save action" closes it; "Cancel" puts the
  action back as it was when the drawer opened.
  """
  attr :actions, :list, required: true, doc: "the action forms"
  attr :editing, :any, default: nil
  attr :trigger, :atom, required: true
  attr :webhooks, :list, default: []
  attr :webhook_statuses, :map, default: %{}
  attr :example, :any, default: nil
  attr :escalating?, :boolean, default: false
  attr :deliveries, :map, default: %{}
  attr :testing?, :boolean, default: false

  def action_drawer(assigns) do
    current = Enum.find(assigns.actions, &(&1.index == assigns.editing))
    type = current && action_type(current)

    assigns =
      assign(assigns,
        current: current,
        type: type,
        total: length(assigns.actions),
        batch?: assigns.trigger in Catalog.batch_triggers()
      )

    ~H"""
    <div
      id="bench-drawer"
      class={["fixed inset-0 z-50", is_nil(@current) && "hidden"]}
      role="dialog"
      aria-modal="true"
      aria-labelledby="bench-drawer-title"
      phx-window-keydown={@current && "close_action"}
      phx-key="Escape"
    >
      <div class="bench-scrim absolute inset-0" phx-click="close_action"></div>
      <aside class="absolute inset-y-0 right-0 flex w-full max-w-[63.125rem] flex-col border-l border-base-300 bg-base-100 shadow-[-24px_0_80px_rgba(0,0,0,0.5)]">
        <div class="flex items-center gap-3.5 border-b border-base-300 px-5 py-4 sm:px-7 sm:py-[1.375rem]">
          <span
            :if={@type}
            class={[
              "flex size-[2.875rem] shrink-0 items-center justify-center rounded-[0.875rem]",
              drawer_tile(@type)
            ]}
          >
            <.icon name={Icons.action(@type)} class="size-5" />
          </span>
          <div class="flex min-w-0 flex-1 flex-col gap-0.5">
            <span :if={@current} class="text-[0.8125rem] text-muted">
              {if @escalating?,
                do: gettext("Step %{number} of %{total}", number: @current.index + 1, total: @total),
                else:
                  gettext("Action %{number} of %{total}", number: @current.index + 1, total: @total)} · {action_group_label(
                @type
              )}
            </span>
            <h2
              id="bench-drawer-title"
              class="truncate font-display text-[1.375rem] font-semibold tracking-tight sm:text-xl"
            >
              {@type && Labels.action(@type)}
            </h2>
          </div>
          <div :if={@current} class="hidden items-center gap-1 sm:flex">
            <.drawer_tool
              click="move_action"
              index={@current.index}
              dir="up"
              disabled={@current.index == 0}
              icon="hero-chevron-up"
              label={gettext("Move this action up")}
            />
            <.drawer_tool
              click="move_action"
              index={@current.index}
              dir="down"
              disabled={@current.index >= @total - 1}
              icon="hero-chevron-down"
              label={gettext("Move this action down")}
            />
            <.drawer_tool
              click="duplicate_action"
              index={@current.index}
              icon="hero-document-duplicate"
              label={gettext("Duplicate this action")}
            />
            <.drawer_tool
              click="remove_action"
              index={@current.index}
              icon="hero-trash"
              label={gettext("Remove this action")}
            />
          </div>
          <button
            type="button"
            phx-click="close_action"
            aria-label={gettext("Close")}
            class="flex size-11 shrink-0 cursor-pointer items-center justify-center rounded-full border border-base-300 bg-secondary"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <div class="grid min-h-0 flex-1 overflow-y-auto lg:grid-cols-[minmax(0,1fr)_25rem] lg:overflow-hidden">
          <div class="relative flex min-w-0 flex-col gap-4 px-5 py-5 sm:px-7 lg:overflow-y-auto lg:border-r lg:border-base-300">
            <div
              :for={action <- @actions}
              id={"bench-action-#{action.index}"}
              class={["flex flex-col gap-4", action.index != @editing && "hidden"]}
            >
              <.action_editor
                action={action}
                webhooks={@webhooks}
                webhook_statuses={@webhook_statuses}
                batch?={@batch?}
                example={@example}
                trigger={@trigger}
              />
            </div>
            <details
              id="bench-variables"
              class="group rounded-2xl border border-base-300"
              data-keep-attrs="open"
            >
              <summary class="flex h-11 cursor-pointer list-none items-center gap-2 px-4 text-[0.8125rem] font-medium [&::-webkit-details-marker]:hidden">
                <span class="font-mono text-accent">&lbrace;…&rbrace;</span>
                {gettext("Variables you can use")}
                <.icon
                  name="hero-chevron-down"
                  class="ml-auto size-4 text-muted transition-transform group-open:rotate-180"
                />
              </summary>
              <div class="border-t border-base-300 p-2.5">
                <.placeholders trigger={@trigger} example={@example} />
              </div>
            </details>
          </div>

          <div class="bench-drawer-side flex min-w-0 flex-col gap-3 px-5 py-5 sm:px-6 lg:overflow-y-auto">
            <.action_preview
              :if={@current}
              action={@current}
              type={@type}
              webhooks={@webhooks}
              example={@example}
              delivery={Map.get(@deliveries, @current.index)}
            />
          </div>
        </div>

        <div class="flex flex-wrap items-center gap-3 border-t border-base-300 px-5 py-4 sm:px-7">
          <button
            :if={@type == :send_discord_webhook}
            id="bench-discord-test"
            type="button"
            phx-click="discord_test"
            phx-value-index={@current && @current.index}
            disabled={@testing?}
            class="flex h-12 cursor-pointer items-center gap-2 rounded-full border border-base-300 bg-secondary pr-5 pl-4 text-sm font-medium disabled:opacity-60"
          >
            <.icon name="hero-paper-airplane" class="size-4" />
            {if @testing?, do: gettext("Sending..."), else: gettext("Send a test to the channel")}
          </button>
          <span :if={@type == :send_discord_webhook} class="hidden text-xs text-muted sm:inline">
            {gettext("goes out marked as a test")}
          </span>
          <span class="grow"></span>
          <button
            id="bench-action-cancel"
            type="button"
            phx-click="cancel_action"
            class="h-12 cursor-pointer rounded-full border border-base-300 bg-base-100 px-5 text-sm font-medium"
          >
            {gettext("Cancel")}
          </button>
          <button
            id="bench-action-save"
            type="button"
            phx-click="close_action"
            class="h-12 cursor-pointer rounded-full bg-primary px-6 text-sm font-semibold text-primary-content"
          >
            {gettext("Save action")}
          </button>
        </div>
      </aside>
    </div>
    """
  end

  defp action_group_label(type) do
    case Enum.find(Catalog.action_groups(), &(type in Catalog.actions_in_group(&1))) do
      nil -> ""
      group -> Labels.action_group(group)
    end
  end

  defp action_type(action_form) do
    case Form.input_value(action_form, :type) do
      type when is_binary(type) -> existing_action(type)
      nil -> :message_player
      type -> type
    end
  end

  defp drawer_tile(:send_discord_webhook), do: "bench-discord-tile"

  defp drawer_tile(type) do
    case Icons.action_tone(type) do
      :error -> "bg-error/14 text-error"
      :warning -> "bg-warning/13 text-warning"
      _info -> "bg-accent/13 text-accent"
    end
  end

  attr :click, :string, required: true
  attr :index, :integer, required: true
  attr :dir, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp drawer_tool(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@click}
      phx-value-index={@index}
      phx-value-dir={@dir}
      disabled={@disabled}
      aria-label={@label}
      title={@label}
      class="flex size-9 cursor-pointer items-center justify-center rounded-full text-muted transition-colors hover:bg-secondary hover:text-base-content disabled:cursor-not-allowed disabled:opacity-40"
    >
      <.icon name={@icon} class="size-4" />
    </button>
    """
  end

  # One action's fields: its type, then its parameters (the Discord action
  # gets the editor of its own board).
  attr :action, :any, required: true
  attr :webhooks, :list, default: []
  attr :webhook_statuses, :map, default: %{}
  attr :batch?, :boolean, default: false
  attr :example, :any, default: nil
  attr :trigger, :atom, required: true

  defp action_editor(assigns) do
    type = action_type(assigns.action)

    assigns =
      assign(assigns,
        type: type,
        params: Catalog.action_params(type),
        parameters: current_parameters(assigns.action),
        errors: action_errors(assigns.action)
      )

    ~H"""
    <label class="flex flex-col gap-1.5">
      <span class="text-xs text-muted">{gettext("Action")}</span>
      <select
        id={@action[:type].id}
        name={@action[:type].name}
        class="bench-tile h-[2.875rem] rounded-[0.875rem]"
      >
        {Phoenix.HTML.Form.options_for_select(Labels.action_options(), to_string(@type))}
      </select>
    </label>

    <.discord_editor
      :if={@type == :send_discord_webhook}
      action={@action}
      parameters={@parameters}
      webhooks={@webhooks}
      statuses={@webhook_statuses}
      batch?={@batch?}
    />

    <div :for={{key, param_type, opts} <- @params} :if={@type != :send_discord_webhook}>
      <div :if={param_type == :text and opts[:template]} class="-mb-6 flex justify-end">
        <.variables_button />
      </div>
      <.param_input
        name={"#{@action.name}[parameters][#{key}]"}
        id={"#{@action.id}_parameters_#{key}"}
        label={Labels.action_param(key)}
        key={key}
        type={param_type}
        value={parameter_value(@parameters, key, opts)}
        min={opts[:min]}
        required={opts[:required]}
        template={opts[:template] == true}
      />
    </div>
    <p
      :if={@params == [] and @type != :send_discord_webhook}
      class="rounded-2xl bg-secondary px-4 py-3 text-[0.8125rem] text-subtle"
    >
      {gettext("This action has nothing to set.")}
    </p>

    <p :for={message <- @errors} class="flex items-center gap-1.5 text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />{message}
    </p>
    """
  end

  # ── Discord action ─────────────────────────────────────────────────────────

  @swatches [
    {"#D2F36B", "Lime"},
    {"#F4C95D", "Amber"},
    {"#FF7B72", "Red"},
    {"#8CC4FF", "Allied blue"},
    {"#FF9F5A", "Axis orange"},
    {"#C3B3FF", "Lavender"}
  ]

  attr :action, :any, required: true
  attr :parameters, :map, required: true
  attr :webhooks, :list, default: []
  attr :statuses, :map, default: %{}
  attr :batch?, :boolean, default: false

  @doc """
  The Discord action's fields, laid out as the ActionDiscord board: webhook,
  delivery switches, title, description, fields, colour, thumbnail, mentions.
  Every control writes the same parameters the engine reads.
  """
  def discord_editor(assigns) do
    parameters = assigns.parameters

    assigns =
      assign(assigns,
        fields: Message.parse_fields(parameters["embed_fields"]),
        color: String.upcase(parameters["embed_color"] || "#5865F2"),
        swatches: @swatches,
        edit?: parameters["mode"] == "edit",
        thread?: present?(parameters["thread_name"]) or present?(parameters["thread_id"]),
        status: webhook_status(assigns.statuses, parameters["webhook_id"]),
        more?:
          Enum.any?(~w(message embed_footer username avatar_url), &present?(parameters[&1])) or
            truthy?(parameters["silent"])
      )

    ~H"""
    <div class="grid grid-cols-[minmax(0,1fr)_auto] items-end gap-2.5">
      <label class="flex min-w-0 flex-col gap-1.5">
        <span class="text-xs text-muted">{gettext("Webhook")}</span>
        <select
          id={pid(@action, :webhook_id)}
          name={pname(@action, :webhook_id)}
          class="bench-tile h-[2.875rem] rounded-[0.875rem]"
        >
          <option value="">{gettext("Choose a webhook")}</option>
          {Phoenix.HTML.Form.options_for_select(@webhooks, to_string(@parameters["webhook_id"]))}
        </select>
      </label>
      <.link
        navigate={~p"/discord"}
        class="flex h-[2.875rem] items-center text-[0.8125rem] text-primary hover:underline"
      >
        {gettext("Manage webhooks")}
      </.link>
    </div>
    <p :if={@status} id={"#{@action.id}_webhook_status"} class="-mt-2 flex items-center gap-2 text-xs">
      <span :if={@status.remote} class="text-muted">{@status.remote}</span>
      <span
        :if={@status.status == :verified}
        class="flex items-center gap-1.5 font-medium text-primary"
      >
        <span class="size-[0.4375rem] rounded-full bg-primary"></span>{gettext("verified")}
      </span>
      <span
        :if={@status.status == :failing}
        class="flex min-w-0 items-center gap-1.5 font-medium text-error"
        title={@status.error}
      >
        <span class="size-[0.4375rem] shrink-0 rounded-full bg-error"></span>
        <span class="truncate">{gettext("failing: %{error}", error: @status.error)}</span>
      </span>
      <span :if={@status.status == :unused} class="text-muted">{gettext("never used yet")}</span>
    </p>
    <p :if={@webhooks == []} class="rounded-2xl bg-warning/10 px-4 py-3 text-[0.8125rem]">
      {gettext("No Discord webhook is registered yet.")}
      <.link navigate={~p"/discord/new"} class="font-medium text-primary hover:underline">
        {gettext("Register one")}
      </.link>
    </p>

    <%!-- "In a thread" only shows its fields: the switch is view state,
          kept by Alpine across patches, while the fields post the values. --%>
    <div x-data={"{ thread: #{@thread?} }"} class="flex flex-col gap-4">
      <div class="grid gap-2.5 sm:grid-cols-3">
        <.switch_tile
          id={pid(@action, :mode)}
          name={pname(@action, :mode)}
          on_value="edit"
          off_value="send"
          checked={@edit?}
          title={gettext("Edit in place")}
          hint={gettext("One message, edited on every run")}
        />
        <.switch_tile
          id={"#{@action.id}_thread_switch"}
          checked={@thread?}
          title={gettext("In a thread")}
          hint={gettext("Opens a post once and keeps posting in it")}
          model="thread"
        />
        <.switch_tile
          :if={@batch?}
          id={pid(@action, :aggregate)}
          name={pname(@action, :aggregate)}
          on_value="true"
          off_value="false"
          checked={truthy?(@parameters["aggregate"])}
          title={gettext("Aggregate")}
          hint={gettext("Every player of one sweep in a single message")}
        />
        <.switch_tile
          :if={not @batch?}
          id={pid(@action, :silent)}
          name={pname(@action, :silent)}
          on_value="true"
          off_value="false"
          checked={truthy?(@parameters["silent"])}
          title={gettext("Silent")}
          hint={gettext("Posts without a notification")}
        />
      </div>

      <label :if={@edit?} class="flex flex-col gap-1.5">
        <span class="text-xs text-muted">{Labels.action_param(:edit_key)}</span>
        <input
          type="text"
          id={pid(@action, :edit_key)}
          name={pname(@action, :edit_key)}
          value={@parameters["edit_key"]}
          placeholder="{map_name}"
          data-template
          class="bench-tile font-mono text-[0.8125rem]"
        />
        <span class="text-xs text-muted">
          {gettext(
            "Empty: a single message per server, edited forever. With a placeholder, a new message whenever its value changes."
          )}
        </span>
      </label>
      <div
        id={"#{@action.id}_thread"}
        class="grid gap-2.5 sm:grid-cols-2"
        x-show="thread"
        x-cloak={not @thread?}
      >
        <label class="flex flex-col gap-1.5">
          <span class="text-xs text-muted">{Labels.action_param(:thread_name)}</span>
          <input
            type="text"
            id={pid(@action, :thread_name)}
            name={pname(@action, :thread_name)}
            value={@parameters["thread_name"]}
            placeholder="{map_name}"
            data-template
            class="bench-tile"
          />
        </label>
        <label class="flex flex-col gap-1.5">
          <span class="text-xs text-muted">{Labels.action_param(:thread_id)}</span>
          <input
            type="text"
            id={pid(@action, :thread_id)}
            name={pname(@action, :thread_id)}
            value={@parameters["thread_id"]}
            class="bench-tile font-mono text-[0.8125rem]"
          />
        </label>
      </div>
    </div>

    <label class="flex flex-col gap-1.5">
      <span class="text-xs text-muted">{gettext("Title")}</span>
      <input
        type="text"
        id={pid(@action, :embed_title)}
        name={pname(@action, :embed_title)}
        value={@parameters["embed_title"]}
        data-template
        class="bench-tile h-[2.875rem] rounded-[0.875rem]"
      />
    </label>

    <label class="flex flex-col gap-1.5">
      <span class="flex items-center gap-2">
        <span class="flex-1 text-xs text-muted">{gettext("Description")}</span>
        <.variables_button />
      </span>
      <textarea
        id={pid(@action, :embed_description)}
        name={pname(@action, :embed_description)}
        rows="3"
        class="bench-tile h-auto min-h-[5.25rem] rounded-[0.875rem] py-3 leading-[1.9]"
      >{@parameters["embed_description"]}</textarea>
    </label>

    <.embed_fields action={@action} fields={@fields} raw={@parameters["embed_fields"]} />

    <div class="grid gap-4 sm:grid-cols-2">
      <fieldset class="flex flex-col gap-2">
        <legend class="mb-2 text-xs text-muted">{gettext("Bar colour")}</legend>
        <div class="flex flex-wrap gap-2">
          <label :for={{hex, name} <- @swatches} class="cursor-pointer">
            <input
              type="radio"
              name={pname(@action, :embed_color)}
              value={hex}
              checked={@color == hex}
              class="peer sr-only"
            />
            <span
              class="block size-[1.875rem] rounded-full peer-checked:shadow-[0_0_0_2px_var(--color-base-100),0_0_0_4px_var(--color-base-content)] peer-focus-visible:ring-2 peer-focus-visible:ring-primary"
              style={"background: #{hex}"}
              title={swatch_label(name)}
            ></span>
            <span class="sr-only">{swatch_label(name)}</span>
          </label>
          <label
            :if={not Enum.any?(@swatches, fn {hex, _name} -> hex == @color end)}
            class="cursor-pointer"
          >
            <input
              type="radio"
              name={pname(@action, :embed_color)}
              value={@color}
              checked
              class="peer sr-only"
            />
            <span
              class="block size-[1.875rem] rounded-full shadow-[0_0_0_2px_var(--color-base-100),0_0_0_4px_var(--color-base-content)]"
              style={"background: #{@color}"}
              title={@color}
            ></span>
          </label>
        </div>
      </fieldset>
      <label class="flex flex-col gap-1.5">
        <span class="text-xs text-muted">{gettext("Thumbnail")}</span>
        <input
          type="text"
          id={pid(@action, :embed_thumbnail_url)}
          name={pname(@action, :embed_thumbnail_url)}
          value={@parameters["embed_thumbnail_url"]}
          placeholder="https://"
          class="bench-tile"
        />
      </label>
    </div>

    <div class="flex flex-col gap-1.5">
      <.chip_input
        field={
          %Phoenix.HTML.FormField{
            id: pid(@action, :mention_role_ids),
            name: pname(@action, :mention_role_ids),
            value: @parameters["mention_role_ids"],
            errors: [],
            field: :mention_role_ids,
            form: @action
          }
        }
        label={gettext("Mentions")}
        label_class="text-xs text-muted"
        placeholder={gettext("A role id, then Enter")}
      />
      <span class="text-xs text-muted">
        {gettext("Nobody is pinged unless listed here. Write <@&id> in the text to mention the role.")}
      </span>
    </div>

    <details open={@more?} class="group rounded-2xl border border-base-300" data-keep-attrs="open">
      <summary class="flex h-11 cursor-pointer list-none items-center gap-2 px-4 text-[0.8125rem] font-medium [&::-webkit-details-marker]:hidden">
        {gettext("More: text outside the card, footer, sender")}
        <.icon
          name="hero-chevron-down"
          class="ml-auto size-4 text-muted transition-transform group-open:rotate-180"
        />
      </summary>
      <div class="grid gap-3 border-t border-base-300 p-4">
        <label class="flex flex-col gap-1.5">
          <span class="text-xs text-muted">{Labels.action_param(:message)}</span>
          <textarea
            id={pid(@action, :message)}
            name={pname(@action, :message)}
            rows="2"
            class="bench-tile h-auto py-2.5"
          >{@parameters["message"]}</textarea>
        </label>
        <label class="flex flex-col gap-1.5">
          <span class="text-xs text-muted">{Labels.action_param(:embed_footer)}</span>
          <input
            type="text"
            id={pid(@action, :embed_footer)}
            name={pname(@action, :embed_footer)}
            value={@parameters["embed_footer"]}
            data-template
            class="bench-tile"
          />
        </label>
        <div class="grid gap-3 sm:grid-cols-2">
          <label class="flex flex-col gap-1.5">
            <span class="text-xs text-muted">{Labels.action_param(:username)}</span>
            <input
              type="text"
              id={pid(@action, :username)}
              name={pname(@action, :username)}
              value={@parameters["username"]}
              data-template
              class="bench-tile"
            />
          </label>
          <label class="flex flex-col gap-1.5">
            <span class="text-xs text-muted">{Labels.action_param(:avatar_url)}</span>
            <input
              type="text"
              id={pid(@action, :avatar_url)}
              name={pname(@action, :avatar_url)}
              value={@parameters["avatar_url"]}
              placeholder="https://"
              class="bench-tile"
            />
          </label>
        </div>
        <label class="flex items-center gap-2 text-sm">
          <input type="hidden" name={pname(@action, :embed_timestamp)} value="false" />
          <input
            type="checkbox"
            id={pid(@action, :embed_timestamp)}
            name={pname(@action, :embed_timestamp)}
            value="true"
            checked={@parameters["embed_timestamp"] in [nil, true, "true"]}
            class="pc-checkbox"
          />
          {Labels.action_param(:embed_timestamp)}
        </label>
        <label :if={@batch?} class="flex items-center gap-2 text-sm">
          <input type="hidden" name={pname(@action, :silent)} value="false" />
          <input
            type="checkbox"
            id={pid(@action, :silent)}
            name={pname(@action, :silent)}
            value="true"
            checked={truthy?(@parameters["silent"])}
            class="pc-checkbox"
          />
          {Labels.action_param(:silent)}
        </label>
      </div>
    </details>
    """
  end

  @doc """
  "+ variable {…}": opens the variable list of the drawer; a click on a
  variable then inserts it where the text was being written.
  """
  def variables_button(assigns) do
    ~H"""
    <button
      type="button"
      class="h-7 cursor-pointer rounded-lg border border-accent/50 bg-accent/12 px-2.5 font-mono text-xs text-accent"
      x-on:mousedown.prevent=""
      x-on:click="const d = document.getElementById('bench-variables'); d.open = true; d.scrollIntoView({block: 'nearest', behavior: 'smooth'})"
    >
      + {gettext("variable")} &lbrace;…&rbrace;
    </button>
    """
  end

  defp webhook_status(statuses, id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Map.get(statuses, id)
      _none -> nil
    end
  end

  defp swatch_label("Lime"), do: gettext("Lime")
  defp swatch_label("Amber"), do: gettext("Amber")
  defp swatch_label("Red"), do: gettext("Red")
  defp swatch_label("Allied blue"), do: gettext("Allied blue")
  defp swatch_label("Axis orange"), do: gettext("Axis orange")
  defp swatch_label("Lavender"), do: gettext("Lavender")

  # A switch card of the Discord editor. With `name` it posts a value (off
  # value first, so the checkbox wins when on); with `model` it only drives
  # an Alpine variable that shows or hides another block.
  attr :id, :string, required: true
  attr :name, :string, default: nil
  attr :on_value, :string, default: "true"
  attr :off_value, :string, default: "false"
  attr :checked, :boolean, default: false
  attr :title, :string, required: true
  attr :hint, :string, required: true

  attr :model, :string,
    default: nil,
    doc: "an Alpine variable the switch drives, instead of a value"

  defp switch_tile(assigns) do
    ~H"""
    <label class="flex cursor-pointer flex-col gap-1.5 rounded-2xl border border-base-300 bg-secondary px-3.5 py-3 transition-colors has-[:checked]:border-primary/40 has-[:checked]:bg-primary/6">
      <span class="flex items-center justify-between gap-2">
        <strong class="text-sm font-semibold">{@title}</strong>
        <input :if={@name} type="hidden" name={@name} value={@off_value} />
        <span class="pc-switch pc-switch--sm shrink-0">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value={@on_value}
            checked={@checked}
            class="peer sr-only"
            x-model={@model}
          /> <span class="pc-switch__fake-input pc-switch__fake-input--sm"></span>
          <span class="pc-switch__fake-input-bg pc-switch__fake-input-bg--sm"></span>
        </span>
      </span>
      <span class="text-xs leading-snug text-subtle">{@hint}</span>
    </label>
    """
  end

  # The embed fields as the board's table. The parameter stays one text,
  # "Name | Value" per line; the rows only edit it.
  attr :action, :any, required: true
  attr :fields, :list, required: true
  attr :raw, :any, default: nil

  defp embed_fields(assigns) do
    assigns =
      assign(assigns,
        rows:
          Jason.encode!(Enum.map(assigns.fields, fn {name, value} -> %{n: name, v: value} end))
      )

    ~H"""
    <div
      id={"#{@action.id}_fields"}
      class="flex flex-col gap-1.5"
      x-data={"{
        rows: #{@rows},
        sync() {
          const hidden = document.getElementById('#{pid(@action, :embed_fields)}');
          hidden.value = this.rows.filter(r => r.n.trim() || r.v.trim()).map(r => r.n + ' | ' + r.v).join('\\n');
          hidden.dispatchEvent(new Event('input', {bubbles: true}));
        }
      }"}
    >
      <textarea
        id={pid(@action, :embed_fields)}
        name={pname(@action, :embed_fields)}
        class="hidden"
        aria-hidden="true"
        tabindex="-1"
      >{@raw}</textarea>
      <div class="grid grid-cols-[9.375rem_minmax(0,1fr)_1.75rem] gap-2 text-xs text-muted">
        <span>{gettext("Field")}</span><span>{gettext("Value")}</span><span></span>
      </div>
      <template x-for="(row, i) in rows" x-bind:key="i">
        <div class="grid grid-cols-[9.375rem_minmax(0,1fr)_1.75rem] items-center gap-2">
          <input
            type="text"
            x-model="row.n"
            x-on:input.stop="sync()"
            x-on:change.stop=""
            x-bind:aria-label={"'#{gettext("Field name")} ' + (i + 1)"}
            class="bench-tile"
          />
          <input
            type="text"
            x-model="row.v"
            x-on:input.stop="sync()"
            x-on:change.stop=""
            data-template
            x-bind:aria-label={"'#{gettext("Field value")} ' + (i + 1)"}
            class="bench-tile font-mono text-[0.8125rem]"
          />
          <button
            type="button"
            x-on:click="rows.splice(i, 1); sync()"
            aria-label={gettext("Remove field")}
            class="flex size-7 cursor-pointer items-center justify-center rounded-lg text-muted hover:text-error"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
      </template>
      <button
        type="button"
        x-show="rows.length < 25"
        x-on:click="rows.push({n: '', v: ''})"
        class="bench-add h-8 self-start"
      >
        + {gettext("Field")} <span class="text-muted">{gettext("(up to 25)")}</span>
      </button>
    </div>
    """
  end

  # ── Previews ───────────────────────────────────────────────────────────────

  attr :action, :any, required: true
  attr :type, :atom, required: true
  attr :webhooks, :list, default: []
  attr :example, :any, default: nil
  attr :delivery, :any, default: nil

  defp action_preview(%{type: :send_discord_webhook} = assigns) do
    parameters = current_parameters(assigns.action)
    render = fn text -> preview_text(text || "", assigns.example) end
    payload = Message.build(parameters, render)

    assigns =
      assign(assigns,
        parameters: parameters,
        payload: payload,
        embed: List.first(payload["embeds"] || []),
        webhook: webhook_name(assigns.webhooks, parameters),
        thread: present?(parameters["thread_name"]) && render.(parameters["thread_name"]),
        mentions: Message.role_ids(parameters["mention_role_ids"])
      )

    ~H"""
    <div class="flex items-baseline gap-3">
      <h3 class="flex-1 font-display text-lg font-semibold">{gettext("Preview")}</h3>
      <span :if={@example && @example.event} class="text-xs text-muted">
        {gettext("with the latest real event")}
      </span>
    </div>
    <div
      id="bench-discord-preview"
      class="bench-embed flex flex-col overflow-hidden rounded-[1.125rem] border border-base-300"
    >
      <div class="flex items-center gap-2 border-b border-base-300 px-3.5 py-2.5 text-[0.8125rem] text-subtle">
        <span class="font-mono text-muted">#</span>{@webhook || gettext("no webhook")}
        <.icon :if={@thread} name="hero-chevron-right" class="size-3.5" />
        <span :if={@thread} class="truncate text-base-content">{@thread}</span>
      </div>
      <div class="grid grid-cols-[2.5rem_minmax(0,1fr)] gap-3 p-3.5">
        <span class="flex size-10 items-center justify-center rounded-xl bg-primary text-primary-content">
          <.icon name="hero-bolt" class="size-5" />
        </span>
        <div class="flex min-w-0 flex-col gap-2">
          <div class="flex flex-wrap items-baseline gap-2">
            <strong class="text-sm font-semibold">
              {@payload["username"] || "HLL Conditional Actions"}
            </strong>
            <span class="rounded bg-secondary px-1.5 text-[0.625rem] font-bold tracking-[0.04em] text-subtle">
              APP
            </span>
            <span :if={@parameters["mode"] == "edit"} class="text-xs text-muted">
              {gettext("edited message")}
            </span>
          </div>
          <span
            :for={role <- @mentions}
            class="self-start rounded-md bg-info/16 px-1.5 text-[0.8125rem] font-semibold text-info"
          >
            @{role}
          </span>
          <p :if={@payload["content"]} class="text-[0.8125rem] whitespace-pre-wrap break-words">
            {@payload["content"]}
          </p>
          <div :if={@embed} class="flex overflow-hidden rounded-[0.625rem] bg-secondary">
            <span class="w-1 shrink-0" style={"background: #{bar_color(@embed)}"}></span>
            <div class="flex min-w-0 flex-1 flex-col gap-2 px-3.5 py-3">
              <div class="grid grid-cols-[minmax(0,1fr)_auto] gap-2.5">
                <div class="flex min-w-0 flex-col gap-1.5">
                  <strong :if={@embed["title"]} class="text-sm font-semibold break-words">
                    {@embed["title"]}
                  </strong>
                  <span
                    :if={@embed["description"]}
                    class="text-[0.8125rem] leading-normal whitespace-pre-wrap break-words text-subtle"
                  >{@embed["description"]}</span>
                </div>
                <img
                  :if={@embed["thumbnail"]}
                  src={@embed["thumbnail"]["url"]}
                  alt=""
                  class="size-[3.25rem] rounded-lg object-cover"
                />
              </div>
              <div :if={@embed["fields"]} class="grid grid-cols-2 gap-x-3 gap-y-2">
                <span :for={field <- @embed["fields"]} class="flex min-w-0 flex-col gap-0.5">
                  <strong class="text-xs font-semibold break-words">{field["name"]}</strong>
                  <span class="text-[0.8125rem] whitespace-pre-wrap break-words text-subtle">{field[
                    "value"
                  ]}</span>
                </span>
              </div>
              <span
                :if={get_in(@embed, ["footer", "text"])}
                class="border-t border-base-300 pt-1 text-[0.6875rem] text-muted"
              >
                {get_in(@embed, ["footer", "text"])}
              </span>
            </div>
          </div>
          <p :if={Message.empty?(@payload)} class="text-[0.8125rem] text-muted italic">
            {gettext("Write a text or an embed to see it here.")}
          </p>
        </div>
      </div>
    </div>
    <div
      :if={@delivery}
      class="bench-embed flex flex-col gap-1.5 rounded-2xl border border-base-300 px-3.5 py-3"
    >
      <span class="text-xs text-muted">{gettext("Last delivery of this action")}</span>
      <span class="text-[0.8125rem]">
        <span class={[
          "font-mono text-xs",
          if(@delivery.status == "delivered", do: "text-primary", else: "text-error")
        ]}>
          {@delivery.status}
        </span>
        <span :if={@delivery.at}>
          · <.local_time id="bench-last-delivery" at={@delivery.at} format="datetime" />
        </span>
        <span :if={@delivery.detail} class="text-muted">· {@delivery.detail}</span>
      </span>
    </div>
    <span class="text-xs leading-normal text-muted">
      {gettext("An approximate drawing. Discord may show it a little differently on a phone.")}
    </span>
    """
  end

  defp action_preview(assigns) do
    parameters = current_parameters(assigns.action)

    texts =
      for {key, :text, opts} <- Catalog.action_params(assigns.type),
          opts[:template],
          value = parameters[to_string(key)],
          is_binary(value) and value != "",
          do: {key, value}

    assigns = assign(assigns, texts: texts)

    ~H"""
    <div class="flex items-baseline gap-3">
      <h3 class="flex-1 font-display text-lg font-semibold">{gettext("Preview")}</h3>
    </div>
    <p :if={@texts == []} class="text-[0.8125rem] leading-normal text-muted">
      {gettext("Nothing written yet: the texts of this action show here as the player reads them.")}
    </p>
    <div :for={{key, text} <- @texts} class="flex flex-col gap-1.5">
      <span class="text-xs text-subtle">{Labels.action_param(key)}</span>
      <.message_preview
        :if={@example}
        id={"#{@action.id}_parameters_#{key}_preview"}
        text={text}
        example={@example}
      />
    </div>
    """
  end

  defp bar_color(%{"color" => color}) when is_integer(color) do
    "#" <> (color |> Integer.to_string(16) |> String.pad_leading(6, "0"))
  end

  defp bar_color(_embed), do: "var(--color-base-300)"

  defp webhook_name(webhooks, parameters) do
    Enum.find_value(webhooks, fn {name, id} ->
      if to_string(id) == to_string(parameters["webhook_id"]), do: name
    end)
  end

  defp pname(action, key), do: "#{action.name}[parameters][#{key}]"
  defp pid(action, key), do: "#{action.id}_parameters_#{key}"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp truthy?(value), do: value in [true, "true", "on", "1"]
end
