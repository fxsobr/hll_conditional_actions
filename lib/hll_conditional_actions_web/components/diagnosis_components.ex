defmodule HllConditionalActionsWeb.DiagnosisComponents do
  @moduledoc """
  How a rule judged one event, drawn the same way wherever it is asked: the
  builder's "try it" panel, the rule page's "why didn't it fire?" and the
  event simulator. The data comes from `HllConditionalActions.Engine.Diagnosis`.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActionsWeb.EventEditor

  @doc """
  The verdict, then the path the event took through the rule: every check in
  the engine's order as a node that passed, stopped it or was never reached,
  the conditions under their check with the value read against the value
  expected, and the actions that would run with their messages rendered.
  """
  attr :diagnosis, :map, required: true
  attr :player, :string, default: nil
  attr :compact, :boolean, default: false, doc: "skip the verdict banner"

  def diagnosis(assigns) do
    ~H"""
    <div class="flex flex-col gap-4" aria-live="polite">
      <p
        :if={!@compact}
        class={[
          "flex items-start gap-2.5 rounded-2xl px-4 py-3 text-sm font-semibold ring-1",
          verdict_tint(@diagnosis.outcome)
        ]}
      >
        <.icon
          name={if @diagnosis.outcome == :fires, do: "hero-check-circle", else: "hero-x-circle"}
          class="mt-px size-5 shrink-0"
        />
        <span>{outcome_sentence(@diagnosis.outcome, @player)}</span>
      </p>

      <ol class="flex flex-col">
        <li
          :for={{step, label, state} <- steps(@diagnosis)}
          class={[
            "group/step relative grid grid-cols-[1.75rem_minmax(0,1fr)] gap-x-3.5 pb-4 last:pb-0",
            state in [:not_reached, :skipped] && "opacity-75"
          ]}
        >
          <span
            class={[
              "absolute top-7 bottom-0 left-[13px] w-0.5 group-last/step:hidden",
              if(state == :passed,
                do: "bg-primary/35",
                else:
                  "bg-[repeating-linear-gradient(180deg,var(--color-base-300)_0_4px,transparent_4px_8px)]"
              )
            ]}
            aria-hidden="true"
          ></span>
          <span class={[
            "relative flex size-7 items-center justify-center rounded-full",
            node_tint(state)
          ]}>
            <.icon :if={state == :passed} name="hero-check" class="size-4" />
            <.icon :if={state == :stopped} name="hero-x-mark" class="size-4" />
            <.icon :if={state == :skipped} name="hero-minus" class="size-4" />
            <span class="sr-only">{state_label(state)}</span>
          </span>

          <div class="flex min-w-0 flex-col gap-2.5 pt-1">
            <span class={[
              "text-sm",
              if(state in [:passed, :stopped],
                do: "font-semibold",
                else: "font-medium text-subtle"
              )
            ]}>
              {label}
            </span>

            <div
              :if={step == :conditions_not_met and @diagnosis.conditions != []}
              class="flex flex-col gap-2 rounded-2xl bg-secondary p-3 sm:p-3.5"
            >
              <div
                :for={condition <- @diagnosis.conditions}
                class="grid gap-x-2.5 gap-y-1 text-[0.8125rem] sm:grid-cols-[minmax(0,1fr)_minmax(0,11rem)_auto] sm:items-center"
              >
                <span class="min-w-0">{Labels.field(condition.field)}</span>
                <span class="text-muted">
                  {gettext("expected")}
                  <span class="text-subtle">{Labels.operator(condition.operator)}</span>
                  <span class="font-mono text-xs text-base-content">
                    {format_value(condition.expected)}
                  </span>
                </span>
                <span class="justify-self-start">
                  <.trace_chip pass={condition.result}>
                    {gettext("read %{value}", value: format_value(condition.actual))}
                  </.trace_chip>
                </span>
              </div>
            </div>
          </div>
        </li>
      </ol>

      <div :if={@diagnosis.actions != []} class="flex flex-col gap-2">
        <p class="text-[0.6875rem] uppercase tracking-[0.08em] text-muted">
          {if @diagnosis.outcome == :fires,
            do: gettext("Would run"),
            else: gettext("Would have run, had it fired")}
        </p>
        <ul class="flex flex-col gap-2">
          <li
            :for={action <- @diagnosis.actions}
            class="flex flex-col gap-1 rounded-2xl bg-secondary px-3.5 py-2.5"
          >
            <p class="flex items-center gap-2 text-sm font-semibold">
              <.icon name={Icons.action(action.type)} class="size-4 shrink-0 text-muted" />
              {Labels.action(action.type)}
            </p>
            <p
              :if={is_binary(action.detail) and action.detail != ""}
              class="whitespace-pre-line font-mono text-xs leading-relaxed text-subtle"
            >
              {action.detail}
            </p>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  @doc """
  The path one real event took through a rule, as the "why didn't it fire?"
  tab draws it: every check in the engine's order, each with what it found,
  a red box where the rule stopped (or a green one when it fired), and the
  checks after the stop drawn as never reached.

  `limits` is `%{last: DateTime | nil, count: n}`: the player's runs of the
  rule in the 24 hours before the event.
  """
  attr :id, :string, required: true
  attr :diagnosis, :map, required: true
  attr :rule, :map, required: true
  attr :server, :map, required: true
  attr :sample, :map, required: true
  attr :execution, :map, default: nil
  attr :limits, :map, default: %{last: nil, count: 0}
  attr :version, :integer, default: nil
  attr :zone, :string, default: "Etc/UTC"

  def event_path(assigns) do
    assigns = assign(assigns, :steps, path_steps(assigns))

    ~H"""
    <ol id={@id} class="flex flex-col">
      <li
        :for={{step, index} <- Enum.with_index(@steps)}
        class={[
          "relative grid grid-cols-[1.75rem_minmax(0,1fr)] gap-x-3.5 pb-5 last:pb-0",
          step.state == :not_reached && "opacity-75"
        ]}
      >
        <span
          :if={index < length(@steps) - 1}
          class={[
            "absolute top-7 bottom-0 left-[13px] w-0.5",
            if(step.state == :passed,
              do: "bg-primary/35",
              else:
                "bg-[repeating-linear-gradient(180deg,var(--color-base-300)_0_4px,transparent_4px_8px)]"
            )
          ]}
          aria-hidden="true"
        ></span>
        <span class={[
          "relative flex size-7 items-center justify-center rounded-full",
          path_node(step.state)
        ]}>
          <.icon :if={step.state == :passed} name="hero-check" class="size-4" />
          <.icon :if={step.state == :stopped} name="hero-x-mark" class="size-4" />
          <span class="sr-only">{state_label(step.state)}</span>
        </span>

        <div class="flex min-w-0 flex-col gap-2.5 pt-0.5">
          <div class="grid gap-x-3.5 gap-y-0.5 sm:grid-cols-[15.625rem_minmax(0,1fr)]">
            <span class={[
              "text-[0.9375rem]",
              if(step.state == :not_reached, do: "font-medium text-subtle", else: "font-semibold")
            ]}>
              {step.question}
              <span :if={step[:aside]} class="font-normal text-muted">{step.aside}</span>
            </span>
            <span
              :if={step.detail}
              class={[
                "text-[0.8125rem] leading-normal",
                if(step.state == :not_reached, do: "text-muted", else: "text-subtle")
              ]}
            >
              {step.detail}
            </span>
          </div>

          <div
            :if={step.key == :conditions and step.state in [:passed, :stopped]}
            class="rounded-[1.125rem] bg-secondary px-4 py-3.5"
          >
            <HllConditionalActionsWeb.RuleComponents.condition_group
              conditions={Enum.reject(@diagnosis.conditions, &(&1.field == :always_true))}
              operator={@rule.logical_operator}
              columns
            />
          </div>

          <div
            :if={step.state == :stopped}
            id={"#{@id}-stop"}
            class="flex flex-col gap-2 rounded-[1.125rem] bg-error/10 px-4 py-3.5 ring-1 ring-error/40"
          >
            <strong class="text-[0.9375rem] font-semibold text-error">{stop_title(@diagnosis, @sample)}</strong>
            <span class="text-[0.8125rem] leading-normal">{stop_text(@diagnosis, @rule)}</span>
            <div class="flex flex-wrap gap-x-4 gap-y-1 text-[0.8125rem] font-medium">
              <.link navigate={~p"/rules/#{@rule}/edit"} class="text-primary hover:underline">
                {gettext("Adjust it in the builder")}
              </.link>
            </div>
          </div>
        </div>
      </li>

      <li :if={@diagnosis.outcome == :fires} class="pl-[2.625rem]">
        <div
          id={"#{@id}-fired"}
          class="flex flex-wrap items-center gap-2 rounded-[1.125rem] bg-primary/12 px-4 py-3 text-sm text-primary ring-1 ring-primary/35"
        >
          <.icon name="hero-bolt" class="size-5" />
          <span class="font-semibold">
            {if @execution,
              do: gettext("The rule fired for this event."),
              else:
                gettext("Today the rule would fire for this event, but no run was recorded for it.")}
          </span>
          <.link
            :if={@execution}
            patch={
              ~p"/rules/#{@rule}?#{[tab: "executions", player: @execution.player_id || @execution.player_name]}"
            }
            class="underline underline-offset-2"
          >
            {gettext("Open the execution")}
          </.link>
        </div>
      </li>
    </ol>
    """
  end

  defp path_node(:passed), do: "bg-primary text-primary-content"
  defp path_node(:stopped), do: "bg-error text-error-content"
  defp path_node(_not_reached), do: "border-[1.5px] border-dashed border-muted"

  # The checks in the engine's order, each `%{key, question, detail, state}`.
  defp path_steps(assigns) do
    %{diagnosis: diagnosis, rule: rule, server: server, sample: sample} = assigns
    stop = path_stop(diagnosis.outcome)

    checks = [
      {:arrived, gettext("Did the event arrive?"), arrived_text(server, sample, assigns.zone)},
      {:trigger, gettext("Is it the right trigger?"), trigger_text(sample, rule)},
      {:scope, gettext("Is the server in scope?"), scope_text(server, rule)},
      {:active, gettext("Was the rule on?"), active_text(rule, assigns.version)},
      {:exempt, gettext("Is the player exempt?"), exempt_text(diagnosis, rule, sample)},
      {:cooldown, gettext("Was it waiting?"),
       cooldown_text(diagnosis, rule, assigns.limits, assigns.zone)},
      {:cap, gettext("Past the 24 h limit?"), cap_text(diagnosis, rule, assigns.limits)},
      {:conditions, gettext("Did the conditions match?"), nil}
    ]

    stop_index = Enum.find_index(checks, fn {key, _q, _d} -> key == stop end)

    checks
    |> Enum.with_index()
    |> Enum.map(fn {{key, question, detail}, index} ->
      state =
        cond do
          stop_index == nil or index < stop_index -> :passed
          index == stop_index -> :stopped
          true -> :not_reached
        end

      step = %{key: key, question: question, detail: detail, state: state}

      cond do
        key == :conditions ->
          Map.put(step, :aside, group_need(rule.logical_operator))

        state == :not_reached ->
          %{step | detail: not_checked(key, rule)}

        true ->
          step
      end
    end)
  end

  defp path_stop(outcome) when outcome in [:disabled, :paused], do: :active
  defp path_stop(:wrong_trigger), do: :trigger
  defp path_stop(:exempt), do: :exempt
  defp path_stop(:cooldown), do: :cooldown
  defp path_stop(:max_executions), do: :cap
  defp path_stop(:conditions_not_met), do: :conditions
  defp path_stop(_fires), do: nil

  defp arrived_text(server, sample, zone) do
    gettext("Yes, from %{server} at %{time}",
      server: server.name,
      time: HllConditionalActionsWeb.RuleComponents.clock(sample.at, zone)
    )
  end

  defp trigger_text(sample, rule) do
    raw =
      case sample do
        %{event: %{action: action}} when is_binary(action) and action != "" -> action
        _other -> to_string(sample.trigger)
      end

    gettext("%{raw} corresponds to “%{trigger}”",
      raw: raw,
      trigger: String.downcase(Labels.trigger(rule.trigger_event))
    )
  end

  defp scope_text(server, rule) do
    gettext("%{server} is part of “%{scope}”",
      server: server.name,
      scope: HllConditionalActionsWeb.RuleComponents.scope_text(rule)
    )
  end

  defp active_text(rule, version) do
    version_text = if version, do: gettext("version %{number}", number: version), else: nil

    cond do
      not rule.enabled ->
        gettext("No: the rule is switched off")

      rule_paused?(rule) ->
        gettext("No: the rule is paused for now")

      rule.simulation ->
        Enum.join(
          Enum.reject(
            [
              gettext("Simulating"),
              version_text,
              gettext("counts as on, its actions are only recorded")
            ],
            &is_nil/1
          ),
          ", "
        )

      true ->
        Enum.join(Enum.reject([gettext("Live"), version_text], &is_nil/1), ", ")
    end
  end

  defp exempt_text(%{outcome: :exempt}, rule, sample) do
    context_vip? = get_in(sample, [Access.key(:player), "is_vip"]) in [true, "true"]

    if rule.exemptions && rule.exemptions.exempt_vip && context_vip?,
      do: gettext("Yes: the player is VIP and the rule leaves VIPs out"),
      else: gettext("Yes: the rule leaves this player out")
  end

  defp exempt_text(_diagnosis, %{exemptions: exemptions}, _sample) do
    if exemptions && HllConditionalActions.Rules.Exemptions.active?(exemptions) do
      gettext("No: %{who} are left out, and this player is not one of them",
        who: HllConditionalActionsWeb.RuleBuilder.exemptions_text(exemptions)
      )
    else
      gettext("No: the rule leaves nobody out")
    end
  end

  defp cooldown_text(_diagnosis, %{cooldown_seconds: 0}, _limits, _zone),
    do: gettext("No: the rule has no cooldown")

  defp cooldown_text(%{limits: :cooldown}, rule, %{last: last}, zone) when not is_nil(last) do
    gettext("Yes: it ran for this player at %{time}, cooldown of %{seconds} s",
      time: HllConditionalActionsWeb.RuleComponents.clock(last, zone),
      seconds: rule.cooldown_seconds
    )
  end

  defp cooldown_text(%{limits: :not_checked}, _rule, _limits, _zone), do: gettext("Not checked")

  defp cooldown_text(_diagnosis, rule, _limits, _zone),
    do: gettext("No · cooldown of %{seconds} s", seconds: rule.cooldown_seconds)

  defp cap_text(_diagnosis, %{max_executions_per_player: 0}, _limits),
    do: gettext("No: the rule has no daily limit")

  defp cap_text(%{limits: :not_checked}, _rule, _limits), do: gettext("Not checked")

  defp cap_text(%{limits: :max_executions}, rule, %{count: count}) do
    gettext("Yes: %{count} of %{max} in 24 h", count: count, max: rule.max_executions_per_player)
  end

  defp cap_text(_diagnosis, rule, %{count: count}) do
    gettext("No · %{count} of %{max} in 24 h", count: count, max: rule.max_executions_per_player)
  end

  defp not_checked(:cooldown, %{cooldown_seconds: seconds}) when seconds > 0,
    do: gettext("Never checked · cooldown of %{seconds} s", seconds: seconds)

  defp not_checked(:cap, %{max_executions_per_player: max}) when max > 0,
    do: gettext("Never checked · limit of %{max} per player", max: max)

  defp not_checked(_key, _rule), do: gettext("Never checked")

  defp group_need(operator) do
    case operator do
      :or -> gettext("any condition is enough")
      :nand -> gettext("not all conditions may hold")
      :nor -> gettext("no condition may hold")
      _and -> gettext("every condition must hold")
    end
  end

  defp stop_title(%{outcome: :conditions_not_met}, _sample),
    do: gettext("Stopped here: the conditions did not match")

  defp stop_title(%{outcome: :exempt}, sample),
    do:
      gettext("Stopped here: %{player} is exempt",
        player: sample.player_name || gettext("the player")
      )

  defp stop_title(%{outcome: :cooldown}, _sample), do: gettext("Stopped here: still in cooldown")

  defp stop_title(%{outcome: :max_executions}, _sample),
    do: gettext("Stopped here: the 24 h limit was reached")

  defp stop_title(%{outcome: :disabled}, _sample), do: gettext("Stopped here: the rule is off")
  defp stop_title(%{outcome: :paused}, _sample), do: gettext("Stopped here: the rule is paused")
  defp stop_title(_diagnosis, _sample), do: gettext("Stopped here")

  defp stop_text(%{outcome: :conditions_not_met} = diagnosis, _rule) do
    failed =
      diagnosis.conditions
      |> Enum.reject(&(&1.result or &1.field == :always_true))
      |> Enum.map(fn condition ->
        gettext("%{field} needed %{operator} %{expected} and read %{actual}",
          field: Labels.field(condition.field),
          operator: Labels.operator(condition.operator),
          expected: format_value(condition.expected),
          actual: format_value(condition.actual)
        )
      end)

    Enum.join(failed ++ [gettext("No action ran, not even in simulation.")], ". ")
  end

  defp stop_text(%{outcome: outcome}, rule) when outcome in [:cooldown, :max_executions] do
    gettext(
      "The rule already acted on this player recently: it holds back so %{name} does not repeat itself. No action ran.",
      name: rule.name
    )
  end

  defp stop_text(_diagnosis, _rule), do: gettext("No action ran, not even in simulation.")

  @doc "A one line pill for an outcome."
  attr :outcome, :atom, required: true

  def outcome_badge(assigns) do
    ~H"""
    <.pill tone={badge_tone(@outcome)} class="h-6 px-2.5 text-[0.6875rem]">
      {outcome_short(@outcome)}
    </.pill>
    """
  end

  @doc """
  The small form that edits a sample's fields; posts `player[...]` and
  `event[...]`.
  """
  attr :id, :string, required: true
  attr :sample, :map, required: true
  attr :target, :any, default: nil
  attr :on_change, :string, default: "edit_event"

  def event_fields(assigns) do
    assigns = assign(assigns, :fields, EventEditor.fields(assigns.sample))

    ~H"""
    <details :if={@fields != []} class="group/fields rounded-2xl bg-secondary px-3.5 py-2.5 text-xs">
      <summary class="flex cursor-pointer list-none items-center gap-2 text-[0.8125rem] font-medium [&::-webkit-details-marker]:hidden">
        <.icon
          name="hero-chevron-right"
          class="size-4 text-muted transition-transform group-open/fields:rotate-90"
        />
        {gettext("Edit the event's fields")}
      </summary>
      <form
        id={@id}
        phx-change={@on_change}
        phx-target={@target}
        class="mt-3 grid grid-cols-2 gap-2.5"
      >
        <label :for={{name, key, value} <- @fields} class="flex flex-col gap-1">
          <span class="text-muted">{sample_field_label(key)}</span>
          <select :if={is_boolean(value)} name={name} class="pc-text-input w-full">
            <option value="true" selected={value}>{gettext("Yes")}</option>
            <option value="false" selected={!value}>{gettext("No")}</option>
          </select>
          <input
            :if={!is_boolean(value)}
            type={if is_integer(value), do: "number", else: "text"}
            name={name}
            value={value}
            phx-debounce="300"
            class="pc-text-input w-full"
          />
        </label>
      </form>
    </details>
    """
  end

  @doc "A short label for a saved event, for pickers."
  @spec sample_label(map(), String.t() | nil) :: String.t()
  def sample_label(sample, server_name \\ nil) do
    detail =
      case sample.event do
        %{weapon: weapon, target_player_name: target} when is_binary(target) ->
          " → #{target}" <> if(weapon, do: " (#{weapon})", else: "")

        %{chat_message: text} when is_binary(text) ->
          " “#{String.slice(text, 0, 40)}”"

        _other ->
          ""
      end

    [
      Calendar.strftime(sample.at, "%m-%d %H:%M"),
      sample.player_name || gettext("Unknown player"),
      server_name
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> Kernel.<>(detail)
  end

  # ── Steps ──────────────────────────────────────────────────────────────────

  @order [:disabled, :paused, :wrong_trigger, :exempt, :limits, :conditions_not_met]

  defp steps(diagnosis) do
    stop = stop_step(diagnosis.outcome)
    stop_index = Enum.find_index(@order, &(&1 == stop)) || length(@order)

    @order
    |> Enum.with_index()
    |> Enum.map(fn {step, index} ->
      state =
        cond do
          step == :limits and diagnosis.limits == :not_checked and index < stop_index ->
            :skipped

          index < stop_index ->
            :passed

          index == stop_index ->
            :stopped

          true ->
            :not_reached
        end

      {step, step_label(step, diagnosis), state}
    end)
  end

  defp stop_step(outcome) when outcome in [:cooldown, :max_executions], do: :limits
  defp stop_step(:fires), do: nil
  defp stop_step(outcome), do: outcome

  defp step_label(:disabled, _d), do: gettext("The rule is enabled")
  defp step_label(:paused, _d), do: gettext("The rule is not paused")
  defp step_label(:wrong_trigger, _d), do: gettext("It listens for this event")
  defp step_label(:exempt, _d), do: gettext("The player is not exempt")

  defp step_label(:limits, %{limits: :cooldown}), do: gettext("Limits: still in cooldown")

  defp step_label(:limits, %{limits: :max_executions}),
    do: gettext("Limits: per-player cap reached")

  defp step_label(:limits, %{limits: :not_checked}),
    do: gettext("Limits: not checked for an unsaved rule")

  defp step_label(:limits, _d), do: gettext("Limits allow it (cooldown and cap)")
  defp step_label(:conditions_not_met, _d), do: gettext("The conditions hold")

  defp node_tint(:passed), do: "bg-primary text-primary-content"
  defp node_tint(:stopped), do: "bg-error text-error-content"
  defp node_tint(:skipped), do: "bg-secondary text-muted"
  defp node_tint(:not_reached), do: "border-[1.5px] border-dashed border-base-300"

  defp state_label(:passed), do: gettext("passed")
  defp state_label(:stopped), do: gettext("stopped here")
  defp state_label(:skipped), do: gettext("not checked")
  defp state_label(:not_reached), do: gettext("not reached")

  # ── Outcomes ───────────────────────────────────────────────────────────────

  defp verdict_tint(:fires), do: "bg-primary/12 text-primary ring-primary/35"
  defp verdict_tint(:conditions_not_met), do: "bg-error/10 text-error ring-error/35"
  defp verdict_tint(_outcome), do: "bg-warning/10 text-warning ring-warning/35"

  defp badge_tone(:fires), do: "live"
  defp badge_tone(:conditions_not_met), do: "neutral"
  defp badge_tone(_outcome), do: "warning"

  @doc "The outcome of a diagnosis as a sentence."
  @spec outcome_sentence(atom(), String.t() | nil) :: String.t()
  def outcome_sentence(outcome, nil), do: outcome_sentence(outcome, gettext("this player"))

  def outcome_sentence(:fires, player),
    do: gettext("This rule would fire for %{player}.", player: player)

  def outcome_sentence(:conditions_not_met, player),
    do:
      gettext("This rule would not fire for %{player}: a condition does not hold.",
        player: player
      )

  def outcome_sentence(:disabled, _player), do: gettext("This rule is disabled.")
  def outcome_sentence(:paused, _player), do: gettext("This rule is paused.")

  def outcome_sentence(:wrong_trigger, _player),
    do: gettext("This rule does not listen for this kind of event.")

  def outcome_sentence(:exempt, player),
    do: gettext("%{player} is exempt from this rule.", player: player)

  def outcome_sentence(:cooldown, player),
    do: gettext("Stopped by the cooldown for %{player}.", player: player)

  def outcome_sentence(:max_executions, player),
    do: gettext("Stopped by the per-player cap for %{player}.", player: player)

  @doc "The outcome of a diagnosis in two or three words."
  @spec outcome_short(atom()) :: String.t()
  def outcome_short(:fires), do: gettext("Fires")
  def outcome_short(:conditions_not_met), do: gettext("Condition failed")
  def outcome_short(:disabled), do: gettext("Disabled")
  def outcome_short(:paused), do: gettext("Paused")
  def outcome_short(:wrong_trigger), do: gettext("Other trigger")
  def outcome_short(:exempt), do: gettext("Exempt")
  def outcome_short(:cooldown), do: gettext("Cooldown")
  def outcome_short(:max_executions), do: gettext("Cap reached")

  # ── Values ─────────────────────────────────────────────────────────────────

  @doc false
  def format_value(nil), do: "-"
  def format_value(""), do: "-"
  def format_value(value) when is_list(value), do: Enum.join(value, ", ")
  def format_value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  def format_value(value) when is_map(value), do: inspect(value)
  def format_value(value), do: to_string(value)

  defp sample_field_label("name"), do: gettext("Player name")
  defp sample_field_label("level"), do: gettext("Level")
  defp sample_field_label("team"), do: gettext("Team")
  defp sample_field_label("role"), do: gettext("Role")
  defp sample_field_label("unit_name"), do: gettext("Squad")
  defp sample_field_label("clan_tag"), do: gettext("Clan tag")
  defp sample_field_label("is_vip"), do: gettext("VIP")
  defp sample_field_label("kills"), do: gettext("Kills")
  defp sample_field_label("deaths"), do: gettext("Deaths")
  defp sample_field_label("team_kills"), do: gettext("Team kills")
  defp sample_field_label("combat"), do: gettext("Combat")
  defp sample_field_label("offense"), do: gettext("Offense")
  defp sample_field_label("defense"), do: gettext("Defense")
  defp sample_field_label("support"), do: gettext("Support")
  defp sample_field_label("map_playtime_seconds"), do: gettext("Playtime (seconds)")
  defp sample_field_label("target_player_name"), do: gettext("Victim")
  defp sample_field_label("weapon"), do: gettext("Weapon")
  defp sample_field_label("chat_message"), do: gettext("Chat text")
  defp sample_field_label("message"), do: gettext("Message")
  defp sample_field_label(key), do: key
end
