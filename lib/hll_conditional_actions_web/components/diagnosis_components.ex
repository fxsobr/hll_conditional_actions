defmodule HllConditionalActionsWeb.DiagnosisComponents do
  @moduledoc """
  How a rule judged one event, drawn the same way wherever it is asked: the
  builder's "try it" panel, the rule page's "why didn't it fire?" and the
  event simulator. The data comes from `HllConditionalActions.Engine.Diagnosis`.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActionsWeb.EventEditor

  @doc """
  The verdict, the checks in the engine's order with the one that stopped
  the rule marked, every condition with the value read against the value
  expected, and the actions that would run with their messages rendered.
  """
  attr :diagnosis, :map, required: true
  attr :player, :string, default: nil
  attr :compact, :boolean, default: false, doc: "skip the verdict banner"

  def diagnosis(assigns) do
    ~H"""
    <div class="space-y-3" aria-live="polite">
      <.alert
        :if={!@compact}
        color={outcome_color(@diagnosis.outcome)}
        variant="soft"
        with_icon
        label={outcome_sentence(@diagnosis.outcome, @player)}
      />
      <ol class="space-y-1 text-xs">
        <li :for={{label, state} <- steps(@diagnosis)} class="flex items-center gap-2">
          <.icon name={step_icon(state)} class={["size-3.5 shrink-0", step_class(state)]} />
          <span class={[state == :stopped && "font-medium"]}>{label}</span>
        </li>
      </ol>
      <ul :if={@diagnosis.conditions != []} class="divide-y divide-base-300 text-xs">
        <li :for={condition <- @diagnosis.conditions} class="flex items-start gap-2 py-1.5">
          <.icon
            name={if condition.result, do: "hero-check", else: "hero-x-mark"}
            class={[
              "mt-0.5 size-3.5 shrink-0",
              if(condition.result, do: "text-success", else: "text-error")
            ]}
          />
          <div class="min-w-0 flex-1">
            <p class="leading-tight">{Labels.field(condition.field)}</p>
            <p class="text-muted">
              {gettext("expected")}:
              <span class="text-subtle">{Labels.operator(condition.operator)}</span>
              <span class="font-mono">{format_value(condition.expected)}</span>
              · {gettext("actual")}: <span class="font-mono">{format_value(condition.actual)}</span>
            </p>
          </div>
        </li>
      </ul>
      <div :if={@diagnosis.actions != []} class="space-y-1">
        <p class="text-xs font-medium text-subtle">
          {if @diagnosis.outcome == :fires,
            do: gettext("Would run"),
            else: gettext("Would have run, had it fired")}
        </p>
        <ul class="space-y-1">
          <li
            :for={action <- @diagnosis.actions}
            class="rounded-box bg-base-200 px-2 py-1.5 text-xs"
          >
            <p class="font-medium">{Labels.action(action.type)}</p>
            <p
              :if={is_binary(action.detail) and action.detail != ""}
              class="whitespace-pre-line text-subtle"
            >
              {action.detail}
            </p>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  @doc "A one line badge for an outcome."
  attr :outcome, :atom, required: true

  def outcome_badge(assigns) do
    ~H"""
    <.tone_badge tone={badge_tone(@outcome)}>{outcome_short(@outcome)}</.tone_badge>
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
    <details :if={@fields != []} class="rounded-box bg-base-200 p-2 text-xs">
      <summary class="cursor-pointer font-medium">{gettext("Edit the event's fields")}</summary>
      <form id={@id} phx-change={@on_change} phx-target={@target} class="mt-2 grid grid-cols-2 gap-2">
        <label :for={{name, key, value} <- @fields} class="space-y-0.5">
          <span class="block text-muted">{sample_field_label(key)}</span>
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

      {step_label(step, diagnosis), state}
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

  defp step_icon(:passed), do: "hero-check-circle-solid"
  defp step_icon(:stopped), do: "hero-x-circle-solid"
  defp step_icon(:skipped), do: "hero-minus-circle"
  defp step_icon(:not_reached), do: "hero-ellipsis-horizontal-circle"

  defp step_class(:passed), do: "text-success"
  defp step_class(:stopped), do: "text-error"
  defp step_class(_state), do: "text-muted"

  # ── Outcomes ───────────────────────────────────────────────────────────────

  defp outcome_color(:fires), do: "success"
  defp outcome_color(:conditions_not_met), do: "info"
  defp outcome_color(_outcome), do: "warning"

  defp badge_tone(:fires), do: "success"
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
