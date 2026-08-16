defmodule HllConditionalActionsWeb.Overview do
  @moduledoc """
  The "360 view" building blocks, ported from the mono-repo's health
  `patient-360` components (`Patient360Header`, `Patient360Tabs`,
  `ClinicalKpiCards`, `ClinicalTimelineCard`).

  The shape is the same one the health product uses to answer *what is this
  thing and how has it been doing?* on a single screen:

    * `entity_header/1` — sticky identity bar: back, avatar, name, status
      pills, one meta line, actions
    * `view_tabs/1` — underline tabs that scroll horizontally on a phone
    * `kpi_cards/1` — a row of tinted-icon metrics, each optionally a button
      that jumps to the section that explains it
    * `timeline_card/1` — one event in the horizontal activity strip

  They are deliberately generic: this app's "patient" is a rule.
  """

  use Phoenix.Component
  use Gettext, backend: HllConditionalActionsWeb.Gettext

  import HllConditionalActionsWeb.Ui, only: [tone_badge: 1, local_time: 1, skeleton_block: 1]
  import PetalComponents.Icon

  # ── Identity header ────────────────────────────────────────────────────────

  @doc """
  The sticky identity bar of a 360 screen.

  ## Example

      <.entity_header
        title={@rule.name}
        initials="TK"
        meta="Player team kills · Every server"
        back={~p"/rules"}
        badges={[%{id: "state", label: "Active", tone: "success"}]}
      >
        <:actions><.button ...  /></:actions>
      </.entity_header>
  """
  attr :title, :string, required: true
  attr :meta, :string, default: nil, doc: "one line of context under the title"
  attr :back, :string, required: true, doc: "where the back arrow goes"
  attr :back_label, :string, default: nil
  attr :icon, :string, default: nil, doc: "heroicon shown in the avatar"
  attr :initials, :string, default: nil, doc: "used when there is no icon"
  attr :tone, :string, default: "primary", values: ~w(primary info success warning error)

  attr :badges, :list,
    default: [],
    doc: "maps of %{id, label, tone, icon} rendered as status pills"

  slot :actions, doc: "buttons pinned to the right"

  def entity_header(assigns) do
    assigns = assign_new(assigns, :back_label, fn -> gettext("Back") end)

    ~H"""
    <header class="-mx-4 -mt-4 mb-2 border-b border-base-300 bg-base-100 px-4 py-3 sm:-mx-6 sm:-mt-6 sm:px-6">
      <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-3">
        <div class="flex min-w-0 flex-1 items-center gap-3">
          <.link
            navigate={@back}
            aria-label={@back_label}
            class="flex size-9 shrink-0 items-center justify-center rounded-field text-muted transition-colors hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-chevron-left" class="size-4" />
          </.link>

          <div class={[
            "flex size-10 shrink-0 items-center justify-center rounded-full",
            avatar_tone(@tone)
          ]}>
            <.icon :if={@icon} name={@icon} class="size-5" />
            <span :if={is_nil(@icon) && @initials} class="text-sm font-semibold">
              {@initials}
            </span>
          </div>

          <div class="flex min-w-0 flex-col gap-1">
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="truncate text-title-large">{@title}</h2>

              <.tone_badge
                :for={badge <- @badges}
                tone={badge.tone}
                size="xs"
                icon={Map.get(badge, :icon)}
              >
                {badge.label}
              </.tone_badge>
            </div>

            <p :if={@meta} class="truncate text-label-small text-muted">{@meta}</p>
          </div>
        </div>

        <div :if={@actions != []} class="flex max-w-full flex-wrap items-center justify-end gap-2">
          {render_slot(@actions)}
        </div>
      </div>
    </header>
    """
  end

  defp avatar_tone("info"), do: "bg-gradient-info text-info"
  defp avatar_tone("success"), do: "bg-gradient-success text-success"
  defp avatar_tone("warning"), do: "bg-gradient-warning text-warning"
  defp avatar_tone("error"), do: "bg-gradient-destructive text-error"
  defp avatar_tone(_primary), do: "bg-gradient-primary text-primary"

  # ── Tabs ───────────────────────────────────────────────────────────────────

  @doc """
  Underline tabs. Each item is `%{id, label, count}` (count optional); the
  active one is driven by `active` and reported through `on_change`.
  """
  attr :id, :string, required: true
  attr :items, :list, required: true
  attr :active, :string, required: true
  attr :on_change, :string, required: true, doc: "the phx-click event name"
  attr :label, :string, default: nil, doc: "accessible name for the tab list"

  def view_tabs(assigns) do
    assigns = assign_new(assigns, :label, fn -> gettext("Sections") end)

    ~H"""
    <nav
      id={@id}
      aria-label={@label}
      class="-mx-4 flex items-end gap-0 overflow-x-auto border-b border-base-300 px-4 sm:-mx-6 sm:px-6 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
    >
      <button
        :for={item <- @items}
        type="button"
        phx-click={@on_change}
        phx-value-tab={item.id}
        aria-pressed={to_string(item.id == @active)}
        class={[
          "-mb-px inline-flex h-12 shrink-0 cursor-pointer items-center gap-2 whitespace-nowrap border-b-2 px-3.5 text-label-medium transition-colors",
          if(item.id == @active,
            do: "border-primary font-semibold text-base-content",
            else: "border-transparent text-muted hover:text-base-content"
          )
        ]}
      >
        {item.label}
        <span
          :if={item[:count]}
          class={[
            "rounded-pill px-1.5 py-0.5 text-label-small tabular-nums",
            if(item.id == @active,
              do: "bg-primary/10 text-primary",
              else: "bg-base-200 text-muted"
            )
          ]}
        >
          {item.count}
        </span>
      </button>
    </nav>
    """
  end

  # ── KPI cards ──────────────────────────────────────────────────────────────

  @doc """
  The metric strip. Each card is `%{id, label, value, hint, icon, tone}`;
  giving a card an `event` turns it into a button that jumps to the section
  explaining it, exactly as the health KPIs jump to their tab. A `value` of
  `:loading` renders a skeleton, for metrics still in flight.
  """
  attr :cards, :list, required: true
  attr :on_select, :string, default: nil, doc: "phx-click event for cards with an :event"

  def kpi_cards(assigns) do
    ~H"""
    <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
      <.kpi_card :for={card <- @cards} card={card} on_select={@on_select} />
    </div>
    """
  end

  attr :card, :map, required: true
  attr :on_select, :string, default: nil

  defp kpi_card(%{card: %{event: _}} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@on_select}
      phx-value-tab={@card.event}
      class="cursor-pointer rounded-box bg-base-100 p-4 text-left shadow-figma-card transition-shadow hover:shadow-figma-card-medium focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
    >
      <.kpi_body card={@card} linked />
    </button>
    """
  end

  defp kpi_card(assigns) do
    ~H"""
    <div class="rounded-box bg-base-100 p-4 shadow-figma-card">
      <.kpi_body card={@card} />
    </div>
    """
  end

  attr :card, :map, required: true
  attr :linked, :boolean, default: false

  defp kpi_body(assigns) do
    ~H"""
    <div class="flex items-start gap-3">
      <div class={[
        "flex size-10 shrink-0 items-center justify-center rounded-box",
        kpi_tone(@card[:tone])
      ]}>
        <.icon name={@card.icon} class="size-5" />
      </div>

      <div class="min-w-0 flex-1">
        <p class="flex items-center gap-1 truncate text-label-medium text-muted">
          {@card.label}
          <.icon :if={@linked} name="hero-arrow-up-right" class="size-3 shrink-0" />
        </p>

        <p class="truncate text-headline-large tabular-nums">
          <%= if @card.value == :loading do %>
            <.skeleton_block class="h-7 w-16" />
          <% else %>
            {@card.value}
          <% end %>
        </p>

        <p :if={@card[:hint]} class="truncate text-label-small text-muted">{@card.hint}</p>
      </div>
    </div>
    """
  end

  defp kpi_tone("primary"), do: "bg-gradient-primary text-primary"
  defp kpi_tone("info"), do: "bg-gradient-info text-info"
  defp kpi_tone("success"), do: "bg-gradient-success text-success"
  defp kpi_tone("warning"), do: "bg-gradient-warning text-warning"
  defp kpi_tone("error"), do: "bg-gradient-destructive text-error"
  defp kpi_tone(_neutral), do: "bg-base-200 text-muted"

  # ── Activity timeline ──────────────────────────────────────────────────────

  @doc """
  The horizontal activity strip: one card per event, newest first, the
  selected one lifted onto white.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  def timeline(assigns) do
    ~H"""
    <div
      id={@id}
      class="-mx-1 flex min-w-0 max-w-full gap-3 overflow-x-auto px-1 pb-2 [scrollbar-width:thin]"
      aria-label={@label}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  One card of the `timeline/1` strip.
  """
  attr :icon, :string, required: true
  attr :tone, :string, default: "neutral", values: ~w(neutral info success warning error)
  attr :kind, :string, required: true, doc: "the event type, e.g. \"Executed\""
  attr :at, :any, required: true, doc: "when it happened"
  attr :at_id, :string, required: true
  attr :snippet, :string, default: nil, doc: "two lines of what happened"
  attr :selected, :boolean, default: false
  attr :rest, :global, include: ~w(phx-click phx-value-id)

  def timeline_card(assigns) do
    ~H"""
    <button
      type="button"
      aria-pressed={to_string(@selected)}
      class={[
        "flex w-64 shrink-0 cursor-pointer flex-col gap-2 rounded-box p-3 text-left transition-shadow",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2",
        if(@selected,
          do: "bg-base-100 shadow-figma-card-medium",
          else: "bg-base-200 hover:bg-base-100 hover:shadow-figma-card"
        )
      ]}
      {@rest}
    >
      <div class="flex items-center gap-2">
        <span class={[
          "flex size-6 shrink-0 items-center justify-center rounded-full bg-base-100",
          kpi_tone(@tone)
        ]}>
          <.icon name={@icon} class="size-3" />
        </span>

        <span class="truncate text-label-medium">{@kind}</span>

        <.local_time id={@at_id} at={@at} class="ml-auto text-label-small text-muted" />
      </div>

      <p :if={@snippet} class="line-clamp-2 text-body-small text-muted">{@snippet}</p>
    </button>
    """
  end
end
