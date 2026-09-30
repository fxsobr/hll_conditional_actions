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
        <%!-- The caption row of the overview: small uppercase title with its
              icon, a hairline under it, controls on the right. --%>
        <div
          :if={@title || @action != []}
          class={[
            "flex flex-wrap items-center justify-between gap-2 pb-1",
            not @padded && "px-4 pt-4 sm:px-5"
          ]}
        >
          <div class="min-w-0">
            <h2 :if={@title} class="overview-card-title">
              <.icon :if={@icon} name={@icon} class="size-4 shrink-0" /> {@title}
            </h2>

            <p :if={@subtitle} class="mt-1 text-xs text-muted">{@subtitle}</p>
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
    <div class="flex flex-col gap-2 rounded-box bg-base-100 p-4 shadow-figma-card sm:p-5">
      <p class="flex items-center justify-between gap-2 text-[0.8125rem] text-subtle">
        <span class="truncate">{@label}</span>
        <span class={[
          "flex size-7 shrink-0 items-center justify-center rounded-selector",
          icon_box(@tone)
        ]}>
          <.icon name={@icon} class="size-4" />
        </span>
      </p>

      <p class="mt-auto truncate font-display text-[2.375rem] font-semibold leading-none tracking-tight tabular-nums">
        <%= if @inner_block != [] do %>
          {render_slot(@inner_block)}
        <% else %>
          {@value}
        <% end %>
      </p>

      <p :if={@hint} class="truncate text-xs text-muted">{@hint}</p>
    </div>
    """
  end

  # The rules icon box: a tinted gradient square carrying the tone.
  defp icon_box("primary"), do: "bg-gradient-primary text-primary"
  defp icon_box("info"), do: "bg-gradient-info text-info"
  defp icon_box("success"), do: "bg-gradient-success text-success"
  defp icon_box("warning"), do: "bg-gradient-warning text-warning"
  defp icon_box("error"), do: "bg-gradient-destructive text-error"
  defp icon_box(_neutral), do: "bg-base-200 text-muted"

  # ── Empty states ───────────────────────────────────────────────────────────

  @doc """
  The empty state (States board, "Vazio"): an icon, a title in the display
  face, one short paragraph and at most one action, centred on a panel.

      <.empty_state icon="hero-bolt" title={gettext("No rules yet")}
        description={gettext("Start from a ready recipe.")}>
        <:action>
          <.link navigate={~p"/rules/new"} class="chip-button chip-button--signal">…</.link>
        </:action>
      </.empty_state>

  The `:action` slot takes the button itself; `chip-button` (secondary),
  `chip-button--signal` (the one lime action) and `chip-button--inverse` are
  the board's shapes.
  """
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :card, :boolean, default: true, doc: "draw it on its own panel"
  attr :tone, :string, default: "primary", values: ~w(primary neutral engine warning error)
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :action, doc: "a single call to action"
  slot :inner_block, doc: "rich text in place of `description`"

  def empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex flex-col items-center justify-center gap-2 px-7 py-10 text-center",
        @card && "rounded-[1.75rem] bg-base-100",
        @class
      ]}
    >
      <.empty_art :if={art_for(@icon)} kind={art_for(@icon)} />
      <span
        :if={!art_for(@icon)}
        class={["mb-1 flex size-12 items-center justify-center rounded-2xl", state_tone(@tone)]}
      >
        <.icon name={@icon} class="size-6" />
      </span>

      <h2 class="font-display text-lg font-semibold">{@title}</h2>

      <p
        :if={@description || @inner_block != []}
        class="max-w-[19rem] text-[0.8125rem] leading-[1.45] text-subtle"
      >
        {@description}{render_slot(@inner_block)}
      </p>

      <div :if={@action != []} class="mt-1.5 flex flex-wrap justify-center gap-2">
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  # The drawings of the States board for the three empties it shows: no
  # rule yet, an empty inbox, a search that found nothing.
  defp art_for("hero-bolt"), do: :rules
  defp art_for(icon) when icon in ["hero-inbox", "hero-inbox-stack"], do: :inbox
  defp art_for("hero-magnifying-glass"), do: :search
  defp art_for(_icon), do: nil

  attr :kind, :atom, required: true

  defp empty_art(%{kind: :rules} = assigns) do
    ~H"""
    <svg width="64" height="48" viewBox="0 0 64 48" fill="none" aria-hidden="true" class="mb-1">
      <rect
        x="6"
        y="6"
        width="36"
        height="12"
        rx="6"
        class="stroke-line-strong"
        stroke-width="1.5"
        stroke-dasharray="4 4"
      />
      <rect
        x="14"
        y="22"
        width="44"
        height="12"
        rx="6"
        class="stroke-line-strong"
        stroke-width="1.5"
        stroke-dasharray="4 4"
      />
      <rect x="6" y="38" width="24" height="8" rx="4" class="fill-primary" />
    </svg>
    """
  end

  defp empty_art(%{kind: :inbox} = assigns) do
    ~H"""
    <svg width="64" height="48" viewBox="0 0 64 48" fill="none" aria-hidden="true" class="mb-1">
      <path
        d="M8 26h14l4 6h12l4-6h14"
        class="stroke-line-strong"
        stroke-width="1.5"
        stroke-linejoin="round"
      />
      <path
        d="M14 10h36l6 16v14H8V26l6-16z"
        class="stroke-line-strong"
        stroke-width="1.5"
        stroke-linejoin="round"
      />
      <circle cx="46" cy="10" r="8" class="fill-primary" />
      <path
        d="m42.5 10 2.5 2.5 4.5-5"
        class="stroke-primary-content"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  defp empty_art(%{kind: :search} = assigns) do
    ~H"""
    <svg width="64" height="48" viewBox="0 0 64 48" fill="none" aria-hidden="true" class="mb-1">
      <circle cx="26" cy="22" r="14" class="stroke-line-strong" stroke-width="1.5" />
      <path d="m36 32 12 12" class="stroke-line-strong" stroke-width="1.5" stroke-linecap="round" />
      <path d="M20 22h12" class="stroke-muted" stroke-width="1.5" stroke-linecap="round" />
    </svg>
    """
  end

  defp state_tone("neutral"), do: "bg-secondary text-subtle"
  defp state_tone("engine"), do: "bg-accent/13 text-accent"
  defp state_tone("warning"), do: "bg-warning/13 text-warning"
  defp state_tone("error"), do: "bg-error/14 text-error"
  defp state_tone(_primary), do: "bg-primary/12 text-primary"

  # ── Error, permission and banners ──────────────────────────────────────────

  @doc """
  Something failed and the page says what and what to do (States board,
  "Erro"): an icon tile, a title, what happened, and the ways out.

      <.error_state id="crcon-down" title={gettext("CRCON of %{server} is down", server: name)}>
        {gettext("We tried 3 times.")}
        <:actions>
          <button class="chip-button chip-button--inverse" phx-click="retry">…</button>
        </:actions>
        <:aside>{gettext("next in 28 s")}</:aside>
      </.error_state>
  """
  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :icon, :string, default: "hero-server-stack"
  attr :class, :any, default: nil
  slot :inner_block
  slot :actions
  slot :aside, doc: "a quiet note at the end of the actions row, e.g. the next retry"

  def error_state(assigns) do
    ~H"""
    <section id={@id} role="alert" class={["state-panel state-panel--error", @class]}>
      <div class="flex items-center gap-3">
        <span class="flex size-[2.375rem] shrink-0 items-center justify-center rounded-xl bg-error/14 text-error">
          <.icon name={@icon} class="size-5" />
        </span>
        <strong class="font-display text-lg font-semibold">{@title}</strong>
      </div>
      <p :if={@inner_block != []} class="text-[0.8125rem] leading-[1.45] text-subtle">
        {render_slot(@inner_block)}
      </p>
      <div
        :if={@actions != [] or @aside != []}
        class="mt-auto flex flex-wrap items-center gap-2 pt-2"
      >
        {render_slot(@actions)}
        <span :if={@aside != []} class="ml-auto font-mono text-[0.6875rem] text-muted">
          {render_slot(@aside)}
        </span>
      </div>
    </section>
    """
  end

  @doc """
  The user may see the page but not do this (States board, "Sem
  permissão"): which role they have and which permission is missing.
  """
  attr :id, :string, default: nil
  attr :role, :string, default: nil, doc: "the user's role name"
  attr :permission, :string, default: nil, doc: "the missing permission, in words"

  attr :can, :string,
    default: nil,
    doc: ~s(what the role still does here, "sees the rules but cannot edit them")

  attr :back, :string, default: "/", doc: "where the way out goes"
  attr :class, :any, default: nil
  slot :actions

  def no_permission(assigns) do
    ~H"""
    <section id={@id} class={["state-panel", @class]}>
      <div class="flex items-center gap-3">
        <span class="flex size-[2.375rem] shrink-0 items-center justify-center rounded-xl bg-secondary text-subtle">
          <.icon name="hero-lock-closed" class="size-5" />
        </span>
        <strong class="flex-1 font-display text-lg font-semibold">{gettext("No permission")}</strong>
        <span class="rounded-lg bg-secondary px-2 py-1 font-mono text-xs text-subtle">403</span>
      </div>
      <p class="text-[0.8125rem] leading-[1.45] text-subtle">
        <%= cond do %>
          <% @role && @can -> %>
            {gettext("Your role,")}
            <strong class="font-semibold text-base-content">{@role}</strong>, {@can}.
          <% @role -> %>
            {gettext("Your role,")}
            <strong class="font-semibold text-base-content">{@role}</strong>{gettext(
              ", cannot do this."
            )}
          <% true -> %>
            {gettext("Your role cannot do this.")}
        <% end %>
        <span :if={@permission}>
          {gettext("The “%{permission}” permission is missing.", permission: @permission)}
        </span>
      </p>
      <div class="mt-auto flex flex-wrap gap-2 pt-2">
        {render_slot(@actions)}
        <.link navigate={@back} class="chip-button chip-button--ghost">
          {gettext("Back to the Briefing")}
        </.link>
      </div>
    </section>
    """
  end

  @doc """
  A strip that tells what is wrong right now across the page (States
  board): `error` with a glowing dot (a stream down, offline), `warning`
  with an icon tile (a rule paused on its own). The action is optional.
  """
  attr :id, :string, default: nil
  attr :tone, :string, default: "error", values: ~w(error warning)
  attr :title, :string, required: true
  attr :detail, :string, default: nil
  attr :icon, :string, default: "hero-pause"
  attr :class, :any, default: nil
  slot :action

  def banner(assigns) do
    ~H"""
    <div
      id={@id}
      role={if @tone == "error", do: "alert", else: "status"}
      class={["state-banner", "state-banner--#{@tone}", @class]}
    >
      <span
        :if={@tone == "error"}
        class="state-banner-dot size-[0.5625rem] shrink-0 rounded-full bg-error"
        aria-hidden="true"
      ></span>
      <span
        :if={@tone == "warning"}
        class="flex size-[1.875rem] shrink-0 items-center justify-center rounded-[0.625rem] bg-warning/16 text-warning"
      >
        <.icon name={@icon} class="size-4" />
      </span>
      <span class="flex min-w-0 flex-1 flex-col gap-0.5">
        <strong class="text-sm font-semibold">{@title}</strong>
        <span
          :if={@detail}
          class={["text-xs", if(@tone == "error", do: "text-error", else: "text-warning")]}
        >
          {@detail}
        </span>
      </span>
      {render_slot(@action)}
    </div>
    """
  end

  # ── Loading ────────────────────────────────────────────────────────────────

  @doc """
  The loading placeholders of the States board ("Carregando"), shaped like
  what is on its way: `kpis` (a row of big-number tiles), `table` (rows
  with a lead tile) and `feed` (time, icon, line, and what is being waited
  for). Marked busy for assistive technology.
  """
  attr :id, :string, default: nil
  attr :variant, :string, default: "table", values: ~w(kpis table feed)
  attr :count, :integer, default: 3, doc: "tiles or rows"
  attr :label, :string, default: nil, doc: "feed only: what is being waited for"
  attr :class, :any, default: nil

  def loading_state(%{variant: "kpis"} = assigns) do
    ~H"""
    <section
      id={@id}
      aria-busy="true"
      aria-label={gettext("Loading")}
      class={["grid gap-2.5 rounded-[1.75rem] bg-base-100 p-3", @class]}
      style={"grid-template-columns: repeat(#{@count}, minmax(0, 1fr))"}
    >
      <div
        :for={i <- 1..@count}
        class="flex min-h-[7rem] flex-col justify-between gap-6 rounded-[1.25rem] bg-secondary px-[1.125rem] py-4"
      >
        <span class="skeleton-bar h-2.5" style={"width: #{Enum.at([70, 60, 65, 55, 75], rem(i, 5))}%"}></span>
        <span class="flex flex-col gap-2">
          <span class="skeleton-bar skeleton-bar--strong h-[1.625rem] w-1/2 rounded-lg"></span>
          <span class="skeleton-bar h-2 w-4/5"></span>
        </span>
      </div>
    </section>
    """
  end

  def loading_state(%{variant: "feed"} = assigns) do
    ~H"""
    <section
      id={@id}
      aria-busy="true"
      aria-label={@label || gettext("Loading")}
      class={["flex flex-col gap-4 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-4", @class]}
    >
      <div
        :for={i <- 1..@count}
        class="grid grid-cols-[3.625rem_1.125rem_minmax(0,1fr)] items-center gap-3"
      >
        <span class="skeleton-bar skeleton-bar--soft h-2"></span>
        <span class="size-[1.125rem] rounded-full bg-secondary"></span>
        <span class="skeleton-bar h-2.5" style={"width: #{Enum.at([76, 58, 88], rem(i, 3))}%"}></span>
      </div>
      <span :if={@label} class="flex items-center gap-2 text-xs text-muted">
        <span class="size-[7px] rounded-full border-[1.5px] border-primary"></span>
        {@label}
      </span>
    </section>
    """
  end

  def loading_state(assigns) do
    ~H"""
    <section
      id={@id}
      aria-busy="true"
      aria-label={gettext("Loading")}
      class={["flex flex-col gap-4 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-4", @class]}
    >
      <div
        :for={i <- 1..@count}
        class="grid grid-cols-[1.75rem_minmax(0,1fr)_3.75rem_3.125rem] items-center gap-3"
      >
        <span class="size-7 rounded-[0.5625rem] bg-secondary"></span>
        <span class="skeleton-bar h-2.5" style={"width: #{Enum.at([70, 55, 82], rem(i, 3))}%"}></span>
        <span class="skeleton-bar skeleton-bar--soft h-2.5"></span>
        <span class="skeleton-bar skeleton-bar--soft h-2.5"></span>
      </div>
    </section>
    """
  end

  # ── Confirmation ───────────────────────────────────────────────────────────

  @doc """
  The confirmation dialog of the States board: centred, an icon tile in the
  action's tone, a question for a title, what will happen under it, the
  fields the action needs, and a footer with a note, Cancel and the action.

  Like `modal/1` it renders open, so drive it with `:if`, and pass the
  command that leaves that state as `on_cancel`.

      <.confirm_dialog :if={@banning} id="ban" tone="axis" icon="hero-no-symbol"
        title={gettext("Ban %{player} for 2 hours?", player: name)}
        on_cancel={JS.push("cancel_ban")}>
        …fields…
        <:note>{gettext("Stays in their history")}</:note>
        <:confirm><button class="chip-button chip-button--danger" …>…</button></:confirm>
      </.confirm_dialog>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :icon, :string, default: "hero-exclamation-triangle"
  attr :tone, :string, default: "axis", values: ~w(axis error warning primary engine neutral)
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block
  slot :note
  slot :confirm, required: true

  def confirm_dialog(assigns) do
    ~H"""
    <dialog
      id={@id}
      class="app-modal app-modal--center"
      phx-hook=".AppModal"
      data-cancel={@on_cancel}
      role="alertdialog"
      aria-labelledby={"#{@id}-title"}
    >
      <div class="flex flex-col gap-3.5 rounded-[1.625rem] border border-line-raised bg-base-100 px-6 py-[1.375rem] shadow-[var(--shadow-dialog)]">
        <div class="flex items-start gap-3.5">
          <span class={[
            "flex size-11 shrink-0 items-center justify-center rounded-[0.875rem]",
            confirm_tone(@tone)
          ]}>
            <.icon name={@icon} class="size-5" />
          </span>
          <div class="flex min-w-0 flex-1 flex-col gap-[3px]">
            <h3
              id={"#{@id}-title"}
              class="font-display text-[1.375rem] font-semibold tracking-[-0.01em]"
            >
              {@title}
            </h3>
            <p :if={@subtitle} class="text-[0.8125rem] text-subtle">{@subtitle}</p>
          </div>
          <form method="dialog">
            <button
              class="flex size-8 shrink-0 cursor-pointer items-center justify-center rounded-full bg-secondary text-subtle"
              aria-label={gettext("Close")}
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </form>
        </div>

        {render_slot(@inner_block)}

        <div class="mt-0.5 flex flex-wrap items-center gap-2.5">
          <span class="flex-1 text-xs text-muted">{render_slot(@note)}</span>
          <form method="dialog">
            <button class="chip-button h-12 px-5 text-sm">{gettext("Cancel")}</button>
          </form>
          {render_slot(@confirm)}
        </div>
      </div>
    </dialog>
    """
  end

  defp confirm_tone("axis"), do: "bg-axis/16 text-axis"
  defp confirm_tone("error"), do: "bg-error/14 text-error"
  defp confirm_tone("warning"), do: "bg-warning/13 text-warning"
  defp confirm_tone("primary"), do: "bg-primary/12 text-primary"
  defp confirm_tone("engine"), do: "bg-accent/13 text-accent"
  defp confirm_tone(_neutral), do: "bg-secondary text-subtle"

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
      <div class="flex h-full flex-col bg-base-100 shadow-figma-card-large lg:rounded-l-[1.75rem]">
        <div class="flex shrink-0 items-start justify-between gap-3 border-b border-base-300 px-5 py-5 sm:px-7">
          <div class="min-w-0">
            <h3 id={"#{@id}-title"} class="font-display text-xl font-semibold">{@title}</h3>

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
      class="flex flex-wrap items-center gap-2 rounded-box bg-base-100 p-2 shadow-figma-card"
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
    <fieldset class="flex items-center gap-1 rounded-full bg-secondary p-1">
      <legend class="sr-only">{@label}</legend>

      <label :for={{label, value} <- @options} class="cursor-pointer">
        <input
          type="radio"
          name={@name}
          value={value}
          checked={to_string(@value) == to_string(value)}
          class="peer sr-only"
        />
        <span class="block whitespace-nowrap rounded-full px-3.5 py-1.5 text-xs text-subtle transition-colors hover:text-base-content peer-checked:bg-base-content peer-checked:font-semibold peer-checked:text-base-100 peer-focus-visible:ring-2 peer-focus-visible:ring-primary/50">
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

  attr :rest, :global,
    include: ~w(navigate patch href method phx-click phx-value-id phx-value-preset data-confirm)

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
    values: ~w(neutral primary info success warning error ghost engine)

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
  defp badge_color("engine"), do: "secondary"
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
    <.pill tone={rule_state_pill(@rule)} class={@size == "xs" && "h-6 px-2.5 text-[0.6875rem]"}>
      {rule_state_label(@rule)}
    </.pill>
    """
  end

  @doc """
  The tone of a rule's state: `success` running, `warning` simulating,
  `neutral` off.
  """
  @spec rule_state_tone(map()) :: String.t()
  def rule_state_tone(rule) do
    cond do
      not rule.enabled -> "neutral"
      rule_paused?(rule) -> "info"
      rule.simulation -> "warning"
      true -> "success"
    end
  end

  @doc """
  Whether a rule (or anything shaped like one) is in a temporary pause now.
  """
  @spec rule_paused?(map()) :: boolean()
  def rule_paused?(%{paused_until: %DateTime{} = until}),
    do: DateTime.compare(until, DateTime.utc_now()) == :gt

  def rule_paused?(_rule), do: false

  defp rule_state_pill(rule) do
    case rule_state_tone(rule) do
      "neutral" -> "neutral"
      "info" -> "warning"
      "warning" -> "simulating"
      _live -> "live"
    end
  end

  @doc "The word for a rule's state: Live, Simulating, Paused or Off."
  @spec rule_state_label(map()) :: String.t()
  def rule_state_label(rule) do
    case rule_state_tone(rule) do
      "neutral" -> gettext("Off")
      "info" -> gettext("Paused")
      "warning" -> gettext("Simulating")
      _live -> gettext("Live")
    end
  end

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
  The picture of the map a server is playing, with its time of day; before
  the engine has read the game state, one of the game's maps, always the
  same for a server. Decorative: always render with `alt=""`
  or as a background under a scrim.
  """
  @hll_art ~w(carentan-day foy-day stmereeglise-day omahabeach-day utahbeach-day
              purpleheartlane-day hurtgenforest-day kursk-day stalingrad-day remagen-day
              elalamein-day driel-day elsenbornridge-day mortain-day hill400-day)
  @hllv_art ~w(wdeva-day wdevb-day wdevc-day wdevd-day wdeve-day wdevf-day)

  def server_art(%{id: id} = server) when is_integer(id) do
    case HllConditionalActions.Engine.Runner.current_map(id) do
      nil -> fallback_art(server)
      map -> HllConditionalActionsWeb.MapArt.url(Map.get(server, :game), map)
    end
  end

  def server_art(_server), do: "/images/hll/banner.webp"

  # Until the engine reads the game state: one of the game's maps, always
  # the same for a server.
  defp fallback_art(%{id: id} = server) do
    {game, pictures} =
      if Map.get(server, :game) == :hllv, do: {"hllv", @hllv_art}, else: {"hll", @hll_art}

    "/images/maps/#{game}/#{Enum.at(pictures, rem(id, length(pictures)))}.webp"
  end

  @doc """
  The app's mark: two chevrons on the signal tile, the same drawing as the
  rail's logo. Decorative; the product name always sits next to it.
  """
  attr :class, :any, default: "size-9"

  def logo_mark(assigns) do
    ~H"""
    <svg viewBox="0 0 64 64" fill="none" class={@class} aria-hidden="true">
      <rect width="64" height="64" rx="20" fill="#d2f36b" />
      <path
        d="m17.3 29.3 14.7-10.6 14.7 10.6M17.3 42 32 31.3 46.7 42"
        stroke="#1a2006"
        stroke-width="5"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

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

  # ── Posto de Comando pieces ────────────────────────────────────────────────
  # The components of the overhaul's Components board that pages share. Each
  # paints with the semantic tokens only, so it follows light and dark.

  @doc """
  A status pill: a dot and a word. `simulating` gets the dashed engine dot,
  `live` the solid signal dot.

      <.pill tone="live">{gettext("Live")}</.pill>
      <.pill tone="simulating">{gettext("Simulating")}</.pill>
  """
  attr :tone, :string,
    default: "neutral",
    values: ~w(live simulating neutral warning error info engine)

  attr :dot, :boolean, default: true
  attr :class, :any, default: nil
  attr :id, :string, default: nil
  slot :inner_block, required: true

  def pill(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "inline-flex h-7 shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full px-3 text-xs font-semibold",
        pill_tone(@tone),
        @class
      ]}
    >
      <span
        :if={@dot}
        class={[
          "size-[7px] shrink-0 rounded-full",
          if(@tone == "simulating",
            do: "border-[1.5px] border-dashed border-current",
            else: "bg-current"
          )
        ]}
        aria-hidden="true"
      ></span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp pill_tone("live"), do: "bg-primary/12 text-primary"
  defp pill_tone(tone) when tone in ["simulating", "engine"], do: "bg-accent/13 text-accent"
  defp pill_tone("warning"), do: "bg-warning/13 text-warning"
  defp pill_tone("error"), do: "bg-error/14 text-error"
  defp pill_tone("info"), do: "bg-info/14 text-info"
  defp pill_tone(_neutral), do: "bg-secondary text-subtle"

  @doc """
  A small tile holding an icon, tinted by tone: the lead of list rows and the
  corner of panels.
  """
  attr :icon, :string, required: true

  attr :tone, :string,
    default: "neutral",
    values: ~w(neutral primary engine warning error info allies axis)

  attr :size, :string, default: "md", values: ~w(sm md lg)

  def icon_tile(assigns) do
    ~H"""
    <span class={[
      "flex shrink-0 items-center justify-center",
      tile_size(@size),
      tile_tone(@tone)
    ]}>
      <.icon name={@icon} class={if @size == "sm", do: "size-3.5", else: "size-[1.125rem]"} />
    </span>
    """
  end

  defp tile_size("sm"), do: "size-7 rounded-[0.625rem]"
  defp tile_size("lg"), do: "size-11 rounded-[0.875rem]"
  defp tile_size(_md), do: "size-10 rounded-xl"

  defp tile_tone("primary"), do: "bg-primary/12 text-primary"
  defp tile_tone("engine"), do: "bg-accent/13 text-accent"
  defp tile_tone("warning"), do: "bg-warning/13 text-warning"
  defp tile_tone("error"), do: "bg-error/14 text-error"
  defp tile_tone("info"), do: "bg-info/14 text-info"
  defp tile_tone("allies"), do: "bg-allies/14 text-allies"
  defp tile_tone("axis"), do: "bg-axis/14 text-axis"
  defp tile_tone(_neutral), do: "bg-secondary text-subtle"

  @doc """
  One row of a list inside a panel: icon tile, title, one line of context,
  and whatever sits on the right (a pill, a time, a count).
  """
  attr :icon, :string, default: nil
  attr :tone, :string, default: "neutral"
  attr :title, :string, required: true
  attr :meta, :string, default: nil
  attr :rest, :global, include: ~w(navigate patch href)
  slot :aside

  def list_row(assigns) do
    ~H"""
    <.link
      class="flex items-center gap-3.5 rounded-2xl px-2 py-2.5 transition-colors hover:bg-secondary"
      {@rest}
    >
      <.icon_tile :if={@icon} icon={@icon} tone={@tone} />
      <span class="flex min-w-0 flex-1 flex-col gap-0.5">
        <strong class="truncate text-sm font-semibold">{@title}</strong>
        <span :if={@meta} class="truncate text-xs text-muted">{@meta}</span>
      </span>
      {render_slot(@aside)}
    </.link>
    """
  end

  @doc """
  A team's name or number in its colour: blue for the Allies, orange for the
  Axis. `team` takes the CRCON spelling (`allies`/`axis`).
  """
  attr :team, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def team_chip(assigns) do
    ~H"""
    <span class={[team_text(@team), "font-semibold", @class]}>{render_slot(@inner_block)}</span>
    """
  end

  @doc "The text colour of a team."
  @spec team_text(String.t() | atom() | nil) :: String.t()
  def team_text(team) when team in ["allies", :allies, "Allies"], do: "text-allies"
  def team_text(team) when team in ["axis", :axis, "Axis"], do: "text-axis"
  def team_text(_none), do: "text-base-content"

  @doc """
  The five sectors of a warfare match, coloured by who holds them.
  """
  attr :allied, :integer, required: true, doc: "sectors held by the Allies (0-5)"
  attr :total, :integer, default: 5
  attr :size, :string, default: "md", values: ~w(sm md lg)
  attr :class, :any, default: nil

  def sector_bar(assigns) do
    ~H"""
    <div
      class={["grid gap-1", @class]}
      style={"grid-template-columns: repeat(#{@total}, minmax(0, 1fr))"}
      role="img"
      aria-label={
        gettext("Allies hold %{allied} of %{total} sectors", allied: @allied, total: @total)
      }
    >
      <span
        :for={index <- 1..@total}
        class={[
          "rounded-[4px]",
          case @size do
            "sm" -> "h-[5px]"
            "lg" -> "h-3"
            _md -> "h-2.5"
          end,
          if(index <= @allied, do: "bg-allies", else: "bg-axis")
        ]}
      ></span>
    </div>
    """
  end

  @doc "How many players each team has, as one split bar."
  attr :allies, :integer, required: true
  attr :axis, :integer, required: true
  attr :class, :any, default: nil

  def balance_bar(assigns) do
    ~H"""
    <div
      class={["flex h-2 gap-[3px] overflow-hidden rounded", @class]}
      role="img"
      aria-label={gettext("%{allies} Allies, %{axis} Axis", allies: @allies, axis: @axis)}
    >
      <span class="rounded bg-allies" style={"flex-grow: #{max(@allies, 0)}"}></span>
      <span class="rounded bg-axis" style={"flex-grow: #{max(@axis, 0)}"}></span>
    </div>
    """
  end

  @doc """
  A row of small bars for a short series (the last 7 days, the last 10
  matches). The last bar can be highlighted.
  """
  attr :values, :list, required: true
  attr :highlight_last, :boolean, default: false
  attr :class, :any, default: "h-10"
  attr :label, :string, required: true

  def sparkline(assigns) do
    assigns = assign(assigns, :max, Enum.max([1 | assigns.values]))

    ~H"""
    <div class={["flex items-end gap-1", @class]} role="img" aria-label={@label}>
      <span
        :for={{value, index} <- Enum.with_index(@values, 1)}
        class={[
          "min-h-[2px] flex-1 rounded-[3px]",
          if(@highlight_last and index == length(@values), do: "bg-primary", else: "bg-base-300")
        ]}
        style={"height: #{round(value / @max * 100)}%"}
      ></span>
    </div>
    """
  end

  @doc """
  An achievement medal: a hexagon in the tier's colour with an icon.
  """
  attr :tier, :string, required: true, values: ~w(bronze silver gold legendary)
  attr :icon, :string, default: "hero-trophy"
  attr :size, :string, default: "md", values: ~w(sm md lg)

  def medal(assigns) do
    ~H"""
    <span
      class={[
        "medal flex shrink-0 items-center justify-center",
        "medal--#{@tier}",
        case @size do
          "sm" -> "size-8"
          "lg" -> "size-16"
          _md -> "size-14"
        end
      ]}
      aria-hidden="true"
    >
      <.icon :if={@size != "sm"} name={@icon} class="size-6" />
    </span>
    """
  end

  @doc """
  What the engine read for one condition, and whether it passed:
  "✓ read 3" / "✗ read “yes”". `pass` nil means not evaluated.
  """
  attr :pass, :any, required: true
  slot :inner_block, required: true

  def trace_chip(assigns) do
    ~H"""
    <span class={[
      "inline-flex h-7 items-center justify-center gap-1.5 rounded-full px-3 font-mono text-xs",
      case @pass do
        true -> "bg-primary/12 text-primary"
        false -> "bg-error/14 text-error"
        _not_evaluated -> "bg-secondary text-muted"
      end
    ]}>
      <span aria-hidden="true">
        {case @pass do
          true -> "✓"
          false -> "✗"
          _ -> "–"
        end}
      </span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  Pill tabs that are links (sub-pages of an area, the tabs of a rule). For
  a choice inside a form use `segmented/1`.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true

  slot :tab, required: true do
    attr :navigate, :string
    attr :patch, :string
    attr :active, :boolean
    attr :count, :any
  end

  def sub_tabs(assigns) do
    ~H"""
    <nav id={@id} aria-label={@label} class="flex">
      <div class="flex flex-wrap gap-1 rounded-full bg-base-100 p-1">
        <.link
          :for={tab <- @tab}
          navigate={tab[:navigate]}
          patch={tab[:patch]}
          aria-current={tab[:active] && "page"}
          class={[
            "flex h-9 items-center gap-2 rounded-full px-4 text-[0.8125rem] transition-colors",
            if(tab[:active],
              do: "bg-base-content font-semibold text-base-100",
              else: "text-subtle hover:text-base-content"
            )
          ]}
        >
          {render_slot(tab)}
          <span :if={tab[:count] not in [nil, 0]} class="font-mono text-xs opacity-70">
            {tab[:count]}
          </span>
        </.link>
      </div>
    </nav>
    """
  end

  @doc """
  The big number of a tile: label on top, the value in the display face,
  one line of context under it. `stat/1` keeps its icon; this is the plain
  one the KPI rows use.
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil
  attr :tone, :string, default: nil, values: [nil, "primary", "warning", "engine", "error"]
  attr :class, :any, default: nil

  def kpi_tile(assigns) do
    ~H"""
    <div class={[
      "flex flex-col justify-between gap-3 rounded-[1.25rem] bg-secondary px-4.5 py-4",
      @class
    ]}>
      <span class="text-[0.8125rem] text-subtle">{@label}</span>
      <span>
        <span class={[
          "block font-display text-[2.375rem] font-semibold leading-none tracking-tight tabular-nums",
          case @tone do
            "primary" -> "text-primary"
            "warning" -> "text-warning"
            "engine" -> "text-accent"
            "error" -> "text-error"
            _ -> nil
          end
        ]}>
          {@value}
        </span>
        <span :if={@hint} class="mt-1 block truncate text-xs text-muted">{@hint}</span>
      </span>
    </div>
    """
  end
end
