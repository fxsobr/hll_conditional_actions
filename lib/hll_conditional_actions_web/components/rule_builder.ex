defmodule HllConditionalActionsWeb.RuleBuilder do
  @moduledoc """
  The inputs the rule builder is assembled from, and the rule in words.

  The builder (`RuleLive.Form`, drawn with
  `HllConditionalActionsWeb.BenchComponents`) reads a rule as a sentence;
  this module holds its controls: the condition row with its searchable
  field picker and a value control that follows the field's type (options,
  chips, weapons, a regex tester, player autocomplete), an action's
  parameter inputs and message preview, and the placeholder palette.

  It also words a rule for the pages that list or compare rules:
  `rule_sentence/2`, `conditions_sentence/3`, `condition_sentence/2` and
  `exemptions_text/1`.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.Crcon.GameText
  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Template
  alias HllConditionalActions.Games.Weapons
  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActions.Rules.Condition
  alias HllConditionalActions.Rules.ConditionGroups
  alias HllConditionalActions.Rules.Exemptions
  alias Phoenix.HTML.Form

  # ── Condition rows ─────────────────────────────────────────────────────────

  @doc """
  One condition of a group on the bench: field, comparison and value drawn as
  the board's tiles, the trace chip when a past event is overlaid, and the
  row menu.

  The value control follows the field's type: a yes/no pick for boolean
  fields, a number box for numbers, chips for "is one of", a live tester for
  patterns, and player autocomplete for ids and names.

  `group` and `group_operator` are posted with the row, so the grouping
  survives every change event; see `HllConditionalActions.Rules.ConditionGroups`.
  """
  attr :condition, :any, required: true
  attr :trigger, :atom, required: true
  attr :game, :atom, required: true
  attr :popular, :list, default: [], doc: "the most used fields, shown first in the picker"
  attr :group, :integer, default: 0
  attr :group_operator, :any, default: nil, doc: "posted as a hidden value when set"
  attr :first?, :boolean, default: false
  attr :last?, :boolean, default: false

  attr :trace, :any,
    default: :none,
    doc: "`:none` outside an overlay, else `%{result, actual}` or nil when not evaluated"

  def condition_row(assigns) do
    field = Form.input_value(assigns.condition, :field) || :always_true
    field = if is_binary(field), do: existing_field(field), else: field
    operator = Form.input_value(assigns.condition, :operator)
    operator = if is_binary(operator), do: existing_operator(operator), else: operator

    assigns =
      assigns
      |> assign(:field, field)
      |> assign(:value_options, value_options(field, assigns.game))
      |> assign(:numeric?, numeric_value?(field, operator))
      |> assign(:list?, Catalog.list_operator?(operator))
      |> assign(:regex?, operator == :regex_match)
      |> assign(:free_text?, field != :always_true)
      |> assign(:players_list, player_datalist(field))
      |> assign(:errors, condition_errors(assigns.condition))
      # A weapon compared for equality or membership is picked from the
      # known list; "contains" and friends stay free text, for names the
      # list does not have (Vietnam's, a weapon added after this release).
      |> assign(
        :weapon_pick?,
        field == :weapon and assigns.game == :hll and
          operator in [nil, :equal, :not_equal, :in_list, :not_in_list]
      )

    ~H"""
    <div
      id={"bench-condition-#{@condition.index}"}
      data-trace={trace_state(@trace)}
      class={[
        "grid grid-cols-[minmax(0,1fr)_minmax(0,1fr)_2rem] items-center gap-2",
        if(@trace == :none,
          do: "sm:grid-cols-[minmax(0,1.3fr)_minmax(0,0.8fr)_minmax(0,0.8fr)_2rem]",
          else: "sm:grid-cols-[minmax(0,1.3fr)_minmax(0,0.8fr)_minmax(0,0.8fr)_8.125rem_2rem]"
        )
      ]}
    >
      <input type="hidden" name={@condition[:group].name} value={@group} />
      <input
        :if={@group_operator}
        type="hidden"
        name={@condition[:group_operator].name}
        value={@group_operator}
      />
      <div class="order-1 col-span-2 min-w-0 sm:order-none sm:col-span-1">
        <.field_picker
          field={@condition[:field]}
          current={@field}
          trigger={@trigger}
          popular={@popular}
        />
      </div>
      <label :if={@free_text?} class="order-3 min-w-0 sm:order-none">
        <span class="sr-only">{gettext("Comparison")}</span>
        <select
          id={@condition[:operator].id}
          name={@condition[:operator].name}
          class="bench-tile bench-tile--quiet"
        >
          {Phoenix.HTML.Form.options_for_select(
            Labels.operator_options(@field),
            to_string(Form.input_value(@condition, :operator))
          )}
        </select>
      </label>
      <%!-- "Always" has nothing to compare; the row keeps its columns. --%>
      <span
        :if={not @free_text?}
        class="order-3 col-span-3 text-sm text-muted sm:order-none sm:col-span-2"
      >
        {gettext("this rule has no condition to check")}
      </span>

      <div :if={@free_text?} class="order-4 col-span-2 min-w-0 sm:order-none sm:col-span-1">
        <label :if={@value_options != nil and not @list?} class="block">
          <span class="sr-only">{gettext("Value")}</span>
          <select
            id={@condition[:value].id}
            name={@condition[:value].name}
            class="bench-tile"
            aria-invalid={@errors != [] && "true"}
          >
            {Phoenix.HTML.Form.options_for_select(
              @value_options,
              to_string(Form.input_value(@condition, :value))
            )}
          </select>
        </label>
        <.option_group
          :if={@value_options != nil and @list?}
          field={@condition[:value]}
          options={@value_options}
        />
        <label :if={@weapon_pick? and not @list? and is_nil(@value_options)} class="block">
          <span class="sr-only">{gettext("Value")}</span>
          <select id={@condition[:value].id} name={@condition[:value].name} class="bench-tile">
            <option value="">{gettext("Pick a weapon")}</option>
            {Phoenix.HTML.Form.options_for_select(
              weapon_options(),
              to_string(Form.input_value(@condition, :value))
            )}
          </select>
        </label>
        <label
          :if={is_nil(@value_options) and @numeric? and not @weapon_pick?}
          class="block"
        >
          <span class="sr-only">{gettext("Value")}</span>
          <input
            type="number"
            id={@condition[:value].id}
            name={@condition[:value].name}
            value={Form.input_value(@condition, :value)}
            step={if Catalog.field_type(@field) == :integer, do: "1", else: "any"}
            placeholder={gettext("Value")}
            class="bench-tile"
            aria-invalid={@errors != [] && "true"}
          />
        </label>
        <.chip_input
          :if={is_nil(@value_options) and @list? and not @weapon_pick?}
          field={@condition[:value]}
          label={gettext("Values")}
          label_class="sr-only"
          placeholder={gettext("Type a value, then Enter")}
          list={@players_list}
          numeric={Catalog.field_type(@field) in [:integer, :float]}
        />
        <label
          :if={is_nil(@value_options) and not @numeric? and not @list? and not @weapon_pick?}
          class="block"
        >
          <span class="sr-only">{gettext("Value")}</span>
          <input
            type="text"
            id={@condition[:value].id}
            name={@condition[:value].name}
            value={Form.input_value(@condition, :value)}
            placeholder={if @regex?, do: gettext("A pattern, such as ^ABC"), else: gettext("Value")}
            list={@players_list}
            autocomplete="off"
            class={[
              "bench-tile",
              (@regex? or @field in [:flags, :clan_tag]) && "font-mono text-[0.8125rem]"
            ]}
            aria-invalid={@errors != [] && "true"}
          />
        </label>
      </div>
      <span
        :if={@trace != :none}
        class="bench-trace order-5 col-span-3 justify-self-start sm:order-none sm:col-span-1 sm:justify-self-stretch"
        data-state={trace_state(@trace)}
        title={trace_text(@trace)}
      >
        <span class="min-w-0 truncate">{trace_text(@trace)}</span>
      </span>
      <.condition_menu index={@condition.index} first?={@first?} last?={@last?} />

      <.weapon_picker :if={@weapon_pick? and @list?} field={@condition[:value]} />
      <.weapon_types_help :if={@field in [:weapon, :weapon_type] and @game == :hll} />
      <.regex_tester :if={@regex?} condition={@condition} />
      <p
        :for={message <- @errors}
        class="order-last col-span-full flex items-center gap-1.5 text-[0.8125rem] text-error sm:order-none"
      >
        <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />{message}
      </p>
    </div>
    """
  end

  defp trace_state(:none), do: nil
  defp trace_state(nil), do: "skip"
  defp trace_state(%{result: true}), do: "ok"
  defp trace_state(_failed), do: "fail"

  @doc """
  The words of a trace chip: "✓ read 3", "✗ read “yes”", "– not evaluated".
  """
  @spec trace_text(map() | nil) :: String.t()
  def trace_text(nil), do: "– " <> gettext("not evaluated")

  def trace_text(%{result: result, actual: actual}) do
    mark = if result, do: "✓ ", else: "✗ "

    case actual do
      nil -> mark <> gettext("read nothing")
      [] -> mark <> gettext("no flags")
      value -> mark <> gettext("read %{value}", value: read_value(value))
    end
  end

  defp read_value(true), do: "“" <> gettext("yes") <> "”"
  defp read_value(false), do: "“" <> gettext("no") <> "”"
  defp read_value(value) when is_number(value), do: to_string(value)

  defp read_value(value) when is_list(value),
    do: "“" <> Enum.map_join(value, ", ", &to_string/1) <> "”"

  defp read_value(value), do: "“" <> String.slice(to_string(value), 0, 24) <> "”"

  defp condition_errors(condition) do
    for {_field, {message, opts}} <- condition.errors, do: translate_error({message, opts})
  end

  # The row menu: move within the group, duplicate, remove.
  attr :index, :integer, required: true
  attr :first?, :boolean, default: false
  attr :last?, :boolean, default: false

  defp condition_menu(assigns) do
    ~H"""
    <div
      class="relative order-2 flex justify-end sm:order-none"
      x-data="{ open: false }"
      x-on:click.outside="open = false"
    >
      <button
        type="button"
        class="flex size-8 cursor-pointer items-center justify-center rounded-full text-muted transition-colors hover:bg-secondary hover:text-base-content"
        aria-label={gettext("More for this condition")}
        x-on:click="open = !open"
        x-bind:aria-expanded="open ? 'true' : 'false'"
      >
        <.icon name="hero-ellipsis-horizontal" class="size-4" />
      </button>
      <div
        x-show="open"
        x-cloak
        class="absolute top-9 right-0 z-30 flex w-56 flex-col rounded-2xl border border-base-300 bg-base-100 p-1.5 shadow-lg"
      >
        <.menu_button
          click="move_condition"
          index={@index}
          dir="up"
          disabled={@first?}
          icon="hero-chevron-up"
          label={gettext("Move this condition up")}
        />
        <.menu_button
          click="move_condition"
          index={@index}
          dir="down"
          disabled={@last?}
          icon="hero-chevron-down"
          label={gettext("Move this condition down")}
        />
        <.menu_button
          click="duplicate_condition"
          index={@index}
          icon="hero-document-duplicate"
          label={gettext("Duplicate this condition")}
        />
        <.menu_button
          click="remove_condition"
          index={@index}
          icon="hero-trash"
          label={gettext("Remove this condition")}
          danger
        />
      </div>
    </div>
    """
  end

  attr :click, :string, required: true
  attr :index, :integer, required: true
  attr :dir, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :danger, :boolean, default: false

  @doc false
  def menu_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@click}
      phx-value-index={@index}
      phx-value-dir={@dir}
      disabled={@disabled}
      x-on:click="open = false"
      class={[
        "flex h-9 cursor-pointer items-center gap-2 rounded-xl px-2.5 text-left text-[0.8125rem] disabled:cursor-not-allowed disabled:opacity-40",
        if(@danger, do: "text-error hover:bg-error/10", else: "hover:bg-secondary")
      ]}
    >
      <.icon name={@icon} class={["size-4 shrink-0", not @danger && "text-muted"]} />{@label}
    </button>
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
      <label for={"#{@field.id}-search"} class="sr-only">{gettext("Field")}</label>
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
          class="bench-tile"
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
        "bench-tile flex h-auto min-h-10 flex-wrap items-center gap-1 px-1.5 py-1",
        @errors != [] && "border-error"
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
    <div class="order-last col-span-full space-y-1.5 rounded-xl bg-secondary p-2.5 sm:order-none">
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
          class="bench-tile font-mono text-[0.8125rem]"
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

  defp verdict_label({:ok, true}), do: gettext("It matches")
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
      class="weapon-picker order-last col-span-full sm:order-none"
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
            class="bench-tile pl-8"
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
    <details class="order-last col-span-full text-xs sm:order-none">
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

  # ── Action parameters ──────────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :text, :any, required: true
  attr :example, :any, required: true

  @doc """
  A message as the player will read it: placeholders filled in from the
  latest real event of the trigger, or from an example player.
  """
  def message_preview(assigns) do
    rendered = preview_text(assigns.text, assigns.example)

    # What the game will actually draw: emoji and fancy symbols are dropped
    # on the way out, so the preview drops them too and says so.
    assigns =
      assign(assigns,
        rendered: GameText.clean(rendered),
        stripped?: GameText.changes?(rendered)
      )

    ~H"""
    <div :if={@rendered != ""} id={@id} class="flex flex-col gap-1.5">
      <p class="flex items-center gap-1.5 text-xs text-muted">
        <span class="live-dot"></span>
        {if @example.event || @example.gamestate,
          do: gettext("As the player sees it, with the latest real event"),
          else: gettext("As the player sees it, with an example player")}
      </p>
      <p class="rounded-2xl bg-secondary px-4 py-3 text-sm leading-relaxed">{@rendered}</p>
      <p :if={@stripped?} class="flex items-center gap-1 text-xs text-warning">
        <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0" />
        {gettext("The game cannot show emoji or special symbols: they are removed.")}
      </p>
    </div>
    """
  end

  @doc """
  A template rendered against a context, or the text as written when it
  cannot be.
  """
  @spec preview_text(String.t() | nil, term()) :: String.t()
  def preview_text(text, _example) when text in [nil, ""], do: ""
  def preview_text(text, nil), do: to_string(text)

  def preview_text(text, example) do
    Template.render(to_string(text), example)
  rescue
    _error -> to_string(text)
  end

  attr :name, :string, required: true
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :type, :atom, required: true
  attr :value, :any, default: nil
  attr :min, :integer, default: nil
  attr :required, :boolean, default: false
  attr :key, :atom, default: nil
  attr :template, :boolean, default: false

  @doc """
  One parameter of an action, drawn as the bench's labelled tile.
  """
  def param_input(%{type: :select} = assigns) do
    ~H"""
    <label class="flex flex-col gap-1.5">
      <span class="text-xs text-muted">{@label}</span>
      <select id={@id} name={@name} class="bench-tile sm:max-w-60">
        {Phoenix.HTML.Form.options_for_select(
          Labels.action_param_options(@key),
          to_string(@value)
        )}
      </select>
    </label>
    """
  end

  def param_input(%{type: :text} = assigns) do
    ~H"""
    <label class="flex flex-col gap-1.5">
      <span class="text-xs text-muted">{@label}</span>
      <textarea
        id={@id}
        name={@name}
        rows="3"
        required={@required}
        class="bench-tile h-auto min-h-[5.25rem] py-3 leading-relaxed"
      >{@value}</textarea>
    </label>
    """
  end

  def param_input(%{type: :integer} = assigns) do
    ~H"""
    <label class="flex flex-col gap-1.5">
      <span class="text-xs text-muted">{@label}</span>
      <input
        type="number"
        id={@id}
        name={@name}
        value={@value}
        min={@min}
        required={@required}
        class="bench-tile sm:max-w-48"
      />
    </label>
    """
  end

  def param_input(assigns) do
    ~H"""
    <label class="flex flex-col gap-1.5">
      <span class="text-xs text-muted">{@label}</span>
      <input
        type="text"
        id={@id}
        name={@name}
        value={@value}
        required={@required}
        data-template={@template}
        class="bench-tile"
      />
    </label>
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
  attr :example, :any, default: nil, doc: "a context whose values are shown beside each variable"

  def placeholders(assigns) do
    variables = if assigns.example, do: Context.variables(assigns.example), else: %{}

    assigns =
      assign(assigns,
        placeholders: Template.placeholders_for(assigns.trigger),
        variables: variables,
        hint: gettext("Click inserts · type { in the text"),
        leaderboard: Template.leaderboard_placeholders() ++ Template.progression_placeholders()
      )

    ~H"""
    <div
      id="rule-placeholders"
      phx-hook=".PlaceholderInsert"
      role="listbox"
      aria-label={gettext("Variables")}
      data-menu-label={gettext("Placeholders")}
      data-empty-label={gettext("No placeholder starts like this")}
      x-data="{ q: '' }"
      class="flex flex-col gap-0.5 rounded-[1.25rem] border border-base-300 bg-secondary p-2.5 shadow-[0_18px_50px_rgba(0,0,0,0.25)]"
    >
      <label class="mb-1.5 flex h-[2.375rem] items-center gap-2 rounded-xl border border-base-300 bg-base-100 px-3 text-muted">
        <.icon name="hero-magnifying-glass" class="size-4 shrink-0" />
        <span class="sr-only">{gettext("Find a variable")}</span>
        <input
          type="search"
          x-model="q"
          x-on:input.stop=""
          x-on:change.stop=""
          placeholder={gettext("Find a variable")}
          autocomplete="off"
          class="min-w-0 flex-1 border-0 bg-transparent p-0 text-[0.8125rem] text-base-content focus:ring-0 focus:outline-none"
        />
      </label>

      <div class="flex max-h-72 flex-col gap-0.5 overflow-y-auto">
        <button
          :for={placeholder <- @placeholders}
          type="button"
          role="option"
          aria-selected="false"
          data-placeholder={placeholder_text(placeholder)}
          x-show={"!q || #{Jason.encode!(fold(placeholder <> " " <> placeholder_description(placeholder)))}.includes($fold(q))"}
          class="grid cursor-pointer grid-cols-[minmax(0,1fr)_auto] items-center gap-2 rounded-xl px-2.5 py-2 text-left transition-colors hover:bg-accent/12"
        >
          <span class="flex min-w-0 flex-col gap-px">
            <span class="font-mono text-[0.8125rem]">{placeholder_text(placeholder)}</span>
            <span class="truncate text-xs text-muted">{placeholder_description(placeholder)}</span>
          </span>
          <span class="max-w-32 truncate text-xs text-subtle">{@variables[placeholder]}</span>
        </button>

        <p class="mt-2 flex items-center gap-1.5 px-2.5 text-xs font-medium text-subtle">
          <.icon name="hero-trophy" class="size-3.5" />{gettext(
            "Leaderboard, achievements and season"
          )}
        </p>
        <p class="px-2.5 pb-1 text-xs leading-snug text-muted">
          {gettext(
            "Each ranking lists the top 3, one per line: \"1. Ana (30)\". Add a number to show more or fewer, from 1 to 10: {top_kills:5}. Write the headings yourself, in your server's language."
          )}
        </p>
        <button
          :for={placeholder <- @leaderboard}
          type="button"
          role="option"
          aria-selected="false"
          data-placeholder={placeholder_text(placeholder)}
          x-show={"!q || #{Jason.encode!(fold(placeholder))}.includes($fold(q))"}
          class="cursor-pointer rounded-xl px-2.5 py-1.5 text-left font-mono text-[0.8125rem] text-accent transition-colors hover:bg-accent/12"
        >
          {placeholder_text(placeholder)}
        </button>
      </div>

      <div class="mt-1 flex justify-between gap-3 border-t border-base-300 px-2.5 pt-2 text-[0.6875rem] text-muted">
        <span>{@hint}</span>
        <span>
          {ngettext(
            "1 variable",
            "%{count} variables",
            length(@placeholders) + length(@leaderboard)
          )}
        </span>
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

  @doc """
  What a placeholder stands for, in a few words.
  """
  @spec placeholder_description(String.t()) :: String.t()
  def placeholder_description("player_name"), do: gettext("Player's name")
  def placeholder_description("player_id"), do: gettext("Player's Steam or console id")
  def placeholder_description("player_level"), do: gettext("Player's level")
  def placeholder_description("player_role"), do: gettext("Role in the squad")
  def placeholder_description("team"), do: gettext("Player's team")
  def placeholder_description("unit_name"), do: gettext("Squad")
  def placeholder_description("clan_tag"), do: gettext("Clan tag")
  def placeholder_description("kills"), do: gettext("His kills this match")
  def placeholder_description("deaths"), do: gettext("His deaths this match")
  def placeholder_description("teamkills"), do: gettext("His team kills this match")
  def placeholder_description("combat"), do: gettext("Combat score")
  def placeholder_description("offense"), do: gettext("Offense score")
  def placeholder_description("defense"), do: gettext("Defense score")
  def placeholder_description("support"), do: gettext("Support score")
  def placeholder_description("is_vip"), do: gettext("Whether he holds VIP")
  def placeholder_description("playtime_minutes"), do: gettext("Minutes played this match")
  def placeholder_description("map_name"), do: gettext("Current map")
  def placeholder_description("game_mode"), do: gettext("Game mode")
  def placeholder_description("server_name"), do: gettext("Server name")
  def placeholder_description("server_player_count"), do: gettext("Players on the server")
  def placeholder_description("vehicles_destroyed"), do: gettext("Vehicles he destroyed")
  def placeholder_description("team_objectives"), do: gettext("Sectors his team holds")
  def placeholder_description("enemy_objectives"), do: gettext("Sectors the enemy holds")
  def placeholder_description("weapon"), do: gettext("Weapon of the kill")
  def placeholder_description("target_player_name"), do: gettext("The other player of the kill")
  def placeholder_description("message"), do: gettext("What he wrote")
  def placeholder_description("strikes"), do: gettext("Times this rule caught him")
  def placeholder_description(_name), do: ""

  # ── The rule, in words ─────────────────────────────────────────────────────

  @doc """
  The whole rule as one plain-language sentence, for lists:
  "When a player connects, if Level is below 10, then Warn."

  Shares the condition wording with `condition_sentence/2`, so the list and
  the rule page describe a rule the same way.
  """
  @spec rule_sentence(map(), atom() | nil) :: String.t()
  def rule_sentence(rule, game \\ nil) do
    game = game || rule.game

    conditions =
      case rule.conditions do
        [] ->
          gettext("no conditions yet")

        conditions ->
          conditions_sentence(conditions, rule.logical_operator, game)
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
  The conditions in words, joined the way they combine. Groups read in
  parentheses: "(Is VIP is No and Flags does not contain admin) or (Team
  kills is at least 3)".
  """
  @spec conditions_sentence([map()], atom(), atom() | nil) :: String.t()
  def conditions_sentence(conditions, logical_operator, game) do
    if ConditionGroups.grouped?(conditions) do
      joiner = " " <> Labels.logical_joiner(logical_operator) <> " "

      conditions
      |> ConditionGroups.groups()
      |> Enum.map_join(joiner, &group_sentence(&1, game))
    else
      joiner = " " <> Labels.logical_joiner(logical_operator) <> " "
      Enum.map_join(conditions, joiner, &condition_sentence(&1, game))
    end
  end

  defp group_sentence(group, game) do
    inner = " " <> Labels.logical_joiner(group.operator) <> " "

    "(" <>
      Enum.map_join(group.conditions, inner, fn {condition, _index} ->
        condition_sentence(condition, game)
      end) <> ")"
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

  # A yes/no field reads as its answer - "Is VIP: no" - rather than
  # "Is VIP is false".
  def condition_sentence(%{operator: operator} = condition, game)
      when operator in [:equal, :not_equal] do
    if Catalog.field_type(condition.field) == :boolean do
      yes? = to_string(condition.value) == "true"
      yes? = if operator == :equal, do: yes?, else: not yes?

      "#{Labels.field(condition.field)}: #{if yes?, do: gettext("yes"), else: gettext("no")}"
    else
      plain_condition_sentence(condition, game)
    end
  end

  def condition_sentence(condition, game), do: plain_condition_sentence(condition, game)

  defp plain_condition_sentence(condition, game) do
    "#{Labels.field(condition.field)} #{Labels.operator(condition.operator)} #{value_text(condition.field, condition.value, game)}"
  end

  @doc """
  A condition's value as the summary shows it: the label the picker used
  when it came from one, "(empty)" when there is none.
  """
  @spec value_text(atom(), term(), atom() | nil) :: String.t()
  def value_text(field, value, game) do
    value =
      case Labels.value_options(field, game) do
        nil -> value
        options -> option_label(options, value)
      end

    to_string(present(value))
  end

  defp option_label(options, value) do
    Enum.find_value(options, value, fn {label, option} -> option == value && label end)
  end

  defp present(value) when value in [nil, ""], do: gettext("(empty)")
  defp present(value), do: value

  # ── Shared helpers ─────────────────────────────────────────────────────────

  # Select inputs post strings; convert to the atom the catalog uses, without
  # ever calling String.to_atom/1 on user input.
  defp existing_field(value) do
    Enum.find(Catalog.fields(), :always_true, &(to_string(&1) == value))
  end

  defp existing_operator(value) do
    Enum.find(Catalog.operators(), :equal, &(to_string(&1) == value))
  end

  @doc false
  def existing_action(value) do
    Enum.find(Catalog.action_types(), :message_player, &(to_string(&1) == value))
  end

  @doc false
  def current_parameters(action_form) do
    case Form.input_value(action_form, :parameters) do
      parameters when is_map(parameters) -> parameters
      _other -> %{}
    end
  end

  @doc false
  def parameter_value(parameters, key, opts) do
    case Map.get(parameters, to_string(key)) do
      nil -> opts[:default]
      value -> value
    end
  end

  @doc false
  def action_errors(action_form) do
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
