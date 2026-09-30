defmodule HllConditionalActionsWeb.ConditionGroupsView do
  @moduledoc """
  A rule's conditions as the pages read them: consecutive conditions that
  ask the same question of one field folded into one entry with its list of
  values (see `HllConditionalActions.Rules.ConditionRuns`), in words.

  Ninety `weapon is not "…"` rows read "Weapon is none of 86 weapons
  (122MM HOWITZER, 150MM HOWITZER, +84)", and the whole list opens in a
  popover (`value_list/1`) - searchable when long, repeats marked "2×",
  what a version added or removed tinted. The rule sentence, the versions
  tab, "why didn't it fire?" and the rules list all go through here, so a
  long rule reads the same everywhere. Display only: nothing here touches
  how a rule is stored or evaluated.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActions.Rules.ConditionRuns
  alias HllConditionalActionsWeb.RuleBuilder

  # Values named inside a chip before the "+N".
  @preview 2
  # A list longer than this gets a search box.
  @searchable 20

  @type entry :: map()

  @doc """
  The entries of a rule: its conditions (without the `always` placeholder)
  folded and put into words. See `entries/3`.
  """
  @spec for_rule(map()) :: [entry()]
  def for_rule(rule) do
    rule.conditions
    |> Enum.reject(&(&1.field == :always_true))
    |> entries(rule.logical_operator, Map.get(rule, :game))
  end

  @doc """
  Conditions folded into entries, in order. Each is a run of
  `HllConditionalActions.Rules.ConditionRuns` plus:

    * `:number` - its place, from 1;
    * `:key` - stable across versions of a rule (group, field, operator and
      which such run it is), so two versions line up;
    * `:list?` - whether it folds more than one value;
    * `:text` - the chip: "Weapon is none of 86 weapons", or the ordinary
      sentence of a single condition;
    * `:head` - field and operator, "Weapon is not";
    * `:noun` - `:weapons` or `:values`, what the list holds;
    * `:preview` - "122MM HOWITZER, 150MM HOWITZER, +84", or `nil`;
    * `:items` - `[%{value, label, count}]`, every distinct value.

  Conditions are `Condition` structs or maps with `:field`, `:operator` and
  `:value` (or `:expected`, as the engine's trace has it).
  """
  @spec entries([map()], atom(), atom() | nil) :: [entry()]
  def entries(conditions, logical_operator, game) do
    conditions
    |> ConditionRuns.fold(logical_operator)
    |> Enum.with_index(1)
    |> Enum.map_reduce(%{}, fn {run, number}, seen ->
      base = {run.group, run.field, run.operator}
      occurrence = Map.get(seen, base, 0)

      entry =
        describe(run, number, "#{run.group}:#{run.field}:#{run.operator}:#{occurrence}", game)

      {entry, Map.put(seen, base, occurrence + 1)}
    end)
    |> elem(0)
  end

  @doc """
  An entry's list in one short phrase, for lists and headers:
  "Weapon is none of 86 weapons". A single condition reads as its sentence.
  """
  @spec short_text(entry()) :: String.t()
  def short_text(entry), do: entry.text

  @doc """
  The chip with its preview: "Weapon is none of 86 weapons (122MM
  HOWITZER, 150MM HOWITZER, +84)".
  """
  @spec full_text(entry()) :: String.t()
  def full_text(%{preview: nil} = entry), do: entry.text
  def full_text(%{reading: :all_at_once} = entry), do: entry.text
  def full_text(entry), do: "#{entry.text} (#{entry.preview})"

  @doc """
  What changed between two versions of one entry, in words: "+68 weapons",
  "−2 values", "+3, −1 values". `nil` when the values are the same.
  """
  @spec delta_text(entry() | nil, entry() | nil) :: String.t() | nil
  def delta_text(before, now) do
    {added, removed} = delta(before, now)
    noun = (now || before).noun

    case {length(added), length(removed)} do
      {0, 0} ->
        nil

      {plus, 0} ->
        added_text(plus, noun)

      {0, minus} ->
        removed_text(minus, noun)

      {plus, minus} ->
        "+#{plus}, " <> removed_text(minus, noun)
    end
  end

  @doc """
  The values one side has and the other lacks: `{added, removed}`, reading
  from `before` to `now`.
  """
  @spec delta(entry() | nil, entry() | nil) :: {[String.t()], [String.t()]}
  def delta(before, now) do
    before_values = (before && before.values) || []
    now_values = (now && now.values) || []
    {now_values -- before_values, before_values -- now_values}
  end

  @doc """
  The items of a list compared across two versions, from the newer one's
  side, the change first: the values it added (marked `:added`), the ones
  it dropped (`:removed`), then the ones both hold.
  """
  @spec diff_items(entry() | nil, entry() | nil) :: [map()]
  def diff_items(before, now) do
    {added, removed} = delta(before, now)
    {new, kept} = Enum.split_with((now && now.items) || [], &(&1.value in added))
    gone = Enum.filter((before && before.items) || [], &(&1.value in removed))

    Enum.map(new, &Map.put(&1, :mark, :added)) ++
      Enum.map(gone, &Map.put(&1, :mark, :removed)) ++
      Enum.map(kept, &Map.put(&1, :mark, nil))
  end

  @doc """
  How many conditions an entry stands for and how many repeat, for the
  popover's subtitle: "90 conditions · 4 repeated".
  """
  @spec members_text(entry()) :: String.t()
  def members_text(entry) do
    total = length(entry.members)
    repeated = total - length(entry.values)

    [
      ngettext("1 condition", "%{count} conditions", total),
      repeated > 0 && ngettext("1 repeated", "%{count} repeated", repeated)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  # ── Words ──────────────────────────────────────────────────────────────────

  defp describe(run, number, key, game) do
    field = run.field
    noun = noun(field)
    items = items(run, game)
    list? = run.reading != :single

    run
    |> Map.merge(%{
      number: number,
      key: key,
      list?: list?,
      noun: noun,
      head: head(field, run.operator),
      items: items,
      text: text(run, noun, items, game),
      preview: if(list?, do: preview(items, field))
    })
  end

  defp items(run, game) do
    Enum.map(run.values, fn value ->
      %{
        value: value,
        label: value_label(run.field, value, game),
        count: Map.get(run.counts, value, 1)
      }
    end)
  end

  defp text(%{reading: :single, members: [{condition, _index} | _rest]}, _noun, _items, game) do
    condition
    |> normalize()
    |> RuleBuilder.condition_sentence(game)
  end

  defp text(%{reading: :all_at_once} = run, _noun, items, _game) do
    gettext("%{field} is at the same time %{values}",
      field: field_name(run.field),
      values: inline_values(items)
    )
  end

  defp text(run, noun, items, _game),
    do: list_text(run.reading, noun, length(items), field_name(run.field))

  defp list_text(:none_of, :weapons, count, field) do
    ngettext("%{field} is none of 1 weapon", "%{field} is none of %{count} weapons", count,
      field: field
    )
  end

  defp list_text(:none_of, _noun, count, field) do
    ngettext("%{field} is none of 1 value", "%{field} is none of %{count} values", count,
      field: field
    )
  end

  defp list_text(:one_of, :weapons, count, field) do
    ngettext("%{field} is one of 1 weapon", "%{field} is one of %{count} weapons", count,
      field: field
    )
  end

  defp list_text(:one_of, _noun, count, field) do
    ngettext("%{field} is one of 1 value", "%{field} is one of %{count} values", count,
      field: field
    )
  end

  defp list_text(:not_all, _noun, count, field) do
    ngettext(
      "%{field} differs from at least one of 1 value",
      "%{field} differs from at least one of %{count} values",
      count,
      field: field
    )
  end

  defp list_text(:contains_any, _noun, count, field) do
    ngettext(
      "%{field} contains one of 1 value",
      "%{field} contains one of %{count} values",
      count,
      field: field
    )
  end

  defp list_text(:contains_all, _noun, count, field) do
    ngettext(
      "%{field} contains all of 1 value",
      "%{field} contains all of %{count} values",
      count,
      field: field
    )
  end

  defp list_text(:contains_none, _noun, count, field) do
    ngettext(
      "%{field} contains none of 1 value",
      "%{field} contains none of %{count} values",
      count,
      field: field
    )
  end

  defp list_text(:lacks_any, _noun, count, field) do
    ngettext(
      "%{field} lacks at least one of 1 value",
      "%{field} lacks at least one of %{count} values",
      count,
      field: field
    )
  end

  # "vtnc, desgraçado and +14"
  defp inline_values(items) do
    labels = Enum.map(items, & &1.label)

    case Enum.split(labels, @preview) do
      {shown, []} ->
        {init, [last]} = Enum.split(shown, -1)
        gettext("%{a} and %{b}", a: Enum.join(init, ", "), b: last)

      {shown, rest} ->
        gettext("%{a} and %{b}", a: Enum.join(shown, ", "), b: "+#{length(rest)}")
    end
  end

  defp preview(items, field) do
    {shown, rest} = Enum.split(items, @preview)
    names = Enum.map(shown, &short_label(&1.label, field))
    Enum.join(names ++ if(rest == [], do: [], else: ["+#{length(rest)}"]), ", ")
  end

  @doc """
  A value short enough for a chip: a weapon by its name, without the
  variant in brackets ("122MM HOWITZER [M1938 (M-30)]" → "122MM HOWITZER");
  anything else cut at 28 characters.
  """
  @spec short_label(String.t(), atom() | String.t()) :: String.t()
  def short_label(label, :weapon) do
    case String.split(label, " [", parts: 2) do
      [name, _variant] when name != "" -> name
      _other -> cut(label)
    end
  end

  def short_label(label, _field), do: cut(label)

  defp cut(label) do
    if String.length(label) > 28, do: String.slice(label, 0, 27) <> "…", else: label
  end

  defp head(field, operator), do: "#{field_name(field)} #{operator_label(operator)}"

  defp added_text(count, :weapons), do: ngettext("+1 weapon", "+%{count} weapons", count)
  defp added_text(count, _values), do: ngettext("+1 value", "+%{count} values", count)

  defp removed_text(count, :weapons), do: ngettext("−1 weapon", "−%{count} weapons", count)
  defp removed_text(count, _values), do: ngettext("−1 value", "−%{count} values", count)

  defp noun(:weapon), do: :weapons
  defp noun(_field), do: :values

  defp field_name(field) when is_atom(field), do: Labels.field(field)
  defp field_name(field), do: to_string(field)

  defp operator_label(operator) when is_atom(operator), do: Labels.operator(operator)
  defp operator_label(operator), do: to_string(operator)

  defp value_label(field, value, game) when is_atom(field) do
    if field in Catalog.fields(),
      do: RuleBuilder.value_text(field, value, game),
      else: to_string(value)
  end

  defp value_label(_field, value, _game), do: to_string(value)

  # The builder's sentence takes a condition with `:value`; the engine's
  # trace calls it `:expected`.
  defp normalize(%{value: _value} = condition), do: condition

  defp normalize(%{expected: expected} = condition),
    do: Map.put(condition, :value, expected)

  defp normalize(condition), do: Map.put(condition, :value, "")

  # ── Components ─────────────────────────────────────────────────────────────

  @doc """
  A folded entry as a chip that opens its list: the chip's words, the
  first values after them, and a list icon. `mark` tints it for the
  versions diff (`:before` struck in the error tone, `:after` in the
  signal); `badge` adds a short note, e.g. "+68 weapons".
  """
  attr :entry, :map, required: true
  attr :popover, :string, required: true, doc: "the id of the `value_list/1` it opens"
  attr :mark, :atom, default: nil
  attr :badge, :string, default: nil
  attr :class, :any, default: nil

  def list_chip(assigns) do
    ~H"""
    <button
      type="button"
      popovertarget={@popover}
      data-list-chip={@entry.key}
      aria-haspopup="dialog"
      class={[
        "group/chip cursor-pointer rounded-[0.625rem] px-2.5 py-[3px] text-left font-medium [box-decoration-break:clone] transition-colors",
        chip_tint(@mark, @entry.reading),
        @class
      ]}
    >
      <span class={[@mark == :before && "line-through decoration-error/60"]}>{@entry.text}</span>
      <span
        :if={@entry.preview && @entry.reading != :all_at_once}
        class="font-normal text-[0.85em] text-muted"
      >
        ({@entry.preview})
      </span>
      <span
        :if={@badge}
        class={[
          "ml-0.5 rounded-full px-1.5 py-px align-[0.08em] font-mono text-[0.7em] font-semibold",
          if(@mark == :before, do: "bg-error/14 text-error", else: "bg-primary/14 text-primary")
        ]}
      >
        {@badge}
      </span>
      <.icon
        name="hero-list-bullet"
        class="ml-0.5 size-[0.95em] align-[-0.12em] text-muted transition-colors group-hover/chip:text-base-content"
      />
    </button>
    """
  end

  defp chip_tint(:before, _reading), do: "bg-error/14 text-error hover:bg-error/20"
  defp chip_tint(:after, _reading), do: "bg-primary/14 text-primary hover:bg-primary/20"

  # A list that can never hold wears the health warning's tone.
  defp chip_tint(_plain, :all_at_once),
    do: "bg-warning/10 text-warning ring-1 ring-inset ring-warning/35 hover:bg-warning/15"

  defp chip_tint(_plain, _reading),
    do: "bg-secondary text-base-content ring-1 ring-inset ring-base-300 hover:bg-base-200"

  @doc """
  Every value of a folded entry, in a native popover a `list_chip/1` (or
  any `popovertarget` button) opens: numbered, repeats marked "2×", a
  search box past #{@searchable} values. Items may carry a `:mark` -
  `:added` in the signal, `:removed` struck, `:hit` for the value an event
  read.
  """
  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :items, :list, default: nil, doc: "defaults to the entry's own; diff_items/2 for a diff"
  attr :note, :string, default: nil, doc: "a line under the title, e.g. the delta"

  def value_list(assigns) do
    assigns =
      assigns
      |> assign(:items, assigns.items || assigns.entry.items)
      |> assign(:searchable, length(assigns.items || assigns.entry.items) > @searchable)

    ~H"""
    <div
      id={@id}
      popover
      role="dialog"
      aria-labelledby={"#{@id}-title"}
      class="m-auto max-h-[min(40rem,calc(100dvh-2rem))] w-[min(34rem,calc(100vw-2rem))] overflow-hidden rounded-[1.75rem] border-0 bg-base-100 p-0 text-base-content shadow-figma-card-large backdrop:bg-black/45"
    >
      <div class="flex max-h-[min(40rem,calc(100dvh-2rem))] flex-col">
        <div class="flex shrink-0 items-start gap-3 border-b border-base-300 px-5 pt-4 pb-3.5">
          <div class="flex min-w-0 flex-1 flex-col gap-0.5">
            <h3 id={"#{@id}-title"} class="font-display text-lg leading-snug font-semibold">
              {@entry.text}
            </h3>
            <p class="text-xs text-muted">{members_text(@entry)}</p>
            <p :if={@note} class="text-xs font-semibold text-primary">{@note}</p>
          </div>
          <button
            type="button"
            popovertarget={@id}
            popovertargetaction="hide"
            aria-label={gettext("Close")}
            class="flex size-8 shrink-0 cursor-pointer items-center justify-center rounded-full text-muted transition-colors hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <label
          :if={@searchable}
          class="mx-5 mt-3 flex h-10 shrink-0 items-center gap-2 rounded-2xl border border-base-300 bg-secondary px-3 text-muted"
        >
          <.icon name="hero-magnifying-glass" class="size-4 shrink-0" />
          <span class="sr-only">{gettext("Search the list")}</span>
          <input
            id={"#{@id}-search"}
            type="search"
            autocomplete="off"
            phx-hook=".ValueFilter"
            data-list={"#{@id}-items"}
            placeholder={gettext("Search %{count} values", count: length(@items))}
            class="w-full border-0 bg-transparent p-0 text-sm text-base-content placeholder:text-muted focus:ring-0"
          />
        </label>

        <ol id={"#{@id}-items"} class="min-h-0 flex-1 overflow-y-auto px-5 pt-1.5 pb-4">
          <li
            :for={{item, index} <- Enum.with_index(@items, 1)}
            data-filter={String.downcase(item.label)}
            data-mark={item[:mark]}
            class={[
              "flex items-baseline gap-2.5 border-b border-base-300 py-2 text-sm last:border-b-0",
              item[:mark] == :added && "text-primary",
              item[:mark] == :removed && "text-error",
              item[:mark] == :hit && "-mx-2 rounded-lg border-transparent bg-error/12 px-2 text-error"
            ]}
          >
            <span class="w-7 shrink-0 text-right font-mono text-[0.6875rem] text-muted">
              {index}
            </span>
            <span :if={item[:mark] == :added} class="font-mono text-xs" aria-hidden="true">+</span>
            <span :if={item[:mark] == :removed} class="font-mono text-xs" aria-hidden="true">−</span>
            <span class="min-w-0 flex-1 break-words">
              <del :if={item[:mark] == :removed} class="decoration-error/60">{item.label}</del>
              <span :if={item[:mark] != :removed}>{item.label}</span>
              <span :if={item[:mark] == :added} class="sr-only">{gettext("added in this version")}</span>
              <span :if={item[:mark] == :removed} class="sr-only">{gettext("dropped in this version")}</span>
            </span>
            <span
              :if={item[:mark] == :hit}
              class="shrink-0 rounded-full bg-error/14 px-2 py-px text-[0.6875rem] font-semibold"
            >
              {gettext("the event's value")}
            </span>
            <span
              :if={item.count > 1}
              title={gettext("repeated in the rule")}
              class="shrink-0 rounded-full bg-warning/13 px-2 py-px font-mono text-[0.6875rem] font-semibold text-warning"
            >
              {item.count}×
            </span>
          </li>
          <li data-empty hidden class="py-6 text-center text-[0.8125rem] text-muted">
            {gettext("No value matches the search.")}
          </li>
        </ol>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ValueFilter">
        export default {
          mounted() {
            this.el.addEventListener("input", () => {
              const list = document.getElementById(this.el.dataset.list)
              if (!list) return
              const query = this.el.value.trim().toLowerCase()
              let shown = 0
              list.querySelectorAll("li[data-filter]").forEach((item) => {
                const match = query === "" || item.dataset.filter.includes(query)
                item.hidden = !match
                if (match) shown++
              })
              const empty = list.querySelector("li[data-empty]")
              if (empty) empty.hidden = shown > 0
            })
          }
        }
      </script>
    </div>
    """
  end
end
