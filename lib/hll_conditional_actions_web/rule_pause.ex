defmodule HllConditionalActionsWeb.RulePause do
  @moduledoc """
  The temporary pause ("snooze") of a rule, shared by the rules list and the
  rule page: the menu entries, the "pause until…" sheet, the remaining-time
  note, and the one event handler both pages route to.

  Every entry point sends a `"pause"` event with a `preset`:

    * `"30m"`, `"2h"` - pause for that long from now
    * `"custom"` - pause until the `until` field (browser local time, with the
      browser's `tz_offset` in minutes as `Date#getTimezoneOffset` gives it)
    * `"resume"` - end the pause now
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Rule

  @presets %{"30m" => 30 * 60, "2h" => 2 * 60 * 60}

  @doc """
  Applies a pause event to a rule.
  """
  @spec run(Rule.t(), map(), map() | nil) :: {:ok, Rule.t(), String.t()} | {:error, String.t()}
  def run(%Rule{} = rule, %{"preset" => "resume"}, actor) do
    case Rules.resume_rule(rule, actor: actor) do
      {:ok, rule} -> {:ok, rule, gettext("Rule resumed.")}
      {:error, _changeset} -> {:error, gettext("Could not resume that rule.")}
    end
  end

  def run(%Rule{} = rule, params, actor) do
    with {:ok, until} <- until_from(params, DateTime.utc_now()),
         {:ok, rule} <- Rules.pause_rule(rule, until, actor: actor, reason: params["reason"]) do
      {:ok, rule, gettext("Rule paused.")}
    else
      {:error, :in_the_past} -> {:error, gettext("Pick a moment in the future.")}
      {:error, :invalid} -> {:error, gettext("Pick a valid date and time.")}
      {:error, _changeset} -> {:error, gettext("Could not pause that rule.")}
    end
  end

  @doc """
  When a pause request ends, in UTC.

      iex> now = ~U[2026-09-26 12:00:00Z]
      iex> HllConditionalActionsWeb.RulePause.until_from(%{"preset" => "30m"}, now)
      {:ok, ~U[2026-09-26 12:30:00Z]}
      iex> HllConditionalActionsWeb.RulePause.until_from(
      ...>   %{"preset" => "custom", "until" => "2026-09-26T18:00", "tz_offset" => "180"},
      ...>   now
      ...> )
      {:ok, ~U[2026-09-26 21:00:00Z]}
      iex> HllConditionalActionsWeb.RulePause.until_from(%{"preset" => "custom", "until" => "x"}, now)
      {:error, :invalid}
  """
  @spec until_from(map(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, :invalid}
  def until_from(%{"preset" => preset}, now) when is_map_key(@presets, preset) do
    {:ok, DateTime.add(now, Map.fetch!(@presets, preset), :second)}
  end

  def until_from(%{"preset" => "custom", "until" => until} = params, _now)
      when is_binary(until) do
    offset =
      case Integer.parse(params["tz_offset"] || "0") do
        {minutes, _rest} when abs(minutes) <= 24 * 60 -> minutes
        _other -> 0
      end

    # datetime-local sends "YYYY-MM-DDTHH:MM", without seconds.
    value = if String.length(until) == 16, do: until <> ":00", else: until

    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} ->
        {:ok, naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(offset * 60, :second)}

      {:error, _reason} ->
        {:error, :invalid}
    end
  end

  def until_from(_params, _now), do: {:error, :invalid}

  @doc """
  The pause entries of a rule's menu.
  """
  attr :rule, :map, required: true
  attr :on_custom, :any, required: true, doc: "what \"Pause until…\" does"

  def pause_menu_items(assigns) do
    ~H"""
    <.menu_item
      :if={rule_paused?(@rule)}
      icon="hero-play"
      phx-click="pause"
      phx-value-id={@rule.id}
      phx-value-preset="resume"
    >
      {gettext("Resume now")}
    </.menu_item>
    <.menu_item icon="hero-clock" phx-click="pause" phx-value-id={@rule.id} phx-value-preset="30m">
      {gettext("Pause 30 minutes")}
    </.menu_item>
    <.menu_item icon="hero-clock" phx-click="pause" phx-value-id={@rule.id} phx-value-preset="2h">
      {gettext("Pause 2 hours")}
    </.menu_item>
    <.menu_item icon="hero-calendar" phx-click={@on_custom} phx-value-id={@rule.id}>
      {gettext("Pause until...")}
    </.menu_item>
    """
  end

  @doc """
  "Paused, back in 25 minutes (reason)", for a paused rule; nothing otherwise.
  """
  attr :rule, :map, required: true
  attr :id, :string, required: true
  attr :class, :any, default: nil

  def pause_note(assigns) do
    ~H"""
    <p
      :if={rule_paused?(@rule)}
      class={["inline-flex flex-wrap items-center gap-1 text-label-small text-info", @class]}
    >
      <.icon name="hero-clock" class="size-3.5" />
      <span>{gettext("Paused, resumes")}</span>
      <.local_time id={@id} at={@rule.paused_until} />
      <span :if={@rule.pause_reason} class="text-muted">({@rule.pause_reason})</span>
    </p>
    """
  end

  @doc """
  The "pause until…" sheet.
  """
  attr :rule, :map, required: true
  attr :on_cancel, JS, required: true

  def pause_modal(assigns) do
    ~H"""
    <.modal
      id="pause-modal"
      title={gettext("Pause %{name}", name: @rule.name)}
      subtitle={
        gettext(
          "The rule stays on but is skipped until then, and comes back by itself. Times are in your local time zone."
        )
      }
      on_cancel={@on_cancel}
    >
      <form id="pause-form" phx-submit="pause" phx-hook=".PauseTimezone" class="space-y-3">
        <input type="hidden" name="rule_id" value={@rule.id} />
        <input type="hidden" name="preset" value="custom" />
        <input type="hidden" name="tz_offset" value="0" />

        <label class="block">
          <span class="mb-1 block text-sm font-medium">{gettext("Pause until")}</span>
          <input type="datetime-local" name="until" required class="pc-text-input w-full" />
        </label>

        <label class="block">
          <span class="mb-1 block text-sm font-medium">{gettext("Reason (optional)")}</span>
          <input
            type="text"
            name="reason"
            maxlength="200"
            placeholder={gettext("e.g. event night, testing a new map")}
            class="pc-text-input w-full"
          />
        </label>

        <div class="flex justify-end">
          <.button type="submit" size="sm" color="primary" icon="hero-clock" label={gettext("Pause")} />
        </div>
      </form>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".PauseTimezone">
        export default {
          mounted() {
            this.el.querySelector("input[name=tz_offset]").value = new Date().getTimezoneOffset()
          }
        }
      </script>
    </.modal>
    """
  end
end
