defmodule HllConditionalActionsWeb.RuleComponents do
  @moduledoc """
  The pieces the Regras area repeats across its pages: the rules list, the
  rule 360 page, the history and the event simulator.

  Everything here paints with the semantic tokens of the overhaul (see
  `docs/design/overhaul.md`), so it follows light and dark. Components that
  every area shares live in `HllConditionalActionsWeb.Ui`; these are the ones
  only the rules pages need - a rule's state as the boards draw it, a rule
  read as a sentence, its escalation ladder, a week of activity as bars, an
  execution's result and its trace.
  """

  use HllConditionalActionsWeb, :html

  import HllConditionalActionsWeb.RuleBuilder, only: [condition_sentence: 2, exemptions_text: 1]

  alias HllConditionalActions.Crcon.Events.Event

  # ── Page frame ─────────────────────────────────────────────────────────────

  @doc """
  A pill button of the page headers: 48px, the panel colour, a hairline.
  `compact` keeps only the icon below the widest screens, where the header
  is shared with the search and the server switcher.
  """
  attr :primary, :boolean, default: false
  attr :compact, :boolean, default: false
  attr :icon, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(navigate patch href download type disabled form name value)
  slot :inner_block, required: true

  def header_button(assigns) do
    ~H"""
    <.link
      :if={@rest[:navigate] || @rest[:patch] || @rest[:href]}
      class={[
        header_button_class(@primary),
        @compact && "max-2xl:w-12 max-2xl:justify-center max-2xl:px-0",
        @class
      ]}
      {@rest}
    >
      <.icon :if={@icon} name={@icon} class="size-[1.125rem] shrink-0" />
      <span class={@compact && "max-2xl:sr-only"}>{render_slot(@inner_block)}</span>
    </.link>
    <button
      :if={!(@rest[:navigate] || @rest[:patch] || @rest[:href])}
      class={[
        header_button_class(@primary),
        @compact && "max-2xl:w-12 max-2xl:justify-center max-2xl:px-0",
        @class
      ]}
      {@rest}
    >
      <.icon :if={@icon} name={@icon} class="size-[1.125rem] shrink-0" />
      <span class={@compact && "max-2xl:sr-only"}>{render_slot(@inner_block)}</span>
    </button>
    """
  end

  defp header_button_class(true),
    do:
      "flex h-12 shrink-0 cursor-pointer items-center gap-2 whitespace-nowrap rounded-full bg-primary pr-[1.375rem] pl-[1.125rem] text-sm font-semibold text-primary-content transition-opacity hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50"

  defp header_button_class(false),
    do:
      "flex h-12 shrink-0 cursor-pointer items-center gap-2 whitespace-nowrap rounded-full border border-base-300 bg-base-100 px-5 text-sm font-medium transition-colors hover:bg-secondary disabled:cursor-not-allowed disabled:opacity-50"

  @doc """
  The pill tabs of the rule page (38px, the panel behind them), as links.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true

  slot :tab, required: true do
    attr :patch, :string
    attr :navigate, :string
    attr :active, :boolean
    attr :count, :any
    attr :id, :string
  end

  def pill_tabs(assigns) do
    ~H"""
    <nav id={@id} aria-label={@label} class="-mx-1 flex max-w-full overflow-x-auto px-1">
      <div class="flex shrink-0 gap-1 rounded-full bg-base-100 p-1">
        <.link
          :for={tab <- @tab}
          id={tab[:id]}
          patch={tab[:patch]}
          navigate={tab[:navigate]}
          aria-current={tab[:active] && "page"}
          class={[
            "flex h-[2.375rem] shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full px-[1.125rem] text-[0.8125rem] transition-colors",
            if(tab[:active],
              do: "bg-base-content font-semibold text-base-100",
              else: "font-medium text-subtle hover:text-base-content"
            )
          ]}
        >
          {render_slot(tab)}
          <span
            :if={tab[:count] not in [nil, 0]}
            class={["font-mono", if(tab[:active], do: "opacity-70", else: "text-muted")]}
          >
            {tab[:count]}
          </span>
        </.link>
      </div>
    </nav>
    """
  end

  @doc """
  A choice of a few options as pill radios inside a form (the time windows,
  the edit modes). Posts `name`.
  """
  attr :name, :string, required: true
  attr :value, :any, required: true
  attr :options, :list, required: true, doc: "`{value, label}`"
  attr :label, :string, required: true
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  def pill_radios(assigns) do
    ~H"""
    <fieldset
      id={@id}
      class={["flex w-fit gap-1 rounded-full border border-base-300 bg-secondary p-1", @class]}
    >
      <legend class="sr-only">{@label}</legend>
      <label :for={{value, label} <- @options} class="cursor-pointer">
        <input
          type="radio"
          name={@name}
          value={value}
          checked={to_string(@value) == to_string(value)}
          class="peer sr-only"
        />
        <span class={[
          "flex h-[2.125rem] items-center whitespace-nowrap rounded-full px-3.5 text-[0.8125rem] transition-colors",
          "peer-focus-visible:ring-2 peer-focus-visible:ring-primary/50",
          if(to_string(@value) == to_string(value),
            do: "bg-base-content font-semibold text-base-100",
            else: "text-subtle hover:text-base-content"
          )
        ]}>
          {label}
        </span>
      </label>
    </fieldset>
    """
  end

  # ── Panels ─────────────────────────────────────────────────────────────────

  @doc """
  A panel of the rules pages: the 28px surface with a display-face title and
  whatever sits on the right of it.
  """
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :class, :any, default: nil
  attr :tone, :string, default: "neutral", values: ~w(neutral engine)
  attr :rest, :global
  slot :action
  slot :inner_block, required: true

  def rule_panel(assigns) do
    ~H"""
    <section
      class={[
        "flex min-w-0 flex-col gap-4 rounded-[1.75rem] p-5 sm:px-7 sm:py-6",
        if(@tone == "engine",
          do: "bg-accent/8 ring-1 ring-accent/25",
          else: "bg-base-100"
        ),
        @class
      ]}
      {@rest}
    >
      <div :if={@title || @action != []} class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <div class="min-w-0 flex-1">
          <h2 :if={@title} class="font-display text-xl font-semibold">{@title}</h2>
          <p :if={@subtitle} class="mt-0.5 text-[0.8125rem] text-muted">{@subtitle}</p>
        </div>
        <div :if={@action != []} class="flex shrink-0 items-center gap-2 text-[0.8125rem]">
          {render_slot(@action)}
        </div>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc "The small uppercase caption over a block inside a panel."
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def caption(assigns) do
    ~H"""
    <p class={["text-[0.6875rem] uppercase tracking-[0.08em] text-muted", @class]}>
      {render_slot(@inner_block)}
    </p>
    """
  end

  # ── A rule's state ─────────────────────────────────────────────────────────

  @doc """
  What a rule is doing, the way the boards name it:

    * `:live` - on and acting on the game
    * `:simulating` - on, recording what it would do
    * `:paused` - switched off after having run, or snoozed for a while
    * `:draft` - switched off and never run yet (new or imported rules)
  """
  @spec state(map(), boolean()) :: :live | :simulating | :paused | :draft
  def state(rule, ran?) do
    cond do
      rule_paused?(rule) -> :paused
      not rule.enabled and not ran? -> :draft
      not rule.enabled -> :paused
      rule.simulation -> :simulating
      true -> :live
    end
  end

  @doc "A rule's state as a pill: 28px, tinted, with its mark."
  attr :state, :atom, required: true
  attr :size, :string, default: "md", values: ~w(md sm)
  attr :class, :any, default: nil

  def state_pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full font-semibold",
      if(@size == "sm", do: "h-[1.625rem] px-2.5 text-xs", else: "h-7 px-[0.6875rem] text-xs"),
      state_tint(@state),
      @class
    ]}>
      <.state_mark state={@state} />
      {state_label(@state)}
    </span>
    """
  end

  @doc "The mark of a state: a dot, a dashed ring, or the pause bars."
  attr :state, :atom, required: true

  def state_mark(assigns) do
    ~H"""
    <span
      :if={@state == :live}
      class="size-[7px] shrink-0 rounded-full bg-current"
      aria-hidden="true"
    ></span>
    <span
      :if={@state == :simulating}
      class="size-[7px] shrink-0 rounded-full border-[1.5px] border-dashed border-current"
      aria-hidden="true"
    ></span>
    <.icon :if={@state == :paused} name="hero-pause-solid" class="size-3 shrink-0" />
    """
  end

  defp state_tint(:live), do: "bg-primary/12 text-primary"
  defp state_tint(:simulating), do: "bg-accent/13 text-accent"
  defp state_tint(:paused), do: "bg-warning/13 text-warning"
  defp state_tint(_draft), do: "bg-secondary text-subtle"

  @doc "The name of a state."
  @spec state_label(atom()) :: String.t()
  def state_label(:live), do: gettext("Live")
  def state_label(:simulating), do: gettext("Simulating")
  def state_label(:paused), do: gettext("Paused")
  def state_label(:draft), do: gettext("Draft")

  @doc "The text colour of a state, for inline mentions."
  @spec state_text(atom()) :: String.t()
  def state_text(:live), do: "text-primary"
  def state_text(:simulating), do: "text-accent"
  def state_text(:paused), do: "text-warning"
  def state_text(_draft), do: "text-subtle"

  @doc """
  A rule's on/off switch as the boards draw it: the signal while live, the
  engine lavender while simulating, dashed while a draft.
  """
  attr :id, :string, required: true
  attr :rule, :map, required: true
  attr :state, :atom, required: true
  attr :disabled, :boolean, default: false
  attr :size, :string, default: "md", values: ~w(md lg)
  attr :rest, :global, include: ~w(phx-click phx-value-id)

  def rule_switch(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      role="switch"
      aria-checked={to_string(@rule.enabled)}
      aria-label={
        if(@rule.enabled,
          do: gettext("Turn off %{name}", name: @rule.name),
          else: gettext("Turn on %{name}", name: @rule.name)
        )
      }
      disabled={@disabled}
      class={[
        "group/switch flex shrink-0 cursor-pointer items-center justify-center disabled:cursor-default",
        @size == "lg" && "h-11 w-12"
      ]}
      {@rest}
    >
      <span class={[
        "flex h-6 w-10 items-center rounded-full p-[3px] transition-colors",
        @rule.enabled && "justify-end",
        switch_track(@state, @rule.enabled)
      ]}>
        <span class={["size-[1.125rem] rounded-full", switch_knob(@state, @rule.enabled)]}></span>
      </span>
    </button>
    """
  end

  defp switch_track(:draft, _enabled), do: "border border-dashed border-base-300"
  defp switch_track(_state, false), do: "bg-base-300"
  defp switch_track(:simulating, true), do: "bg-accent"
  defp switch_track(:paused, true), do: "bg-warning"
  defp switch_track(_live, true), do: "bg-primary"

  defp switch_knob(:draft, _enabled), do: "bg-secondary"
  defp switch_knob(_state, false), do: "bg-muted"
  defp switch_knob(_state, true), do: "bg-primary-content"

  @doc """
  The "…" menu of a row: a borderless round trigger and the same Alpine
  behaviour as `Ui.row_menu/1` (Escape, outside click, arrow keys).
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, default: "hero-ellipsis-horizontal"
  attr :class, :any, default: "size-[1.875rem]"
  slot :inner_block, required: true

  def rule_menu(assigns) do
    ~H"""
    <div
      class="relative"
      x-data="{ open: false }"
      x-on:keydown.escape.stop="open = false; $refs.trigger.focus()"
    >
      <button
        type="button"
        class={[
          "flex cursor-pointer items-center justify-center rounded-full text-muted transition-colors hover:bg-secondary hover:text-base-content",
          @class
        ]}
        aria-label={@label}
        aria-haspopup="menu"
        x-ref="trigger"
        x-on:click.stop="open = !open"
        x-bind:aria-expanded="open"
      >
        <.icon name={@icon} class="size-[1.125rem]" />
      </button>
      <ul
        id={@id}
        role="menu"
        class="absolute right-0 z-40 mt-1 w-56 rounded-2xl border border-base-300 bg-base-100 p-1 shadow-xl"
        x-show="open"
        x-cloak
        x-on:click.outside="open = false"
        x-on:click="open = false"
        x-effect="if (open) $nextTick(() => $el.querySelector('button, a')?.focus())"
        x-on:keydown.arrow-down.prevent="(() => { const items = [...$el.querySelectorAll('button, a')]; const i = items.indexOf(document.activeElement); items[Math.min(i + 1, items.length - 1)]?.focus() })()"
        x-on:keydown.arrow-up.prevent="(() => { const items = [...$el.querySelectorAll('button, a')]; const i = items.indexOf(document.activeElement); items[Math.max(i - 1, 0)]?.focus() })()"
        x-transition.opacity.duration.150ms
      >
        {render_slot(@inner_block)}
      </ul>
    </div>
    """
  end

  # ── Activity ───────────────────────────────────────────────────────────────

  @doc """
  A week of runs as seven small bars, coloured by what the rule is: the
  signal while live, the engine lavender while simulating. Days without a
  run show as a flat stub so the week keeps its shape; `alert_last` paints
  today's bar amber (it failed today).
  """
  attr :values, :list, required: true
  attr :tone, :string, default: "live", values: ~w(live simulating neutral)
  attr :label, :string, required: true
  attr :alert_last, :boolean, default: false
  attr :class, :any, default: nil

  def week_bars(assigns) do
    assigns =
      assigns
      |> assign(:max, Enum.max([1 | assigns.values]))
      |> assign(:last, length(assigns.values) - 1)

    ~H"""
    <span
      class={["flex h-[1.125rem] shrink-0 items-end gap-0.5", @class]}
      role="img"
      aria-label={@label}
    >
      <span
        :for={{value, index} <- Enum.with_index(@values)}
        class={[
          "w-[5px] rounded-[1px]",
          cond do
            value == 0 -> "bg-base-300"
            @alert_last and index == @last -> "bg-warning"
            @tone == "simulating" -> "bg-accent"
            @tone == "live" -> "bg-primary"
            true -> "bg-subtle"
          end
        ]}
        style={"height: #{if value == 0, do: 2, else: max(round(value / @max * 18), 3)}px"}
      ></span>
    </span>
    """
  end

  @doc "The bars' tone for a rule: what it is doing, not how it is doing."
  @spec activity_tone(map()) :: String.t()
  def activity_tone(rule) do
    cond do
      not rule.enabled -> "neutral"
      rule.simulation -> "simulating"
      true -> "live"
    end
  end

  # ── Results ────────────────────────────────────────────────────────────────

  @doc """
  What came of one evaluation, as a pill: the signal when it landed, the
  engine lavender when it was only simulated, amber when it waited or part
  of it failed, red when it failed, neutral when the rule let it pass.
  """
  attr :status, :atom, required: true
  attr :detail, :string, default: nil
  attr :dot, :boolean, default: false
  attr :size, :string, default: "md", values: ~w(xs sm md)
  attr :class, :any, default: nil
  slot :inner_block, doc: "replaces the status label"

  def result_pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex max-w-full shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full font-semibold",
      case @size do
        "xs" -> "h-[1.375rem] px-2 text-[0.6875rem]"
        "sm" -> "h-[1.625rem] px-2.5 text-xs"
        _md -> "h-7 px-2.5 text-xs"
      end,
      result_tint(@status),
      @class
    ]}>
      <span
        :if={@dot and @status == :simulated}
        class="size-2 shrink-0 rounded-full border-[1.5px] border-dashed border-current"
        aria-hidden="true"
      ></span>
      <span
        :if={@dot and @status != :simulated}
        class="size-1.5 shrink-0 rounded-full bg-current"
        aria-hidden="true"
      ></span>
      <span class="truncate">
        <%= if @inner_block != [] do %>
          {render_slot(@inner_block)}
        <% else %>
          {outcome_label(@status)}<span :if={@detail}> · {@detail}</span>
        <% end %>
      </span>
    </span>
    """
  end

  defp result_tint(:executed), do: "bg-primary/12 text-primary"
  defp result_tint(:simulated), do: "bg-accent/13 text-accent"

  defp result_tint(status) when status in [:partial, :waiting, :capped],
    do: "bg-warning/13 text-warning"

  defp result_tint(:failed), do: "bg-error/14 text-error"
  defp result_tint(:exempt), do: "ring-1 ring-inset ring-base-300 text-subtle"
  defp result_tint(_neutral), do: "bg-secondary text-subtle"

  @doc "An evaluation outcome in one or two words, as the boards write them."
  @spec outcome_label(atom()) :: String.t()
  def outcome_label(:executed), do: gettext("executed")
  def outcome_label(:simulated), do: gettext("simulated")
  def outcome_label(:partial), do: gettext("partial")
  def outcome_label(:failed), do: gettext("failed")
  def outcome_label(:no_match), do: gettext("did not match")
  def outcome_label(:waiting), do: gettext("waiting")
  def outcome_label(:capped), do: gettext("at the limit")
  def outcome_label(:exempt), do: gettext("exempt")
  def outcome_label(:inactive), do: gettext("rule off")
  def outcome_label(:unrecorded), do: gettext("not recorded")
  def outcome_label(:ignored), do: gettext("ignored")
  def outcome_label(other), do: to_string(other)

  @doc "The pill tone of an execution status."
  @spec result_tone(atom()) :: String.t()
  def result_tone(:executed), do: "live"
  def result_tone(:simulated), do: "simulating"
  def result_tone(:partial), do: "warning"
  def result_tone(:failed), do: "error"
  def result_tone(_status), do: "neutral"

  @doc "The fill colour of an execution status, for bars and dots."
  @spec result_fill(atom()) :: String.t()
  def result_fill(:executed), do: "bg-primary"
  def result_fill(:simulated), do: "bg-accent"
  def result_fill(:partial), do: "bg-warning"
  def result_fill(:failed), do: "bg-error"
  def result_fill(_status), do: "bg-base-300"

  # ── The rule as a sentence ─────────────────────────────────────────────────

  @doc """
  The rule written out as one sentence, with the parts an admin changes -
  the trigger, each condition, each action - raised as chips so the eye
  lands on them.
  """
  attr :rule, :map, required: true
  attr :id, :string, default: nil
  attr :class, :any, default: "text-lg leading-[1.7] sm:text-xl"

  def rule_sentence_chips(assigns) do
    assigns = assign(assigns, :parts, sentence_parts(assigns.rule))

    ~H"""
    <p id={@id} class={["text-subtle [text-wrap:pretty]", @class]}>
      <span
        :for={{kind, text} <- @parts}
        class={
          kind == :chip &&
            "rounded-[0.625rem] bg-secondary px-2.5 py-[3px] font-medium text-base-content [box-decoration-break:clone]"
        }
      >{text}</span>
    </p>
    """
  end

  @doc """
  The sentence of a rule as `{:text | :chip, text}` parts: "When [trigger],
  if [a] and [b], then [x], [y]." An escalating rule reads as a ladder:
  "…, count the offence and go up one step of the ladder. The ladder resets
  after [30 minutes] without offences."
  """
  @spec sentence_parts(map()) :: [{:text | :chip, String.t()}]
  def sentence_parts(rule) do
    conditions = Enum.reject(rule.conditions, &(&1.field == :always_true))
    joiner = " " <> Labels.logical_joiner(rule.logical_operator) <> " "

    trigger = [
      {:text, gettext("When") <> " "},
      {:chip, lower_first(Labels.trigger(rule.trigger_event))}
    ]

    ifs =
      case conditions do
        [] ->
          []

        conditions ->
          [{:text, ", " <> gettext("if") <> " "}] ++
            (conditions
             |> Enum.map(&{:chip, condition_sentence(&1, rule.game)})
             |> Enum.intersperse({:text, joiner}))
      end

    thens =
      cond do
        rule.escalation_window_seconds > 0 and length(rule.actions) > 1 ->
          [
            {:text,
             ", " <> gettext("count the offence and go up one step of the ladder") <> ". "},
            {:text, gettext("The ladder resets after") <> " "},
            {:chip, duration_text(rule.escalation_window_seconds)},
            {:text, " " <> gettext("without offences")}
          ]

        rule.actions == [] ->
          [{:text, ", " <> gettext("then") <> " " <> gettext("no actions yet")}]

        true ->
          [{:text, ", " <> gettext("then") <> " "}] ++
            (rule.actions
             |> Enum.map(&{:chip, lower_first(action_text(&1))})
             |> Enum.intersperse({:text, ", "}))
      end

    exempt =
      case exemptions_text(Map.get(rule, :exemptions)) do
        nil -> [{:text, "."}]
        who -> [{:text, ". " <> gettext("Doesn't apply to") <> " "}, {:chip, who}, {:text, "."}]
      end

    trigger ++ ifs ++ thens ++ exempt
  end

  @doc """
  A rule in one short line for the list: when, what it checks, what it
  does - "When the player connects · 1 condition · message the player".
  """
  @spec short_sentence(map()) :: String.t()
  def short_sentence(rule) do
    conditions = Enum.reject(rule.conditions, &(&1.field == :always_true))

    when_text =
      if rule.trigger_event == :periodic,
        do: gettext("Periodically"),
        else: gettext("When") <> " " <> lower_first(Labels.trigger(rule.trigger_event))

    checks =
      case conditions do
        [] -> nil
        [single] -> condition_sentence(single, rule.game)
        many -> ngettext("1 condition", "%{count} conditions", length(many))
      end

    does =
      cond do
        rule.escalation_window_seconds > 0 and length(rule.actions) > 1 ->
          ngettext("ladder of 1", "ladder of %{count}", length(rule.actions))

        rule.actions == [] ->
          gettext("no actions yet")

        true ->
          Enum.map_join(rule.actions, ", ", &lower_first(Labels.action(&1.type)))
      end

    [when_text, checks, does] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
  end

  @doc """
  An action with the parameter that tells it apart: "Ban for 2 hours".
  """
  @spec action_text(map()) :: String.t()
  def action_text(%{type: :temp_ban_player, parameters: params}) do
    case params && (params["duration_hours"] || params[:duration_hours]) do
      nil -> Labels.action(:temp_ban_player)
      hours -> ngettext("Ban for 1 hour", "Ban for %{count} hours", to_int(hours))
    end
  end

  def action_text(%{type: type}), do: Labels.action(type)

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) do
    case Integer.parse(to_string(value)) do
      {int, _rest} -> int
      :error -> 0
    end
  end

  @doc "A span of seconds the way the sentence says it: \"30 minutes\"."
  @spec duration_text(non_neg_integer()) :: String.t()
  def duration_text(seconds) when seconds >= 3600 and rem(seconds, 3600) == 0,
    do: ngettext("1 hour", "%{count} hours", div(seconds, 3600))

  def duration_text(seconds) when seconds >= 60 and rem(seconds, 60) == 0,
    do: ngettext("1 minute", "%{count} minutes", div(seconds, 60))

  def duration_text(seconds), do: ngettext("1 second", "%{count} seconds", seconds)

  @doc """
  Where a rule runs: "BR #1" when pinned, "Every HLL server" when not.
  """
  @spec scope_text(map()) :: String.t()
  def scope_text(%{server: %{name: name}}) when is_binary(name), do: name
  def scope_text(rule), do: gettext("Every %{game} server", game: game_short(rule.game))

  @doc ~s(Where a rule runs, as short as a list column: "BR #1", "All HLL".)
  @spec scope_short(map()) :: String.t()
  def scope_short(%{server: %{name: name}}) when is_binary(name), do: name
  def scope_short(rule), do: gettext("All %{game}", game: game_short(rule.game))

  @doc "The short name of a game: HLL, HLL Vietnam."
  @spec game_short(atom()) :: String.t()
  def game_short(:hllv), do: "HLL Vietnam"
  def game_short(_hll), do: "HLL"

  @doc "The context line of a rule page: where it runs and its priority."
  @spec meta_line(map()) :: String.t()
  def meta_line(rule) do
    scope_text(rule) <> " · " <> gettext("priority %{value}", value: rule.priority)
  end

  defp lower_first(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest
  defp lower_first(text), do: text

  # ── Events ─────────────────────────────────────────────────────────────────

  @doc """
  What happened in an event sample, in words: "killed the teammate Santos",
  "typed !admin", "connected".
  """
  @spec event_text(map() | nil, atom() | String.t() | nil) :: String.t()
  def event_text(nil, trigger), do: lower_first(trigger_label(trigger))

  def event_text(sample, _trigger) do
    event = Map.get(sample, :event)
    describe_event(sample.trigger, event, event_field(event, :target_player_name))
  end

  defp describe_event(:player_team_kill, _event, target) when is_binary(target),
    do: gettext("killed the teammate %{name}", name: target)

  defp describe_event(:player_kill, _event, target) when is_binary(target),
    do: gettext("killed %{name}", name: target)

  defp describe_event(:player_death, _event, target) when is_binary(target),
    do: gettext("was killed by %{name}", name: target)

  defp describe_event(:chat_command, event, _target),
    do: gettext("typed %{text}", text: short_text(event_field(event, :chat_message)))

  defp describe_event(:player_chat, event, _target),
    do: gettext("wrote “%{text}”", text: short_text(event_field(event, :chat_message)))

  defp describe_event(:player_connected, _event, _target), do: gettext("connected")
  defp describe_event(:player_disconnected, _event, _target), do: gettext("disconnected")
  defp describe_event(:team_switch, _event, _target), do: gettext("switched teams")
  defp describe_event(trigger, _event, _target), do: lower_first(trigger_label(trigger))

  defp event_field(%Event{} = event, key), do: Map.get(event, key)
  defp event_field(%{} = event, key), do: Map.get(event, key)
  defp event_field(_event, _key), do: nil

  defp short_text(nil), do: "…"
  defp short_text(text), do: String.slice(text, 0, 40)

  @doc "The weapon of an event sample, if it names one."
  @spec event_weapon(map() | nil) :: String.t() | nil
  def event_weapon(nil), do: nil
  def event_weapon(sample), do: event_field(Map.get(sample, :event), :weapon)

  # ── Time ───────────────────────────────────────────────────────────────────

  @doc """
  The time zone the area writes clock times in: the one most of the servers
  use, or UTC.
  """
  @spec zone([map()]) :: String.t()
  def zone(servers) do
    servers
    |> Enum.map(&Map.get(&1, :timezone))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
    |> Enum.max_by(fn {_zone, count} -> count end, fn -> {"Etc/UTC", 0} end)
    |> elem(0)
  end

  @doc "A moment in a time zone, falling back to UTC for an unknown zone."
  @spec local(DateTime.t(), String.t()) :: DateTime.t()
  def local(%DateTime{} = at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, shifted} -> shifted
      {:error, _reason} -> at
    end
  end

  @doc """
  When something happened, as short as a list column can take it: the clock
  time today, "yesterday", then "20 Sep".
  """
  @spec when_text(DateTime.t() | nil, String.t()) :: String.t()
  def when_text(nil, _zone), do: gettext("never")

  def when_text(%DateTime{} = at, zone) do
    local = local(at, zone)
    today = DateTime.utc_now() |> local(zone) |> DateTime.to_date()
    date = DateTime.to_date(local)

    cond do
      date == today -> Calendar.strftime(local, "%H:%M")
      date == Date.add(today, -1) -> gettext("yesterday")
      true -> day_month(date)
    end
  end

  @doc "A date as \"20 Sep\"."
  @spec day_month(Date.t()) :: String.t()
  def day_month(%Date{day: day, month: month}), do: "#{day} #{month_short(month)}"

  @doc "The clock time of a moment in a zone, with seconds: \"21:49:31\"."
  @spec clock(DateTime.t(), String.t()) :: String.t()
  def clock(%DateTime{} = at, zone), do: at |> local(zone) |> Calendar.strftime("%H:%M:%S")

  @doc "A moment as \"29/09 21:49:31\" in a zone."
  @spec stamp(DateTime.t(), String.t()) :: String.t()
  def stamp(%DateTime{} = at, zone), do: at |> local(zone) |> Calendar.strftime("%d/%m %H:%M:%S")

  defp month_short(1), do: gettext("Jan")
  defp month_short(2), do: gettext("Feb")
  defp month_short(3), do: gettext("Mar")
  defp month_short(4), do: gettext("Apr")
  defp month_short(5), do: gettext("May")
  defp month_short(6), do: gettext("Jun")
  defp month_short(7), do: gettext("Jul")
  defp month_short(8), do: gettext("Aug")
  defp month_short(9), do: gettext("Sep")
  defp month_short(10), do: gettext("Oct")
  defp month_short(11), do: gettext("Nov")
  defp month_short(12), do: gettext("Dec")

  @doc "A weekday's short name."
  @spec weekday_short(Date.t()) :: String.t()
  def weekday_short(date) do
    case Date.day_of_week(date) do
      1 -> gettext("Mon")
      2 -> gettext("Tue")
      3 -> gettext("Wed")
      4 -> gettext("Thu")
      5 -> gettext("Fri")
      6 -> gettext("Sat")
      _sunday -> gettext("Sun")
    end
  end

  @doc "A number with thousands separated the Brazilian way: 12.480."
  @spec number(integer() | nil) :: String.t()
  def number(nil), do: "0"

  def number(value) when is_integer(value) do
    value
    |> abs()
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1.")
    |> String.reverse()
    |> then(&if(value < 0, do: "-" <> &1, else: &1))
  end

  def number(value), do: to_string(value)

  # ── Escalation ladder ──────────────────────────────────────────────────────

  @doc """
  An escalation rule's actions as the steps of its ladder, each with how many
  times it ran (read from the executions' trace). Without counts the steps
  still read in order.
  """
  attr :id, :string, required: true
  attr :rule, :map, required: true
  attr :counts, :map, default: %{}, doc: "%{step_number => runs}"
  attr :compact, :boolean, default: false, doc: "the phone's shorter rows"

  def ladder(assigns) do
    assigns = assign(assigns, :max, Enum.max([1 | Map.values(assigns.counts)]))

    ~H"""
    <ol id={@id} class="flex flex-col gap-2">
      <li
        :for={{action, index} <- Enum.with_index(@rule.actions, 1)}
        class={[
          "grid items-center",
          if(@compact,
            do: "grid-cols-[1.625rem_minmax(0,1fr)_4.375rem_1.75rem] gap-2.5",
            else:
              "grid-cols-[2rem_minmax(0,1fr)_3rem] gap-x-3.5 gap-y-1 sm:grid-cols-[2rem_13.75rem_minmax(0,1fr)_3rem]"
          )
        ]}
      >
        <span class={[
          "flex items-center justify-center rounded-full bg-secondary font-mono",
          if(@compact, do: "size-[1.625rem] text-xs", else: "size-8 text-[0.8125rem]")
        ]}>
          {index}
        </span>
        <span class="truncate text-sm">{action_text(action)}</span>
        <span class={[
          "flex rounded bg-secondary",
          if(@compact,
            do: "h-1.5",
            else: "col-span-3 row-start-2 h-2 sm:col-span-1 sm:row-start-auto"
          )
        ]}>
          <span
            class={["rounded", ladder_fill(action.type, @rule.simulation)]}
            style={"width: #{ladder_width(Map.get(@counts, index, 0), @max)}%"}
          ></span>
        </span>
        <span
          id={"#{@id}-step-#{index}"}
          class={[
            "text-right font-mono text-subtle",
            if(@compact,
              do: "text-xs",
              else: "text-[0.8125rem] max-sm:col-start-3 max-sm:row-start-1"
            )
          ]}
        >
          {Map.get(@counts, index, 0)}
        </span>
      </li>
    </ol>
    """
  end

  defp ladder_width(0, _max), do: 0
  defp ladder_width(count, max), do: max(round(count / max * 100), 3)

  defp ladder_fill(type, simulation?) do
    case Icons.action_tone(type) do
      :error -> "bg-error"
      :warning -> "bg-axis"
      _info -> if(simulation?, do: "bg-accent", else: "bg-primary")
    end
  end

  @doc """
  Which rung of the ladder a run was on, as segments: `step` of `steps`
  filled.
  """
  attr :step, :integer, required: true
  attr :steps, :integer, required: true
  attr :tone, :string, default: "engine"

  def ladder_meter(assigns) do
    ~H"""
    <span
      class="grid gap-1"
      style={"grid-template-columns: repeat(#{max(@steps, 1)}, minmax(0, 1fr))"}
      aria-hidden="true"
    >
      <span
        :for={index <- 1..max(@steps, 1)}
        class={[
          "h-1.5 rounded-[3px]",
          if(index <= @step,
            do: if(@tone == "live", do: "bg-primary", else: "bg-accent"),
            else: "bg-base-300"
          )
        ]}
      ></span>
    </span>
    """
  end

  # ── Execution trace ────────────────────────────────────────────────────────

  @doc """
  The conditions a run read, as the boards draw them: a group header (the
  way the conditions combine and whether it matched), then each condition
  with the value it needed and the value it read.
  """
  attr :conditions, :list, required: true, doc: "trace maps (string keys) or diagnosis maps"
  attr :operator, :any, default: nil
  attr :columns, :boolean, default: false, doc: "the wider three-column rows"

  def condition_group(assigns) do
    assigns =
      assigns
      |> assign(:rows, Enum.map(assigns.conditions, &condition_row/1))
      |> then(fn assigns ->
        assign(assigns, :held?, group_held?(assigns.operator, Enum.map(assigns.rows, & &1.pass)))
      end)

    ~H"""
    <div class="flex flex-col gap-2">
      <div class="flex items-center gap-2 text-[0.8125rem]">
        <span class="h-4 w-[3px] rounded-sm bg-accent" aria-hidden="true"></span>
        <strong class="font-semibold">{gettext("Group 1")}</strong>
        <span class="text-muted">{group_rule(@operator)}</span>
        <span class="grow"></span>
        <span class={["text-xs font-semibold", if(@held?, do: "text-primary", else: "text-error")]}>
          {if @held?, do: gettext("matched"), else: gettext("did not match")}
        </span>
      </div>
      <p :if={@rows == []} class="text-xs text-muted">
        {gettext("No conditions: it answers every event of its trigger.")}
      </p>
      <div
        :for={row <- @rows}
        class={[
          "grid items-center gap-2 text-[0.8125rem]",
          if(@columns,
            do: "gap-x-2.5 sm:grid-cols-[minmax(0,1fr)_9.375rem_9.375rem]",
            else: "grid-cols-[minmax(0,1fr)_auto]"
          )
        ]}
      >
        <span :if={!@columns} class="min-w-0 text-subtle">
          {row.label} <span class="text-muted">{row.operator}</span>
          <span class="font-mono text-xs text-base-content">{row.expected}</span>
        </span>
        <span :if={@columns} class="min-w-0">{row.label}</span>
        <span :if={@columns} class="text-muted">
          {gettext("needed")}
          <span class="font-mono text-xs text-base-content">{row.operator} {row.expected}</span>
        </span>
        <span class={[
          "w-fit justify-self-start rounded-full px-2.5 py-[3px] font-mono text-xs",
          !@columns && "justify-self-end",
          if(row.pass, do: "bg-primary/12 text-primary", else: "bg-error/14 text-error")
        ]}>
          {if row.pass, do: "✓", else: "✗"} {gettext("read %{value}", value: row.actual)}
        </span>
      </div>
    </div>
    """
  end

  defp condition_row(%{"field" => field} = condition) do
    %{
      label: condition_field_label(field),
      operator: operator_label(condition["operator"]),
      expected: condition["expected"],
      actual: read_value(condition["actual"]),
      pass: condition["result"] == true
    }
  end

  defp condition_row(%{field: field} = condition) do
    %{
      label: Labels.field(field),
      operator: Labels.operator(condition.operator),
      expected: condition.expected,
      actual: read_value(condition.actual),
      pass: condition.result == true
    }
  end

  defp group_held?(operator, results) do
    case to_string(operator || "and") do
      "or" -> Enum.any?(results)
      "nand" -> not Enum.all?(results)
      "nor" -> not Enum.any?(results)
      _and -> Enum.all?(results)
    end
  end

  defp group_rule(operator) do
    case to_string(operator || "and") do
      "or" -> gettext("any one is enough")
      "nand" -> gettext("not all of them")
      "nor" -> gettext("none of them")
      _and -> gettext("all must hold")
    end
  end

  @doc """
  One execution, opened up. The rule page's executions tab and the history
  both expand a row into this: the conditions it read, the ladder and the
  protections it went through (or, in the history, the trigger), what each
  action did, and how long it took.

  `limits` are the player's earlier runs (`[DateTime]`), for the cooldown and
  cap lines; `variant` is `:rule` (conditions · ladder · actions) or
  `:history` (trace · actions · Discord).
  """
  attr :execution, :map, required: true
  attr :id, :string, required: true
  attr :rule, :map, default: nil
  attr :limits, :list, default: nil
  attr :zone, :string, default: "Etc/UTC"
  attr :variant, :atom, default: :rule, values: [:rule, :history]
  attr :rule_link, :boolean, default: true

  def execution_trace(assigns) do
    trace = assigns.execution.trace || %{}
    rule = assigns.rule || assigns.execution.rule

    assigns =
      assigns
      |> assign(:rule, rule)
      |> assign(
        :conditions,
        Enum.reject(trace["conditions"] || [], &(&1["field"] == "always_true"))
      )
      |> assign(:recorded?, (trace["conditions"] || []) != [])
      |> assign(:logical_operator, trace["logical_operator"])
      |> assign(:step, trace["step"])
      |> assign(:steps, trace["steps"])
      |> assign(:duration_ms, trace["duration_ms"])
      |> assign(:deliveries, discord_deliveries(assigns.execution))

    ~H"""
    <div
      id={@id}
      class={[
        "grid gap-3.5",
        if(@variant == :history,
          do:
            "md:grid-cols-[minmax(0,1.05fr)_minmax(0,1.15fr)_minmax(0,0.9fr)] md:gap-0 md:divide-x md:divide-base-300",
          else: "md:grid-cols-[minmax(0,1.25fr)_minmax(0,0.85fr)_minmax(0,1fr)]"
        )
      ]}
    >
      <%!-- Conditions / trace --%>
      <div class={[
        "flex flex-col gap-2.5",
        if(@variant == :history,
          do: "md:px-[1.125rem] md:py-3.5",
          else: "rounded-2xl bg-base-100 p-4"
        )
      ]}>
        <.caption :if={@variant == :rule}>
          {gettext("Conditions")} · {group_rule(@logical_operator)}
        </.caption>
        <.caption :if={@variant == :history} class="font-mono tracking-[0.1em]">
          {gettext("Trace · why it fired")}
        </.caption>

        <.trace_row :if={@variant == :history}>
          <span>
            <span class="text-muted">{gettext("When")}</span>
            {lower_first(trigger_label(@execution.trigger_event))}
          </span>
          <:chip>
            <span class="font-mono text-[0.6875rem] text-primary">✓ {gettext("received")}</span>
          </:chip>
        </.trace_row>

        <p :if={not @recorded?} class="text-xs text-muted">
          {gettext("Not recorded for executions older than this version.")}
        </p>

        <.condition_group
          :if={@recorded? and @variant == :rule}
          conditions={@conditions}
          operator={@logical_operator}
        />

        <.trace_row :for={condition <- @conditions} :if={@variant == :history}>
          <span class="min-w-0">
            {condition_field_label(condition["field"])}
            <span class="text-muted">{operator_label(condition["operator"])}</span>
            {condition["expected"]}
          </span>
          <:chip>
            <span class={[
              "font-mono text-[0.6875rem]",
              if(condition["result"], do: "text-primary", else: "text-error")
            ]}>
              {if condition["result"], do: "✓", else: "✗"} {gettext("read %{value}",
                value: read_value(condition["actual"])
              )}
            </span>
          </:chip>
        </.trace_row>

        <.trace_row :if={(@variant == :history and @rule) && @rule.cooldown_seconds > 0}>
          <span>
            <span class="text-muted">{gettext("Protection")}</span>
            {gettext("cooldown of %{time} per player",
              time: duration_text(@rule.cooldown_seconds)
            )}
          </span>
          <:chip>
            <span class="font-mono text-[0.6875rem] text-primary">✓ {gettext("free")}</span>
          </:chip>
        </.trace_row>
      </div>

      <%!-- Ladder and protections (rule page only) --%>
      <div :if={@variant == :rule} class="flex flex-col gap-2.5 rounded-2xl bg-base-100 p-4">
        <.caption>{gettext("Ladder and protections")}</.caption>
        <div :if={@step} class="flex flex-col gap-2.5">
          <strong class="font-display text-xl font-semibold">
            {gettext("Offence %{number} of %{total}", number: @step, total: @steps)}
          </strong>
          <.ladder_meter
            :if={is_integer(@steps)}
            step={@step}
            steps={@steps}
            tone={if @execution.status == :simulated, do: "engine", else: "live"}
          />
        </div>
        <p :if={is_nil(@step)} class="text-[0.8125rem] text-muted">
          {gettext("No ladder: every run does every action.")}
        </p>
        <dl :if={@rule} class="flex flex-col gap-2 text-[0.8125rem]">
          <div class="flex justify-between gap-3">
            <dt class="text-muted">
              {if @rule.cooldown_seconds > 0,
                do: gettext("Cooldown %{time}", time: duration_text(@rule.cooldown_seconds)),
                else: gettext("Cooldown")}
            </dt>
            <dd class="text-right">{cooldown_text(@rule, @limits, @execution, @zone)}</dd>
          </div>
          <div class="flex justify-between gap-3">
            <dt class="text-muted">{gettext("Limit in 24 h")}</dt>
            <dd class="text-right font-mono text-xs">{cap_text(@rule, @limits, @execution)}</dd>
          </div>
          <div class="flex justify-between gap-3">
            <dt class="text-muted">{gettext("Exemptions")}</dt>
            <dd class="text-right">{gettext("none applies")}</dd>
          </div>
        </dl>
      </div>

      <%!-- Actions --%>
      <div class={[
        "flex flex-col gap-2.5",
        if(@variant == :history,
          do: "md:px-[1.125rem] md:py-3.5",
          else: "rounded-2xl bg-base-100 p-4"
        )
      ]}>
        <.caption class={@variant == :history && "font-mono tracking-[0.1em]"}>
          {gettext("Actions")}
        </.caption>
        <strong :if={@step && @variant == :history} class="font-display text-lg font-semibold">
          {gettext("Offence %{number} of %{total}", number: @step, total: @steps)}
        </strong>

        <p :if={@execution.results == []} class="text-xs text-muted">{gettext("No action ran.")}</p>

        <ol :if={@execution.results != []} class="flex flex-col gap-2.5">
          <li
            :for={{result, index} <- Enum.with_index(@execution.results)}
            class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-2.5 gap-y-1.5"
          >
            <span
              :if={@variant == :rule}
              class={[
                "h-fit rounded-full px-2 py-[3px] text-[0.6875rem] font-semibold",
                action_state_tint(delivery_state(result, delivery(@execution, index)))
              ]}
            >
              {action_state_label(delivery_state(result, delivery(@execution, index)))}
            </span>
            <span
              :if={@variant == :history}
              class={[
                "flex size-[1.625rem] items-center justify-center rounded-full font-mono text-xs font-semibold",
                action_state_tint(delivery_state(result, delivery(@execution, index)))
              ]}
            >
              {index + 1}
            </span>
            <span class="flex min-w-0 flex-col gap-1">
              <span class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-0.5">
                <span class="text-sm font-semibold">{action_label(result["type"])}</span>
                <span :if={@variant == :history} class="font-mono text-[0.6875rem] text-muted">
                  {result["type"]}
                </span>
                <span
                  :if={@variant == :history}
                  class={[
                    "ml-auto text-xs font-semibold",
                    action_state_text(delivery_state(result, delivery(@execution, index)))
                  ]}
                >
                  {delivery_label(result, delivery(@execution, index)) ||
                    result_label(result["status"])}
                </span>
              </span>
              <span
                :if={delivery_detail(result, delivery(@execution, index))}
                class={[
                  "break-words font-mono text-xs leading-relaxed",
                  if(delivery_state(result, delivery(@execution, index)) == :error,
                    do: "rounded-xl border border-base-300 bg-base-200 px-3 py-2.5 text-subtle",
                    else: "text-subtle"
                  )
                ]}
              >
                {delivery_detail(result, delivery(@execution, index))}
              </span>
            </span>
          </li>
        </ol>

        <p
          :if={@execution.error && @variant == :history}
          class="text-xs leading-snug text-subtle"
        >
          {@execution.error}
        </p>

        <div
          :if={@variant == :rule}
          class="mt-auto flex flex-col gap-1.5 border-t border-base-300 pt-2.5"
        >
          <span class="text-xs text-muted">
            {gettext("Duration")} · {if @duration_ms, do: "#{@duration_ms} ms", else: "—"}
          </span>
          <span :if={@duration_ms} class="flex h-2 overflow-hidden rounded" aria-hidden="true">
            <span class="w-full rounded bg-allies"></span>
          </span>
          <div class="mt-1 flex flex-wrap gap-x-3.5 gap-y-1 text-[0.8125rem] font-medium">
            <.link
              navigate={~p"/rules/#{@execution.rule_id}/edit"}
              class="text-primary hover:underline"
            >
              {gettext("Open in the builder")}
            </.link>
            <.link
              navigate={
                ~p"/rules/simulate?#{[server_id: @execution.server_id, trigger: @execution.trigger_event]}"
              }
              class="text-primary hover:underline"
            >
              {gettext("Open in the simulator")}
            </.link>
            <.link
              :if={@execution.player_id}
              navigate={~p"/players/#{@execution.player_id}"}
              class="text-primary hover:underline"
            >
              {gettext("Player profile")}
            </.link>
          </div>
        </div>
      </div>

      <%!-- Discord and what to do next (history only) --%>
      <div :if={@variant == :history} class="flex flex-col gap-2.5 md:px-[1.125rem] md:py-3.5">
        <.caption class="font-mono tracking-[0.1em]">
          {if @deliveries != [], do: gettext("Discord notice"), else: gettext("Timing")}
        </.caption>
        <div
          :for={{index, delivery} <- @deliveries}
          class={[
            "flex flex-col gap-1 rounded-[0.875rem] border-l-[3px] bg-secondary px-3 py-2.5",
            if(delivery["status"] == "failed", do: "border-error", else: "border-primary")
          ]}
        >
          <span class="flex items-center gap-2 text-[0.8125rem] font-semibold">
            <span class="font-mono text-xs font-medium text-subtle">
              {gettext("action %{number}", number: index + 1)}
            </span>
            <span class="grow"></span>
            <span class={[
              "text-xs font-semibold",
              if(delivery["status"] == "failed", do: "text-error", else: "text-primary")
            ]}>
              {if delivery["status"] == "failed",
                do: gettext("not delivered"),
                else: gettext("delivered")}
            </span>
          </span>
          <span :if={delivery["detail"]} class="text-xs text-muted">{delivery["detail"]}</span>
        </div>
        <p :if={@deliveries == [] and @duration_ms} class="font-mono text-xs text-subtle">
          {gettext("Took %{ms} ms", ms: @duration_ms)}
        </p>
        <p :if={@deliveries == [] and is_nil(@duration_ms)} class="text-xs text-muted">
          {gettext("Not recorded.")}
        </p>
        <span class="grow"></span>
        <div class="flex flex-wrap gap-2">
          <.link
            :if={@rule_link}
            navigate={~p"/rules/#{@execution.rule_id}"}
            class="flex h-11 items-center rounded-full border border-base-300 bg-secondary px-4 text-sm transition-colors hover:bg-base-200"
          >
            {gettext("Open the rule")}
          </.link>
          <.link
            :if={@execution.player_id}
            navigate={~p"/players/#{@execution.player_id}"}
            class="flex h-11 items-center rounded-full border border-base-300 bg-secondary px-4 text-sm transition-colors hover:bg-base-200"
          >
            {gettext("Player profile")}
          </.link>
        </div>
        <.link
          :if={@execution.status in [:failed, :partial]}
          navigate={~p"/servers/#{@execution.server_id}"}
          class="text-xs text-primary hover:underline"
        >
          {gettext("Check the key of %{server}", server: server_name(@execution))}
        </.link>
      </div>
    </div>
    """
  end

  defp server_name(%{server: %{name: name}}), do: name
  defp server_name(_execution), do: gettext("the server")

  defp discord_deliveries(execution) do
    (execution.deliveries || %{})
    |> Enum.flat_map(fn {index, delivery} ->
      case Integer.parse(to_string(index)) do
        {number, ""} -> [{number, delivery}]
        _other -> []
      end
    end)
    |> Enum.sort()
  end

  defp cooldown_text(%{cooldown_seconds: 0}, _limits, _execution, _zone), do: gettext("none")
  defp cooldown_text(_rule, nil, _execution, _zone), do: "—"

  defp cooldown_text(_rule, limits, _execution, zone) do
    case List.last(limits) do
      nil ->
        gettext("free · first run")

      at ->
        gettext("free · last at %{time}", time: at |> local(zone) |> Calendar.strftime("%H:%M"))
    end
  end

  defp cap_text(%{max_executions_per_player: 0}, _limits, _execution), do: gettext("no limit")
  defp cap_text(_rule, nil, _execution), do: "—"

  defp cap_text(rule, limits, _execution) do
    gettext("%{count} of %{max}", count: length(limits) + 1, max: rule.max_executions_per_player)
  end

  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :chip

  defp trace_row(assigns) do
    ~H"""
    <div class={[
      "grid grid-cols-[minmax(0,1fr)_auto] items-center gap-2.5 rounded-xl bg-secondary px-2.5 py-1.5 text-[0.8125rem]",
      @class
    ]}>
      {render_slot(@inner_block)}
      {render_slot(@chip)}
    </div>
    """
  end

  @doc "What one execution did, for the row summary: \"Offence 2 of 4 · Punish\"."
  @spec summary(map()) :: String.t() | nil
  def summary(execution) do
    trace = execution.trace || %{}

    step =
      if trace["step"],
        do: gettext("Offence %{number} of %{total}", number: trace["step"], total: trace["steps"])

    actions =
      case execution.results do
        [] -> nil
        results -> Enum.map_join(results, ", ", &action_label(&1["type"]))
      end

    case Enum.reject([step, actions], &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  @doc "The duration of an execution, when the trace recorded one."
  @spec duration(map()) :: String.t() | nil
  def duration(%{trace: %{"duration_ms" => ms}}) when is_number(ms), do: "#{number(ms)} ms"
  def duration(_execution), do: nil

  # Queued actions (Discord) say "ok" once queued; what happened to the
  # delivery itself is written later, under the action's index.
  defp delivery(execution, index), do: Map.get(execution.deliveries || %{}, to_string(index))

  defp delivery_state(_result, %{"status" => "failed"}), do: :error
  defp delivery_state(%{"status" => "ok"}, _delivery), do: :ok
  defp delivery_state(%{"status" => "simulated"}, _delivery), do: :simulated
  defp delivery_state(%{"status" => "skipped"}, _delivery), do: :skipped
  defp delivery_state(_result, _delivery), do: :error

  defp delivery_detail(result, %{"status" => "failed", "detail" => reason})
       when is_binary(reason),
       do: Enum.join(Enum.reject([result["detail"], reason], &is_nil/1), " - ")

  defp delivery_detail(result, _delivery), do: result["detail"]

  defp delivery_label(_result, %{"status" => "delivered"}), do: gettext("Delivered")
  defp delivery_label(_result, %{"status" => "failed"}), do: gettext("Not delivered")

  defp delivery_label(%{"type" => "send_discord_webhook", "status" => "ok"}, nil),
    do: gettext("Queued")

  defp delivery_label(_result, _delivery), do: nil

  defp result_label("ok"), do: gettext("done")
  defp result_label("simulated"), do: gettext("simulated")
  defp result_label("skipped"), do: gettext("did not run")
  defp result_label(_status), do: gettext("failed")

  defp action_state_label(:ok), do: gettext("done")
  defp action_state_label(:simulated), do: gettext("simulated")
  defp action_state_label(:skipped), do: gettext("did not run")
  defp action_state_label(:error), do: gettext("failed")

  defp action_state_tint(:ok), do: "bg-primary/12 text-primary"
  defp action_state_tint(:simulated), do: "bg-accent/13 text-accent"
  defp action_state_tint(:skipped), do: "bg-base-300 text-muted"
  defp action_state_tint(:error), do: "bg-error/20 text-error"

  defp action_state_text(:ok), do: "text-primary"
  defp action_state_text(:simulated), do: "text-accent"
  defp action_state_text(:skipped), do: "text-muted"
  defp action_state_text(:error), do: "text-error"

  @doc "A value the engine read, the way the trace shows it."
  @spec read_value(term()) :: String.t()
  def read_value(nil), do: gettext("nothing")
  def read_value(""), do: gettext("nothing")
  def read_value(true), do: gettext("yes")
  def read_value(false), do: gettext("no")
  def read_value("true"), do: gettext("yes")
  def read_value("false"), do: gettext("no")
  def read_value(value) when is_list(value), do: Enum.join(value, ", ")
  def read_value(value) when is_map(value), do: inspect(value)
  def read_value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  def read_value(value), do: to_string(value)

  # ── Labels from stored strings ─────────────────────────────────────────────
  # Executions store the vocabulary as strings; these read them back through
  # the same labels the builder uses, falling back to the raw value.

  @doc "The translated label of a stored trigger."
  @spec trigger_label(atom() | String.t() | nil) :: String.t()
  def trigger_label(trigger) when is_atom(trigger) and not is_nil(trigger),
    do: Labels.trigger(trigger)

  def trigger_label(trigger), do: to_existing(trigger, &Labels.trigger/1)

  @doc "The translated label of a stored action type."
  @spec action_label(String.t() | atom() | nil) :: String.t()
  def action_label(type) when is_atom(type) and not is_nil(type), do: Labels.action(type)
  def action_label(type), do: to_existing(type, &Labels.action/1)

  @doc "The heroicon of a stored trigger."
  @spec trigger_icon(atom() | String.t() | nil) :: String.t()
  def trigger_icon(trigger) when is_atom(trigger) and not is_nil(trigger),
    do: Icons.trigger(trigger)

  def trigger_icon(trigger) do
    Icons.trigger(String.to_existing_atom(trigger))
  rescue
    _unknown -> "hero-bolt"
  end

  @doc "The label of a stored condition field."
  @spec condition_field_label(String.t() | atom() | nil) :: String.t()
  def condition_field_label(field) when is_atom(field) and not is_nil(field),
    do: Labels.field(field)

  def condition_field_label(field), do: to_existing(field, &Labels.field/1)

  @doc "The label of a stored operator."
  @spec operator_label(String.t() | atom() | nil) :: String.t()
  def operator_label(operator) when is_atom(operator) and not is_nil(operator),
    do: Labels.operator(operator)

  def operator_label(operator), do: to_existing(operator, &Labels.operator/1)

  defp to_existing(nil, _label), do: ""

  defp to_existing(value, label) do
    label.(String.to_existing_atom(value))
  rescue
    _unknown -> to_string(value)
  end
end
