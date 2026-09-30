defmodule HllConditionalActionsWeb.BriefingComponents do
  @moduledoc """
  The pieces of the Briefing (`HllConditionalActionsWeb.DashboardLive`): the
  greeting, the summary tiles, the rule ready to leave simulation, the fires
  chart, the items of "Needs you" and the servers now; and the first steps
  of a new server, which take the page's place until they are done or
  skipped.

  They only draw what the page hands them; every number comes from the
  page's own queries. Canvas: "HLL Conditional Actions — Overhaul",
  Briefing, BriefingLight, TabletBriefing, MobileBriefing, Onboarding and
  States boards.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.Rules.Recipes
  alias HllConditionalActionsWeb.LiveComponents
  alias HllConditionalActionsWeb.MapArt

  # ── Panel ──────────────────────────────────────────────────────────────────

  @doc """
  A Briefing panel: the large rounded surface, a display-face title and an
  optional link or control on the right.
  """
  attr :id, :string, default: nil
  attr :title, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :action
  slot :inner_block, required: true

  def briefing_panel(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        "flex min-w-0 flex-col rounded-3xl bg-base-100 px-4 py-3.5 shadow-[var(--shadow-card)] md:rounded-[1.75rem] md:px-5 md:py-5 xl:px-6 xl:py-[1.125rem]",
        @class
      ]}
      {@rest}
    >
      <header :if={@title || @action != []} class="mb-2 flex items-baseline gap-2">
        <h2
          :if={@title}
          class="flex-1 font-display text-lg font-semibold tracking-tight md:text-[1.25rem]"
        >
          {@title}
        </h2>
        {render_slot(@action)}
      </header>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc "The small text link on the right of a panel title."
  attr :navigate, :string, required: true
  attr :id, :string, default: nil
  slot :inner_block, required: true

  def panel_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class="text-[0.8125rem] font-medium text-primary transition-opacity hover:opacity-80"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  # ── Greeting ───────────────────────────────────────────────────────────────

  @doc """
  The date and a greeting for the time of day. Both depend on the viewer's
  clock, so the server renders a neutral version and the hook swaps in the
  local date and the right greeting; the element is then left alone by
  later renders. The desktop's first panel, with the week in one sentence
  (`inner_block`), only shown from `xl` up; phones and tablets greet in the
  header instead.
  """
  attr :name, :string, required: true
  slot :inner_block

  def greeting(assigns) do
    ~H"""
    <section
      id="briefing-greeting"
      class="flex h-full min-w-0 flex-col xl:rounded-[1.75rem] xl:bg-base-100 xl:px-7 xl:py-6 xl:shadow-[var(--shadow-card)]"
    >
      <div
        id="briefing-greeting-heading"
        phx-hook=".BriefingGreeting"
        phx-update="ignore"
        data-morning={gettext("Good morning, %{name}", name: @name)}
        data-afternoon={gettext("Good afternoon, %{name}", name: @name)}
        data-evening={gettext("Good evening, %{name}", name: @name)}
      >
        <p class="flex items-center gap-2 text-sm text-subtle">
          <.icon name="hero-calendar" class="size-4" />
          <span data-date>{Calendar.strftime(DateTime.utc_now(), "%d/%m/%Y")}</span>
        </p>
        <h2
          data-greeting
          class="truncate font-display font-semibold xl:mt-[1.625rem] xl:text-[2.5rem] xl:leading-none xl:tracking-[-0.03em]"
        >
          {gettext("Hello, %{name}", name: @name)}
        </h2>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".BriefingGreeting">
          export default {
            mounted() {
              const lang = document.documentElement.lang || "en"
              const now = new Date()
              const hour = now.getHours()
              const key = hour >= 5 && hour < 12 ? "morning" : hour >= 12 && hour < 18 ? "afternoon" : "evening"

              const greeting = this.el.querySelector("[data-greeting]")
              if (greeting && this.el.dataset[key]) greeting.textContent = this.el.dataset[key]

              const date = this.el.querySelector("[data-date]")
              if (date) {
                const text = new Intl.DateTimeFormat(lang, {weekday: "long", day: "numeric", month: "long"}).format(now)
                date.textContent = text.charAt(0).toUpperCase() + text.slice(1)
              }
            }
          }
        </script>
      </div>
      <p :if={@inner_block != []} class="mt-3 text-base text-subtle">
        {render_slot(@inner_block)}
      </p>
    </section>
    """
  end

  @doc """
  "... 12% more": the change against the week before, highlighted, or
  nothing when there is no earlier week.
  """
  attr :change, :any, required: true

  def week_change(assigns) do
    ~H"""
    <strong
      :if={is_integer(@change) and @change != 0}
      class="rounded-md bg-primary-300 px-1.5 font-semibold text-base-content dark:bg-transparent dark:px-0 dark:text-primary"
    >
      {if @change > 0,
        do: gettext("%{change}% more", change: @change),
        else: gettext("%{change}% less", change: abs(@change))}
    </strong>
    <span :if={@change == 0}>{gettext("as many as the week before")}</span>
    """
  end

  # ── Change ─────────────────────────────────────────────────────────────────

  @doc """
  A change against the period before: an arrow and the amount, lime when it
  went the good way and red when it did not.
  """
  attr :change, :any, required: true
  attr :unit, :string, default: "%"
  attr :lower_is_better, :boolean, default: false
  attr :class, :any, default: nil

  def change_note(assigns) do
    ~H"""
    <span
      :if={is_number(@change)}
      class={["whitespace-nowrap text-xs font-medium", change_tone(@change, @lower_is_better), @class]}
      title={gettext("%{change} vs before", change: signed(@change, @unit))}
    >
      {arrow(@change)} {amount(@change)}{@unit}
    </span>
    """
  end

  defp change_tone(change, _lower_is_better) when change == 0, do: "text-muted"

  defp change_tone(change, lower_is_better) do
    if change > 0 != lower_is_better, do: "text-primary", else: "text-error"
  end

  defp arrow(change) when change > 0, do: "↑"
  defp arrow(change) when change < 0, do: "↓"
  defp arrow(_zero), do: "="

  # Past a thousand percent the number says nothing more than "a lot".
  defp amount(change) when abs(change) > 999, do: "999+"
  defp amount(change), do: format_decimal(abs(change))

  defp signed(change, unit) when change > 0, do: "+#{format_decimal(change)}#{unit}"
  defp signed(change, unit), do: "#{format_decimal(change)}#{unit}"

  # ── Summary tiles ──────────────────────────────────────────────────────────

  @doc """
  The five tiles of the summary: label and icon on top, the big number,
  one line of context. `tiles` are maps with `id`, `label`, `icon`,
  `value`, `hint`, `tone` and `to`.
  """
  attr :tiles, :list, required: true

  def kpi_row(assigns) do
    ~H"""
    <section
      id="overview-kpis"
      aria-label={gettext("Summary")}
      class="hidden min-w-0 gap-2.5 rounded-[1.75rem] bg-base-100 p-2.5 shadow-[var(--shadow-card)] md:grid xl:p-3"
      style={"grid-template-columns: repeat(#{max(length(@tiles), 1)}, minmax(0, 1fr))"}
    >
      <.link
        :for={tile <- @tiles}
        id={"kpi-#{tile.id}"}
        navigate={tile.to}
        class={[
          "flex min-w-0 flex-col justify-between gap-2 rounded-[1.25rem] px-3.5 py-3 transition-opacity hover:opacity-85 xl:px-[1.125rem] xl:py-4",
          kpi_surface(tile.tone)
        ]}
      >
        <span class={[
          "flex items-start justify-between gap-2 text-xs xl:text-[0.8125rem]",
          kpi_label(tile.tone)
        ]}>
          <span class="truncate">{tile.label}</span>
          <.icon name={tile.icon} class={["hidden size-4 shrink-0 dark:block", kpi_icon(tile.tone)]} />
        </span>
        <span class="min-w-0">
          <span class={[
            "block font-display text-[1.75rem] font-semibold leading-[1.1] tracking-[-0.02em] tabular-nums xl:text-[2.375rem]",
            kpi_value(tile.tone)
          ]}>
            {tile.value}
          </span>
          <span class={["block truncate text-xs", kpi_hint(tile)]}>{tile.hint}</span>
        </span>
      </.link>
    </section>
    """
  end

  # In the light theme the tiles that ask for something are tinted; in the
  # dark one they stay raised and only their number is coloured.
  defp kpi_surface("warning"), do: "bg-warning/15 dark:bg-secondary"
  defp kpi_surface("engine"), do: "bg-accent/15 dark:bg-secondary"
  defp kpi_surface(_tone), do: "bg-secondary"

  defp kpi_label("warning"), do: "text-warning dark:text-subtle"
  defp kpi_label("engine"), do: "text-accent dark:text-subtle"
  defp kpi_label(_tone), do: "text-subtle"

  defp kpi_icon("warning"), do: "text-warning"
  defp kpi_icon("engine"), do: "text-accent"
  defp kpi_icon("error"), do: "text-error"
  defp kpi_icon(_tone), do: "text-subtle"

  defp kpi_value("warning"), do: "text-warning"
  defp kpi_value("engine"), do: "text-accent"
  defp kpi_value("error"), do: "text-error"
  defp kpi_value(_tone), do: nil

  defp kpi_hint(%{hint_tone: "primary"}), do: "font-semibold text-primary dark:font-normal"
  defp kpi_hint(%{hint_tone: "error"}), do: "text-error"
  defp kpi_hint(%{tone: "warning"}), do: "text-warning dark:text-muted"
  defp kpi_hint(%{tone: "engine"}), do: "text-accent dark:text-muted"
  defp kpi_hint(_tile), do: "text-muted"

  # ── Phone: servers and the week ────────────────────────────────────────────

  @doc """
  The phone's row of servers: one chip each, with its players and score,
  "no stream" in red, or the seeding count.
  """
  attr :cards, :list, required: true, doc: "the same maps the server cards take"

  def server_chips(assigns) do
    ~H"""
    <nav
      id="briefing-server-chips"
      aria-label={gettext("Servers now")}
      class="grid grid-cols-3 gap-2 md:hidden"
    >
      <.link
        :for={card <- Enum.take(@cards, 3)}
        id={"briefing-chip-#{card.server.id}"}
        navigate={~p"/servers/#{card.server}"}
        class={[
          "flex min-h-14 min-w-0 flex-col justify-center gap-0.5 rounded-[1.125rem] border px-3 py-2",
          if(card.state == :no_stream,
            do: "border-error/35 bg-error/8",
            else: "border-transparent bg-base-100 shadow-[var(--shadow-card)]"
          )
        ]}
      >
        <span class="flex items-center gap-1.5 text-[0.8125rem] font-semibold">
          <span class={["size-[7px] shrink-0 rounded-full", card_dot(card)]}></span>
          <span class="truncate">{card.server.name}</span>
        </span>
        <span class={[
          "truncate text-xs",
          if(card.state == :no_stream, do: "text-error", else: "text-muted")
        ]}>
          <%= case card.state do %>
            <% :no_stream -> %>
              {gettext("no stream")}
            <% :disabled -> %>
              {gettext("switched off")}
            <% :seeding -> %>
              {slots(card.live)} · {gettext("seeding")}
            <% :match -> %>
              {slots(card.live)} · <span class="text-allies">{card.live.allied_score || 0}</span>:<span class="text-axis">{card.live.axis_score ||
                0}</span>
            <% _unknown -> %>
              –
          <% end %>
        </span>
      </.link>
    </nav>
    """
  end

  @doc """
  The phone's summary of the week: fires with the change and a bar per day,
  then the rules, the players online and the success rate.
  """
  attr :week, :map, required: true
  attr :rules, :any, default: nil
  attr :players, :any, default: nil
  attr :success, :any, default: nil

  def week_card(assigns) do
    days = assigns.week.daily |> Enum.take(-7) |> Enum.map(& &1.fired)
    top = Enum.max([1 | days])

    assigns = assign(assigns, bars: Enum.map(days, &max(round(&1 * 44 / top), 3)))

    ~H"""
    <section
      id="briefing-week"
      aria-label={gettext("The week")}
      class="flex flex-col gap-2.5 rounded-3xl bg-base-100 px-4 py-3.5 shadow-[var(--shadow-card)] md:hidden"
    >
      <div class="flex items-end gap-3">
        <div class="flex min-w-0 flex-1 flex-col gap-0.5">
          <span class="text-xs text-subtle">{gettext("Fires this week")}</span>
          <span class="flex items-baseline gap-2">
            <strong class="font-display text-[2.125rem] font-semibold leading-[1.05] tracking-[-0.02em] tabular-nums">
              {format_number(@week.totals.fired)}
            </strong>
            <.change_note change={change(@week.totals.fired, @week.previous.fired)} />
          </span>
        </div>
        <svg
          width="134"
          height="48"
          viewBox="0 0 134 48"
          role="img"
          aria-label={gettext("Fires per day, last 7 days")}
        >
          <rect
            :for={{height, index} <- Enum.with_index(@bars)}
            x={index * 20}
            y={48 - height}
            width="14"
            height={height}
            rx="4"
            class={
              if(index == length(@bars) - 1,
                do: "fill-primary dark:fill-primary",
                else: "fill-base-300 dark:fill-[#3a3d30]"
              )
            }
          />
        </svg>
      </div>
      <div class="grid grid-cols-3 gap-2">
        <div :if={@rules} class="flex flex-col">
          <strong class="font-display text-[1.0625rem] font-semibold">{@rules}</strong>
          <span class="text-xs text-muted">{gettext("active rules")}</span>
        </div>
        <div class="flex flex-col">
          <strong class="font-display text-[1.0625rem] font-semibold">{@players || "–"}</strong>
          <span class="text-xs text-muted">{gettext("playing now")}</span>
        </div>
        <div class="flex flex-col">
          <strong class="font-display text-[1.0625rem] font-semibold">{@success || "–"}</strong>
          <span class="text-xs text-muted">{gettext("success")}</span>
        </div>
      </div>
    </section>
    """
  end

  # ── Ready to go live ───────────────────────────────────────────────────────

  @doc """
  A rule that simulated long enough, with no failure, to be trusted: the one
  decision the Briefing puts in front of everything else, with what it
  would have done, action by action. In the light theme it is the one dark
  panel of the page.
  """
  attr :rule, :map, required: true
  attr :digest, :map, required: true

  def suggestion(assigns) do
    total = assigns.digest.actions |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    assigns =
      assign(assigns,
        total: total,
        meters: assigns.digest.actions |> Enum.take(2) |> Enum.map(&meter(&1, total))
      )

    ~H"""
    <section
      id="briefing-suggestion"
      class="briefing-suggestion flex min-w-0 flex-col gap-2.5 rounded-3xl border border-base-300 bg-base-100 p-4 md:gap-3 md:rounded-[1.75rem] md:p-[1.375rem] xl:gap-3.5 xl:px-7 xl:py-5"
      aria-labelledby="briefing-suggestion-title"
    >
      <div class="flex items-center justify-between gap-2">
        <.pill tone="engine" dot={false}>
          <.icon name="hero-sparkles" class="size-3.5" />{gettext("Ready to act")}
        </.pill>
        <span class="text-xs text-muted md:text-[0.8125rem]">
          {ngettext("1 day in simulation", "%{count} days in simulation", @digest.days)}
        </span>
      </div>

      <h3
        id="briefing-suggestion-title"
        class="font-display text-[1.25rem] font-semibold leading-tight tracking-[-0.01em] md:text-[1.4375rem] xl:mt-1 xl:text-[1.625rem] xl:leading-[1.15] xl:tracking-[-0.02em]"
      >
        {gettext("“%{rule}” can leave simulation", rule: @rule.name)}
      </h3>
      <p class="text-[0.8125rem] leading-snug text-subtle md:text-sm md:leading-normal xl:text-[0.9375rem] xl:leading-[1.55]">
        {digest_sentence(@digest)}
      </p>

      <div :if={@meters != []} class="mt-1 hidden grid-cols-2 gap-2.5 md:grid xl:gap-3">
        <div
          :for={meter <- @meters}
          class="flex min-w-0 flex-col gap-2 rounded-2xl bg-secondary px-3 py-2.5 xl:gap-2.5 xl:rounded-[1.125rem] xl:px-4 xl:py-3.5"
        >
          <span class="flex items-baseline justify-between gap-2 text-xs text-subtle xl:text-[0.8125rem]">
            <span class="truncate">{would_have(meter.type)}</span>
            <strong class="font-display text-base font-semibold text-base-content xl:text-lg">
              {format_number(meter.count)}
            </strong>
          </span>
          <span
            class="briefing-meter hidden grid-cols-10 gap-[3px] dark:grid"
            role="img"
            aria-label={gettext("%{count} of %{total}", count: meter.count, total: @total)}
          >
            <span
              :for={index <- 1..10}
              class={[
                "h-[5px] rounded-[3px] xl:h-1.5",
                if(index <= meter.dots, do: meter.tone, else: "bg-base-300 dark:bg-[#33352e]")
              ]}
            ></span>
          </span>
        </div>
      </div>

      <div class="hidden flex-1 md:block"></div>

      <div class="mt-0.5 flex gap-2 md:gap-2.5">
        <.link
          id="briefing-suggestion-review"
          navigate={~p"/rules/#{@rule.id}"}
          class="flex h-11 flex-1 items-center justify-center rounded-full bg-primary-300 px-5 text-sm font-semibold text-[#1a2006] transition-opacity hover:opacity-90 md:h-12 xl:flex-none xl:px-[1.375rem]"
        >
          {gettext("Review and activate")}
        </.link>
        <.link
          id="briefing-suggestion-runs"
          navigate={~p"/executions?#{[rule_id: @rule.id, status: "simulated"]}"}
          class="flex h-11 items-center rounded-full border border-base-300 bg-secondary px-4 text-sm font-medium transition-colors hover:border-base-content/25 md:h-12 md:px-[1.125rem] xl:border-transparent xl:px-[1.375rem]"
        >
          <span class="xl:hidden">
            {ngettext("1 simulation", "%{count} simulations", @digest.runs)}
          </span>
          <span class="hidden xl:inline">
            {ngettext("See the simulation", "See the %{count} simulations", @digest.runs)}
          </span>
        </.link>
      </div>
    </section>
    """
  end

  defp meter({type, count}, total) do
    dots = if total > 0, do: max(round(count * 10 / total), 1), else: 0
    %{type: type, count: count, dots: min(dots, 10), tone: meter_tone(type)}
  end

  @messaging ~w(message_player message_all_players broadcast_message temporary_broadcast set_welcome_message)
  @punishment ~w(punish_player kick_player temp_ban_player perma_ban_player blacklist_player)

  defp meter_tone(type) when type in @messaging, do: "bg-primary"
  defp meter_tone(type) when type in @punishment, do: "bg-axis"
  defp meter_tone(_type), do: "bg-accent"

  defp digest_sentence(%{players: 0} = digest),
    do:
      gettext(
        "In these %{days} days it would have acted %{runs} times. Nothing reached the game.",
        days: digest.days,
        runs: digest.runs
      )

  defp digest_sentence(digest),
    do:
      ngettext(
        "In these %{days} days it would have acted %{runs} times, always on the same player. Nothing reached the game.",
        "In these %{days} days it would have acted %{runs} times, on %{count} different players. Nothing reached the game.",
        digest.players,
        days: digest.days,
        runs: digest.runs
      )

  @doc "What a simulated action would have done, as the label of its meter."
  @spec would_have(String.t()) :: String.t()
  def would_have("message_player"), do: gettext("Would have warned")
  def would_have("message_all_players"), do: gettext("Would have messaged everyone")
  def would_have("broadcast_message"), do: gettext("Would have broadcast")
  def would_have("temporary_broadcast"), do: gettext("Would have broadcast")
  def would_have("punish_player"), do: gettext("Would have punished")
  def would_have("kick_player"), do: gettext("Would have kicked")
  def would_have("temp_ban_player"), do: gettext("Would have banned for a while")
  def would_have("perma_ban_player"), do: gettext("Would have banned")
  def would_have("blacklist_player"), do: gettext("Would have blacklisted")
  def would_have("switch_player_team"), do: gettext("Would have switched team")
  def would_have("switch_player_on_death"), do: gettext("Would have switched team")
  def would_have("add_player_flag"), do: gettext("Would have flagged")
  def would_have("add_to_watchlist"), do: gettext("Would have watched")
  def would_have("grant_vip"), do: gettext("Would have given VIP")
  def would_have("open_ticket"), do: gettext("Would have opened a ticket")
  def would_have("send_discord_webhook"), do: gettext("Would have posted to Discord")

  def would_have(type) do
    Labels.action(String.to_existing_atom(type))
  rescue
    _unknown -> type
  end

  # ── Fires ──────────────────────────────────────────────────────────────────

  @doc """
  One of the period's totals over the chart, and the switch that picks what
  the chart draws: a check when it is the one drawn, an empty ring when not.
  """
  attr :id, :string, required: true
  attr :metric, :string, required: true
  attr :selected, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :change, :any, default: nil
  attr :lower_is_better, :boolean, default: false

  def metric_tile(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="chart_metric"
      phx-value-metric={@metric}
      aria-pressed={to_string(@metric == @selected)}
      class={[
        "flex min-w-0 cursor-pointer items-center gap-2.5 rounded-[1.125rem] border px-4 py-3 text-left transition-colors",
        if(@metric == @selected,
          do: "border-base-content bg-white dark:border-[#3a3d30] dark:bg-secondary",
          else: "border-base-300 hover:border-base-content/25"
        )
      ]}
    >
      <span class="flex min-w-0 flex-1 flex-col gap-0.5">
        <span class="truncate text-xs leading-[1.2] text-subtle">{@label}</span>
        <span class="flex min-w-0 flex-wrap items-baseline gap-x-2">
          <strong class="font-display text-[1.375rem] font-semibold leading-[1.2] tabular-nums">{@value}</strong>
          <.change_note
            change={@change}
            lower_is_better={@lower_is_better}
            class="font-semibold dark:font-medium"
          />
        </span>
      </span>
      <span
        class={[
          "hidden shrink-0 items-center justify-center rounded-full dark:flex",
          if(@metric == @selected,
            do: "size-[1.375rem] bg-primary text-primary-content",
            else: "size-[1.125rem] border-[1.5px] border-[#4a4c43]"
          )
        ]}
        aria-hidden="true"
      >
        <.icon :if={@metric == @selected} name="hero-check" class="size-3.5" />
      </span>
    </button>
    """
  end

  @chart_width 740
  @chart_height 210
  @chart_top 12

  @doc """
  Fires per day, drawn on the server as SVG: one bar per day under a
  smoothed line, and a dashed marker on the busiest day. Hovering a day
  shows its numbers; until then the busiest day's are shown. `points` is
  one `%{date, value, tip, extra}` per day, oldest first. The axis labels
  sit outside the drawing, so the SVG can stretch to the panel without
  distorting any text.
  """
  attr :id, :string, required: true
  attr :points, :list, required: true
  attr :label, :string, required: true
  attr :tone, :string, default: "primary", values: ~w(primary error accent)

  def fires_chart(assigns) do
    values = Enum.map(assigns.points, & &1.value)
    max = values |> Enum.max(fn -> 0 end) |> nice_max()
    count = length(values)
    slot = @chart_width / max(count, 1)
    bar = Float.round(min(slot * 0.56, 14.0), 1)

    points =
      assigns.points
      |> Enum.with_index()
      |> Enum.map(fn {point, index} ->
        Map.merge(point, %{
          index: index,
          x: Float.round(slot * index + slot / 2, 1),
          y: y_for(point.value, max)
        })
      end)

    peak = Enum.max_by(points, & &1.value, fn -> nil end)
    peak = if peak && peak.value > 0, do: peak

    assigns =
      assign(assigns,
        width: @chart_width,
        height: @chart_height,
        bar: bar,
        count: count,
        plotted: points,
        peak: peak,
        ticks: Enum.map(3..0//-1, &round(max * &1 / 3)),
        labels: x_labels(assigns.points)
      )

    ~H"""
    <div class={["briefing-chart flex min-h-0 flex-1 gap-2.5 xl:gap-3", "briefing-chart--#{@tone}"]}>
      <div
        class="flex w-5 shrink-0 flex-col justify-between pt-1 pb-6 text-right font-mono text-[0.6875rem] text-muted xl:w-[1.375rem] xl:pt-1.5 xl:pb-7"
        aria-hidden="true"
      >
        <span :for={tick <- @ticks}>{compact(tick)}</span>
      </div>

      <div class="flex min-w-0 flex-1 flex-col gap-1.5 xl:gap-2">
        <div class="relative">
          <svg
            id={@id}
            viewBox={"0 0 #{@width} #{@height}"}
            preserveAspectRatio="none"
            class="h-[7.375rem] w-full overflow-visible md:h-[7.375rem] xl:h-[11.875rem]"
            role="img"
            aria-label={@label}
          >
            <path
              d={"M0 #{chart_top()}H#{@width}M0 #{mid(1)}H#{@width}M0 #{mid(2)}H#{@width}"}
              class="briefing-chart-grid"
            />
            <rect
              :for={point <- @plotted}
              x={Float.round(point.x - @bar / 2, 1)}
              y={bar_y(point.y)}
              width={@bar}
              height={Float.round(@height - bar_y(point.y), 1)}
              rx="4"
              class={["briefing-chart-bar", @peak && point.index == @peak.index && "is-peak"]}
            />
            <path d={area_path(@plotted, @height)} class="briefing-chart-area" />
            <path d={smooth_path(@plotted)} class="briefing-chart-line" />
            <path
              :if={@peak}
              d={"M#{@peak.x} #{@peak.y}V#{@height}"}
              class="briefing-chart-peak"
            />
          </svg>

          <div class="briefing-chart-hits absolute inset-0 flex" aria-hidden="true">
            <div
              :for={point <- @plotted}
              class={[
                "briefing-chart-hit relative flex-1",
                @peak && point.index == @peak.index && "is-peak"
              ]}
            >
              <span class="briefing-chart-guide"></span>
              <span class={[
                "briefing-chart-tip",
                @peak && point.index == @peak.index && "is-peak",
                tip_side(point.index, @count)
              ]}>
                <span class="text-xs text-subtle">{day_label(point.date)}</span>
                <span class="flex items-center gap-2 text-[0.8125rem] whitespace-nowrap">
                  <span class="briefing-chart-dot size-2 rounded-full"></span>
                  <strong class="font-semibold">{point.tip}</strong>
                  <span :if={point.extra} class="text-subtle">{point.extra}</span>
                </span>
              </span>
            </div>
          </div>
        </div>

        <div class="flex justify-between font-mono text-[0.6875rem] text-muted" aria-hidden="true">
          <span :for={label <- @labels}>{label}</span>
        </div>
      </div>
    </div>
    """
  end

  defp tip_side(index, count) when index * 3 < count, do: "is-left"
  defp tip_side(index, count) when index * 3 >= count * 2, do: "is-right"
  defp tip_side(_index, _count), do: nil

  defp chart_top, do: @chart_top

  # The two inner grid lines, a third of the way down each.
  defp mid(n), do: Float.round(@chart_top + (@chart_height - @chart_top) * n / 3, 1)

  # A day with nothing still shows a sliver, so the row of days reads.
  defp bar_y(y), do: min(y, @chart_height - 3.0)

  defp nice_max(0), do: 3

  defp nice_max(value) do
    magnitude = :math.pow(10, floor(:math.log10(value)))

    step =
      Enum.find([1, 2, 2.5, 5, 10], fn factor -> factor * magnitude * 3 >= value end) * magnitude

    max(round(step * 3), 3)
  end

  defp y_for(value, max) do
    span = @chart_height - @chart_top
    Float.round(@chart_height - span * value / max, 1)
  end

  # Catmull-Rom through the points, as cubic Béziers.
  defp smooth_path([]), do: ""

  defp smooth_path([first | _rest] = points) do
    coords = Enum.map(points, &{&1.x, &1.y})
    padded = [hd(coords)] ++ coords ++ [List.last(coords)]

    segments =
      padded
      |> Enum.chunk_every(4, 1, :discard)
      |> Enum.map(fn [{x0, y0}, {x1, y1}, {x2, y2}, {x3, y3}] ->
        # Control points are held between the two ends of the segment, so a
        # spike never swings the line below zero or above its own peak.
        c1 = {x1 + (x2 - x0) / 6, clamp(y1 + (y2 - y0) / 6, y1, y2)}
        c2 = {x2 - (x3 - x1) / 6, clamp(y2 - (y3 - y1) / 6, y1, y2)}
        "C#{pt(c1)} #{pt(c2)} #{pt({x2, y2})}"
      end)

    "M#{pt({first.x, first.y})} " <> Enum.join(segments, " ")
  end

  defp clamp(value, a, b), do: value |> max(min(a, b)) |> min(max(a, b))

  defp area_path([], _bottom), do: ""

  defp area_path(points, bottom) do
    first = hd(points)
    last = List.last(points)
    smooth_path(points) <> " L#{pt({last.x, bottom})} L#{pt({first.x, bottom})} Z"
  end

  defp pt({x, y}), do: "#{Float.round(x * 1.0, 1)},#{Float.round(y * 1.0, 1)}"

  # Five dates under the axis, whatever the period: the ends and three
  # evenly between.
  defp x_labels([]), do: []

  defp x_labels(points) do
    last = length(points) - 1

    0..4
    |> Enum.map(&round(last * &1 / 4))
    |> Enum.uniq()
    |> Enum.map(fn index -> points |> Enum.at(index) |> Map.fetch!(:date) |> short_date() end)
  end

  defp compact(number) when number >= 10_000, do: "#{div(number, 1000)}k"

  defp compact(number) when number >= 1000,
    do: "#{format_decimal(Float.round(number / 1000, 1))}k"

  defp compact(number), do: to_string(number)

  @doc "\"31 Aug\": a day and its month, in the viewer's language."
  @spec short_date(Date.t()) :: String.t()
  def short_date(date), do: "#{date.day} #{month(date.month)}"

  @doc "\"Wed, 23 Sep\"."
  @spec day_label(Date.t()) :: String.t()
  def day_label(date), do: "#{weekday(Date.day_of_week(date))}, #{short_date(date)}"

  defp month(1), do: gettext("Jan")
  defp month(2), do: gettext("Feb")
  defp month(3), do: gettext("Mar")
  defp month(4), do: gettext("Apr")
  defp month(5), do: gettext("May")
  defp month(6), do: gettext("Jun")
  defp month(7), do: gettext("Jul")
  defp month(8), do: gettext("Aug")
  defp month(9), do: gettext("Sep")
  defp month(10), do: gettext("Oct")
  defp month(11), do: gettext("Nov")
  defp month(12), do: gettext("Dec")

  defp weekday(1), do: gettext("Mon")
  defp weekday(2), do: gettext("Tue")
  defp weekday(3), do: gettext("Wed")
  defp weekday(4), do: gettext("Thu")
  defp weekday(5), do: gettext("Fri")
  defp weekday(6), do: gettext("Sat")
  defp weekday(7), do: gettext("Sun")

  @doc "The chart's empty state: nothing fired in the period."
  attr :period, :integer, required: true

  def quiet_period(assigns) do
    ~H"""
    <div
      id="overview-quiet"
      class="flex flex-1 flex-col items-center justify-center gap-2 py-8 text-center"
    >
      <svg width="64" height="48" viewBox="0 0 64 48" fill="none" aria-hidden="true">
        <rect x="6" y="6" width="36" height="12" rx="6" class="briefing-empty-stroke" />
        <rect x="14" y="22" width="44" height="12" rx="6" class="briefing-empty-stroke" />
        <rect x="6" y="38" width="24" height="8" rx="4" class="fill-primary" />
      </svg>
      <p class="font-display text-lg font-semibold">
        {gettext("No rule fired in the last %{count} days", count: @period)}
      </p>
      <p class="max-w-sm text-[0.8125rem] leading-relaxed text-subtle">
        {gettext(
          "Either nothing matched, or no rule is enabled yet. Try a recipe, or replay a rule against recent events from the builder."
        )}
      </p>
    </div>
    """
  end

  # ── Needs you ──────────────────────────────────────────────────────────────

  @doc """
  One item of the attention inbox as a row: icon tile, what happened, one
  line of detail, and a tag saying what kind of thing it is. `extra` holds
  what the page looked up for the rows: `last_events` by server id and
  ticket `quotes` by ticket id.
  """
  attr :item, :map, required: true
  attr :extra, :map, default: %{}
  attr :class, :any, default: nil

  def attention_row(assigns) do
    ~H"""
    <.link
      id={"briefing-attention-#{dom_id(@item.key)}"}
      navigate={item_path(@item)}
      class={[
        "flex min-h-[3.25rem] items-center gap-3 rounded-2xl transition-colors hover:bg-secondary md:min-h-[3.875rem] md:px-1.5 xl:min-h-0 xl:gap-3.5 xl:px-2 xl:py-2.5",
        @class
      ]}
    >
      <span class={[
        "flex size-9 shrink-0 items-center justify-center rounded-xl md:size-10",
        item_tint(@item)
      ]}>
        <.icon name={item_icon(@item)} class="size-[1.125rem]" />
      </span>
      <span class="flex min-w-0 flex-1 flex-col gap-px md:gap-0.5">
        <strong class="truncate text-sm font-semibold">{item_title(@item, @extra)}</strong>
        <span class="truncate text-xs text-muted xl:line-clamp-2 xl:whitespace-normal">{item_detail(
          @item,
          @extra
        )}</span>
      </span>
      <span class={[
        "shrink-0 rounded-full px-[0.5625rem] py-1 text-[0.6875rem] font-bold",
        item_tint(@item)
      ]}>
        {item_tag(@item)}
      </span>
    </.link>
    """
  end

  @doc "The empty state of \"Needs you\": inbox zero."
  attr :feed_path, :string, default: nil

  def needs_you_empty(assigns) do
    ~H"""
    <div
      id="briefing-attention-empty"
      class="flex flex-1 flex-col items-center justify-center gap-2 py-3 text-center"
    >
      <svg width="64" height="48" viewBox="0 0 64 48" fill="none" aria-hidden="true">
        <path d="M8 26h14l4 6h12l4-6h14" class="briefing-empty-line" />
        <path d="M14 10h36l6 16v14H8V26l6-16z" class="briefing-empty-line" />
        <circle cx="46" cy="10" r="8" class="fill-primary-300" />
        <path
          d="m42.5 10 2.5 2.5 4.5-5"
          fill="none"
          stroke="#1a2006"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </svg>
      <p class="font-display text-lg font-semibold">{gettext("Nothing needs you right now")}</p>
      <p class="max-w-[18.75rem] text-[0.8125rem] leading-[1.45] text-subtle">
        {gettext("Inbox zero. New tickets, failures and alerts show up here as soon as they arrive.")}
      </p>
      <.link
        :if={@feed_path}
        id="briefing-attention-feed"
        navigate={@feed_path}
        class="mt-1.5 flex h-10 items-center rounded-full border border-base-300 bg-secondary px-[1.125rem] text-[0.8125rem] transition-colors hover:border-base-content/25"
      >
        {gettext("See the live feed")}
      </.link>
    </div>
    """
  end

  @doc "A DOM-safe version of an attention key."
  def dom_id(key), do: String.replace(key, ~r/[^a-z0-9_-]/i, "-")

  defp item_icon(%{kind: :stream_down}), do: "hero-exclamation-triangle"
  defp item_icon(%{kind: :ticket_waiting}), do: "hero-chat-bubble-left"
  defp item_icon(%{kind: :rule_broken}), do: "hero-no-symbol"
  defp item_icon(%{kind: :failures}), do: "hero-bolt"
  defp item_icon(%{kind: :review}), do: "hero-eye"
  defp item_icon(%{kind: :ready_to_go_live}), do: "hero-rocket-launch"
  defp item_icon(%{kind: :rule_quiet}), do: "hero-moon"
  defp item_icon(%{kind: :vip_failed}), do: "hero-shopping-bag"
  defp item_icon(_item), do: "hero-exclamation-triangle"

  defp item_tint(%{kind: :ticket_waiting}), do: "bg-accent/13 text-accent"
  defp item_tint(%{kind: :review}), do: "bg-axis/14 text-axis"
  defp item_tint(%{kind: :ready_to_go_live}), do: "bg-primary/12 text-primary"
  defp item_tint(%{severity: :error}), do: "bg-error/14 text-error"
  defp item_tint(%{severity: :warning}), do: "bg-warning/13 text-warning"
  defp item_tint(_info), do: "bg-secondary text-subtle"

  defp item_tag(%{kind: :ticket_waiting}), do: gettext("Ticket")
  defp item_tag(%{kind: :review}), do: gettext("Player")
  defp item_tag(%{severity: :error}), do: gettext("Urgent")
  defp item_tag(%{severity: :warning}), do: gettext("To review")
  defp item_tag(_info), do: gettext("Suggestion")

  @doc "What an attention item is about, in one line."
  def item_title(item, extra \\ %{})

  def item_title(%{kind: :vip_failed, subject: %{order: order}}, _extra),
    do:
      gettext("Paid VIP not granted for %{player}",
        player: order.player_name || order.player_id
      )

  def item_title(%{kind: :ticket_waiting, subject: %{ticket: ticket}}, _extra),
    do:
      gettext("%{player}'s ticket has waited %{time}",
        player: ticket.player_name || ticket.player_id,
        time: ago(ticket.last_activity_at)
      )

  def item_title(%{kind: :stream_down, subject: %{server: server}}, _extra),
    do: gettext("Stream down on %{server}", server: server.name)

  def item_title(%{kind: kind, subject: %{rule: rule, issue: issue}}, _extra)
      when kind in [:rule_broken, :rule_quiet],
      do: "#{rule.name} · #{Labels.health_issue(issue.id)}"

  def item_title(%{kind: :failures, subject: %{rule: rule, count: count}}, _extra),
    do:
      ngettext("“%{rule}” failed once", "“%{rule}” failed %{count} times", count, rule: rule.name)

  def item_title(%{kind: :review, subject: %{execution: execution}}, _extra),
    do: gettext("Review %{player}", player: execution.player_name || execution.player_id)

  def item_title(%{kind: :ready_to_go_live, subject: %{rule: rule}}, _extra),
    do: gettext("%{rule} looks ready to go live", rule: rule.name)

  @doc "The one line of detail under an attention item."
  def item_detail(item, extra \\ %{})

  def item_detail(%{kind: :ticket_waiting, subject: %{ticket: ticket}}, extra) do
    case extra |> Map.get(:quotes, %{}) |> Map.get(ticket.id) do
      quote when is_binary(quote) and quote != "" -> "“#{quote}”"
      _none -> gettext("Ticket #%{id} on %{server}", id: ticket.id, server: ticket.server.name)
    end
  end

  def item_detail(%{kind: :stream_down, subject: %{server: server} = subject}, extra) do
    case extra |> Map.get(:last_events, %{}) |> Map.get(server.id) do
      %DateTime{} = at -> gettext("No rule has heard this server for %{time}", time: ago(at))
      _never -> stream_down_reason(subject.reason)
    end
  end

  def item_detail(%{kind: kind, subject: %{issue: issue}}, _extra)
      when kind in [:rule_broken, :rule_quiet],
      do: Labels.health_explanation(issue.id)

  def item_detail(%{kind: :vip_failed, subject: %{order: order}}, _extra),
    do:
      gettext("Order #%{id}, %{package}. Failed on: %{servers}",
        id: order.id,
        package: order.package_name,
        servers:
          order.grants
          |> Enum.filter(&(&1.status == "failed"))
          |> Enum.map_join(", ", & &1.server_name)
      )

  def item_detail(%{kind: :failures, subject: %{error: error}}, _extra),
    do: error || gettext("unknown error")

  def item_detail(%{kind: :review, subject: %{execution: execution, reason: reason}}, _extra),
    do:
      Enum.join(
        Enum.reject([execution.rule.name, execution.server.name, reason], &is_nil/1),
        " · "
      )

  def item_detail(%{kind: :ready_to_go_live, subject: %{runs: runs}}, _extra),
    do:
      gettext(
        "It has been simulating for days, %{runs} recorded runs and no failure. Read what it would have done, then turn simulation off.",
        runs: runs
      )

  defp stream_down_reason(:stopped),
    do:
      gettext(
        "The engine for this server stopped. It starts again on its own within a minute; if it does not, save the server again."
      )

  defp stream_down_reason(reason),
    do:
      gettext("No rule can react to this server until it is back. CRCON said: %{reason}",
        reason: reason
      )

  defp item_path(%{kind: :stream_down, subject: %{server: server}}), do: ~p"/servers/#{server}"

  defp item_path(%{kind: :ticket_waiting, subject: %{ticket: ticket}}),
    do: ~p"/tickets/#{ticket.id}"

  defp item_path(%{kind: :review, subject: %{execution: execution}}),
    do: ~p"/players/#{execution.player_id}"

  defp item_path(%{kind: :vip_failed}), do: ~p"/vip-shop/purchases"
  defp item_path(%{subject: %{rule: rule}}), do: ~p"/rules/#{rule.id}"
  defp item_path(_item), do: ~p"/inbox"

  # ── Servers now ────────────────────────────────────────────────────────────

  @doc """
  A server as a card: the picture of the map it plays, its name with a
  status dot, the map and mode, then what is happening there - the score
  with its sectors and the players, the seeding count, or why the rules
  cannot see it. `card` comes from the page: `server`, `state` (`:match`,
  `:seeding`, `:no_stream`, `:disabled`, `:loading` or `:unreachable`),
  `live`, `seeding` (the threshold) and `last_event`.
  """
  attr :card, :map, required: true

  def server_card(assigns) do
    ~H"""
    <.link
      id={"briefing-server-#{@card.server.id}"}
      navigate={~p"/servers/#{@card.server}"}
      class="group flex min-h-[7.5rem] min-w-0 gap-3.5 rounded-[1.25rem] bg-secondary p-2.5 transition-colors hover:bg-base-300/60 xl:min-h-[9.5rem]"
    >
      <img
        src={card_art(@card)}
        alt={@card.live[:map] || ""}
        loading="lazy"
        class={[
          "w-[5.75rem] shrink-0 rounded-[0.875rem] object-cover",
          @card.state in [:no_stream, :disabled] && "opacity-55"
        ]}
      />
      <span class="flex min-w-0 flex-1 flex-col gap-1 py-1 pr-1">
        <span class="flex items-center gap-1.5 text-sm font-semibold">
          <span class={["size-2 shrink-0 rounded-full", card_dot(@card)]}></span>
          <span class="truncate">{@card.server.name}</span>
        </span>
        <span class="truncate text-xs text-muted">{card_where(@card)}</span>
        <span class="flex-1"></span>
        <%= case @card.state do %>
          <% :match -> %>
            <span class="font-display text-[1.625rem] font-semibold leading-tight tabular-nums">
              <span class="text-allies">{@card.live.allied_score || 0}</span>
              <span class="text-muted">:</span>
              <span class="text-axis">{@card.live.axis_score || 0}</span>
            </span>
            <.sector_bar allied={min(@card.live.allied_score || 0, 5)} size="sm" />
            <span class="truncate text-xs text-subtle">{match_line(@card.live)}</span>
          <% :seeding -> %>
            <span class="font-display text-[1.625rem] font-semibold leading-tight tabular-nums">
              {@card.live.players}<span
                :if={@card.live.max_players}
                class="text-[0.9375rem] text-muted"
              >/{@card.live.max_players}</span>
            </span>
            <span class="flex h-[5px] overflow-hidden rounded-[3px] bg-base-300">
              <span
                class="rounded-[3px] bg-primary"
                style={"width: #{fill(@card.live.players, @card.live.max_players || @card.seeding)}%"}
              ></span>
            </span>
            <span class="text-xs leading-snug text-subtle">
              {gettext("Seeding reward active")}
            </span>
          <% :no_stream -> %>
            <span class="text-[0.8125rem] font-semibold text-error">{gettext("No stream")}</span>
            <span class="line-clamp-3 text-xs leading-snug text-subtle">
              <%= if @card.last_event do %>
                {gettext("Last event at %{time}. The rules of this server are blind.",
                  time: clock(@card.last_event, @card.server)
                )}
              <% else %>
                {gettext("The rules of this server cannot see the game until it is back.")}
              <% end %>
            </span>
          <% :disabled -> %>
            <span class="text-[0.8125rem] font-semibold text-subtle">{gettext("Disabled")}</span>
            <span class="text-xs leading-snug text-muted">
              {gettext("No rule runs on this server.")}
            </span>
          <% :unreachable -> %>
            <span class="text-[0.8125rem] font-semibold text-warning">
              {gettext("CRCON not answering")}
            </span>
            <span class="text-xs leading-snug text-subtle">
              {gettext("The stream is up, but the match could not be read.")}
            </span>
          <% _loading -> %>
            <span class="h-6 w-16 animate-pulse rounded-lg bg-base-300"></span>
            <span class="h-[5px] w-full animate-pulse rounded-[3px] bg-base-300"></span>
            <span class="h-3 w-24 animate-pulse rounded bg-base-300"></span>
        <% end %>
      </span>
    </.link>
    """
  end

  defp card_art(%{live: %{layer: layer}, server: server}) when is_map(layer),
    do: MapArt.url(server.game, layer)

  defp card_art(%{server: server}), do: server_art(server)

  defp card_where(%{live: %{map: map} = live, server: server}) when is_binary(map),
    do: "#{map} · #{mode_or_game(live, server)}"

  defp card_where(%{server: server}), do: Labels.game(server.game)

  defp mode_or_game(%{mode: mode}, _server) when is_binary(mode),
    do: LiveComponents.mode_label(mode)

  defp mode_or_game(_live, server), do: Labels.game(server.game)

  defp card_dot(%{state: :disabled}), do: "bg-base-300"
  defp card_dot(%{state: :no_stream}), do: "bg-error"
  defp card_dot(%{state: :unreachable}), do: "bg-warning"
  defp card_dot(%{status: :connecting}), do: "bg-warning"
  defp card_dot(_card), do: "bg-primary"

  defp match_line(live) do
    [slots(live), minutes(live.time_remaining)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp slots(%{players: players, max_players: max}) when is_integer(max), do: "#{players}/#{max}"
  defp slots(%{players: players}), do: to_string(players)

  defp minutes(nil), do: nil
  defp minutes(seconds), do: gettext("%{count} min", count: div(seconds, 60))

  defp fill(_players, nil), do: 0
  defp fill(_players, 0), do: 0
  defp fill(players, total), do: min(round(players * 100 / total), 100)

  # "21:43" in the server's own time zone.
  defp clock(at, server) do
    zone = Map.get(server, :timezone) || "Etc/UTC"

    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> Calendar.strftime(local, "%H:%M")
      _error -> Calendar.strftime(at, "%H:%M")
    end
  end

  # ── First steps ────────────────────────────────────────────────────────────

  @doc """
  The first steps of a new server (or of a fresh install): the track on the
  left - done steps as one line, the step to do now opened up with its
  actions, the rest with what they take - and on the right the events the
  server is sending, its facts and the team to bring in.
  """
  attr :steps, :list, required: true
  attr :server, :any, default: nil
  attr :others, :list, default: [], doc: "the other servers, to copy modules from"
  attr :picked, :any, required: true, doc: "the modules ticked in the picker"
  attr :events, :map, required: true, doc: "%{count, first_at, rate, recent}"
  attr :live, :any, default: nil
  attr :rules, :list, default: []
  attr :team, :list, default: []
  attr :has_servers, :boolean, default: false, doc: "the install has servers, none in focus"

  def onboarding(assigns) do
    done = Enum.count(assigns.steps, &(&1.state == :done))
    focus = open_step(assigns.steps)

    assigns =
      assign(assigns,
        done: done,
        total: length(assigns.steps),
        focus: focus,
        indexed: Enum.with_index(assigns.steps, 1)
      )

    ~H"""
    <div
      id="onboarding"
      phx-hook=".OnboardingSkip"
      data-server={@server && @server.id}
      class={[
        "grid gap-4 md:gap-5",
        @server && "xl:grid-cols-[minmax(0,1fr)_22.5rem]"
      ]}
    >
      <section
        aria-labelledby="onboarding-title"
        class="flex min-w-0 flex-col gap-2 rounded-[1.75rem] bg-base-100 p-4 shadow-[var(--shadow-card)] md:px-7 md:py-[1.625rem]"
      >
        <div class="mb-2.5 flex flex-wrap items-end gap-x-6 gap-y-4">
          <div class="flex min-w-0 flex-1 basis-72 flex-col gap-1.5">
            <h2
              id="onboarding-title"
              class="font-display text-[1.625rem] font-semibold leading-tight tracking-[-0.02em]"
            >
              <%= cond do %>
                <% @server -> %>
                  {gettext("Let's get %{server} ready", server: @server.name)}
                <% @has_servers -> %>
                  {gettext("Let's get your servers ready")}
                <% true -> %>
                  {gettext("Let's connect your first server")}
              <% end %>
            </h2>
            <p class="text-sm text-subtle">
              {gettext(
                "A new server starts empty: no module, no rule. Nothing acts in the game until you say so."
              )}
            </p>
          </div>

          <div class="flex w-full flex-col gap-2 sm:w-[13.75rem]">
            <span class="flex justify-between text-[0.8125rem] text-subtle">
              {gettext("Progress")}
              <strong class="font-mono font-medium text-base-content">
                {gettext("%{done} of %{total}", done: @done, total: @total)}
              </strong>
            </span>
            <span
              class="grid gap-1"
              style={"grid-template-columns: repeat(#{max(@total, 1)}, minmax(0, 1fr))"}
              role="img"
              aria-label={gettext("%{done} of %{total}", done: @done, total: @total)}
            >
              <span
                :for={step <- @steps}
                class={[
                  "h-1.5 rounded-[3px]",
                  cond do
                    step.state == :done -> "bg-primary"
                    @focus && step.id == @focus.id -> "bg-base-content"
                    true -> "bg-base-300 dark:bg-[#33352e]"
                  end
                ]}
              ></span>
            </span>
          </div>
        </div>

        <ol class="flex flex-col gap-2">
          <%= for {step, index} <- @indexed do %>
            <.focus_step
              :if={@focus && step.id == @focus.id}
              step={step}
              index={index}
              server={@server}
              others={@others}
              picked={@picked}
              events={@events}
            />
            <.step_row
              :if={!(@focus && step.id == @focus.id)}
              step={step}
              index={index}
              server={@server}
              events={@events}
              rules={@rules}
            />
          <% end %>
        </ol>
      </section>

      <div :if={@server} class="flex min-w-0 flex-col gap-4 md:gap-5">
        <.events_card server={@server} events={@events} live={@live} rules={@rules} />
        <.server_facts server={@server} steps={@steps} rules={@rules} />
        <.team_card :if={@team != []} server={@server} team={@team} />
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".OnboardingSkip">
        // "Skip for now" lasts for the browser session: the next visit in a
        // new session shows the first steps again. Storage can throw
        // (private mode, blocked site data); skipping still works for this page.
        const key = (id) => `onboarding-skipped:${id || "install"}`

        export default {
          mounted() {
            try {
              if (sessionStorage.getItem(key(this.el.dataset.server)) === "1") {
                this.pushEvent("skip_onboarding", {})
                return
              }
            } catch (_e) {}

            this.onClick = (event) => {
              if (!event.target.closest("#onboarding-skip")) return
              try { sessionStorage.setItem(key(this.el.dataset.server), "1") } catch (_e) {}
            }
            document.addEventListener("click", this.onClick, true)
          },
          destroyed() {
            if (this.onClick) document.removeEventListener("click", this.onClick, true)
          }
        }
      </script>
    </div>
    """
  end

  # The step opened up as a card: the one to do now, or one that went wrong.
  # A stream that is still connecting does not hold the next thing back -
  # modules can be installed meanwhile - so waiting only opens when there is
  # nothing to do but wait.
  defp open_step(steps) do
    Enum.find(steps, &(&1.state in [:current, :blocked])) ||
      Enum.find(steps, &(&1.state == :available and &1.id != :two_factor)) ||
      Enum.find(steps, &(&1.state == :waiting))
  end

  attr :step, :map, required: true
  attr :index, :integer, required: true
  attr :server, :any, default: nil
  attr :events, :map, required: true
  attr :rules, :list, default: []

  defp step_row(assigns) do
    ~H"""
    <li
      id={"onboarding-step-#{@step.id}"}
      data-state={@step.state}
      class="briefing-step grid grid-cols-[2.125rem_minmax(0,1fr)_auto] items-center gap-3.5 rounded-2xl px-2 py-2 md:px-3.5"
    >
      <.step_marker step={@step} index={@index} />
      <span class="flex min-w-0 flex-col gap-px leading-[1.25]">
        <span class={[
          "text-[0.9375rem]",
          if(@step.state == :done, do: "font-semibold", else: "font-medium")
        ]}>
          {step_title(@step.id)}
        </span>
        <span class="text-[0.8125rem] text-muted">
          <%= if @step.state == :done do %>
            <.done_detail step={@step} events={@events} rules={@rules} />
          <% else %>
            {step_hint(@step, @server)}
          <% end %>
        </span>
      </span>
      <span class="shrink-0 text-right">
        <.step_aside step={@step} server={@server} />
      </span>
    </li>
    """
  end

  attr :step, :map, required: true
  attr :index, :integer, required: true

  defp step_marker(assigns) do
    ~H"""
    <span
      class={[
        "flex size-[1.875rem] items-center justify-center rounded-full font-mono text-[0.8125rem]",
        marker_tone(@step)
      ]}
      aria-hidden="true"
    >
      <%= case @step.state do %>
        <% :done -> %>
          <.icon name="hero-check" class="size-4" />
        <% :waiting -> %>
          <span class="briefing-pulse size-2 rounded-full bg-primary"></span>
        <% :blocked -> %>
          <.icon name="hero-exclamation-triangle" class="size-4" />
        <% _numbered -> %>
          {@index}
      <% end %>
    </span>
    """
  end

  defp marker_tone(%{state: :done}), do: "bg-primary text-primary-content"
  defp marker_tone(%{state: :current}), do: "bg-base-content text-base-100"
  defp marker_tone(%{state: :blocked}), do: "bg-error/14 text-error"

  defp marker_tone(%{state: :waiting, id: :simulation}),
    do: "border-[1.5px] border-dashed border-accent"

  defp marker_tone(%{state: :waiting}), do: "border-[1.5px] border-primary"

  defp marker_tone(%{id: :simulation}),
    do: "border-[1.5px] border-dashed border-accent text-accent"

  defp marker_tone(_step), do: "border-[1.5px] border-base-300 text-subtle dark:border-[#3a3d30]"

  attr :step, :map, required: true
  attr :events, :map, required: true
  attr :rules, :list, default: []

  defp done_detail(%{step: %{id: :server}} = assigns) do
    ~H"""
    <%= case length((@step.context[:server] && @step.context.server.known_permissions) || []) do %>
      <% 0 -> %>
        {gettext("Connection tested")}
      <% count -> %>
        {ngettext(
          "Connection tested · the key has 1 permission",
          "Connection tested · the key has %{count} permissions",
          count
        )}
    <% end %>
    """
  end

  defp done_detail(%{step: %{id: :stream}} = assigns) do
    ~H"""
    <span :if={@events.first_at}>
      {gettext("The log stream arrived at %{time}",
        time: clock(@events.first_at, @step.context.server)
      )} ·
    </span>
    <span class="text-primary">
      {ngettext("1 event so far", "%{count} events so far", @events.count)}
    </span>
    """
  end

  defp done_detail(%{step: %{id: :modules}} = assigns) do
    ~H"""
    {@step.context |> Map.get(:installed, MapSet.new()) |> Enum.map_join(", ", &Labels.feature/1)}
    """
  end

  defp done_detail(%{step: %{id: :rule}} = assigns) do
    ~H"""
    {@rules |> Enum.take(3) |> Enum.map_join(", ", & &1.name)}
    """
  end

  defp done_detail(%{step: %{id: :simulation}} = assigns) do
    ~H"""
    {gettext("It recorded what it would have done")}
    """
  end

  defp done_detail(%{step: %{id: :live}} = assigns) do
    ~H"""
    {gettext("A rule acts on the game")}
    """
  end

  defp done_detail(assigns) do
    ~H"""
    {gettext("Two-step verification is on")}
    """
  end

  attr :step, :map, required: true
  attr :server, :any, default: nil

  defp step_aside(%{step: %{id: :server, state: :done}, server: server} = assigns)
       when not is_nil(server) do
    ~H"""
    <.link
      navigate={~p"/servers/#{@server}/edit"}
      class="text-[0.8125rem] text-primary hover:opacity-80"
    >
      {gettext("Revisit")}
    </.link>
    """
  end

  defp step_aside(%{step: %{id: :stream, state: :done}} = assigns) do
    ~H"""
    <.pill tone="live" class="h-[1.625rem] px-2.5">{gettext("listening")}</.pill>
    """
  end

  defp step_aside(%{step: %{id: :stream, state: :waiting}} = assigns) do
    ~H"""
    <.pill tone="warning" class="h-[1.625rem] px-2.5">{gettext("connecting")}</.pill>
    """
  end

  defp step_aside(%{step: %{id: :modules, state: :done}, server: server} = assigns)
       when not is_nil(server) do
    ~H"""
    <.link
      navigate={~p"/servers/#{@server}/marketplace"}
      class="text-[0.8125rem] text-primary hover:opacity-80"
    >
      {gettext("Modules")}
    </.link>
    """
  end

  defp step_aside(%{step: %{id: :two_factor, state: state}} = assigns) when state != :done do
    ~H"""
    <.link navigate={~p"/account"} class="text-[0.8125rem] text-primary hover:opacity-80">
      {gettext("Do it now")}
    </.link>
    """
  end

  defp step_aside(%{step: %{state: :done}} = assigns) do
    ~H"""
    <.icon name="hero-check" class="size-4 text-primary" />
    """
  end

  defp step_aside(%{step: %{id: :rule}} = assigns) do
    ~H"""
    <span class="text-xs text-muted">{gettext("~2 min")}</span>
    """
  end

  defp step_aside(%{step: %{id: :simulation}} = assigns) do
    ~H"""
    <span class="text-xs text-muted">{gettext("3 days")}</span>
    """
  end

  defp step_aside(%{step: %{id: :live}} = assigns) do
    ~H"""
    <span class="text-xs text-muted">{gettext("1 click")}</span>
    """
  end

  defp step_aside(assigns) do
    ~H"""
    """
  end

  attr :step, :map, required: true
  attr :index, :integer, required: true
  attr :server, :any, default: nil
  attr :others, :list, default: []
  attr :picked, :any, required: true
  attr :events, :map, required: true

  defp focus_step(assigns) do
    ~H"""
    <li
      id={"onboarding-step-#{@step.id}"}
      data-state={@step.state}
      class="flex flex-col gap-3.5 rounded-[1.375rem] border border-base-300 bg-secondary px-4 py-[1.125rem] md:px-5 md:pb-5 dark:border-[#3a3d30]"
    >
      <div class="grid grid-cols-[2.125rem_minmax(0,1fr)] items-center gap-3.5 sm:grid-cols-[2.125rem_minmax(0,1fr)_auto]">
        <.step_marker step={@step} index={@index} />
        <span class="flex min-w-0 flex-col gap-px">
          <span class="text-[1.0625rem] font-semibold">{step_title(@step.id)}</span>
          <span class="text-[0.8125rem] text-subtle">{focus_hint(@step, @server)}</span>
        </span>
        <span :if={@step.id == :modules} class="hidden text-xs text-muted sm:block">
          {ngettext("1 chosen", "%{count} chosen", MapSet.size(@picked))}
        </span>
      </div>

      <.focus_body step={@step} server={@server} others={@others} picked={@picked} />
    </li>
    """
  end

  attr :step, :map, required: true
  attr :server, :any, default: nil
  attr :others, :list, default: []
  attr :picked, :any, required: true

  defp focus_body(%{step: %{id: :modules}} = assigns) do
    assigns = assign(assigns, :source, Enum.find(assigns.others, &(&1.modules != [])))

    ~H"""
    <.form
      for={%{}}
      as={:modules}
      id="onboarding-modules"
      phx-change="pick_modules"
      phx-submit="install_modules"
      class="flex flex-col gap-3.5"
    >
      <div class="grid gap-2.5 sm:grid-cols-2 lg:grid-cols-3">
        <label
          :for={feature <- onboarding_modules()}
          class={[
            "relative grid cursor-pointer grid-cols-[1.75rem_minmax(0,1fr)] items-center gap-x-2.5 gap-y-1.5 rounded-[1.125rem] bg-base-100 px-4 py-3.5 transition-colors",
            if(MapSet.member?(@picked, feature),
              do: "border-[1.5px] border-primary",
              else: "border border-base-300 hover:border-base-content/25"
            )
          ]}
        >
          <input
            type="checkbox"
            name="modules[]"
            value={feature}
            checked={MapSet.member?(@picked, feature)}
            class="absolute top-3.5 right-3.5 size-[1.125rem] cursor-pointer accent-primary"
          />
          <span class={[
            "flex size-7 items-center justify-center rounded-[0.5625rem]",
            if(MapSet.member?(@picked, feature),
              do: "bg-primary/12 text-primary",
              else: "bg-secondary text-subtle"
            )
          ]}>
            <.icon name={module_icon(feature)} class="size-4" />
          </span>
          <strong class="pr-6 text-sm font-semibold">{Labels.feature(feature)}</strong>
          <span class="col-span-2 text-xs leading-[1.4] text-muted">{module_blurb(feature)}</span>
        </label>
      </div>
      <input type="hidden" name="modules[]" value="" />

      <div class="flex flex-wrap items-center gap-2.5">
        <button
          id="onboarding-install"
          type="submit"
          disabled={MapSet.size(@picked) == 0}
          class="h-12 cursor-pointer rounded-full bg-primary px-[1.375rem] text-sm font-semibold text-primary-content transition-opacity hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {ngettext("Install 1 module", "Install %{count} modules", MapSet.size(@picked))}
        </button>
        <button
          :if={@source}
          id="onboarding-copy-modules"
          type="button"
          phx-click="copy_modules"
          phx-value-from={@source.server.id}
          class="h-12 cursor-pointer rounded-full border border-base-300 bg-base-100 px-[1.125rem] text-sm transition-colors hover:border-base-content/25"
        >
          {gettext("Copy from %{server}", server: @source.server.name)}
        </button>
        <span class="flex-1"></span>
        <span class="text-xs text-muted">{gettext("Installing turns nothing on in the game")}</span>
      </div>
    </.form>
    """
  end

  defp focus_body(%{step: %{id: :server}} = assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2.5 sm:ml-12">
      <.link
        id="onboarding-connect"
        navigate={~p"/servers/new?from=onboarding"}
        class="flex h-12 items-center gap-2 rounded-full bg-primary px-[1.375rem] text-sm font-semibold text-primary-content hover:opacity-90"
      >
        <.icon name="hero-plus" class="size-4" />{gettext("Connect a server")}
      </.link>
      <span class="text-xs text-muted">
        {gettext("You will need its address and an API key from CRCON.")}
      </span>
    </div>
    """
  end

  defp focus_body(%{step: %{id: :stream, state: :blocked}} = assigns) do
    ~H"""
    <p class="rounded-xl bg-error/14 px-3 py-2 font-mono text-xs break-words text-error sm:ml-12">
      {stream_problem(@step.context.error)}
    </p>
    <div :if={@step.context[:server]} class="sm:ml-12">
      <.link
        navigate={~p"/servers/#{@step.context.server}/edit"}
        class="inline-flex h-11 items-center gap-2 rounded-full bg-primary px-5 text-sm font-semibold text-primary-content hover:opacity-90"
      >
        <.icon name="hero-wrench-screwdriver" class="size-4" />{gettext("Review the server")}
      </.link>
    </div>
    """
  end

  defp focus_body(%{step: %{id: :stream}} = assigns) do
    ~H"""
    <p class="flex items-center gap-2 text-xs text-muted sm:ml-12">
      <span class="briefing-pulse size-2 rounded-full bg-primary"></span>
      {gettext("Connecting to the live log stream…")}
    </p>
    """
  end

  defp focus_body(
         %{step: %{id: :rule, context: %{rules_installed?: false, server: server}}} = assigns
       )
       when not is_nil(server) do
    ~H"""
    <div class="sm:ml-12">
      <.link
        navigate={~p"/servers/#{@step.context.server}/marketplace"}
        class="inline-flex h-11 items-center gap-2 rounded-full bg-primary px-5 text-sm font-semibold text-primary-content hover:opacity-90"
      >
        <.icon name="hero-bolt" class="size-4" />{gettext("Install Conditional rules")}
      </.link>
    </div>
    """
  end

  defp focus_body(%{step: %{id: :rule}} = assigns) do
    assigns =
      assign(assigns, :server_id, assigns.step.context[:server] && assigns.step.context.server.id)

    ~H"""
    <div class="flex flex-wrap items-center gap-2 sm:ml-12">
      <.link
        :for={recipe <- Enum.take(Recipes.all(), 3)}
        navigate={new_rule_path(recipe: recipe.id, server_id: @server_id)}
        class="briefing-recipe"
      >
        <.recipe_art id={recipe.id} class="size-6 text-primary" />{Labels.recipe_name(recipe.id)}
      </.link>
      <.link navigate={new_rule_path(server_id: @server_id)} class="briefing-recipe">
        <.icon name="hero-document-plus" class="size-4 text-muted" />{gettext("Blank rule")}
      </.link>
    </div>
    """
  end

  defp focus_body(%{step: %{id: :simulation}} = assigns) do
    ~H"""
    <div :if={@step.context[:rule]} class="flex flex-wrap items-center gap-2.5 sm:ml-12">
      <.link
        navigate={~p"/rules/#{@step.context.rule.id}/edit"}
        class="inline-flex h-11 items-center gap-2 rounded-full border border-base-300 bg-base-100 px-5 text-sm font-medium hover:border-base-content/25"
      >
        <.icon name="hero-arrow-path" class="size-4" />{gettext("Replay it on recent events")}
      </.link>
      <.link
        navigate={~p"/rules/#{@step.context.rule.id}"}
        class="text-xs text-muted hover:text-primary"
      >
        {gettext("Open %{name}", name: @step.context.rule.name)}
      </.link>
    </div>
    """
  end

  defp focus_body(%{step: %{id: :live}} = assigns) do
    ~H"""
    <div class="sm:ml-12">
      <.link
        navigate={if @step.context[:rule], do: ~p"/rules/#{@step.context.rule.id}", else: ~p"/rules"}
        class="inline-flex h-11 items-center gap-2 rounded-full bg-primary px-5 text-sm font-semibold text-primary-content hover:opacity-90"
      >
        <.icon name="hero-play" class="size-4" />
        {if @step.context[:rule],
          do: gettext("Review %{name}", name: @step.context.rule.name),
          else: gettext("Open your rules")}
      </.link>
    </div>
    """
  end

  defp focus_body(assigns) do
    ~H"""
    <div class="sm:ml-12">
      <.link
        navigate={~p"/account"}
        class="inline-flex h-11 items-center gap-2 rounded-full bg-primary px-5 text-sm font-semibold text-primary-content hover:opacity-90"
      >
        <.icon name="hero-shield-check" class="size-4" />{gettext("Set up two factor")}
      </.link>
    </div>
    """
  end

  @doc "The modules the first steps offer, in the order of the board."
  @spec onboarding_modules() :: [atom()]
  def onboarding_modules, do: [:rules, :live_feed, :tickets, :stats, :progression, :vip_shop]

  @doc "The modules ticked before the user touches the picker."
  @spec default_modules() :: MapSet.t()
  def default_modules, do: MapSet.new([:rules, :live_feed, :tickets])

  defp module_icon(:rules), do: "hero-bolt"
  defp module_icon(:live_feed), do: "hero-signal"
  defp module_icon(:tickets), do: "hero-chat-bubble-left"
  defp module_icon(:stats), do: "hero-chart-bar"
  defp module_icon(:progression), do: "hero-trophy"
  defp module_icon(:vip_shop), do: "hero-shopping-bag"

  defp module_blurb(:rules),
    do:
      gettext("When something happens in the game, the panel acts. %{count} ready-made recipes.",
        count: length(Recipes.all())
      )

  defp module_blurb(:live_feed), do: gettext("Kills, chat and what the rules did, in real time.")

  defp module_blurb(:tickets),
    do: gettext("Players call the staff from the chat, and it all lands in the Inbox.")

  defp module_blurb(:stats),
    do: gettext("Scoreboard, match history and statistics per player.")

  defp module_blurb(:progression),
    do: gettext("Medals and levels. Needs Leaderboard and matches.")

  defp module_blurb(:vip_shop),
    do: gettext("Sell VIP with Stripe or Mercado Pago, delivered automatically.")

  attr :server, :map, required: true
  attr :events, :map, required: true
  attr :live, :any, default: nil
  attr :rules, :list, default: []

  defp events_card(assigns) do
    ~H"""
    <section
      id="onboarding-events"
      aria-label={gettext("Stream")}
      class="flex flex-col gap-3.5 rounded-[1.75rem] bg-base-100 px-6 py-[1.375rem] shadow-[var(--shadow-card)]"
    >
      <div class="flex items-center gap-3">
        <svg width="56" height="56" viewBox="0 0 56 56" fill="none" aria-hidden="true">
          <circle cx="28" cy="28" r="26" class="stroke-base-300" stroke-width="1.5" />
          <circle cx="28" cy="28" r="18" class="stroke-base-300" stroke-width="1.5" />
          <circle cx="28" cy="28" r="10" class="stroke-primary/45" stroke-width="1.5" />
          <circle cx="28" cy="28" r="4" class="fill-primary" />
          <path d="M28 28 L50 16" class="stroke-primary" stroke-width="1.5" stroke-linecap="round" />
        </svg>
        <div class="flex flex-col gap-0.5">
          <span class="text-[0.8125rem] text-subtle">{gettext("Events received")}</span>
          <strong class="font-display text-[2.375rem] font-semibold leading-none tabular-nums">
            {format_number(@events.count)}
          </strong>
        </div>
        <span class="flex-1"></span>
        <span :if={@events.rate > 0} class="font-mono text-xs text-primary">
          {gettext("+%{count}/min", count: @events.rate)}
        </span>
      </div>

      <div class="flex flex-col gap-0.5 border-t border-base-300 pt-2.5">
        <div
          :for={entry <- @events.recent}
          class="grid grid-cols-[4rem_minmax(0,1fr)] gap-2 py-[0.3125rem] text-[0.8125rem]"
        >
          <span class="pt-0.5 font-mono text-[0.6875rem] text-muted">
            {clock_seconds(entry.at, @server)}
          </span>
          <span class="min-w-0 break-words"><.event_line event={entry.event} /></span>
        </div>
        <p :if={@events.recent == []} class="py-1.5 text-[0.8125rem] text-muted">
          {gettext("Waiting for the first event from the game…")}
        </p>
      </div>

      <span :if={(@live && @live[:map]) || @rules == []} class="text-xs leading-[1.45] text-muted">
        <%= if @live && @live[:map] do %>
          {ngettext("%{map} · 1 player.", "%{map} · %{count} players.", @live.players, map: @live.map)}
        <% end %>
        <%= if @rules == [] do %>
          {gettext("As soon as there is a rule, you see here what it would do with each event.")}
        <% end %>
      </span>
    </section>
    """
  end

  attr :event, :map, required: true

  defp event_line(%{event: %{type: :player_connected}} = assigns) do
    ~H"""
    <strong class="font-semibold">{@event.player_name}</strong> {gettext("joined the server")}
    """
  end

  defp event_line(%{event: %{type: :player_disconnected}} = assigns) do
    ~H"""
    <strong class="font-semibold">{@event.player_name}</strong> {gettext("left the server")}
    """
  end

  defp event_line(%{event: %{type: type}} = assigns)
       when type in [:player_kill, :player_team_kill] do
    {actor, target} = kill_teams(assigns.event)
    assigns = assign(assigns, actor: actor, target: target)

    ~H"""
    <strong class={["font-semibold", team_text(@actor)]}>{@event.player_name}</strong>
    {if @event.type == :player_team_kill,
      do: gettext("killed a teammate,"),
      else: gettext("killed")}
    <strong class={["font-semibold", team_text(@target)]}>{@event.target_player_name}</strong>
    """
  end

  defp event_line(%{event: %{type: :player_chat}} = assigns) do
    ~H"""
    <strong class={["font-semibold", team_text(@event.chat_team && String.downcase(@event.chat_team))]}>
      {@event.player_name}
    </strong>
    {gettext("in chat:")} “{@event.chat_message || @event.message}”
    """
  end

  defp event_line(assigns) do
    ~H"""
    <span class="text-subtle">{@event.action}</span>
    <strong :if={@event.player_name} class="font-semibold">{@event.player_name}</strong>
    """
  end

  # CRCON writes both teams into a kill line:
  # "Chris(Allies/7656…) -> Muctar(Axis/7656…) with M1 GARAND".
  defp kill_teams(event) do
    text = Enum.find([event.message, get_in(event.raw || %{}, ["raw"])], &is_binary/1) || ""

    case Regex.scan(~r/\((Allies|Axis)\//i, text, capture: :all_but_first) do
      [[actor], [target] | _rest] -> {String.downcase(actor), String.downcase(target)}
      [[actor]] -> {String.downcase(actor), nil}
      _none -> {nil, nil}
    end
  end

  attr :server, :map, required: true
  attr :steps, :list, required: true
  attr :rules, :list, default: []

  defp server_facts(assigns) do
    modules =
      case Enum.find(assigns.steps, &(&1.id == :modules)) do
        %{context: %{installed: installed}} -> Enum.map(installed, &Labels.feature/1)
        _other -> []
      end

    assigns = assign(assigns, :modules, modules)

    ~H"""
    <section
      id="onboarding-server"
      aria-label={gettext("Your server")}
      class="flex flex-col gap-2.5 rounded-[1.75rem] bg-base-100 px-6 py-[1.375rem] shadow-[var(--shadow-card)]"
    >
      <h3 class="mb-1 font-display text-[1.25rem] font-semibold">{@server.name}</h3>
      <.fact label={gettext("Game")}>{Labels.game(@server.game)}</.fact>
      <.fact label={gettext("CRCON")}>
        <span class="font-mono text-xs">{crcon_host(@server.base_url)}</span>
      </.fact>
      <.fact label={gettext("Time zone")}>{@server.timezone}</.fact>
      <.fact label={gettext("Modules")}>
        <span :if={@modules == []} class="text-subtle">{gettext("no module yet")}</span>
        {Enum.join(@modules, ", ")}
      </.fact>
      <.fact label={gettext("Rules")}>
        <span :if={@rules == []} class="text-subtle">{gettext("no rule yet")}</span>
        <span :if={@rules != []}>{length(@rules)}</span>
      </.fact>
    </section>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp fact(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3 text-[0.8125rem]">
      <span class="shrink-0 text-muted">{@label}</span>
      <span class="min-w-0 truncate text-right">{render_slot(@inner_block)}</span>
    </div>
    """
  end

  attr :server, :map, required: true
  attr :team, :list, required: true

  defp team_card(assigns) do
    assigns = assign(assigns, :names, names(assigns.team))

    ~H"""
    <section
      id="onboarding-team"
      class="flex flex-1 flex-col items-start gap-3 rounded-[1.75rem] bg-base-100 px-6 py-[1.375rem] shadow-[var(--shadow-card)]"
    >
      <div aria-hidden="true" class="flex">
        <span class="size-7 rounded-full border-2 border-base-100 bg-secondary"></span>
        <span class="-ml-3 size-7 rounded-full border-2 border-base-100 bg-base-300"></span>
        <span class="-ml-3 size-7 rounded-full border-[1.5px] border-dashed border-base-content/30"></span>
      </div>
      <strong class="text-[0.9375rem] font-semibold">{gettext("Bring the team")}</strong>
      <span class="text-[0.8125rem] leading-[1.45] text-muted">
        {ngettext(
          "%{names} already has access to the other servers. Open %{server} to them with the same role.",
          "%{names} already have access to the other servers. Open %{server} to them with the same role.",
          length(@team),
          names: @names,
          server: @server.name
        )}
      </span>
      <button
        id="onboarding-team-grant"
        type="button"
        phx-click="grant_team"
        class="h-10 cursor-pointer rounded-full border border-base-300 bg-secondary px-4 text-[0.8125rem] transition-colors hover:border-base-content/25"
      >
        {gettext("Open it to %{names}", names: @names)}
      </button>
    </section>
    """
  end

  defp names(users) do
    users = Enum.map(users, &(Map.get(&1, :name) || &1.username))

    case users do
      [one] ->
        one

      [first, second] ->
        gettext("%{first} and %{second}", first: first, second: second)

      [first, second | rest] ->
        gettext("%{first}, %{second} and %{count} more",
          first: first,
          second: second,
          count: length(rest)
        )
    end
  end

  defp step_title(:server), do: gettext("Connect the CRCON")
  defp step_title(:stream), do: gettext("Receive events")
  defp step_title(:modules), do: gettext("Install modules")
  defp step_title(:rule), do: gettext("First rule from a recipe")
  defp step_title(:simulation), do: gettext("See what it would have done")
  defp step_title(:live), do: gettext("Let it act for real")
  defp step_title(:two_factor), do: gettext("Protect your account")

  # The one line under a step that is not done: what it takes.
  defp step_hint(%{id: :server}, _server),
    do: gettext("The connection is tested before saving, and the key is stored encrypted.")

  defp step_hint(%{id: :stream}, _server),
    do: gettext("Kills, chat and connections reach the engine once the log stream connects.")

  defp step_hint(%{id: :modules}, _server),
    do:
      gettext("Choose what this server will have. You can turn them on and off later in Modules.")

  defp step_hint(%{id: :rule}, _server),
    do:
      gettext("%{recipes}… all start in simulation",
        recipes: Recipes.all() |> Enum.take(3) |> Enum.map_join(", ", &Labels.recipe_name(&1.id))
      )

  defp step_hint(%{id: :simulation}, nil),
    do:
      gettext(
        "The simulation runs with real events and shows every fire, without touching the game"
      )

  defp step_hint(%{id: :simulation}, server),
    do:
      gettext(
        "The simulation runs with real events from %{server} and shows every fire, without touching the game",
        server: server.name
      )

  defp step_hint(%{id: :live}, _server),
    do: gettext("Unlocks after 3 days simulating with no CRCON failure")

  defp step_hint(%{id: :two_factor}, _server),
    do: gettext("Two-step verification with an authenticator app and 10 recovery codes")

  # The line under the step to do now, which says more.
  defp focus_hint(%{id: :stream, state: :blocked}, _server),
    do: gettext("The live log stream could not connect. This is what CRCON answered:")

  defp focus_hint(%{id: :stream, context: %{server: server}}, _server) when not is_nil(server),
    do:
      gettext(
        "Connecting to the live log stream of %{name}. Kills, chat and connections reach the engine once it is up.",
        name: server.name
      )

  defp focus_hint(%{id: :rule, context: %{rules_installed?: false}}, _server),
    do:
      gettext(
        "Rules are a module as well: install Conditional rules from the marketplace to write the first one."
      )

  defp focus_hint(%{id: :rule}, _server),
    do:
      gettext(
        "Pick a recipe to start with everything filled in for your server. Recipes start in simulation: they record what they would do, and touch nothing."
      )

  defp focus_hint(%{id: :simulation, state: :waiting, context: %{rule: rule}}, _server)
       when not is_nil(rule),
       do:
         gettext(
           "\"%{name}\" records what it would do without touching the game. Its first result shows up as soon as it matches someone - or replay it on recent events right now.",
           name: rule.name
         )

  defp focus_hint(%{id: :live}, _server),
    do:
      gettext(
        "Happy with what it recorded? Open the rule, turn simulation off, and it starts acting."
      )

  defp focus_hint(%{id: :two_factor}, _server),
    do: gettext("This tool can kick and ban. A second factor keeps that power with you.")

  defp focus_hint(step, server), do: step_hint(step, server)

  defp stream_problem(:stopped),
    do:
      gettext(
        "The engine for this server stopped. It starts again on its own within a minute; if it does not, save the server again."
      )

  defp stream_problem(reason), do: reason

  # The builder, pointed at the server the rule is for when there is one. A
  # role that cannot see servers gets the builder's own default instead.
  defp new_rule_path(params) do
    ~p"/rules/new?#{Enum.reject(params, fn {_key, value} -> is_nil(value) end)}"
  end

  defp crcon_host(url) do
    case URI.parse(to_string(url)) do
      %URI{host: host, port: port} when is_binary(host) and is_integer(port) ->
        if port in [80, 443], do: host, else: "#{host}:#{port}"

      _other ->
        url
    end
  end

  defp clock_seconds(at, server) do
    zone = Map.get(server, :timezone) || "Etc/UTC"

    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> Calendar.strftime(local, "%H:%M:%S")
      _error -> Calendar.strftime(at, "%H:%M:%S")
    end
  end

  # ── Formatting ─────────────────────────────────────────────────────────────

  @doc "How long ago, in the largest unit that fits: 4 min, 2 h, 3 d."
  @spec ago(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def ago(nil), do: "–"
  def ago(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> ago()

  def ago(at) do
    seconds = max(DateTime.diff(DateTime.utc_now(), at), 0)

    cond do
      seconds < 3600 -> gettext("%{count} min", count: max(div(seconds, 60), 1))
      seconds < 86_400 -> gettext("%{count} h", count: div(seconds, 3600))
      true -> gettext("%{count} d", count: div(seconds, 86_400))
    end
  end

  @doc "A whole number with the viewer's thousands separator: 1.284 or 1,284."
  @spec format_number(integer() | nil) :: String.t()
  def format_number(nil), do: "–"

  def format_number(number) when is_integer(number) and number >= 1000 do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(thousands_separator())
    |> String.reverse()
  end

  def format_number(number), do: to_string(number)

  @doc "A number with at most one decimal, with the viewer's decimal mark: 98,6 or 98.6."
  @spec format_decimal(number()) :: String.t()
  def format_decimal(number) when is_integer(number), do: Integer.to_string(number)

  def format_decimal(number) when is_float(number) do
    rounded = Float.round(number, 1)

    if rounded == trunc(rounded) do
      Integer.to_string(trunc(rounded))
    else
      rounded |> Float.to_string() |> String.replace(".", decimal_mark())
    end
  end

  defp comma_locale?,
    do: Gettext.get_locale(HllConditionalActionsWeb.Gettext) in ["pt_BR", "pt", "es", "de", "fr"]

  defp thousands_separator, do: if(comma_locale?(), do: ".", else: ",")
  defp decimal_mark, do: if(comma_locale?(), do: ",", else: ".")

  defp change(_current, previous) when previous in [nil, 0], do: nil
  defp change(nil, _previous), do: nil
  defp change(current, previous), do: round((current - previous) * 100 / previous)
end
