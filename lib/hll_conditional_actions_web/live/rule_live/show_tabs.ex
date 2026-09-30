defmodule HllConditionalActionsWeb.RuleLive.ShowTabs do
  @moduledoc """
  The definition and versions tabs of the rule page
  (`HllConditionalActionsWeb.RuleLive.Show`), which owns their data and
  events: the rule as an expression and as JSON, and any two versions
  compared as a sentence and line by line.
  """

  use HllConditionalActionsWeb, :html

  import HllConditionalActionsWeb.RuleComponents

  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActions.Rules.Expression
  alias HllConditionalActions.Rules.Snapshot
  alias HllConditionalActionsWeb.ConditionGroupsView
  alias HllConditionalActionsWeb.RuleDiff

  # ── Definition ─────────────────────────────────────────────────────────────

  @doc """
  The definition tab: the rule's *when* and *if* edited as an expression (or
  read as a sentence in the visual mode), the fields and operators it may
  use, its actions, and the rule as JSON.
  """
  attr :rule, :map, required: true
  attr :shown, :map, required: true, doc: "the rule as it reads now: the draft over the rule"
  attr :mode, :string, required: true
  attr :expression, :string, required: true
  attr :parsed, :any, required: true
  attr :can_edit, :boolean, required: true
  attr :json, :any, default: nil
  attr :json_errors, :list, default: []
  attr :fields_open, :boolean, default: false
  attr :chips, :list, default: []
  attr :export, :string, default: nil, doc: "the export JSON, computed once by the page"
  attr :version, :integer, default: nil
  attr :zone, :string, default: "Etc/UTC"

  def definition_tab(assigns) do
    assigns =
      assigns
      |> assign(:lines, String.split(assigns.expression, "\n"))
      |> assign(:export, assigns.export || export_json(assigns.rule))

    ~H"""
    <div
      id="rule-definition"
      class="grid items-start gap-5 xl:grid-cols-[minmax(0,1fr)_29.375rem]"
    >
      <div class="flex min-w-0 flex-col gap-5">
        <section
          aria-label={gettext("Expression editor")}
          class="flex min-w-0 flex-col overflow-hidden rounded-[1.75rem] bg-base-100"
        >
          <div class="flex flex-wrap items-center gap-3 border-b border-base-300 px-5 py-4">
            <div
              role="radiogroup"
              aria-label={gettext("Edit mode")}
              class="flex gap-1 rounded-full border border-base-300 bg-secondary p-1"
            >
              <button
                :for={
                  {value, label} <- [
                    {"visual", gettext("Visual")},
                    {"expression", gettext("Expression")}
                  ]
                }
                id={"rule-mode-#{value}"}
                type="button"
                role="radio"
                aria-checked={to_string(@mode == value)}
                phx-click="definition_mode"
                phx-value-mode={value}
                class={[
                  "h-[2.125rem] cursor-pointer rounded-full px-4 text-[0.8125rem] transition-colors",
                  if(@mode == value,
                    do: "bg-base-content font-semibold text-base-100",
                    else: "text-subtle hover:text-base-content"
                  )
                ]}
              >
                {label}
              </button>
            </div>
            <span class="text-[0.8125rem] text-muted">
              {if @mode == "expression",
                do: gettext("When and If, by hand"),
                else: gettext("The rule as a sentence")}
            </span>
            <span class="grow"></span>
            <button
              :if={@mode == "expression"}
              id="rule-expression-format"
              type="button"
              phx-click="expression_format"
              class="h-[2.125rem] cursor-pointer rounded-full px-3 text-[0.8125rem] text-subtle transition-colors hover:text-base-content"
            >
              {gettext("Format")}
            </button>
            <button
              :if={@mode == "expression" and @can_edit}
              id="rule-expression-apply"
              type="button"
              phx-click="expression_apply"
              disabled={not match?({:ok, _attrs}, @parsed)}
              class="h-[2.125rem] cursor-pointer rounded-full border border-base-300 bg-secondary px-3.5 text-[0.8125rem] transition-colors hover:bg-base-200 disabled:cursor-not-allowed disabled:opacity-50"
            >
              {if HllConditionalActions.Rules.draft_required?(@rule),
                do: gettext("Apply to the draft"),
                else: gettext("Apply")}
            </button>
            <.link
              :if={@mode == "visual" and @can_edit}
              navigate={~p"/rules/#{@rule}/edit"}
              class="h-[2.125rem] rounded-full border border-base-300 bg-secondary px-3.5 text-[0.8125rem] leading-[2.125rem] transition-colors hover:bg-base-200"
            >
              {gettext("Open in the builder")}
            </.link>
          </div>

          <%!-- Expression: a textarea over its own highlighted copy. --%>
          <form
            :if={@mode == "expression"}
            id="rule-expression-form"
            phx-change="expression_change"
            phx-submit="expression_apply"
            class="bg-base-200/60 py-3.5"
          >
            <div class="grid grid-cols-[3.25rem_minmax(0,1fr)] overflow-x-auto">
              <ol class="rules-code select-none text-muted" aria-hidden="true">
                <li
                  :for={{_line, index} <- Enum.with_index(@lines, 1)}
                  class={[
                    "pl-5",
                    error_line(@parsed) == index && "bg-error/10 text-error"
                  ]}
                >
                  {index}
                </li>
              </ol>
              <div class="relative min-w-0">
                <pre class="rules-code pointer-events-none whitespace-pre pr-5" aria-hidden="true"><span
                    :for={{line, index} <- Enum.with_index(@lines, 1)}
                    class={["block min-h-[1.6875rem]", error_line(@parsed) == index && "bg-error/10"]}
                  ><span :for={{class, text} <- Expression.highlight(line)} class={token_class(class)}>{text}</span></span></pre>
                <label for="rule-expression-text" class="sr-only">{gettext(
                  "The rule as an expression"
                )}</label>
                <textarea
                  id="rule-expression-text"
                  name="expression"
                  rows={length(@lines)}
                  spellcheck="false"
                  autocomplete="off"
                  phx-debounce="250"
                  phx-hook=".ExpressionCursor"
                  class="rules-code rules-code-input absolute inset-0 block w-full border-0 p-0 pr-5"
                >{@expression}</textarea>
              </div>
            </div>
          </form>

          <div
            :if={@mode == "expression"}
            id="rule-expression-status"
            class={[
              "flex flex-wrap items-center gap-2.5 border-t px-5 py-3",
              if(match?({:ok, _attrs}, @parsed),
                do: "border-primary/25 bg-primary/7",
                else: "border-error/30 bg-error/8"
              )
            ]}
          >
            <span class={[
              "flex size-[1.375rem] shrink-0 items-center justify-center rounded-[0.4375rem]",
              if(match?({:ok, _attrs}, @parsed),
                do: "bg-primary text-primary-content",
                else: "bg-error text-error-content"
              )
            ]}>
              <.icon
                name={if match?({:ok, _attrs}, @parsed), do: "hero-check", else: "hero-x-mark"}
                class="size-3.5"
              />
            </span>
            <span class="min-w-0 flex-1 text-sm">
              <%= case @parsed do %>
                <% {:ok, attrs} -> %>
                  <strong class="font-semibold">{gettext("Valid expression")}</strong>
                  <span class="text-subtle">
                    · {expression_stats(attrs)} · {if same_as_visual?(attrs, @shown),
                      do: gettext("same as the visual mode"),
                      else: gettext("differs from the visual mode")}
                  </span>
                <% {:error, error} -> %>
                  <strong class="font-semibold text-error">{gettext("Invalid expression")}</strong>
                  <span class="text-subtle">· {error_text(error)}</span>
              <% end %>
            </span>
            <span id="rule-expression-cursor" class="font-mono text-xs text-muted" phx-update="ignore">
              {gettext("line %{line}, col %{col}", line: 1, col: 1)}
            </span>
          </div>

          <div :if={@mode == "visual"} class="flex flex-col gap-5 px-5 py-6 sm:px-7">
            <.rule_sentence_chips
              id="rule-definition-sentence"
              rule={@shown}
              class="text-lg leading-[1.8]"
            />
            <dl class="flex flex-col divide-y divide-base-300 text-[0.8125rem]">
              <div
                :for={{label, value} <- settings_rows(@shown)}
                class="flex justify-between gap-3 py-2"
              >
                <dt class="text-muted">{label}</dt>
                <dd class="text-right">{value}</dd>
              </div>
            </dl>
          </div>
        </section>

        <section
          :if={@mode == "expression"}
          aria-label={gettext("Fields and operators")}
          class="flex flex-col gap-2.5 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-[1.125rem]"
        >
          <div class="flex flex-wrap items-baseline gap-2">
            <h2 class="flex-1 font-display text-lg font-semibold">
              {gettext("Fields and operators")}
            </h2>
            <span class="text-xs text-muted">{gettext("click a field to copy its name")}</span>
          </div>
          <div class="flex flex-wrap gap-1.5">
            <button
              :for={{name, type} <- if(@fields_open, do: all_field_chips(), else: @chips)}
              type="button"
              phx-hook=".CopyText"
              id={"rule-field-#{String.replace(name, ".", "-")}"}
              data-copy={name}
              class="cursor-pointer rounded-[0.625rem] bg-secondary px-2.5 py-[5px] font-mono text-xs rules-teal transition-colors hover:bg-base-200"
            >
              {name} <span class="text-muted">{type_label(type)}</span>
            </button>
            <button
              type="button"
              phx-click="toggle_fields"
              class="cursor-pointer rounded-[0.625rem] border border-dashed border-base-300 px-2.5 py-[5px] text-xs text-subtle hover:text-base-content"
            >
              {if @fields_open,
                do: gettext("Show fewer"),
                else:
                  gettext("+ %{count} fields in %{groups} groups",
                    count: length(all_field_chips()) - length(@chips),
                    groups: length(Expression.field_names())
                  )}
            </button>
          </div>
          <div class="flex flex-wrap items-center gap-1.5">
            <span class="mr-1 text-xs text-muted">{gettext("Operators")}</span>
            <span
              :for={operator <- Expression.operator_names()}
              class="rounded-lg bg-accent/10 px-2 py-1 font-mono text-xs text-accent"
            >
              {operator}
            </span>
          </div>
        </section>

        <section
          aria-label={gettext("Actions")}
          class="flex flex-col gap-3 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-[1.125rem]"
        >
          <div class="flex flex-wrap items-baseline gap-2">
            <h2 class="flex-1 font-display text-lg font-semibold">{gettext("Then")}</h2>
            <.link
              :if={@can_edit}
              navigate={~p"/rules/#{@rule}/edit"}
              class="text-[0.8125rem] text-primary"
            >
              {gettext("Edit the actions in the visual mode")}
            </.link>
          </div>
          <div class="flex flex-wrap items-center gap-2 text-sm">
            <span class="text-subtle">{actions_lead(@shown)}</span>
            <span
              :for={{action, index} <- Enum.with_index(@shown.actions, 1)}
              class="flex h-8 items-center gap-1.5 rounded-[0.625rem] bg-secondary px-3"
            >
              <span class="font-mono text-xs text-muted">{index}</span>
              {short_action_text(action)}
            </span>
            <span :if={protections(@shown) != ""} class="text-[0.8125rem] text-muted">
              · {protections(@shown)}
            </span>
          </div>
        </section>

        <HllConditionalActionsWeb.RuleLive.ShowTabs.json_editor
          :if={@json}
          rule={@rule}
          json={@json}
          errors={@json_errors}
        />
      </div>

      <section
        id="rule-export"
        aria-label={gettext("Export as JSON")}
        class="flex min-w-0 flex-col overflow-hidden rounded-[1.75rem] bg-base-100"
      >
        <div class="flex flex-wrap items-center gap-2.5 border-b border-base-300 px-5 py-4">
          <div class="flex min-w-0 flex-1 flex-col gap-0.5">
            <h2 class="font-display text-lg font-semibold">{gettext("Export as JSON")}</h2>
            <span class="text-xs text-muted">
              {if @version, do: "v#{@version} · ", else: ""}{gettext(
                "import it into another panel under Rules, Import"
              )}
            </span>
          </div>

          <button
            id="rule-json-copy"
            type="button"
            phx-hook=".CopyText"
            data-copy={@export}
            data-copied={gettext("Copied")}
            class="flex h-[2.375rem] cursor-pointer items-center gap-1.5 rounded-full border border-base-300 bg-secondary pr-3.5 pl-3 text-[0.8125rem] transition-colors hover:bg-base-200"
          >
            <.icon name="hero-document-duplicate" class="size-4" />
            <span data-label>{gettext("Copy")}</span>
          </button>
          <a
            href={"/rules/export?" <> URI.encode_query(ids: @rule.id)}
            download
            aria-label={gettext("Download the JSON file")}
            class="flex size-[2.375rem] items-center justify-center rounded-full border border-base-300 bg-secondary transition-colors hover:bg-base-200"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" />
          </a>
        </div>
        <pre class="max-h-[42rem] overflow-auto whitespace-pre-wrap bg-base-200/60 px-5 py-3.5 font-mono text-xs leading-[1.1875rem] text-subtle [overflow-wrap:anywhere]"><span
            :for={{class, text} <- json_tokens(@export)}
            class={json_class(class)}
          >{text}</span></pre>
        <div class="flex flex-wrap items-center gap-3 border-t border-base-300 px-5 py-3">
          <p class="min-w-0 flex-1 text-xs leading-normal text-muted">
            {gettext(
              "No CRCON keys or addresses. Imported rules always arrive switched off, as a draft to read over."
            )}
          </p>
          <button
            :if={@can_edit and is_nil(@json)}
            id="rule-json-open"
            type="button"
            phx-click="json_open"
            class="flex shrink-0 cursor-pointer items-center gap-1.5 text-xs text-primary hover:underline"
          >
            <.icon name="hero-code-bracket" class="size-3.5" /> {gettext("Edit as JSON")}
          </button>
        </div>
      </section>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ExpressionCursor">
        export default {
          mounted() {
            const out = document.getElementById("rule-expression-cursor")
            const update = () => {
              const before = this.el.value.slice(0, this.el.selectionStart)
              const lines = before.split("\n")
              const label = out.dataset.template || out.textContent
              out.dataset.template = label
              out.textContent = label.replace(/\d+/, lines.length).replace(/(\D+\d+\D+)\d+/, "$1" + (lines[lines.length - 1].length + 1))
            }
            this.el.addEventListener("keyup", update)
            this.el.addEventListener("click", update)
            this.el.addEventListener("input", () => {
              this.el.rows = this.el.value.split("\n").length
            })
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyText">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              navigator.clipboard?.writeText(this.el.dataset.copy || "")
              const label = this.el.querySelector("[data-label]")
              if (label && this.el.dataset.copied) {
                const before = label.textContent
                label.textContent = this.el.dataset.copied
                setTimeout(() => (label.textContent = before), 1500)
              }
            })
          }
        }
      </script>
    </div>
    """
  end

  attr :rule, :map, required: true
  attr :json, :string, required: true
  attr :errors, :list, required: true

  def json_editor(assigns) do
    ~H"""
    <section
      id="rule-json"
      class="flex flex-col gap-3 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-[1.125rem]"
    >
      <div class="flex flex-col gap-0.5">
        <h2 class="font-display text-lg font-semibold">{gettext("Edit as JSON")}</h2>
        <p class="text-[0.8125rem] text-muted">
          {gettext(
            "Checked as you type with the same rules as the builder. The server and the enabled switch are not part of the text."
          )}
        </p>
      </div>
      <form
        id="rule-json-form"
        phx-change="json_validate"
        phx-submit="json_save"
        class="flex flex-col gap-3"
      >
        <label for="rule-json-text" class="sr-only">{gettext("Rule as JSON")}</label>
        <textarea
          id="rule-json-text"
          name="json"
          rows="20"
          spellcheck="false"
          phx-debounce="400"
          class="pc-text-input w-full rounded-2xl font-mono text-xs"
        >{@json}</textarea>
        <p
          :if={@errors == []}
          id="rule-json-ok"
          class="flex items-center gap-2 text-[0.8125rem] text-primary"
        >
          <.icon name="hero-check-circle" class="size-4" /> {gettext("Valid")}
        </p>
        <ul :if={@errors != []} id="rule-json-errors" class="flex flex-col gap-1">
          <li
            :for={{path, message} <- @errors}
            class="rounded-xl bg-error/10 px-3 py-1.5 text-xs text-error"
          >
            <code :if={path} class="font-mono">{path}</code>
            {message}
          </li>
        </ul>
        <div class="flex flex-wrap gap-2">
          <.button
            type="button"
            size="sm"
            variant="outline"
            color="gray"
            phx-click="json_close"
            label={gettext("Cancel")}
          />
          <.button
            :if={HllConditionalActions.Rules.draft_required?(@rule)}
            id="rule-json-draft"
            type="submit"
            size="sm"
            variant="outline"
            color="primary"
            name="intent"
            value="draft"
            label={gettext("Save draft")}
          />
          <.button
            :if={HllConditionalActions.Rules.draft_required?(@rule)}
            id="rule-json-publish"
            type="submit"
            size="sm"
            color="primary"
            name="intent"
            value="publish"
            label={gettext("Publish")}
          />
          <.button
            :if={not HllConditionalActions.Rules.draft_required?(@rule)}
            id="rule-json-save"
            type="submit"
            size="sm"
            color="primary"
            label={gettext("Save rule")}
          />
        </div>
      </form>
    </section>
    """
  end

  defp error_line({:error, {_reason, line, _col}}), do: line
  defp error_line(_parsed), do: nil

  defp token_class(:comment), do: "text-muted italic"
  defp token_class(:field), do: "rules-teal"
  defp token_class(:keyword), do: "text-accent"
  defp token_class(:operator), do: "text-accent"
  defp token_class(:string), do: "text-warning"
  defp token_class(:number), do: "text-axis"
  defp token_class(:bool), do: "text-accent"
  defp token_class(:punct), do: "text-subtle"
  defp token_class(:error), do: "text-error underline decoration-wavy"
  defp token_class(_space), do: nil

  defp expression_stats(attrs) do
    stats = Expression.stats(attrs)

    Enum.join(
      [
        gettext("1 trigger"),
        ngettext("1 group", "%{count} groups", stats.groups),
        ngettext("1 condition", "%{count} conditions", stats.conditions)
      ],
      ", "
    )
  end

  defp same_as_visual?(attrs, shown) do
    visual =
      shown.conditions
      |> Enum.reject(&(&1.field == :always_true))
      |> Enum.map(&{to_string(&1.field), to_string(&1.operator), to_string(&1.value)})

    parsed =
      attrs.conditions
      |> Enum.reject(&(&1["field"] == "always_true"))
      |> Enum.map(&{&1["field"], &1["operator"], &1["value"]})

    attrs.trigger_event == shown.trigger_event and Map.get(attrs, :game, shown.game) == shown.game and
      visual == parsed and
      (parsed == [] or length(parsed) == 1 or attrs.logical_operator == shown.logical_operator)
  end

  @doc "What went wrong in an expression, in words."
  @spec error_text(tuple()) :: String.t()
  def error_text({reason, line, col}) do
    error_message(reason) <> " · " <> gettext("line %{line}, col %{col}", line: line, col: col)
  end

  defp error_message(:missing_trigger),
    do: gettext("say which event it listens to: event.type eq \"…\"")

  defp error_message(:two_triggers), do: gettext("a rule listens to one event only")
  defp error_message(:two_games), do: gettext("the game is said twice")

  defp error_message(:mixed),
    do: gettext("a group joins its conditions with and or with or, not both")

  defp error_message(:unclosed), do: gettext("a parenthesis or bracket is not closed")
  defp error_message(:unclosed_string), do: gettext("a text is missing its closing quote")
  defp error_message(:unexpected_end), do: gettext("the expression ends too early")
  defp error_message({:unexpected, text}), do: gettext("did not expect “%{text}”", text: text)

  defp error_message({:expected_and, text}),
    do: gettext("expected and before “%{text}”", text: text)

  defp error_message({:unknown_field, text}),
    do: gettext("there is no field called %{name}", name: text)

  defp error_message({:unknown_operator, text}),
    do: gettext("there is no operator called %{name}", name: text)

  defp error_message({:operator_not_for_field, text}),
    do: gettext("%{name} does not work with this field", name: text)

  defp error_message({:expected_value, text}),
    do: gettext("expected a value, found “%{text}”", text: text)

  defp error_message({:unknown_trigger, text}),
    do: gettext("there is no event called %{name}", name: text)

  defp error_message({:unknown_game, text}),
    do: gettext("the game is hll or hllv, not %{name}", name: text)

  defp error_message({:invalid, message}), do: message
  defp error_message(_other), do: gettext("the expression cannot be read")

  defp all_field_chips do
    for {_group, fields} <- Expression.field_names(), field <- fields, do: field
  end

  @doc "The fields worth showing first: the ones the rules use most."
  @spec top_field_chips() :: [{String.t(), atom()}]
  def top_field_chips do
    8
    |> HllConditionalActions.Rules.most_used_fields()
    |> Enum.map(&{Expression.field_name(&1), Catalog.field_type(&1)})
  end

  defp type_label(:boolean), do: gettext("yes/no")
  defp type_label(:list), do: gettext("list")
  defp type_label(type) when type in [:integer, :float], do: gettext("number")
  defp type_label(_string), do: gettext("text")

  defp actions_lead(rule) do
    cond do
      rule.escalation_window_seconds > 0 and length(rule.actions) > 1 ->
        gettext("ladder of %{count} in %{window}:",
          count: length(rule.actions),
          window: duration_text(rule.escalation_window_seconds)
        )

      rule.actions == [] ->
        gettext("no actions yet")

      true ->
        gettext("in order:")
    end
  end

  defp protections(rule) do
    exempt = HllConditionalActionsWeb.RuleBuilder.exemptions_text(rule.exemptions)

    [
      rule.cooldown_seconds > 0 &&
        gettext("cooldown %{time}", time: duration_text(rule.cooldown_seconds)),
      rule.max_executions_per_player > 0 &&
        gettext("up to %{count} per player in 24 h", count: rule.max_executions_per_player),
      exempt && gettext("never: %{who}", who: exempt)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp settings_rows(rule) do
    [
      {gettext("Trigger"), Labels.trigger(rule.trigger_event)},
      {gettext("Applies to"), scope_text(rule)},
      {gettext("Folder"), if(rule.group in [nil, ""], do: "—", else: rule.group)},
      {gettext("Priority"), rule.priority},
      {gettext("How conditions combine"), Labels.logical_operator(rule.logical_operator)},
      {gettext("Cooldown per player"),
       if(rule.cooldown_seconds > 0,
         do: duration_text(rule.cooldown_seconds),
         else: gettext("none")
       )},
      {gettext("Maximum times per player per day"),
       if(rule.max_executions_per_player > 0,
         do: rule.max_executions_per_player,
         else: gettext("none")
       )},
      {gettext("Simulation"), if(rule.simulation, do: gettext("yes"), else: gettext("no"))}
    ]
  end

  @export_order ~w(
    name description group game trigger_event trigger_interval_seconds
    logical_operator conditions actions escalation_window_seconds
    cooldown_seconds max_executions_per_player exemptions priority
    simulation enabled
  )

  @doc "The published rule as the JSON an export carries."
  @spec export_json(map()) :: String.t()
  def export_json(rule) do
    dumped = HllConditionalActions.Rules.Transfer.dump_rule(rule)

    # Read top to bottom like the rule: who it is, when, if, then, limits.
    ordered = for key <- @export_order, Map.has_key?(dumped, key), do: {key, dumped[key]}
    others = dumped |> Map.drop(@export_order) |> Enum.sort()

    Jason.encode!(Jason.OrderedObject.new(ordered ++ others), pretty: true)
  end

  # Pretty JSON as `{class, text}` pieces for highlighting.
  defp json_tokens(json) do
    ~r/("(?:\\.|[^"\\])*")(\s*:)?|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|(true|false|null)|([^"\d\-tfn]+|.)/
    |> Regex.scan(json)
    |> Enum.flat_map(fn
      [_all, string, colon | _rest] when string != "" and colon != "" ->
        [{:key, string}, {:punct, colon}]

      [_all, string | _rest] when string != "" ->
        [{:string, string}]

      [_all, "", "", number | _rest] when number != "" ->
        [{:number, number}]

      [_all, "", "", "", literal | _rest] when literal != "" ->
        [{:literal, literal}]

      [all | _rest] ->
        [{:punct, all}]
    end)
  end

  defp json_class(:key), do: "text-allies"
  defp json_class(:string), do: "text-warning"
  defp json_class(:number), do: "text-axis"
  defp json_class(:literal), do: "text-accent"
  defp json_class(_punct), do: nil

  # ── Versions ───────────────────────────────────────────────────────────────

  @doc """
  The versions tab: every recorded change on the left; on the right the two
  chosen versions compared as a sentence and line by line, and how each
  would have answered the week's real events.
  """
  attr :rows, :list, required: true, doc: "newest first: %{version, number, previous}"
  attr :older, :map, default: nil
  attr :newer, :map, required: true
  attr :servers, :list, required: true
  attr :rule, :map, required: true
  attr :can_edit, :boolean, required: true
  attr :only_changes, :boolean, default: false
  attr :replay, :map, default: nil
  attr :zone, :string, default: "Etc/UTC"

  def versions_tab(assigns) do
    before_lines =
      RuleDiff.field_lines(assigns.older && assigns.older.version.snapshot, assigns.servers)

    after_lines = RuleDiff.field_lines(assigns.newer.version.snapshot, assigns.servers)
    aligned = RuleDiff.align(before_lines, after_lines)
    changed = Enum.count(aligned, &elem(&1, 2))

    assigns =
      assigns
      |> assign(
        :aligned,
        if(assigns.only_changes, do: Enum.filter(aligned, &elem(&1, 2)), else: aligned)
      )
      |> assign(:changed, changed)
      |> assign(:same, length(aligned) - changed)
      |> assign(:older_rule, snapshot_rule(assigns.rule, assigns.older))
      |> assign(:newer_rule, snapshot_rule(assigns.rule, assigns.newer))
      |> assign(:latest, List.first(assigns.rows))

    ~H"""
    <div id="rule-versions" class="grid items-start gap-5 lg:grid-cols-[22.5rem_minmax(0,1fr)]">
      <section
        aria-label={gettext("Version history")}
        class="flex flex-col gap-1.5 rounded-[1.75rem] bg-base-100 px-4 py-5 lg:self-stretch"
      >
        <div class="flex items-baseline gap-2 px-2 pb-2">
          <h2 class="flex-1 font-display text-xl font-semibold">
            {ngettext("1 version", "%{count} versions", length(@rows))}
          </h2>
          <span class="text-xs text-muted">{gettext("every change")}</span>
        </div>

        <button
          :for={row <- @rows}
          id={"version-row-#{row.version.id}"}
          type="button"
          phx-click="pick_version"
          phx-value-id={row.version.id}
          aria-pressed={to_string(row.version.id in [@newer.version.id, @older && @older.version.id])}
          class={[
            "grid cursor-pointer grid-cols-[2.75rem_minmax(0,1fr)] items-start gap-3 rounded-[1.125rem] border p-3 text-left transition-colors",
            cond do
              row.version.id == @newer.version.id -> "border-primary/45 bg-primary/7"
              @older && row.version.id == @older.version.id -> "border-error/45 bg-error/6"
              true -> "border-transparent hover:bg-secondary/60"
            end
          ]}
        >
          <span class={[
            "flex size-11 items-center justify-center rounded-[0.875rem] font-mono text-sm",
            cond do
              row.version.id == @newer.version.id ->
                "bg-primary font-medium text-primary-content"

              @older && row.version.id == @older.version.id ->
                "border border-base-300 bg-secondary font-medium"

              true ->
                "bg-secondary text-subtle"
            end
          ]}>
            v{row.number}
          </span>
          <span class="flex min-w-0 flex-col gap-[3px]">
            <strong class="text-sm font-semibold">{RuleDiff.title(row.version, row.previous)}</strong>
            <span class={[
              "text-xs",
              if(row.version.id in [@newer.version.id, @older && @older.version.id],
                do: "text-subtle",
                else: "text-muted"
              )
            ]}>
              {row.version.user_name || gettext("the system")} · {version_when(
                row.version.inserted_at,
                @zone
              )}
            </span>
            <span
              :if={
                row.version.id == @latest.version.id or row.version.id == @newer.version.id or
                  (@older && row.version.id == @older.version.id)
              }
              class="flex gap-1.5"
            >
              <span
                :if={row.version.id == @latest.version.id}
                class="rounded-full bg-primary px-2 py-0.5 text-[0.6875rem] font-semibold text-primary-content"
              >
                {gettext("current")}
              </span>
              <span
                :if={row.version.id == @newer.version.id}
                class="rounded-full bg-primary/12 px-2 py-0.5 text-[0.6875rem] font-semibold text-primary"
              >
                {gettext("after")}
              </span>
              <span
                :if={@older && row.version.id == @older.version.id}
                class="rounded-full bg-error/14 px-2 py-0.5 text-[0.6875rem] font-semibold text-error"
              >
                {gettext("before")}
              </span>
            </span>
          </span>
        </button>

        <p class="mt-auto px-2 pt-3 text-xs leading-normal text-muted">
          {gettext(
            "Click two versions to compare them. Restoring loads the chosen one as a draft to publish; nothing is deleted."
          )}
        </p>
      </section>

      <section
        id="version-diff"
        aria-label={gettext("Differences")}
        class="flex min-w-0 flex-col rounded-[1.75rem] bg-base-100"
      >
        <form
          id="version-compare"
          phx-change="compare_versions"
          class="flex flex-wrap items-center gap-3 border-b border-base-300 px-6 py-[1.125rem]"
        >
          <div class="flex items-center gap-2">
            <label class="relative">
              <span class="sr-only">{gettext("Before")}</span>
              <select
                name="before"
                class="h-9 cursor-pointer appearance-none rounded-xl border border-error/45 bg-error/8 py-0 pr-8 pl-3 font-mono text-[0.8125rem] text-error focus:ring-0"
              >
                <option
                  :for={row <- @rows}
                  value={row.version.id}
                  selected={@older && row.version.id == @older.version.id}
                >
                  v{row.number}
                </option>
              </select>
              <.icon
                name="hero-chevron-down"
                class="pointer-events-none absolute top-1/2 right-2.5 size-3.5 -translate-y-1/2 text-error"
              />
            </label>
            <.icon name="hero-arrow-right" class="size-4 text-muted" />
            <label class="relative">
              <span class="sr-only">{gettext("After")}</span>
              <select
                name="after"
                class="h-9 cursor-pointer appearance-none rounded-xl border border-primary/45 bg-primary/8 py-0 pr-8 pl-3 font-mono text-[0.8125rem] text-primary focus:ring-0"
              >
                <option
                  :for={row <- @rows}
                  value={row.version.id}
                  selected={row.version.id == @newer.version.id}
                >
                  v{row.number}
                </option>
              </select>
              <.icon
                name="hero-chevron-down"
                class="pointer-events-none absolute top-1/2 right-2.5 size-3.5 -translate-y-1/2 text-primary"
              />
            </label>
          </div>
          <span class="text-[0.8125rem] text-subtle">
            {ngettext("1 field changed", "%{count} fields changed", @changed)} · {ngettext(
              "1 the same",
              "%{count} the same",
              @same
            )}
          </span>
          <span class="grow"></span>
          <label class="flex cursor-pointer items-center gap-2 text-[0.8125rem] text-subtle">
            <input
              type="checkbox"
              name="only_changes"
              value="true"
              checked={@only_changes}
              class="pc-checkbox size-4"
            />
            {gettext("Only what changed")}
          </label>
          <button
            :if={@newer.version.id != @latest.version.id}
            type="button"
            phx-click="compare_with_current"
            class="h-10 cursor-pointer rounded-full border border-base-300 bg-secondary px-4 text-[0.8125rem] font-medium transition-colors hover:bg-base-200"
          >
            {gettext("Compare with the current one")}
          </button>
          <button
            :if={@older != nil and is_map(@older.version.snapshot) and @can_edit}
            id={"version-restore-#{@older.version.id}"}
            type="button"
            phx-click="restore_version"
            phx-value-id={@older.version.id}
            data-confirm={
              gettext("Load this version as a draft? Nothing changes until you publish it.")
            }
            class="flex h-10 cursor-pointer items-center gap-2 rounded-full border border-base-300 bg-secondary pr-4 pl-3 text-[0.8125rem] font-medium transition-colors hover:bg-base-200"
          >
            <.icon name="hero-arrow-uturn-left" class="size-4" />
            {gettext("Restore v%{number}", number: @older.number)}
          </button>
        </form>

        <div class="flex flex-col gap-4 px-6 pt-[1.125rem] pb-[1.375rem]">
          <div :if={@older_rule && @newer_rule} class="flex flex-col gap-2">
            <.caption>{gettext("The sentence")}</.caption>
            <div class="grid gap-3 md:grid-cols-2">
              <.diff_sentence rule={@older_rule} other={@newer_rule} side={:before} />
              <.diff_sentence rule={@newer_rule} other={@older_rule} side={:after} />
            </div>
          </div>

          <div class="flex min-w-0 flex-col gap-2">
            <.caption>{gettext("Fields")}</.caption>
            <p :if={is_nil(@newer.version.snapshot)} class="text-[0.8125rem] text-muted">
              {gettext(
                "This change was recorded before whole versions were kept; only its fields are known."
              )}
            </p>
            <div
              :if={is_map(@newer.version.snapshot)}
              class="grid overflow-hidden rounded-2xl border border-base-300 bg-base-200/60 font-mono text-[0.78125rem] md:grid-cols-2"
            >
              <div class="flex min-w-0 flex-col md:border-r md:border-base-300">
                <.diff_line
                  :for={{left, _right, changed} <- @aligned}
                  line={left}
                  changed={changed}
                  side={:before}
                />
              </div>
              <div class="flex min-w-0 flex-col max-md:border-t max-md:border-base-300">
                <.diff_line
                  :for={{_left, right, changed} <- @aligned}
                  line={right}
                  changed={changed}
                  side={:after}
                />
              </div>
            </div>
          </div>

          <div
            :if={@replay && @older}
            id="version-replay"
            class="flex flex-wrap items-center gap-3 rounded-2xl bg-accent/8 px-4 py-3 ring-1 ring-accent/25"
          >
            <.icon name="hero-clock" class="size-4 shrink-0 text-accent" />
            <span class="min-w-0 flex-1 text-[0.8125rem] text-base-content/90">
              {replay_text(@replay, @older.number, @newer.number)}
            </span>
            <.link
              :if={@can_edit}
              navigate={~p"/rules/#{@rule}/edit"}
              class="text-[0.8125rem] text-accent hover:underline"
            >
              {gettext("See the replay")}
            </.link>
          </div>
        </div>
      </section>
    </div>
    """
  end

  attr :rule, :map, required: true
  attr :other, :map, required: true
  attr :side, :atom, required: true

  defp diff_sentence(assigns) do
    other_parts = sentence_parts(assigns.other)
    other_chips = for {:chip, text} <- other_parts, into: MapSet.new(), do: text
    other_lists = for {:list, entry} <- other_parts, into: %{}, do: {entry.key, entry}
    parts = sentence_parts(assigns.rule)

    # A folded list is compared by its values; its popover shows what the
    # newer version added (tinted) and dropped (struck).
    lists =
      for {:list, entry} <- parts do
        other = Map.get(other_lists, entry.key)
        {before, now} = if assigns.side == :after, do: {other, entry}, else: {entry, other}

        %{
          entry: entry,
          # The popover reads as the newer version's list.
          title_entry: now || before,
          id: "version-#{assigns.side}-list-#{entry.number}",
          same?: other != nil and other.values == entry.values and other.counts == entry.counts,
          delta: ConditionGroupsView.delta_text(before, now),
          items: ConditionGroupsView.diff_items(before, now)
        }
      end

    assigns =
      assigns
      |> assign(:parts, parts)
      |> assign(:other_chips, other_chips)
      |> assign(:lists, Map.new(lists, &{&1.entry.key, &1}))

    ~H"""
    <div class="min-w-0">
      <%!-- No whitespace between the pieces: the sentence carries its own. --%>
      <p class="rounded-2xl bg-secondary px-4 py-3.5 text-[0.9375rem] leading-[1.75] text-subtle [text-wrap:pretty]">
        <.diff_piece
          :for={part <- @parts}
          part={part}
          lists={@lists}
          other_chips={@other_chips}
          side={@side}
        />
      </p>
      <ConditionGroupsView.value_list
        :for={list <- Map.values(@lists)}
        id={list.id}
        entry={list.title_entry}
        items={list.items}
        note={list.delta}
      />
    </div>
    """
  end

  attr :part, :any, required: true
  attr :lists, :map, required: true
  attr :other_chips, :any, required: true
  attr :side, :atom, required: true

  defp diff_piece(%{part: {:list, entry}} = assigns) do
    assigns = assign(assigns, :list, assigns.lists[entry.key])

    ~H"""
    <ConditionGroupsView.list_chip
      entry={@list.entry}
      popover={@list.id}
      mark={if @list.same?, do: nil, else: @side}
      badge={if @side == :after, do: @list.delta}
    />
    """
  end

  defp diff_piece(%{part: {kind, text}} = assigns) do
    mark =
      cond do
        kind != :chip -> nil
        MapSet.member?(assigns.other_chips, text) -> :same
        true -> assigns.side
      end

    assigns = assign(assigns, kind: kind, text: text, mark: mark)

    ~H"""
    <.sentence_bit kind={@kind} text={@text} mark={@mark} />
    """
  end

  attr :kind, :atom, required: true
  attr :text, :string, required: true
  attr :mark, :atom, default: nil

  defp sentence_bit(%{mark: :before} = assigns),
    do:
      ~H'<del class="rounded-md bg-error/14 px-1.5 py-0.5 text-error decoration-error/60">{@text}</del>'

  defp sentence_bit(%{mark: :after} = assigns),
    do:
      ~H'<ins class="rounded-md bg-primary/14 px-1.5 py-0.5 text-primary no-underline">{@text}</ins>'

  defp sentence_bit(%{mark: :same} = assigns),
    do: ~H'<span class="text-base-content">{@text}</span>'

  defp sentence_bit(assigns), do: ~H"{@text}"

  attr :line, :any, required: true
  attr :changed, :boolean, required: true
  attr :side, :atom, required: true

  defp diff_line(assigns) do
    ~H"""
    <div class={[
      "grid h-[1.875rem] grid-cols-[2.25rem_1rem_minmax(0,1fr)] items-center",
      cond do
        @changed and @side == :before and @line -> "bg-error/14 text-error"
        @changed and @side == :after and @line -> "bg-primary/12 text-primary"
        true -> "text-subtle"
      end
    ]}>
      <%= if @line do %>
        <span class={["pl-3", !@changed && "text-muted"]}>{elem(@line, 0)}</span>
        <span>{if @changed, do: if(@side == :before, do: "−", else: "+")}</span>
        <span class="truncate pr-3">
          <span class={if(@changed, do: "opacity-80", else: "text-muted")}>{elem(@line, 1)}:</span>
          {RuleDiff.line_text(elem(@line, 2))}
        </span>
      <% else %>
        <span class="col-span-3"></span>
      <% end %>
    </div>
    """
  end

  defp snapshot_rule(_rule, nil), do: nil

  defp snapshot_rule(rule, %{version: %{snapshot: snapshot}}) when is_map(snapshot),
    do: Snapshot.to_rule(rule, snapshot)

  defp snapshot_rule(_rule, _row), do: nil

  defp version_when(at, zone) do
    local = local(DateTime.from_naive!(to_naive(at), "Etc/UTC"), zone)
    today = DateTime.utc_now() |> local(zone) |> DateTime.to_date()
    date = DateTime.to_date(local)
    time = Calendar.strftime(local, "%H:%M")

    cond do
      date == today -> gettext("today, %{time}", time: time)
      date == Date.add(today, -1) -> gettext("yesterday, %{time}", time: time)
      true -> "#{weekday_short(date)}, #{day_month(date)}, #{time}"
    end
  end

  defp to_naive(%DateTime{} = at), do: DateTime.to_naive(at)
  defp to_naive(%NaiveDateTime{} = at), do: at

  defp replay_text(%{events: 0}, _before, _after),
    do:
      gettext(
        "No real event of this trigger was kept in the last 7 days to replay both versions against."
      )

  defp replay_text(replay, before, now) do
    difference = replay.after.fires - replay.before.fires

    comparison =
      cond do
        difference > 0 ->
          ngettext("1 time more than", "%{count} times more than", difference)

        difference < 0 ->
          ngettext("1 time less than", "%{count} times less than", -difference)

        true ->
          gettext("as often as")
      end

    gettext(
      "In the 7-day replay (%{events} real events), v%{after} would fire %{comparison} v%{before}: %{after_fires} times for %{after_players} players, against %{before_fires} for %{before_players}.",
      events: replay.events,
      after: now,
      before: before,
      comparison: comparison,
      after_fires: replay.after.fires,
      after_players: replay.after.players,
      before_fires: replay.before.fires,
      before_players: replay.before.players
    )
  end
end
