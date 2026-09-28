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

  alias HllConditionalActions.Crcon.GameText
  alias HllConditionalActions.Engine.Template
  alias HllConditionalActions.Games.Weapons
  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActions.Rules.Condition
  alias HllConditionalActions.Rules.Exemptions
  alias HllConditionalActionsWeb.DiscordComponents
  alias Phoenix.HTML.Form

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
          checked={Form.normalize_value("checkbox", @field.value)}
          class="peer sr-only"
        /> <span class="pc-switch__fake-input pc-switch__fake-input--sm"></span>
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

  The value control follows the field's type: a switch for yes/no fields,
  a number box for numbers, chips for "is one of", a live tester for
  patterns, and player autocomplete for ids and names.
  """
  attr :condition, :any, required: true
  attr :trigger, :atom, required: true
  attr :game, :atom, required: true
  attr :total, :integer, required: true
  attr :popular, :list, default: [], doc: "the most used fields, shown first in the picker"

  def condition_row(assigns) do
    field = Form.input_value(assigns.condition, :field) || :always_true
    field = if is_binary(field), do: existing_field(field), else: field
    operator = Form.input_value(assigns.condition, :operator)
    operator = if is_binary(operator), do: existing_operator(operator), else: operator
    boolean? = field != :always_true and Catalog.field_type(field) == :boolean

    assigns =
      assigns
      |> assign(:field, field)
      |> assign(:value_options, value_options(field, assigns.game))
      |> assign(:numeric?, numeric_value?(field, operator))
      |> assign(:list?, Catalog.list_operator?(operator))
      |> assign(:boolean?, boolean?)
      |> assign(:regex?, operator == :regex_match)
      |> assign(:free_text?, field != :always_true)
      |> assign(:players_list, player_datalist(field))
      # A weapon compared for equality or membership is picked from the
      # known list; "contains" and friends stay free text, for names the
      # list does not have (Vietnam's, a weapon added after this release).
      |> assign(
        :weapon_pick?,
        field == :weapon and assigns.game == :hll and
          operator in [nil, :equal, :not_equal, :in_list, :not_in_list]
      )

    ~H"""
    <div class="condition-grid rounded-box border border-base-300 bg-base-200/50 p-2.5">
      <.field_picker
        field={@condition[:field]}
        current={@field}
        trigger={@trigger}
        popular={@popular}
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

      <.boolean_toggle :if={@boolean?} field={@condition[:value]} />
      <.input
        :if={@free_text? and not @boolean? and @value_options != nil and not @list?}
        field={@condition[:value]}
        type="select"
        options={@value_options}
        label={gettext("Value")}
        label_class="lg:sr-only"
        no_margin
      />
      <.option_group
        :if={@free_text? and not @boolean? and @value_options != nil and @list?}
        field={@condition[:value]}
        options={@value_options}
      />
      <.input
        :if={@weapon_pick? and not @list?}
        field={@condition[:value]}
        type="select"
        prompt={gettext("Pick a weapon")}
        options={weapon_options()}
        label={gettext("Value")}
        label_class="lg:sr-only"
        no_margin
      /> <.weapon_picker :if={@weapon_pick? and @list?} field={@condition[:value]} />
      <.weapon_types_help :if={@field in [:weapon, :weapon_type] and @game == :hll} />
      <.input
        :if={@free_text? and is_nil(@value_options) and @numeric? and not @weapon_pick?}
        field={@condition[:value]}
        type="number"
        step={if Catalog.field_type(@field) == :integer, do: "1", else: "any"}
        placeholder={gettext("Value")}
        label={gettext("Value")}
        label_class="lg:sr-only"
        no_margin
      />
      <.chip_input
        :if={@free_text? and is_nil(@value_options) and @list? and not @weapon_pick?}
        field={@condition[:value]}
        label={gettext("Values")}
        placeholder={gettext("Type a value, then Enter")}
        list={@players_list}
        numeric={Catalog.field_type(@field) in [:integer, :float]}
      />
      <.input
        :if={
          @free_text? and is_nil(@value_options) and not @numeric? and not @list? and
            not @weapon_pick?
        }
        field={@condition[:value]}
        type="text"
        placeholder={if @regex?, do: gettext("A pattern, such as ^ABC"), else: gettext("Value")}
        label={gettext("Value")}
        label_class="lg:sr-only"
        list={@players_list}
        autocomplete="off"
        no_margin
      />
      <div class="flex items-end justify-end">
        <.row_tools kind="condition" index={@condition.index} total={@total} />
      </div>
      <.regex_tester :if={@regex?} condition={@condition} />
    </div>
    """
  end

  # The fields whose values are players this install has already seen.
  defp player_datalist(:player_id), do: "known-player-ids"

  defp player_datalist(field) when field in [:player_name, :target_player_name],
    do: "known-player-names"

  defp player_datalist(_field), do: nil

  @doc """
  The datalists behind player autocomplete: ids (labelled with the name)
  and names. Rendered once per page; inputs point at them with `list`.
  """
  attr :players, :list, required: true, doc: "`{player_id, player_name}` pairs"

  def player_datalists(assigns) do
    assigns = assign(assigns, :names, assigns.players |> Enum.map(&elem(&1, 1)) |> Enum.uniq())

    ~H"""
    <datalist id="known-player-ids">
      <option :for={{id, name} <- @players} value={id}>{name}</option>
    </datalist>
    <datalist id="known-player-names">
      <option :for={name <- @names} value={name}></option>
    </datalist>
    """
  end

  # The searchable field picker: a combobox in place of a 70-option select.
  # The hidden input is what the form posts; the text box only searches.
  attr :field, Phoenix.HTML.FormField, required: true
  attr :current, :atom, required: true
  attr :trigger, :atom, required: true
  attr :popular, :list, default: []

  defp field_picker(assigns) do
    allowed = Catalog.fields_for_trigger(assigns.trigger)

    groups =
      for group <- Catalog.field_groups(),
          fields = Enum.filter(Catalog.fields_in_group(group), &(&1 in allowed)),
          fields != [],
          do: {to_string(group), Labels.field_group(group), fields}

    popular = Enum.filter(assigns.popular, &(&1 in allowed))

    groups =
      if popular == [],
        do: groups,
        else: [{"popular", gettext("Most used"), popular} | groups]

    assigns =
      assign(assigns,
        groups: groups,
        allowed: allowed,
        listbox_id: "#{assigns.field.id}-listbox",
        label: Labels.field(assigns.current)
      )

    ~H"""
    <div
      id={"#{@field.id}-picker"}
      class="relative"
      x-data="fieldCombobox"
      x-on:click.outside="close()"
    >
      <label for={"#{@field.id}-search"} class="pc-label lg:sr-only">{gettext("Field")}</label>
      <%!-- The control the form posts: a real select, kept out of sight and
            out of the tab order, so the picker can only ever post a field
            this trigger allows. --%>
      <select
        id={@field.id}
        name={@field.name}
        class="hidden"
        tabindex="-1"
        aria-hidden="true"
        x-ref="value"
      >
        <option :for={field <- @allowed} value={field} selected={field == @current}>
          {Labels.field(field)}
        </option>
      </select>
      <div class="relative">
        <.icon
          name="hero-magnifying-glass"
          class="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted"
        />
        <input
          type="text"
          id={"#{@field.id}-search"}
          role="combobox"
          aria-autocomplete="list"
          aria-controls={@listbox_id}
          x-bind:aria-expanded="isOpen ? 'true' : 'false'"
          x-bind:aria-activedescendant="activeId"
          autocomplete="off"
          spellcheck="false"
          value={@label}
          data-label={@label}
          placeholder={gettext("Search fields")}
          class="pc-text-input w-full pl-8"
          x-ref="search"
          x-on:focus="open()"
          x-on:click="open()"
          x-on:input.stop="filter($event.target.value)"
          x-on:change.stop=""
          x-on:keydown.arrow-down.prevent="move(1)"
          x-on:keydown.arrow-up.prevent="move(-1)"
          x-on:keydown.enter.prevent="choose()"
          x-on:keydown.escape.prevent.stop="close()"
          x-on:keydown.tab="close()"
        />
      </div>

      <ul
        id={@listbox_id}
        role="listbox"
        aria-label={gettext("Fields")}
        x-show="isOpen"
        x-cloak
        class="absolute z-40 mt-1 max-h-80 w-full min-w-72 overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 shadow-lg"
      >
        <li :for={{key, title, fields} <- @groups} role="presentation" data-group={key}>
          <p class="px-2 pt-2 pb-1 text-[0.625rem] font-semibold tracking-wide text-muted uppercase">
            {title}
          </p>

          <ul role="group" aria-label={title}>
            <li
              :for={field <- fields}
              id={"#{@field.id}-option-#{key}-#{field}"}
              role="option"
              aria-selected="false"
              data-value={field}
              data-label={Labels.field(field)}
              data-search={search_text(field, title)}
              class={[
                "cursor-pointer rounded-field px-2 py-1.5 aria-selected:bg-primary/10",
                field == @current && "font-medium text-primary"
              ]}
              x-on:mousedown.prevent="pick($el)"
              x-on:mousemove="activate($el)"
            >
              <span class="block text-sm leading-tight">{Labels.field(field)}</span>
              <span class="block text-xs text-muted">{Labels.field_description(field)}</span>
            </li>
          </ul>
        </li>
        <li
          role="presentation"
          data-empty
          hidden
          class="px-2 py-3 text-center text-sm text-muted"
        >
          {gettext("No field matches that search.")}
        </li>
      </ul>
    </div>
    """
  end

  # Folded the same way the picker folds what is typed (see rule_builder.js),
  # so "nivel" finds "Nível" on a keyboard without dead keys.
  defp search_text(field, group_title) do
    [Labels.field(field), Labels.field_description(field), group_title, to_string(field)]
    |> Enum.join(" ")
    |> fold()
  end

  @doc """
  Lower case without accents, for matching what someone types against a
  label. The builder's client side search folds the query the same way.

      iex> HllConditionalActionsWeb.RuleBuilder.fold("Nível do Jogador")
      "nivel do jogador"
  """
  @spec fold(String.t()) :: String.t()
  def fold(text) do
    text
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
  end

  # A yes/no condition value as a switch. The hidden "false" is overridden by
  # the checkbox when it is on, the same trick Phoenix's checkbox uses.
  attr :field, Phoenix.HTML.FormField, required: true

  defp boolean_toggle(assigns) do
    assigns = assign(assigns, :on?, Form.normalize_value("checkbox", assigns.field.value))

    ~H"""
    <label class="flex h-10 cursor-pointer items-center gap-2 text-sm">
      <input type="hidden" name={@field.name} value="false" />
      <span class="pc-switch pc-switch--sm shrink-0">
        <input
          type="checkbox"
          id={@field.id}
          name={@field.name}
          value="true"
          checked={@on?}
          class="peer sr-only"
        /> <span class="pc-switch__fake-input pc-switch__fake-input--sm"></span>
        <span class="pc-switch__fake-input-bg pc-switch__fake-input-bg--sm"></span>
      </span>
      <span>{if @on?, do: gettext("Yes"), else: gettext("No")}</span>
    </label>
    """
  end

  @doc """
  Chips over one comma separated value, for lists typed by hand ("is one
  of", exempt flags, exempt players). The chips are drawn from the value;
  Alpine only edits the hidden input.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :placeholder, :string, default: nil
  attr :list, :string, default: nil, doc: "a datalist id for suggestions"
  attr :numeric, :boolean, default: false
  attr :label_class, :string, default: "lg:sr-only"

  def chip_input(assigns) do
    assigns =
      assign(assigns,
        chosen: assigns.field.value |> list_value() |> Enum.uniq(),
        errors: Enum.map(assigns.field.errors, &translate_error/1)
      )

    ~H"""
    <div id={"#{@field.id}-chips"} x-data="chipInput" class="min-w-0">
      <label for={"#{@field.id}-entry"} class={["pc-label", @label_class]}>{@label}</label>
      <input
        type="hidden"
        id={@field.id}
        name={@field.name}
        value={Enum.join(@chosen, ",")}
        x-ref="value"
      />
      <div class={[
        "flex min-h-10 flex-wrap items-center gap-1 rounded-field border bg-base-100 px-1.5 py-1 focus-within:border-primary",
        if(@errors == [], do: "border-base-300", else: "border-error")
      ]}>
        <span
          :for={value <- @chosen}
          class="inline-flex items-center gap-0.5 rounded-pill bg-primary/10 py-0.5 pr-0.5 pl-2 text-xs text-primary"
        >
          {value}
          <button
            type="button"
            class="flex size-4 cursor-pointer items-center justify-center rounded-full hover:bg-primary/20"
            aria-label={gettext("Remove %{value}", value: value)}
            x-on:click={"remove(#{Jason.encode!(value)})"}
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </span>
        <input
          type="text"
          id={"#{@field.id}-entry"}
          list={@list}
          inputmode={if @numeric, do: "decimal"}
          autocomplete="off"
          placeholder={if @chosen == [], do: @placeholder}
          class="min-w-24 flex-1 border-0 bg-transparent px-1 py-0.5 text-sm focus:ring-0 focus:outline-none"
          x-ref="entry"
          x-on:input.stop=""
          x-on:change.stop="add()"
          x-on:keydown.enter.prevent="add()"
          x-on:keydown.comma.prevent="add()"
          x-on:keydown.backspace="backspace()"
        />
      </div>

      <p :for={error <- @errors} class="mt-1 text-xs text-error">{error}</p>
    </div>
    """
  end

  defp list_value(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp list_value(value), do: chosen_values(value)

  # The pattern run against text the admin types, the way the engine will
  # run it, so "does this catch [ABC] Ana?" is answered before saving.
  attr :condition, :any, required: true

  defp regex_tester(assigns) do
    pattern = Form.input_value(assigns.condition, :value)
    sample = Form.input_value(assigns.condition, :sample)
    blank? = pattern in [nil, ""]

    assigns =
      assign(assigns,
        sample: sample,
        verdict:
          if(blank? or sample in [nil, ""], do: nil, else: Condition.test_regex(pattern, sample)),
        invalid: if(blank?, do: nil, else: invalid_regex(pattern))
      )

    ~H"""
    <div class="col-span-full space-y-1.5 rounded-field bg-base-100 p-2">
      <label for={@condition[:sample].id} class="text-xs font-medium text-subtle">
        {gettext("Try the pattern on some text")}
      </label>
      <div class="flex items-center gap-2">
        <input
          type="text"
          id={@condition[:sample].id}
          name={@condition[:sample].name}
          value={@sample}
          autocomplete="off"
          placeholder={gettext("A player name or a chat line")}
          class="pc-text-input w-full font-mono text-sm"
        />
        <span
          :if={@verdict}
          id={"#{@condition[:sample].id}-verdict"}
          data-match={match?({:ok, true}, @verdict)}
          aria-live="polite"
          class={[
            "inline-flex shrink-0 items-center gap-1 rounded-pill px-2 py-0.5 text-xs font-medium",
            verdict_class(@verdict)
          ]}
        >
          <.icon name={verdict_icon(@verdict)} class="size-3.5" />{verdict_label(@verdict)}
        </span>
      </div>
      <p :if={@invalid} class="flex items-center gap-1 text-xs text-error">
        <.icon name="hero-exclamation-circle" class="size-3.5 shrink-0" />
        {gettext("This pattern is not valid: %{reason}", reason: @invalid)}
      </p>
    </div>
    """
  end

  defp verdict_class({:ok, true}), do: "bg-success/15 text-success"
  defp verdict_class({:ok, false}), do: "bg-base-200 text-muted"
  defp verdict_class(_error), do: "bg-error/15 text-error"

  defp verdict_icon({:ok, true}), do: "hero-check"
  defp verdict_icon({:ok, false}), do: "hero-x-mark"
  defp verdict_icon(_error), do: "hero-exclamation-circle"

  defp verdict_label({:ok, true}), do: gettext("Matches")
  defp verdict_label({:ok, false}), do: gettext("No match")
  defp verdict_label(_error), do: gettext("Invalid pattern")

  defp invalid_regex(pattern) do
    case Condition.test_regex(pattern, "") do
      {:error, reason} -> reason
      {:ok, _matched} -> nil
    end
  end

  # A group of values for "is one of" / "is none of" on a field with known
  # options - several weapon types, roles or teams at once. The condition
  # still stores one comma separated value; the chips only edit it. The
  # hidden input is the one the form posts, and each click fires `input` on
  # it so the form's phx-change sees the new group.
  attr :field, Phoenix.HTML.FormField, required: true
  attr :options, :list, required: true

  defp option_group(assigns) do
    assigns = assign(assigns, :chosen, chosen_values(assigns.field.value))

    ~H"""
    <fieldset class="lg:col-span-1" id={"#{@field.id}-group"} x-data>
      <legend class="sr-only">{gettext("Values")}</legend>
      <input type="hidden" id={@field.id} name={@field.name} value={Enum.join(@chosen, ",")} />
      <div class="flex flex-wrap gap-1.5">
        <label :for={{label, value} <- @options} class="option-chip">
          <input
            type="checkbox"
            value={value}
            checked={value in @chosen}
            class="peer sr-only"
            x-on:change={"
              const hidden = document.getElementById('#{@field.id}');
              const picked = [...$root.querySelectorAll('input[type=checkbox]:checked')].map(i => i.value);
              hidden.value = picked.join(',');
              hidden.dispatchEvent(new Event('input', {bubbles: true}));
            "}
          /> <span>{label}</span>
        </label>
      </div>

      <p :if={@chosen == []} class="mt-1 text-xs text-muted">{gettext("Pick one or more")}</p>
    </fieldset>
    """
  end

  defp chosen_values(value) when is_binary(value) do
    value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  defp chosen_values(_value), do: []

  defp weapon_options do
    for {category, names} <- Weapons.catalog() do
      {Labels.weapon_type(category), Enum.map(names, &{&1, &1})}
    end
  end

  # Picking several weapons by name: every known weapon, grouped by type,
  # with a search and "all / none" per type. Like `option_group/1`, it only
  # edits the one comma separated value the condition stores.
  attr :field, Phoenix.HTML.FormField, required: true

  defp weapon_picker(assigns) do
    assigns =
      assign(assigns,
        chosen: chosen_values(assigns.field.value),
        catalog: Weapons.catalog()
      )

    ~H"""
    <fieldset
      id={"#{@field.id}-weapons"}
      class="weapon-picker col-span-full"
      x-data={"{
        q: '',
        sync() {
          const hidden = document.getElementById('#{@field.id}');
          hidden.value = [...$root.querySelectorAll('input[type=checkbox]:checked')].map(i => i.value).join(',');
          hidden.dispatchEvent(new Event('input', {bubbles: true}));
        },
        all(group, on) {
          $root.querySelectorAll('[data-group=\"' + group + '\"] input[type=checkbox]').forEach(i => i.checked = on);
          this.sync();
        }
      }"}
    >
      <legend class="sr-only">{gettext("Weapons")}</legend>
      <input type="hidden" id={@field.id} name={@field.name} value={Enum.join(@chosen, ",")} />
      <div class="flex flex-wrap items-center gap-2">
        <label class="relative min-w-48 flex-1">
          <span class="sr-only">{gettext("Find a weapon")}</span>
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted"
          />
          <input
            type="search"
            x-model="q"
            placeholder={gettext("Find a weapon")}
            autocomplete="off"
            class="pc-text-input w-full pl-8"
          />
        </label>

        <span class="text-xs text-muted">
          {ngettext("1 weapon picked", "%{count} weapons picked", length(@chosen))}
        </span>
      </div>

      <div class="mt-2 max-h-80 space-y-1 overflow-y-auto pr-1">
        <details
          :for={{category, names} <- @catalog}
          class="weapon-group"
          data-group={category}
          open={Enum.any?(names, &(&1 in @chosen))}
          data-keep-attrs="open"
          x-show={"!q || #{Jason.encode!(Enum.map(names, &fold/1))}.some(n => n.includes($fold(q)))"}
        >
          <summary class="flex cursor-pointer list-none items-center gap-2 py-1.5 text-sm [&::-webkit-details-marker]:hidden">
            <.icon name="hero-chevron-right" class="weapon-group-chevron size-3.5 text-muted" />
            <span class="font-medium">{Labels.weapon_type(category)}</span>
            <span class="text-xs text-muted">
              {Enum.count(names, &(&1 in @chosen))}/{length(names)}
            </span>

            <span class="ml-auto flex gap-1">
              <button
                type="button"
                class="rounded-pill px-2 py-0.5 text-xs text-primary hover:bg-primary/10"
                x-on:click.prevent={"all('#{category}', true)"}
              >
                {gettext("All")}
              </button>

              <button
                type="button"
                class="rounded-pill px-2 py-0.5 text-xs text-muted hover:bg-base-200"
                x-on:click.prevent={"all('#{category}', false)"}
              >
                {gettext("None")}
              </button>
            </span>
          </summary>

          <div class="flex flex-wrap gap-1.5 pb-2 pl-5">
            <label
              :for={name <- names}
              class="option-chip"
              x-show={"!q || #{Jason.encode!(fold(name))}.includes($fold(q))"}
            >
              <input
                type="checkbox"
                value={name}
                checked={name in @chosen}
                class="peer sr-only"
                x-on:change="sync()"
              /> <span>{name}</span>
            </label>
          </div>
        </details>
      </div>
    </fieldset>
    """
  end

  # "Which weapons are melee?" answered where the question comes up.
  defp weapon_types_help(assigns) do
    assigns = assign(assigns, :catalog, Weapons.catalog())

    ~H"""
    <details class="col-span-full text-xs">
      <summary class="cursor-pointer text-muted hover:text-primary">
        {gettext("Which weapons are in each type?")}
      </summary>

      <dl class="mt-2 grid gap-2 sm:grid-cols-2">
        <div :for={{category, names} <- @catalog} class="rounded-field bg-base-100 p-2">
          <dt class="font-medium">{Labels.weapon_type(category)}</dt>

          <dd class="mt-0.5 text-muted">{Enum.join(names, ", ")}</dd>
        </div>
      </dl>
    </details>
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

  attr :webhooks, :list, default: [], doc: "Discord webhooks as `{name, id}` pairs"
  attr :batch?, :boolean, default: false, doc: "whether the trigger sweeps every player"

  attr :example, :any,
    default: nil,
    doc: "a context to render the messages with, so the admin reads what the player will"

  def action_node(assigns) do
    type = Form.input_value(assigns.action, :type) || :message_player
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

      <DiscordComponents.action_fields
        :if={@type == :send_discord_webhook}
        action={@action}
        parameters={@parameters}
        webhooks={@webhooks}
        batch?={@batch?}
      />
      <div
        :for={{key, param_type, opts} <- @params}
        :if={@type != :send_discord_webhook}
        class="max-w-xl sm:pl-10"
      >
        <.action_param_input
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
        <.message_preview
          :if={param_type == :text and @example}
          id={"#{@action.id}_parameters_#{key}_preview"}
          text={parameter_value(@parameters, key, opts)}
          example={@example}
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

  attr :id, :string, required: true
  attr :text, :any, required: true
  attr :example, :any, required: true

  # The message as the player will read it: placeholders filled in from the
  # latest real event of the trigger, or from an example player.
  defp message_preview(assigns) do
    rendered = preview_text(assigns.text, assigns.example)

    # What the game will actually draw: emoji and fancy symbols are dropped
    # on the way out, so the preview drops them too and says so.
    assigns =
      assign(assigns,
        rendered: GameText.clean(rendered),
        stripped?: GameText.changes?(rendered)
      )

    ~H"""
    <div :if={@rendered != ""} id={@id} class="mt-2">
      <p class="flex items-center gap-1.5 text-xs text-muted">
        <span class="live-dot"></span>
        {if @example.event || @example.gamestate,
          do: gettext("As the player sees it, with the latest real event"),
          else: gettext("As the player sees it, with an example player")}
      </p>
      <p class="message-preview">{@rendered}</p>
      <p :if={@stripped?} class="mt-1 flex items-center gap-1 text-xs text-warning">
        <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0" />
        {gettext("The game cannot show emoji or special symbols: they are removed.")}
      </p>
    </div>
    """
  end

  defp preview_text(text, _example) when text in [nil, ""], do: ""

  defp preview_text(text, example) do
    Template.render(to_string(text), example)
  rescue
    _error -> to_string(text)
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
  attr :key, :atom, default: nil
  attr :template, :boolean, default: false

  defp action_param_input(%{type: :select} = assigns) do
    ~H"""
    <.input
      type="select"
      id={@id}
      name={@name}
      value={@value}
      label={@label}
      options={Labels.action_param_options(@key)}
      no_margin
      class="sm:max-w-48"
    />
    """
  end

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
      data-template={@template}
      no_margin
    />
    """
  end

  @doc """
  The placeholder palette. Each chip is a button that inserts its
  placeholder into the message field that was focused last, at the cursor —
  the hook keeps track of which field that was.

  The same hook opens a menu as soon as `{` is typed in a message field:
  the placeholders this trigger can fill, filtered as the name is typed,
  picked with the arrows and Enter (or Tab), or a click.
  """
  attr :trigger, :atom, default: :player_connected

  def placeholders(assigns) do
    assigns =
      assign(assigns,
        placeholders: Template.placeholders_for(assigns.trigger),
        hint:
          gettext(
            "Click one to insert it into the message field you were editing, or type { in the message to pick one."
          ),
        leaderboard: Template.leaderboard_placeholders() ++ Template.progression_placeholders()
      )

    ~H"""
    <div
      id="rule-placeholders"
      phx-hook=".PlaceholderInsert"
      data-menu-label={gettext("Placeholders")}
      data-empty-label={gettext("No placeholder starts like this")}
      class="rounded-box border border-base-300 bg-base-200/60 p-3"
    >
      <p class="eyebrow mb-1 text-muted">
        {gettext("Placeholders you can use in messages")}
      </p>

      <p class="mb-2 text-xs text-muted">
        {@hint}
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

      <p class="mt-3 mb-1 flex items-center gap-1.5 text-xs font-medium text-subtle">
        <.icon name="hero-trophy" class="size-3.5" />{gettext("Leaderboard, achievements and season")}
      </p>

      <p class="mb-2 text-xs text-muted">
        {gettext(
          "Each ranking lists the top 3, one per line: \"1. Ana (30)\". Add a number to show more or fewer, from 1 to 10: {top_kills:5}. Write the headings yourself, in your server's language."
        )}
      </p>

      <div class="flex flex-wrap gap-1">
        <button
          :for={placeholder <- @leaderboard}
          type="button"
          class="cursor-pointer rounded-selector border border-primary/25 bg-primary/5 px-1.5 py-0.5 font-mono text-xs text-primary transition-colors hover:border-primary/60"
          data-placeholder={placeholder_text(placeholder)}
        >
          {placeholder_text(placeholder)}
        </button>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".PlaceholderInsert">
        const FIELDS = "#rule-form textarea, #rule-form input[type=text][data-template]"
        const PARTIAL = /\{([a-z0-9_]*)$/

        export default {
          mounted() {
            this.onFocus = (e) => {
              if (e.target.matches(FIELDS)) this.target = e.target
            }
            document.addEventListener("focusin", this.onFocus)

            this.el.addEventListener("click", (e) => {
              const chip = e.target.closest("[data-placeholder]")
              if (!chip || !this.target || !document.contains(this.target)) return
              const start = this.target.selectionStart ?? this.target.value.length
              const end = this.target.selectionEnd ?? start
              this.insert(this.target, chip.dataset.placeholder, start, end)
            })

            // The "{" menu: one listbox on <body>, outside anything LiveView
            // patches, positioned under the field being typed in.
            this.menu = document.createElement("ul")
            this.menu.id = "placeholder-menu"
            this.menu.setAttribute("role", "listbox")
            this.menu.setAttribute("aria-label", this.el.dataset.menuLabel)
            this.menu.className = "placeholder-menu"
            this.menu.hidden = true
            document.body.appendChild(this.menu)
            this.menu.addEventListener("mousedown", (e) => {
              const option = e.target.closest("[role=option]")
              if (!option) return
              e.preventDefault()
              this.pick(option.dataset.value)
            })

            this.onInput = (e) => {
              if (e.target.matches(FIELDS)) this.suggest(e.target)
            }
            this.onKeydown = (e) => {
              if (this.menu.hidden || e.target !== this.field) return
              if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                e.preventDefault()
                this.move(e.key === "ArrowDown" ? 1 : -1)
              } else if (e.key === "Enter" || e.key === "Tab") {
                const active = this.options()[this.active]
                if (active) {
                  e.preventDefault()
                  this.pick(active.dataset.value)
                }
              } else if (e.key === "Escape") {
                e.preventDefault()
                this.close()
              }
            }
            this.onBlur = (e) => {
              if (e.target === this.field) this.close()
            }
            document.addEventListener("input", this.onInput)
            document.addEventListener("keydown", this.onKeydown, true)
            document.addEventListener("focusout", this.onBlur)
          },

          names() {
            return [...this.el.querySelectorAll("[data-placeholder]")]
              .map(chip => chip.dataset.placeholder.slice(1, -1))
          },

          options() {
            return [...this.menu.querySelectorAll("[role=option]")]
          },

          suggest(field) {
            const caret = field.selectionStart ?? field.value.length
            const match = field.value.slice(0, caret).match(PARTIAL)
            if (!match) return this.close()
            const partial = match[1]
            const names = this.names().filter(name => name.startsWith(partial))
            this.field = field
            this.from = caret - match[0].length
            this.to = caret
            this.menu.replaceChildren()
            names.forEach((name, index) => {
              const li = document.createElement("li")
              li.id = `placeholder-option-${index}`
              li.setAttribute("role", "option")
              li.dataset.value = name
              li.textContent = `{${name}}`
              this.menu.appendChild(li)
            })
            if (names.length === 0) {
              const li = document.createElement("li")
              li.className = "placeholder-menu-empty"
              li.textContent = this.el.dataset.emptyLabel
              this.menu.appendChild(li)
            }
            const rect = field.getBoundingClientRect()
            this.menu.style.left = `${rect.left + window.scrollX}px`
            this.menu.style.top = `${rect.bottom + window.scrollY + 4}px`
            this.menu.style.minWidth = `${Math.min(rect.width, 320)}px`
            this.menu.hidden = false
            field.setAttribute("aria-controls", this.menu.id)
            field.setAttribute("aria-expanded", "true")
            this.active = 0
            this.highlight()
          },

          move(step) {
            const count = this.options().length
            if (count === 0) return
            this.active = (this.active + step + count) % count
            this.highlight()
          },

          highlight() {
            this.options().forEach((option, index) => {
              const on = index === this.active
              option.setAttribute("aria-selected", on ? "true" : "false")
              if (on) {
                this.field.setAttribute("aria-activedescendant", option.id)
                option.scrollIntoView({block: "nearest"})
              }
            })
          },

          pick(name) {
            if (!this.field) return
            const field = this.field
            this.close()
            this.insert(field, `{${name}}`, this.from, this.to)
          },

          close() {
            this.menu.hidden = true
            if (this.field) {
              this.field.setAttribute("aria-expanded", "false")
              this.field.removeAttribute("aria-activedescendant")
            }
            this.field = null
          },

          insert(field, text, start, end) {
            field.setRangeText(text, start, end, "end")
            field.focus()
            // Let LiveView see the change as if it had been typed.
            field.dispatchEvent(new Event("input", {bubbles: true}))
          },

          destroyed() {
            document.removeEventListener("focusin", this.onFocus)
            document.removeEventListener("input", this.onInput)
            document.removeEventListener("keydown", this.onKeydown, true)
            document.removeEventListener("focusout", this.onBlur)
            this.menu.remove()
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
              /> <span>{Labels.action(action.type)}</span>
            </li>
          </ul>
        </div>

        <div :if={exemptions_text(@rule.exemptions)}>
          <p class="eyebrow text-muted">{gettext("Doesn't apply to")}</p>

          <p>{exemptions_text(@rule.exemptions)}</p>
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

  @doc """
  The whole rule as one plain-language sentence, for lists:
  "When a player connects, if Level is below 10, then Warn."

  Shares the condition wording with `rule_summary/1`, so the list and the
  builder describe a rule the same way.
  """
  @spec rule_sentence(map(), atom() | nil) :: String.t()
  def rule_sentence(rule, game \\ nil) do
    game = game || rule.game

    conditions =
      case rule.conditions do
        [] ->
          gettext("no conditions yet")

        conditions ->
          joiner = " " <> Labels.logical_joiner(rule.logical_operator) <> " "
          Enum.map_join(conditions, joiner, &condition_sentence(&1, game))
      end

    actions =
      case rule.actions do
        [] -> gettext("no actions yet")
        actions -> Enum.map_join(actions, ", ", &Labels.action(&1.type))
      end

    sentence =
      gettext("When %{trigger}, if %{conditions}, then %{actions}.",
        trigger: lower_first(Labels.trigger(rule.trigger_event)),
        conditions: conditions,
        actions: lower_first(actions)
      )

    case exemptions_text(Map.get(rule, :exemptions)) do
      nil -> sentence
      text -> sentence <> " " <> gettext("Doesn't apply to %{who}.", who: text)
    end
  end

  @doc """
  Who a rule leaves alone, in words - "VIPs, players flagged staff, 2 listed
  players" - or `nil` when it applies to everybody.
  """
  @spec exemptions_text(Exemptions.t() | nil) :: String.t() | nil
  def exemptions_text(exemptions) do
    if Exemptions.active?(exemptions) do
      [
        exemptions.exempt_vip && gettext("VIPs"),
        exemptions.exempt_flags != [] &&
          gettext("players flagged %{flags}", flags: Enum.join(exemptions.exempt_flags, ", ")),
        exemptions.exempt_player_ids != [] &&
          ngettext(
            "1 listed player",
            "%{count} listed players",
            length(exemptions.exempt_player_ids)
          )
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(", ")
    end
  end

  defp lower_first(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest
  defp lower_first(text), do: text

  # "Kills is at least 5". Values that came from a picker are shown with the
  # label the picker used, so the summary matches what was chosen.
  @doc """
  One condition in words: "Kills is at least 5".
  """
  @spec condition_sentence(map(), atom() | nil) :: String.t()
  def condition_sentence(%{field: :always_true}, _game), do: gettext("always")

  def condition_sentence(condition, game) do
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
    case Form.input_value(action_form, :parameters) do
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
    for {:parameters, {message, opts}} <- action_form.errors,
        do: translate_error({message, opts})
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
