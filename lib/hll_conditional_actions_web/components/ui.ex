defmodule HllConditionalActionsWeb.Ui do
  @moduledoc """
  The application's component library, built over Petal Components.

  Petal owns the primitives (buttons, badges, fields, alerts); this module
  owns everything the pages of *this* app repeat: cards, stats, empty
  states, the native-dialog modal, filter bars, responsive tables, paging,
  skeletons and time. The rules they encode — surfaces, type scale, tones,
  spacing — live in the tokens at the top of `assets/css/app.css`.

  Imported app-wide from `HllConditionalActionsWeb.html_helpers/0`.
  """

  use Phoenix.Component
  use Gettext, backend: HllConditionalActionsWeb.Gettext

  import PetalComponents.Badge
  import PetalComponents.Icon

  alias Phoenix.LiveView.JS

  # ── Cards and sections ─────────────────────────────────────────────────────

  @doc """
  A content card: the only surface content sits on.

  ## Examples

      <.card>plain body</.card>

      <.card title={gettext("Rules on this server")} icon="hero-bolt">
        <:action><.link navigate={~p"/rules"}>{gettext("See all")}</.link></:action>
        ...
      </.card>
  """
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :icon, :string, default: nil, doc: "leading icon next to the title"
  attr :class, :any, default: nil, doc: "extra classes for the card body"
  attr :padded, :boolean, default: true, doc: "false removes the body padding (tables)"
  attr :rest, :global
  slot :action, doc: "controls pinned to the right of the title"
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <section class="rounded-box bg-base-100 shadow-figma-card" {@rest}>
      <div class={["flex flex-col gap-3", if(@padded, do: "p-4 sm:p-5", else: "p-0"), @class]}>
        <div
          :if={@title || @action != []}
          class={["flex flex-wrap items-center justify-between gap-2", not @padded && "px-4 pt-4"]}
        >
          <div class="min-w-0">
            <h2 :if={@title} class="flex items-center gap-2 text-title-medium">
              <.icon :if={@icon} name={@icon} class="size-4 shrink-0 text-primary" /> {@title}
            </h2>

            <p :if={@subtitle} class="mt-0.5 text-label-small text-muted">{@subtitle}</p>
          </div>

          <div :if={@action != []} class="flex shrink-0 items-center gap-2">
            {render_slot(@action)}
          </div>
        </div>

        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  # ── Stats ──────────────────────────────────────────────────────────────────

  @doc """
  A stat tile: icon chip, small label, big value, one line of context.
  `tone` colours the chip (and only the chip) by meaning.
  """
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :icon, :string, required: true
  attr :hint, :string, default: nil
  attr :tone, :string, default: "neutral", values: ~w(neutral primary info success warning error)
  slot :inner_block, doc: "rich value content, rendered instead of `value`"

  def stat(assigns) do
    ~H"""
    <div class="rounded-box bg-base-100 p-4 shadow-figma-card transition-shadow hover:shadow-figma-card-medium">
      <div class="flex items-start gap-3">
        <div class={[
          "flex size-10 shrink-0 items-center justify-center rounded-box",
          icon_box(@tone)
        ]}>
          <.icon name={@icon} class="size-5" />
        </div>

        <div class="min-w-0 flex-1">
          <p class="truncate text-label-medium text-muted">{@label}</p>

          <p class="truncate text-headline-large tabular-nums">
            <%= if @inner_block != [] do %>
              {render_slot(@inner_block)}
            <% else %>
              {@value}
            <% end %>
          </p>

          <p :if={@hint} class="truncate text-label-small text-muted">{@hint}</p>
        </div>
      </div>
    </div>
    """
  end

  # The VTIX icon box: a tinted gradient square carrying the tone.
  defp icon_box("primary"), do: "bg-gradient-primary text-primary"
  defp icon_box("info"), do: "bg-gradient-info text-info"
  defp icon_box("success"), do: "bg-gradient-success text-success"
  defp icon_box("warning"), do: "bg-gradient-warning text-warning"
  defp icon_box("error"), do: "bg-gradient-destructive text-error"
  defp icon_box(_neutral), do: "bg-base-200 text-muted"

  # ── Empty states ───────────────────────────────────────────────────────────

  @doc """
  The empty state: icon chip, a title, one paragraph, at most one action.
  """
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :card, :boolean, default: true
  slot :action, doc: "a single call to action"

  def empty_state(assigns) do
    ~H"""
    <div class={[
      "flex flex-col items-center gap-2 py-12 text-center",
      @card && "rounded-box bg-base-100 shadow-figma-card"
    ]}>
      <div class="flex size-12 items-center justify-center rounded-box bg-gradient-primary">
        <.icon name={@icon} class="size-6 text-primary" />
      </div>

      <h2 class="text-title-large">{@title}</h2>

      <p :if={@description} class="max-w-md px-4 text-body-small text-muted">{@description}</p>

      <div :if={@action != []} class="mt-2">{render_slot(@action)}</div>
    </div>
    """
  end

  # ── Modal ──────────────────────────────────────────────────────────────────

  @doc """
  A modal on the native `<dialog>` element, which is what gives it focus
  trapping, Escape handling and focus restoration for free.

  It opens as a full-height sheet that slides in from the right: the whole
  screen up to `lg`, a panel of `class` width past it. The header stays put
  and only the body scrolls, so the title and ✕ never leave.

  It renders open, so drive it with `:if` off `@live_action` (or any flag)
  and pass the command that leaves that state as `on_cancel` — Escape, the
  backdrop and the ✕ button all run it.

  ## Example

      <.modal
        :if={@live_action in [:new, :edit]}
        id="server-modal"
        title={gettext("New server")}
        on_cancel={JS.patch(~p"/servers")}
      >
        <.form ...>...</.form>
      </.modal>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :on_cancel, JS, default: %JS{}

  attr :class, :any,
    default: "max-w-lg",
    doc: "how wide the sheet gets past `lg`, e.g. max-w-2xl"

  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <dialog
      id={@id}
      class={["app-modal", @class]}
      phx-hook=".AppModal"
      data-cancel={@on_cancel}
      aria-labelledby={"#{@id}-title"}
    >
      <div class="flex h-full flex-col border-l border-base-300 bg-base-100 shadow-figma-card-large">
        <div class="flex shrink-0 items-start justify-between gap-3 border-b border-base-300 px-5 py-4 sm:px-6">
          <div class="min-w-0">
            <h3 id={"#{@id}-title"} class="text-title-large">{@title}</h3>

            <p :if={@subtitle} class="mt-0.5 text-label-small text-muted">{@subtitle}</p>
          </div>

          <form method="dialog">
            <button
              class="flex size-8 cursor-pointer items-center justify-center rounded-field text-muted transition-colors hover:bg-base-200 hover:text-base-content"
              aria-label={gettext("Close")}
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </form>
        </div>

        <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4 sm:px-6">
          {render_slot(@inner_block)}
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".AppModal">
        export default {
          mounted() {
            // Rendered means open: `:if` on the component is the source of truth.
            this.el.showModal()
            // Clicking the backdrop (the dialog element itself) closes.
            this.el.addEventListener("mousedown", (e) => {
              if (e.target === this.el) this.el.close()
            })
            this.el.addEventListener("close", () => {
              const cancel = this.el.getAttribute("data-cancel")
              if (!cancel || cancel === "[]") return
              // The command that removes this dialog runs once the sheet has
              // slid back out, so closing is as animated as opening.
              const run = () => this.liveSocket.execJS(this.el, cancel)
              // A hidden tab paints nothing and throttles its timers, so there
              // is no exit to wait for - and waiting would strand the dialog.
              const still =
                document.hidden || window.matchMedia("(prefers-reduced-motion: reduce)").matches
              const ms = still ? 0 : this.transitionMs()
              ms > 0 ? window.setTimeout(run, ms) : run()
            })
          },
          transitionMs() {
            const value = getComputedStyle(this.el).transitionDuration.split(",")[0].trim()
            return value.endsWith("ms") ? parseFloat(value) : parseFloat(value) * 1000
          }
        }
      </script>
    </dialog>
    """
  end

  # ── Filter bar ─────────────────────────────────────────────────────────────

  @doc """
  The filter strip that sits above a list: one `phx-change` form, labelled
  controls, and a clear button when anything is active.
  """
  attr :id, :string, required: true
  attr :on_change, :string, required: true
  slot :clear
  slot :inner_block, required: true

  def filter_bar(assigns) do
    ~H"""
    <form
      id={@id}
      phx-change={@on_change}
      class="flex flex-wrap items-center gap-2 rounded-box border border-base-300 bg-base-100 p-2"
    >
      <span class="hidden px-1 text-muted sm:inline-flex" aria-hidden="true">
        <.icon name="hero-funnel" class="size-4" />
      </span>

      {render_slot(@inner_block)} {render_slot(@clear)}
    </form>
    """
  end

  @doc """
  A labelled select for the filter bar. The label is visually hidden but
  always present, so every control reads out loud.
  """
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :prompt, :string, required: true, doc: "the \"everything\" option"
  attr :options, :list, required: true, doc: "{label, value} pairs"
  attr :class, :any, default: nil

  def filter_select(assigns) do
    ~H"""
    <label class={["max-sm:grow", @class]}>
      <span class="sr-only">{@label}</span>
      <select name={@name} class="pc-text-input w-full sm:w-44" title={@label}>
        <option value="">{@prompt}</option>

        <option
          :for={{label, value} <- @options}
          value={value}
          selected={to_string(@value) == to_string(value)}
        >
          {label}
        </option>
      </select>
    </label>
    """
  end

  @doc """
  A segmented control for a short, mutually exclusive choice.

  Two or three states you flip between constantly (all / active / disabled)
  read better as one visible row than as a closed select: you see where you
  are and what else there is without opening anything.

  Renders radios, so it works inside the filter form with no JavaScript.
  """
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :options, :list, required: true, doc: "{label, value} pairs; use \"\" for the neutral one"

  def segmented(assigns) do
    ~H"""
    <fieldset class="flex items-center gap-0.5 rounded-field border border-base-300 bg-base-100 p-0.5">
      <legend class="sr-only">{@label}</legend>

      <label :for={{label, value} <- @options} class="cursor-pointer">
        <input
          type="radio"
          name={@name}
          value={value}
          checked={to_string(@value) == to_string(value)}
          class="peer sr-only"
        />
        <span class="block whitespace-nowrap rounded-selector px-2.5 py-1 text-label-small text-muted transition-colors hover:text-base-content peer-checked:bg-primary/10 peer-checked:font-medium peer-checked:text-primary peer-focus-visible:ring-2 peer-focus-visible:ring-primary/50">
          {label}
        </span>
      </label>
    </fieldset>
    """
  end

  @doc """
  A search box with the magnifier inside it.
  """
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :placeholder, :string, default: nil
  attr :class, :any, default: nil

  def search_input(assigns) do
    ~H"""
    <label class={["relative block", @class]}>
      <span class="sr-only">{@label}</span>

      <span class="pointer-events-none absolute inset-y-0 left-0 flex items-center pl-2.5 text-muted">
        <.icon name="hero-magnifying-glass" class="size-4" />
      </span>

      <input
        type="search"
        name={@name}
        value={@value}
        placeholder={@placeholder || @label}
        class="pc-text-input w-full pl-8"
        phx-debounce="300"
      />
    </label>
    """
  end

  # ── Data table ─────────────────────────────────────────────────────────────

  @doc """
  A data table that collapses into stacked cards below `sm` (see
  `.table-collapse` in `app.css`) instead of scrolling sideways.

  The first `:col` is the row's identity and renders full-width on mobile;
  every other column shows its header as an inline label. Works with lists
  and LiveView streams alike.
  """
  attr :id, :string, required: true
  attr :rows, :any, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "maps each row before handing it to the slots"

  slot :col, required: true do
    attr :label, :string
    attr :class, :any
  end

  slot :action, doc: "the row's controls, rendered right-aligned"

  def data_table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table-collapse app-table">
      <thead>
        <tr>
          <th :for={col <- @col} class={[col[:class]]}>{col[:label]}</th>

          <th :if={@action != []} class="w-0 text-right">
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>

      <tbody
        id={@id}
        phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}
        class="divide-y divide-base-300"
      >
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)} class="sm:hover:bg-base-200/60">
          <td
            :for={{col, index} <- Enum.with_index(@col)}
            data-label={index > 0 && col[:label]}
            data-cell={index == 0 && "lead"}
            class={[col[:class]]}
          >
            {render_slot(col, @row_item.(row))}
          </td>

          <td :if={@action != []} data-cell="actions">
            <div class="flex items-center justify-end gap-1">
              {render_slot(@action, @row_item.(row))}
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  The kebab menu holding a row's secondary actions.

  Alpine-driven: closes on Escape and outside click, moves focus to the
  first entry when opened, and arrow keys walk the entries.
  """
  attr :id, :string, required: true
  attr :label, :string, default: nil
  slot :inner_block, required: true, doc: "menu entries: buttons or links"

  def row_menu(assigns) do
    assigns = assign_new(assigns, :label, fn -> gettext("More actions") end)

    ~H"""
    <div
      class="relative"
      x-data="{ open: false }"
      x-on:keydown.escape.stop="open = false; $refs.trigger.focus()"
    >
      <button
        type="button"
        class="flex size-8 cursor-pointer items-center justify-center rounded-field border border-base-300 text-muted transition-colors hover:bg-base-200 hover:text-base-content"
        aria-label={@label}
        aria-haspopup="menu"
        x-ref="trigger"
        x-on:click.stop="open = !open"
        x-bind:aria-expanded="open"
      >
        <.icon name="hero-ellipsis-vertical" class="size-4" />
      </button>

      <ul
        id={@id}
        role="menu"
        class="absolute right-0 z-40 mt-1 w-48 rounded-field border border-base-300 bg-base-100 p-1 shadow-xl"
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

  @doc """
  One entry of a `row_menu/1`. `tone="error"` marks the destructive entry.
  """
  attr :tone, :string, default: "neutral", values: ~w(neutral error)
  attr :icon, :string, default: nil
  attr :rest, :global, include: ~w(navigate patch href method phx-click phx-value-id data-confirm)
  slot :inner_block, required: true

  def menu_item(assigns) do
    ~H"""
    <li role="none">
      <.link
        role="menuitem"
        class={[
          "flex w-full items-center gap-2 rounded-field px-2.5 py-1.5 text-left text-sm",
          "hover:bg-base-200 focus-visible:bg-base-200 focus-visible:outline-none",
          @tone == "error" && "text-error"
        ]}
        {@rest}
      >
        <.icon :if={@icon} name={@icon} class="size-4 shrink-0" /> {render_slot(@inner_block)}
      </.link>
    </li>
    """
  end

  # ── Badges and dots ────────────────────────────────────────────────────────

  @doc """
  A tone-coloured badge over Petal's badge, using the app's tone names.
  """
  attr :tone, :string,
    default: "neutral",
    values: ~w(neutral primary info success warning error ghost)

  attr :icon, :string, default: nil
  attr :size, :string, default: "sm", values: ~w(xs sm)
  attr :title, :string, default: nil
  slot :inner_block, required: true

  def tone_badge(assigns) do
    ~H"""
    <.badge
      color={badge_color(@tone)}
      variant="soft"
      size={@size}
      with_icon={@icon != nil}
      title={@title}
    >
      <.icon :if={@icon} name={@icon} class={if @size == "xs", do: "size-2.5", else: "size-3"} />
      {render_slot(@inner_block)}
    </.badge>
    """
  end

  defp badge_color("primary"), do: "primary"
  defp badge_color("info"), do: "info"
  defp badge_color("success"), do: "success"
  defp badge_color("warning"), do: "warning"
  defp badge_color("error"), do: "danger"
  defp badge_color(_neutral_or_ghost), do: "gray"

  @doc """
  Whether a rule is on, only simulating, or off - as one chip.

  A rule's state is the first thing an admin looks for in a list, and a
  coloured dot alone never said which of the three it was, so it is spelled
  out. `Ui.rule_state_tone/1` gives the same three states as a tone, for the
  rail that leads a row.

  ## Example

      <.rule_state rule={rule} />
  """
  attr :rule, :map, required: true
  attr :size, :string, default: "xs", values: ~w(xs sm)

  def rule_state(assigns) do
    ~H"""
    <.tone_badge tone={rule_state_tone(@rule)} size={@size} icon={rule_state_icon(@rule)}>
      {rule_state_label(@rule)}
    </.tone_badge>
    """
  end

  @doc """
  The tone of a rule's state: `success` running, `warning` simulating,
  `neutral` off.
  """
  @spec rule_state_tone(map()) :: String.t()
  def rule_state_tone(%{enabled: false}), do: "neutral"
  def rule_state_tone(%{simulation: true}), do: "warning"
  def rule_state_tone(_rule), do: "success"

  defp rule_state_icon(%{enabled: false}), do: "hero-pause-circle"
  defp rule_state_icon(%{simulation: true}), do: "hero-beaker"
  defp rule_state_icon(_rule), do: "hero-bolt"

  defp rule_state_label(%{enabled: false}), do: gettext("Off")
  defp rule_state_label(%{simulation: true}), do: gettext("Simulating")
  defp rule_state_label(_rule), do: gettext("Live")

  @doc """
  The little status dot that leads list rows; always carries a text label
  for assistive technology via `label`.
  """
  attr :tone, :string, required: true, values: ~w(neutral info success warning error)
  attr :label, :string, required: true
  attr :class, :any, default: nil

  def status_dot(assigns) do
    ~H"""
    <span class={["inline-flex size-2 shrink-0 rounded-full", dot_tone(@tone), @class]} title={@label}>
      <span class="sr-only">{@label}</span>
    </span>
    """
  end

  defp dot_tone("info"), do: "bg-info"
  defp dot_tone("success"), do: "bg-success"
  defp dot_tone("warning"), do: "bg-warning"
  defp dot_tone("error"), do: "bg-error"
  defp dot_tone(_neutral), do: "bg-base-300"

  # ── Skeletons ──────────────────────────────────────────────────────────────

  @doc """
  Loading placeholders for content still on its way from CRCON. Marked busy
  for assistive technology; pair with real content behind `:if`.
  """
  attr :lines, :integer, default: 3
  attr :class, :any, default: nil

  def skeleton(assigns) do
    ~H"""
    <div class={["space-y-2", @class]} role="status" aria-label={gettext("Loading")}>
      <div
        :for={index <- 1..@lines}
        class={[
          "h-4 animate-pulse rounded-field bg-base-300/70",
          if(rem(index, 3) == 0, do: "w-1/2", else: "w-full")
        ]}
      >
      </div>
    </div>
    """
  end

  @doc """
  An inline block-shaped loading placeholder (for stat values and the like).
  """
  attr :class, :any, default: "h-6 w-16"

  def skeleton_block(assigns) do
    ~H"""
    <span
      class={["inline-block animate-pulse rounded-field bg-base-300/70 align-middle", @class]}
      role="status"
      aria-label={gettext("Loading")}
    ></span>
    """
  end

  # ── Time ───────────────────────────────────────────────────────────────────

  @doc """
  A timestamp rendered in the viewer's locale and timezone.

  `format="relative"` (the default) shows "2 min ago" via
  `Intl.RelativeTimeFormat`, refreshed every half minute, with the absolute
  local time in the tooltip. `format="time"` and `format="datetime"` show
  absolute local time. The server-rendered UTC fallback is replaced as soon
  as the hook mounts, so tests and no-JS renders still see a value.
  """
  attr :id, :string, required: true
  attr :at, :any, required: true, doc: "a DateTime or NaiveDateTime (assumed UTC)"
  attr :format, :string, default: "relative", values: ~w(relative time datetime)
  attr :class, :any, default: nil

  def local_time(%{at: nil} = assigns), do: ~H"<span class={@class}>–</span>"

  def local_time(assigns) do
    assigns = assign(assigns, :utc, to_utc(assigns.at))

    ~H"""
    <time
      id={@id}
      datetime={DateTime.to_iso8601(@utc)}
      data-format={@format}
      phx-hook=".LocalTime"
      class={["whitespace-nowrap tabular-nums", @class]}
    >{Calendar.strftime(@utc, "%Y-%m-%d %H:%M")}</time>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      const lang = () => document.documentElement.lang || "en"

      const UNITS = [
        [60, "second"], [3600, "minute"], [86400, "hour"], [604800, "day"],
        [2629800, "week"], [31557600, "month"], [Infinity, "year"],
      ]

      function relative(date) {
        const seconds = (date.getTime() - Date.now()) / 1000
        const abs = Math.abs(seconds)
        let cumulative = 1
        for (const [limit, unit] of UNITS) {
          if (abs < limit) {
            const value = Math.round(seconds / cumulative)
            return new Intl.RelativeTimeFormat(lang(), {numeric: "auto"}).format(value, unit)
          }
          cumulative = limit
        }
      }

      export default {
        mounted() {
          this.date = new Date(this.el.getAttribute("datetime"))
          this.render()
          if (this.el.dataset.format === "relative") {
            this.timer = setInterval(() => this.render(), 30000)
          }
        },
        updated() {
          this.date = new Date(this.el.getAttribute("datetime"))
          this.render()
        },
        destroyed() {
          if (this.timer) clearInterval(this.timer)
        },
        render() {
          const full = new Intl.DateTimeFormat(lang(), {dateStyle: "short", timeStyle: "medium"})
          this.el.title = full.format(this.date)
          switch (this.el.dataset.format) {
            case "time":
              this.el.textContent = new Intl.DateTimeFormat(lang(), {timeStyle: "medium"}).format(this.date)
              break
            case "datetime":
              this.el.textContent = new Intl.DateTimeFormat(lang(), {dateStyle: "short", timeStyle: "short"}).format(this.date)
              break
            default:
              this.el.textContent = relative(this.date)
          }
        }
      }
    </script>
    """
  end

  defp to_utc(%DateTime{} = at), do: at
  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  # ── Artwork ────────────────────────────────────────────────────────────────

  @doc """
  Deterministic Hell Let Loose map artwork for a server, so a server keeps
  the same banner between visits. Decorative: always render with `alt=""`
  or as a background under a scrim.
  """
  def server_art(%{id: id}) when is_integer(id) do
    Enum.at(
      [
        "/images/hll/map-carentan.webp",
        "/images/hll/map-foy.webp",
        "/images/hll/map-stalingrad.webp"
      ],
      rem(id, 3)
    )
  end

  def server_art(_server), do: "/images/hll/banner.webp"

  # ── Paging ─────────────────────────────────────────────────────────────────

  @doc """
  The footer of a long list: which rows these are, and how to reach the rest.

  The range is stated in words ("1–50 of 213") rather than as page numbers
  alone, because "which page am I on" is never the real question — "have I
  seen everything" is. Numbered buttons appear only around the current page,
  so a history with two hundred pages does not render two hundred buttons.

  ## Example

      <.pagination page={@page} per_page={@per_page} total={@total} on_page="page" />
  """
  attr :page, :integer, required: true, doc: "1-based"
  attr :per_page, :integer, required: true
  attr :total, :integer, required: true, doc: "rows matching the filters, all pages"
  attr :on_page, :string, required: true, doc: "event name; receives %{\"page\" => n}"
  attr :class, :any, default: nil

  def pagination(assigns) do
    pages = max(ceil(assigns.total / max(assigns.per_page, 1)), 1)
    page = assigns.page |> max(1) |> min(pages)

    assigns =
      assigns
      |> assign(:pages, pages)
      |> assign(:page, page)
      |> assign(:first, (page - 1) * assigns.per_page + 1)
      |> assign(:last, min(page * assigns.per_page, assigns.total))
      |> assign(:window, page_window(page, pages))

    ~H"""
    <nav
      :if={@total > 0}
      class={[
        "flex flex-wrap items-center justify-between gap-3 border-t border-base-300 px-4 py-3",
        @class
      ]}
      aria-label={gettext("Pages")}
    >
      <p class="text-label-small text-muted">
        {gettext("%{first}–%{last} of %{total}", first: @first, last: @last, total: @total)}
      </p>

      <div :if={@pages > 1} class="flex items-center gap-1">
        <button
          type="button"
          class="flex size-8 cursor-pointer items-center justify-center rounded-field text-muted transition-colors hover:bg-base-200 hover:text-base-content disabled:cursor-default disabled:opacity-40 disabled:hover:bg-transparent"
          disabled={@page == 1}
          phx-click={@on_page}
          phx-value-page={@page - 1}
          aria-label={gettext("Previous page")}
        >
          <.icon name="hero-chevron-left" class="size-4" />
        </button>

        <button
          :for={number <- @window}
          type="button"
          class={[
            "min-w-8 cursor-pointer rounded-field px-2 py-1.5 text-label-small transition-colors",
            if(number == @page,
              do: "bg-primary text-primary-content",
              else: "text-muted hover:bg-base-200 hover:text-base-content"
            )
          ]}
          phx-click={@on_page}
          phx-value-page={number}
          aria-current={number == @page && "page"}
          aria-label={gettext("Page %{number}", number: number)}
        >
          {number}
        </button>

        <button
          type="button"
          class="flex size-8 cursor-pointer items-center justify-center rounded-field text-muted transition-colors hover:bg-base-200 hover:text-base-content disabled:cursor-default disabled:opacity-40 disabled:hover:bg-transparent"
          disabled={@page == @pages}
          phx-click={@on_page}
          phx-value-page={@page + 1}
          aria-label={gettext("Next page")}
        >
          <.icon name="hero-chevron-right" class="size-4" />
        </button>
      </div>
    </nav>
    """
  end

  # At most five numbers, kept centred on the current page and clamped to the
  # ends so the row does not change width as you walk through it.
  defp page_window(page, pages) do
    span = min(5, pages)
    start = page |> Kernel.-(div(span, 2)) |> max(1) |> min(pages - span + 1)

    Enum.to_list(start..(start + span - 1))
  end

  # ── Dialog helper ──────────────────────────────────────────────────────────

  @doc """
  A `JS` command that opens the native `<dialog>` with the given id as a
  modal (the listener lives in `app.js`). Used by the mobile sidebar.
  """
  def show_dialog(js \\ %JS{}, id) do
    JS.dispatch(js, "app:show-dialog", to: "##{id}")
  end
end
