defmodule HllConditionalActionsWeb.RuleBuilder do
  @moduledoc """
  The function components the visual rule builder is assembled from.

  The builder draws a rule as a vertical pipeline — the way an admin thinks
  about it: *this happens* (trigger node), *this is checked* (condition
  group), *this runs* (one node per action). Nodes hang off a spine
  (`.flow-spine` / `.flow-node` in `app.css`), each tinted by what it does,
  so a ban never reads like a chat message.

  `RuleLive.Form` owns the state and the events; this module owns the look
  of every node, the plain-language summary and the "try it" panel.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.Engine.Template
  alias HllConditionalActions.Rules.Catalog

  # ── Step navigator ─────────────────────────────────────────────────────────

  @doc """
  The map of the builder: one chip per step, anchored to its node.

  A rule is a long form, and the spine only tells you where you are once you
  have scrolled there. The chips stay in view, say which step is asking for
  something, and jump to it - the same anchors the footer's error list uses.
  """
  attr :steps, :list,
    required: true,
    doc: "%{id, label, icon, errors} maps, in the order they appear on the page"

  def step_nav(assigns) do
    ~H"""
    <nav
      class="sticky top-0 z-30 -mx-1 flex gap-1.5 overflow-x-auto rounded-box bg-base-100/90 px-1 py-2 backdrop-blur"
      aria-label={gettext("Steps of this rule")}
    >
      <a
        :for={{step, index} <- Enum.with_index(@steps, 1)}
        href={"##{step.id}"}
        class={[
          "flex shrink-0 items-center gap-1.5 rounded-field border px-2.5 py-1.5 text-xs transition-colors",
          if(step.errors > 0,
            do: "border-error/40 bg-error/10 text-error hover:bg-error/20",
            else: "border-base-300 text-muted hover:border-primary/40 hover:text-base-content"
          )
        ]}
      >
        <.icon name={step.icon} class="size-3.5 shrink-0" />
        <span class="font-medium">{step.label}</span>
        <span
          :if={step.errors > 0}
          class="rounded-full bg-error px-1.5 text-[0.625rem] font-semibold text-white"
        >
          {step.errors}
        </span>
        <span class="sr-only">{gettext("step %{number}", number: index)}</span>
      </a>
    </nav>
    """
  end

  # ── Flow nodes ─────────────────────────────────────────────────────────────

  @doc """
  One node of the pipeline. `tone` colours the connector dot and the icon
  chip; `error_count` turns the header red so the sticky footer's "step 3
  needs attention" has a visible anchor.
  """
  attr :id, :string, required: true
  attr :tone, :string, default: "neutral", values: ~w(neutral primary info warning error)
  attr :eyebrow, :string, required: true, doc: "WHEN / IF / THEN marker"
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :hint, :string, default: nil
  attr :error_count, :integer, default: 0
  slot :aside, doc: "a control pinned to the right of the node header"
  slot :inner_block, required: true

  def flow_node(assigns) do
    ~H"""
    <section
      id={@id}
      data-tone={@tone}
      class="flow-node scroll-mt-24 rounded-box border border-base-300 bg-base-100"
    >
      <div class="flex flex-col gap-4 p-4 sm:p-5">
        <div class="flex flex-wrap items-center gap-3">
          <div class={[
            "flex size-9 shrink-0 items-center justify-center rounded-field",
            if(@error_count > 0, do: "bg-error/15 text-error", else: node_chip(@tone))
          ]}>
            <.icon name={@icon} class="size-4" />
          </div>

          <div class="min-w-0 flex-1">
            <p class="eyebrow text-muted">{@eyebrow}</p>

            <h2 class="flex items-baseline gap-2 font-semibold leading-tight">
              {@title}
              <.tone_badge :if={@error_count > 0} tone="error" size="xs">
                {ngettext("%{count} problem", "%{count} problems", @error_count, count: @error_count)}
              </.tone_badge>
            </h2>

            <p :if={@hint} class="truncate text-xs text-muted">{@hint}</p>
          </div>

          <div :if={@aside != []} class="shrink-0">{render_slot(@aside)}</div>
        </div>

        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  defp node_chip("primary"), do: "bg-primary/15 text-primary"
  defp node_chip("info"), do: "bg-info/15 text-info"
  defp node_chip("warning"), do: "bg-warning/15 text-warning"
  defp node_chip("error"), do: "bg-error/15 text-error"
  defp node_chip(_neutral), do: "bg-base-200 text-subtle"

  @doc """
  A checkbox that reads as a setting rather than as a form field: a Petal
  switch inside a card that tints when active.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :hint, :string, required: true
  attr :tone, :string, default: "primary", values: ~w(primary warning)

  def switch_card(assigns) do
    ~H"""
    <label class={[
      "flex cursor-pointer items-start gap-3 rounded-box border border-base-300 p-3 transition-colors",
      @tone == "warning" && "has-[:checked]:border-warning has-[:checked]:bg-warning/10",
      @tone == "primary" && "has-[:checked]:border-primary has-[:checked]:bg-primary/5"
    ]}>
      <input type="hidden" name={@field.name} value="false" />
      <label class="pc-switch pc-switch--sm mt-0.5 shrink-0">
        <input
          type="checkbox"
          id={@field.id}
          name={@field.name}
          value="true"
          checked={Phoenix.HTML.Form.normalize_value("checkbox", @field.value)}
          class="peer sr-only"
        />
        <span class="pc-switch__fake-input pc-switch__fake-input--sm"></span>
        <span class="pc-switch__fake-input-bg pc-switch__fake-input-bg--sm"></span>
      </label>
      <div class="min-w-0">
        <p class="flex items-center gap-1.5 text-sm font-medium leading-tight">
          <.icon name={@icon} class="size-3.5 shrink-0 text-muted" />{@title}
        </p>

        <p class="mt-0.5 text-xs text-muted">{@hint}</p>
      </div>
    </label>
    """
  end

  # ── Condition rows ─────────────────────────────────────────────────────────

  @doc """
  One condition of the "If" node.
  """
  attr :condition, :any, required: true
  attr :trigger, :atom, required: true
  attr :game, :atom, required: true
  attr :total, :integer, required: true

  def condition_row(assigns) do
    field = Phoenix.HTML.Form.input_value(assigns.condition, :field) || :always_true
    field = if is_binary(field), do: existing_field(field), else: field
    operator = Phoenix.HTML.Form.input_value(assigns.condition, :operator)
    operator = if is_binary(operator), do: existing_operator(operator), else: operator

    assigns =
      assigns
      |> assign(:field, field)
      |> assign(:value_options, value_options(field, assigns.game))
      |> assign(:numeric?, numeric_value?(field, operator))
      |> assign(:list?, Catalog.list_operator?(operator))
      |> assign(:free_text?, field != :always_true)

    ~H"""
    <div class="condition-grid rounded-box border border-base-300 bg-base-200/50 p-2.5">
      <.input
        field={@condition[:field]}
        type="select"
        options={Labels.field_options(@trigger)}
        label={gettext("Field")}
        label_class="lg:sr-only"
        no_margin
      />
      <.input
        :if={@free_text?}
        field={@condition[:operator]}
        type="select"
        options={Labels.operator_options(@field)}
        label={gettext("Comparison")}
        label_class="lg:sr-only"
        no_margin
      />
      <%!-- Spans the operator and value columns this row is not using, so the
            row tools stay where they are on every other row. --%>
      <div
        :if={not @free_text?}
        class="hidden items-center text-sm text-muted lg:col-span-2 lg:flex"
      >
        {gettext("this rule has no condition to check")}
      </div>

      <.input
        :if={@free_text? and @value_options}
        field={@condition[:value]}
        type="select"
        options={@value_options}
        label={gettext("Value")}
        label_class="lg:sr-only"
        no_margin
      />
      <.input
        :if={@free_text? and is_nil(@value_options) and @numeric?}
        field={@condition[:value]}
        type="number"
        step="any"
        placeholder={gettext("Value")}
        label={gettext("Value")}
        label_class="lg:sr-only"
        no_margin
      />
      <.input
        :if={@free_text? and is_nil(@value_options) and not @numeric?}
        field={@condition[:value]}
        type="text"
        placeholder={if @list?, do: gettext("value, other value"), else: gettext("Value")}
        label={gettext("Value")}
        label_class="lg:sr-only"
        help_text={if @list?, do: gettext("Separate each one with a comma")}
        no_margin
      />
      <div class="flex items-end justify-end">
        <.row_tools kind="condition" index={@condition.index} total={@total} />
      </div>
    </div>
    """
  end

  # ── Action rows ────────────────────────────────────────────────────────────

  @doc """
  One action node of the "Then" stage: type picker, its parameters, and the
  row tools. The connector dot and left stripe carry the action's tone.
  """
  attr :action, :any, required: true
  attr :total, :integer, required: true

  attr :step, :any,
    default: false,
    doc: "the 1-based rung when the rule escalates, false when it does not"

  def action_node(assigns) do
    type = Phoenix.HTML.Form.input_value(assigns.action, :type) || :message_player
    type = if is_binary(type), do: existing_action(type), else: type
    tone = Icons.action_tone(type)

    assigns =
      assigns
      |> assign(:type, type)
      |> assign(:tone, to_string(tone))
      |> assign(:params, Catalog.action_params(type))
      |> assign(:parameters, current_parameters(assigns.action))
      |> assign(:accent, Icons.accent(tone))
      |> assign(:chip, Icons.chip(tone))

    ~H"""
    <div
      data-tone={@tone}
      class={[
        "rise-in space-y-3 rounded-box border border-l-2 border-base-300 bg-base-100 p-3 sm:p-4",
        @accent
      ]}
    >
      <div class="flex flex-wrap items-start gap-2">
        <div class={["mt-1 flex size-8 shrink-0 items-center justify-center rounded-field", @chip]}>
          <.icon name={Icons.action(@type)} class="size-4" />
        </div>

        <div class="min-w-52 flex-1">
          <p :if={@step} class="mb-1 text-label-small text-muted">
            {step_label(@step, @total)}
          </p>

          <.input
            field={@action[:type]}
            type="select"
            options={Labels.action_options()}
            label={gettext("Action")}
            label_class="lg:sr-only"
            no_margin
            class="sm:max-w-80"
          />
        </div>

        <div class="pt-1">
          <.row_tools kind="action" index={@action.index} total={@total} />
        </div>
      </div>

      <div :for={{key, param_type, opts} <- @params} class="max-w-xl sm:pl-10">
        <.action_param_input
          name={"#{@action.name}[parameters][#{key}]"}
          id={"#{@action.id}_parameters_#{key}"}
          label={Labels.action_param(key)}
          type={param_type}
          value={parameter_value(@parameters, key, opts)}
          min={opts[:min]}
          required={opts[:required]}
        />
      </div>

      <p
        :for={message <- action_errors(@action)}
        class="flex items-center gap-1.5 text-sm text-error sm:pl-10"
      >
        <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />{message}
      </p>
    </div>
    """
  end

  # "1st offence", and "4th offence and beyond" for the last rung, because
  # the ladder repeats its final step forever.
  defp step_label(step, total) when step >= total,
    do: gettext("Offence %{number} and beyond", number: step)

  defp step_label(step, _total), do: gettext("Offence %{number}", number: step)

  # The move/duplicate/remove cluster shared by condition and action rows.
  attr :kind, :string, required: true, values: ~w(condition action)
  attr :index, :integer, required: true
  attr :total, :integer, required: true

  defp row_tools(assigns) do
    ~H"""
    <div class="flex divide-x divide-base-300 overflow-hidden rounded-field border border-base-300 bg-base-100">
      <.tool_button
        click={"move_#{@kind}"}
        index={@index}
        dir="up"
        disabled={@index == 0}
        label={move_up_label(@kind)}
        icon="hero-chevron-up"
      />
      <.tool_button
        click={"move_#{@kind}"}
        index={@index}
        dir="down"
        disabled={@index >= @total - 1}
        label={move_down_label(@kind)}
        icon="hero-chevron-down"
      />
      <.tool_button
        click={"duplicate_#{@kind}"}
        index={@index}
        label={duplicate_label(@kind)}
        icon="hero-document-duplicate"
      />
      <.tool_button
        click={"remove_#{@kind}"}
        index={@index}
        label={remove_label(@kind)}
        icon="hero-trash"
        danger
      />
    </div>
    """
  end

  attr :click, :string, required: true
  attr :index, :integer, required: true
  attr :dir, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :danger, :boolean, default: false

  defp tool_button(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "flex size-7 cursor-pointer items-center justify-center text-muted transition-colors",
        "disabled:cursor-not-allowed disabled:opacity-40",
        if(@danger,
          do: "hover:bg-error/10 hover:text-error",
          else: "hover:bg-base-200 hover:text-base-content"
        )
      ]}
      phx-click={@click}
      phx-value-index={@index}
      phx-value-dir={@dir}
      disabled={@disabled}
      aria-label={@label}
    >
      <.icon name={@icon} class="size-3.5" />
    </button>
    """
  end

  defp move_up_label("condition"), do: gettext("Move this condition up")
  defp move_up_label("action"), do: gettext("Move this action up")
  defp move_down_label("condition"), do: gettext("Move this condition down")
  defp move_down_label("action"), do: gettext("Move this action down")
  defp duplicate_label("condition"), do: gettext("Duplicate this condition")
  defp duplicate_label("action"), do: gettext("Duplicate this action")
  defp remove_label("condition"), do: gettext("Remove this condition")
  defp remove_label("action"), do: gettext("Remove this action")

  attr :name, :string, required: true
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :type, :atom, required: true
  attr :value, :any, default: nil
  attr :min, :integer, default: nil
  attr :required, :boolean, default: false

  defp action_param_input(%{type: :text} = assigns) do
    ~H"""
    <.input
      type="textarea"
      id={@id}
      name={@name}
      value={@value}
      label={@label}
      rows="2"
      required={@required}
      no_margin
    />
    """
  end

  defp action_param_input(%{type: :integer} = assigns) do
    ~H"""
    <.input
      type="number"
      id={@id}
      name={@name}
      value={@value}
      label={@label}
      min={@min}
      required={@required}
      no_margin
      class="sm:max-w-48"
    />
    """
  end

  defp action_param_input(assigns) do
    ~H"""
    <.input
      type="text"
      id={@id}
      name={@name}
      value={@value}
      label={@label}
      required={@required}
      no_margin
    />
    """
  end

  @doc """
  The placeholder palette. Each chip is a button that inserts its
  placeholder into the message field that was focused last, at the cursor —
  the hook keeps track of which field that was.
  """
  def placeholders(assigns) do
    assigns = assign(assigns, :placeholders, Template.known_placeholders())

    ~H"""
    <div
      id="rule-placeholders"
      phx-hook=".PlaceholderInsert"
      class="rounded-box border border-base-300 bg-base-200/60 p-3"
    >
      <p class="eyebrow mb-1 text-muted">
        {gettext("Placeholders you can use in messages")}
      </p>

      <p class="mb-2 text-xs text-muted">
        {gettext("Click one to insert it into the message field you were editing.")}
      </p>

      <div class="flex flex-wrap gap-1">
        <button
          :for={placeholder <- @placeholders}
          type="button"
          class="cursor-pointer rounded-selector border border-base-300 bg-base-100 px-1.5 py-0.5 font-mono text-xs text-base-content/80 transition-colors hover:border-primary/50 hover:text-primary"
          data-placeholder={placeholder_text(placeholder)}
        >
          {placeholder_text(placeholder)}
        </button>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".PlaceholderInsert">
        export default {
          mounted() {
            this.onFocus = (e) => {
              const el = e.target
              if (el.matches("#rule-form textarea, #rule-form input[type=text]")) {
                this.target = el
              }
            }
            document.addEventListener("focusin", this.onFocus)

            this.el.addEventListener("click", (e) => {
              const chip = e.target.closest("[data-placeholder]")
              if (!chip || !this.target || !document.contains(this.target)) return
              const text = chip.dataset.placeholder
              const start = this.target.selectionStart ?? this.target.value.length
              const end = this.target.selectionEnd ?? start
              this.target.setRangeText(text, start, end, "end")
              this.target.focus()
              // Let LiveView see the change as if it had been typed.
              this.target.dispatchEvent(new Event("input", {bubbles: true}))
            })
          },
          destroyed() {
            document.removeEventListener("focusin", this.onFocus)
          }
        }
      </script>
    </div>
    """
  end

  defp placeholder_text(placeholder), do: "{" <> placeholder <> "}"

  # ── The rule, in words ─────────────────────────────────────────────────────

  @doc """
  The live plain-language reading of the rule as currently typed.
  """
  attr :rule, :map, required: true
  attr :game, :atom, required: true
  attr :servers, :list, required: true

  def rule_summary(assigns) do
    ~H"""
    <.card title={gettext("In plain words")} icon="hero-document-text">
      <div class="space-y-2.5 text-sm">
        <div>
          <p class="eyebrow text-muted">{gettext("When")}</p>

          <p>{Labels.trigger(@rule.trigger_event)}</p>
        </div>

        <div>
          <p class="eyebrow text-muted">{gettext("If")}</p>

          <p :if={@rule.conditions == []} class="text-muted">
            {gettext("no conditions yet")}
          </p>

          <ul class="space-y-1">
            <li
              :for={{condition, index} <- Enum.with_index(@rule.conditions)}
              class="flex flex-wrap items-baseline gap-x-1.5"
            >
              <span :if={index > 0} class="text-xs text-muted">
                {Labels.logical_joiner(@rule.logical_operator)}
              </span>
              <span>{condition_sentence(condition, @game)}</span>
            </li>
          </ul>

          <p
            :if={@rule.logical_operator in [:nand, :nor] and @rule.conditions != []}
            class="mt-1 text-xs text-warning"
          >
            {Labels.logical_operator(@rule.logical_operator)}
          </p>
        </div>

        <div>
          <p class="eyebrow text-muted">{gettext("Then")}</p>

          <p :if={@rule.actions == []} class="text-muted">
            {gettext("no actions yet")}
          </p>

          <ul class="space-y-1">
            <li :for={action <- @rule.actions} class="flex items-center gap-1.5">
              <.icon
                name={Icons.action(action.type)}
                class={["size-3.5 shrink-0", Icons.text(Icons.action_tone(action.type))]}
              />
              <span>{Labels.action(action.type)}</span>
            </li>
          </ul>
        </div>
      </div>

      <div class="flex flex-wrap gap-1 border-t border-base-300 pt-3">
        <.tone_badge tone="ghost">{Labels.game(@game)}</.tone_badge>
        <.tone_badge tone="ghost">{scope_label(@rule, @servers)}</.tone_badge>
        <.tone_badge :if={@rule.simulation} tone="warning">{gettext("Simulation")}</.tone_badge>
        <.tone_badge :if={not @rule.enabled} tone="ghost">{gettext("Disabled")}</.tone_badge>
      </div>
    </.card>
    """
  end

  # "Kills is at least 5". Values that came from a picker are shown with the
  # label the picker used, so the summary matches what was chosen.
  defp condition_sentence(%{field: :always_true}, _game), do: gettext("always")

  defp condition_sentence(condition, game) do
    value =
      case Labels.value_options(condition.field, game) do
        nil -> condition.value
        options -> option_label(options, condition.value)
      end

    "#{Labels.field(condition.field)} #{Labels.operator(condition.operator)} #{present(value)}"
  end

  defp option_label(options, value) do
    Enum.find_value(options, value, fn {label, option} -> option == value && label end)
  end

  defp present(value) when value in [nil, ""], do: gettext("(empty)")
  defp present(value), do: value

  defp scope_label(%{server_id: nil}, _servers), do: gettext("Every server")

  defp scope_label(%{server_id: id}, servers) do
    case Enum.find(servers, &(&1.id == id)) do
      nil -> gettext("Every server")
      server -> server.name
    end
  end

  # ── Try it ─────────────────────────────────────────────────────────────────

  @doc """
  The dry-run panel: pick a server, pick a connected player, see which
  conditions hold. Nothing is ever sent to the game from here.
  """
  attr :servers, :list, required: true
  attr :game, :atom, required: true
  attr :test_server_id, :any, default: nil
  attr :test_players, :list, default: []
  attr :test_loading?, :boolean, default: false
  attr :test_result, :any, default: nil
  attr :test_error, :any, default: nil
  attr :test_player_name, :string, default: nil

  def test_panel(assigns) do
    ~H"""
    <.card
      title={gettext("Try it")}
      icon="hero-play-circle"
      subtitle={
        gettext(
          "Evaluates the rule as typed here, including unsaved changes, against a player connected right now. Nothing is sent to the game."
        )
      }
    >
      <form phx-change="load_test_players" id="test-server-picker">
        <label>
          <span class="sr-only">{gettext("Pick a server")}</span>
          <select name="server_id" class="pc-text-input w-full">
            <option value="">{gettext("Pick a server")}</option>

            <option
              :for={server <- Enum.filter(@servers, &(&1.game == @game))}
              value={server.id}
              selected={@test_server_id == to_string(server.id)}
            >
              {server.name}
            </option>
          </select>
        </label>
      </form>

      <.skeleton :if={@test_loading?} lines={2} />

      <form :if={@test_players != []} phx-change="run_test" id="test-player-picker">
        <label>
          <span class="sr-only">{gettext("Pick a player")}</span>
          <select name="player_id" class="pc-text-input w-full">
            <option value="">{gettext("Pick a player")}</option>

            <option :for={{name, id} <- @test_players} value={id}>{name}</option>
          </select>
        </label>
      </form>

      <.alert :if={@test_error} color="warning" variant="soft" with_icon label={@test_error} />
      <.test_result :if={@test_result} result={@test_result} player={@test_player_name} />
    </.card>
    """
  end

  attr :result, :map, required: true
  attr :player, :string, default: nil

  defp test_result(assigns) do
    ~H"""
    <div class="space-y-2" aria-live="polite">
      <.alert
        color={if @result.result, do: "success", else: "info"}
        variant="soft"
        with_icon
        label={
          if @result.result,
            do: gettext("This rule would fire for %{player}.", player: @player),
            else: gettext("This rule would not fire for %{player}.", player: @player)
        }
      />

      <ul class="divide-y divide-base-300 text-xs">
        <li :for={condition <- @result.conditions} class="flex items-start gap-2 py-1.5">
          <.icon
            name={if condition.result, do: "hero-check", else: "hero-x-mark"}
            class={[
              "mt-0.5 size-3.5 shrink-0",
              if(condition.result, do: "text-success", else: "text-error")
            ]}
          />
          <div class="min-w-0 flex-1">
            <p class="leading-tight">
              {Labels.field(condition.field)}
              <span class="text-muted">{Labels.operator(condition.operator)}</span>
              <span class="font-mono">{condition.expected}</span>
            </p>

            <p class="text-muted">
              {gettext("actual")}: <span class="font-mono">{format_actual(condition.actual)}</span>
            </p>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  defp format_actual(nil), do: "-"
  defp format_actual(value) when is_list(value), do: Enum.join(value, ", ")
  defp format_actual(true), do: "true"
  defp format_actual(false), do: "false"
  defp format_actual(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_actual(value), do: to_string(value)

  # ── Shared helpers ─────────────────────────────────────────────────────────

  # Select inputs post strings; convert to the atom the catalog uses, without
  # ever calling String.to_atom/1 on user input.
  defp existing_field(value) do
    Enum.find(Catalog.fields(), :always_true, &(to_string(&1) == value))
  end

  defp existing_operator(value) do
    Enum.find(Catalog.operators(), :equal, &(to_string(&1) == value))
  end

  defp existing_action(value) do
    Enum.find(Catalog.action_types(), :message_player, &(to_string(&1) == value))
  end

  defp current_parameters(action_form) do
    case Phoenix.HTML.Form.input_value(action_form, :parameters) do
      parameters when is_map(parameters) -> parameters
      _other -> %{}
    end
  end

  defp parameter_value(parameters, key, opts) do
    case Map.get(parameters, to_string(key)) do
      nil -> opts[:default]
      value -> value
    end
  end

  defp action_errors(action_form) do
    for {:parameters, {message, _opts}} <- action_form.errors, do: message
  end

  # A boolean field takes no picker from the catalog, but "Yes/No" beats
  # asking somebody to type `true`.
  defp value_options(:always_true, _game), do: nil

  defp value_options(field, game) do
    case Labels.value_options(field, game) do
      nil -> if Catalog.field_type(field) == :boolean, do: Labels.boolean_options()
      options -> options
    end
  end

  # A list operator takes "a, b, c", which a number input refuses to hold.
  defp numeric_value?(field, operator) do
    Catalog.field_type(field) in [:integer, :float] and not Catalog.list_operator?(operator)
  end
end
