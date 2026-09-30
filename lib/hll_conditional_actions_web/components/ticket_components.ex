defmodule HllConditionalActionsWeb.TicketComponents do
  @moduledoc """
  The pieces of the Caixa and the ticket pages: the conversation with a
  player and the cards beside it (who called, what happened before the
  call, the player the ticket is about and the actions on them), the sheets
  for an action and for the ticket's other options, the panel and avatar
  shapes the Caixa repeats, and the tabs between the ticket pages.

  From the widest screens down, the cards beside the conversation fold into
  its header: two compact player cards and a "punish the reported player"
  menu, and the feed before the call joins the conversation.

  Also the browser side of tickets: the sound and desktop notification when a
  ticket arrives, the switch to turn them on, and copying or downloading a
  ticket as text.

  Alerts are a per-browser choice, kept in `localStorage`: an admin turns
  them on on the machine where the panel stays open, and the browser asks
  for notification permission on that click (it refuses to ask without
  one). The server pushes `ticket-alert` events through
  `HllConditionalActionsWeb.Nav`; the listener lives in the app layout so it
  hears them on any page.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.Tickets.Settings
  alias HllConditionalActionsWeb.TicketLive.Conversation

  @doc """
  The invisible listener for ticket alerts. Rendered once, by the layout.
  """
  def alert_listener(assigns) do
    ~H"""
    <div id="ticket-alerts" phx-hook=".TicketAlerts" hidden></div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".TicketAlerts">
      export default {
        mounted() {
          this.handleEvent("ticket-alert", ({title, body, url}) => {
            let enabled = false
            try { enabled = localStorage.getItem("ticketAlerts") === "on" } catch (_e) {}
            if (!enabled) return

            this.beep()

            if (document.hidden && "Notification" in window && Notification.permission === "granted") {
              const notification = new Notification(title, {body, tag: url})
              notification.onclick = () => {
                window.focus()
                window.location.assign(url)
                notification.close()
              }
            }
          })
        },
        // Two short tones; no audio file to ship or load.
        beep() {
          try {
            const context = new (window.AudioContext || window.webkitAudioContext)()
            ;[0, 0.18].forEach((offset, index) => {
              const oscillator = context.createOscillator()
              const gain = context.createGain()
              oscillator.frequency.value = index === 0 ? 880 : 1175
              gain.gain.setValueAtTime(0.15, context.currentTime + offset)
              gain.gain.exponentialRampToValueAtTime(0.001, context.currentTime + offset + 0.15)
              oscillator.connect(gain).connect(context.destination)
              oscillator.start(context.currentTime + offset)
              oscillator.stop(context.currentTime + offset + 0.16)
            })
            setTimeout(() => context.close(), 600)
          } catch (_e) {}
        }
      }
    </script>
    """
  end

  @doc """
  The switch that turns alerts on or off in this browser. `compact` draws it
  as a round icon button.
  """
  attr :id, :string, required: true
  attr :compact, :boolean, default: false

  def alert_toggle(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-hook=".TicketAlertToggle"
      data-on={gettext("Alerts on")}
      data-off={gettext("Turn on alerts")}
      data-blocked={gettext("Notifications are blocked in this browser; only the sound will play.")}
      aria-label={gettext("Turn on alerts")}
      class={[
        "inline-flex shrink-0 cursor-pointer items-center justify-center gap-1.5 rounded-full border border-base-300 text-subtle transition-colors hover:border-primary/50 hover:text-primary data-[state=on]:border-primary/40 data-[state=on]:bg-primary/10 data-[state=on]:text-primary",
        if(@compact, do: "size-12 bg-base-100", else: "px-3 py-1.5 text-sm")
      ]}
      title={gettext("A sound, and a notification when this tab is in the background")}
    >
      <.icon name="hero-bell" class={if @compact, do: "size-[1.125rem]", else: "size-4"} />
      <span data-label class={@compact && "sr-only"}>{gettext("Turn on alerts")}</span>
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".TicketAlertToggle">
      export default {
        mounted() {
          this.render()
          this.el.addEventListener("click", async () => {
            const on = this.enabled()
            try { localStorage.setItem("ticketAlerts", on ? "off" : "on") } catch (_e) {}
            if (!on && "Notification" in window && Notification.permission === "default") {
              await Notification.requestPermission()
            }
            if (!on && "Notification" in window && Notification.permission === "denied") {
              window.alert(this.el.dataset.blocked)
            }
            this.render()
          })
        },
        updated() { this.render() },
        enabled() {
          try { return localStorage.getItem("ticketAlerts") === "on" } catch (_e) { return false }
        },
        render() {
          const on = this.enabled()
          const label = on ? this.el.dataset.on : this.el.dataset.off
          this.el.dataset.state = on ? "on" : "off"
          this.el.setAttribute("aria-label", label)
          this.el.querySelector("[data-label]").textContent = label
        }
      }
    </script>
    """
  end

  @doc """
  Copy and download buttons for a ticket's transcript.
  """
  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :filename, :string, required: true

  def export_buttons(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".TicketExport"
      data-filename={@filename}
      data-copied={gettext("Copied")}
      class="flex flex-wrap gap-2"
    >
      <textarea data-transcript hidden readonly>{@text}</textarea>
      <button
        type="button"
        data-export="copy"
        class="inline-flex h-8 cursor-pointer items-center gap-1.5 rounded-full border border-base-300 bg-secondary px-3 text-xs text-subtle transition-colors hover:border-primary/50 hover:text-primary"
      >
        <.icon name="hero-clipboard-document" class="size-3.5" />
        <span data-label>{gettext("Copy as text")}</span>
      </button>
      <button
        type="button"
        data-export="download"
        class="inline-flex h-8 cursor-pointer items-center gap-1.5 rounded-full border border-base-300 bg-secondary px-3 text-xs text-subtle transition-colors hover:border-primary/50 hover:text-primary"
      >
        <.icon name="hero-arrow-down-tray" class="size-3.5" />
        {gettext("Download .txt")}
      </button>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".TicketExport">
      export default {
        mounted() {
          this.el.addEventListener("click", async (event) => {
            const button = event.target.closest("[data-export]")
            if (!button) return
            const text = this.el.querySelector("[data-transcript]").value

            if (button.dataset.export === "copy") {
              await navigator.clipboard.writeText(text)
              const label = button.querySelector("[data-label]")
              const before = label.textContent
              label.textContent = this.el.dataset.copied
              setTimeout(() => { label.textContent = before }, 1500)
            } else {
              const url = URL.createObjectURL(new Blob([text], {type: "text/plain;charset=utf-8"}))
              const link = document.createElement("a")
              link.href = url
              link.download = this.el.dataset.filename
              link.click()
              URL.revokeObjectURL(url)
            }
          })
        }
      }
    </script>
    """
  end

  @doc """
  A time of day ("21:48") in the reader's own clock. The server renders it
  in UTC until the browser takes over.
  """
  attr :id, :string, required: true
  attr :at, :any, required: true
  attr :class, :any, default: nil

  def clock(%{at: nil} = assigns), do: ~H"<span class={@class}>–</span>"

  def clock(assigns) do
    assigns = assign(assigns, :utc, to_utc(assigns.at))

    ~H"""
    <time
      id={@id}
      datetime={DateTime.to_iso8601(@utc)}
      phx-hook=".Clock"
      class={["whitespace-nowrap tabular-nums", @class]}
    >{Calendar.strftime(@utc, "%H:%M")}</time>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Clock">
      export default {
        mounted() { this.render() },
        updated() { this.render() },
        render() {
          const date = new Date(this.el.getAttribute("datetime"))
          const lang = document.documentElement.lang || "en"
          this.el.textContent = new Intl.DateTimeFormat(lang, {hour: "2-digit", minute: "2-digit"}).format(date)
          this.el.title = new Intl.DateTimeFormat(lang, {dateStyle: "short", timeStyle: "short"}).format(date)
        }
      }
    </script>
    """
  end

  defp to_utc(%DateTime{} = at), do: at
  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  # ── Caixa shapes ───────────────────────────────────────────────────────────

  @doc """
  The grid of the Caixa and the ticket page, sized to the window from `md`
  up so its panels scroll inside: it measures where it starts, whatever the
  header above it holds, and leaves room below for the tab bar or the page
  margin (`inbox.css`).
  """
  attr :id, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def frame(assigns) do
    ~H"""
    <div id={@id} phx-hook=".InboxFrame" class={["inbox-frame", @class]}>
      {render_slot(@inner_block)}
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".InboxFrame">
      export default {
        mounted() {
          this.measure = () => {
            const top = this.el.getBoundingClientRect().top + window.scrollY
            this.el.style.setProperty("--inbox-frame-top", `${Math.round(top)}px`)
          }
          this.measure()
          window.addEventListener("resize", this.measure)
        },
        updated() { this.measure() },
        destroyed() { window.removeEventListener("resize", this.measure) }
      }
    </script>
    """
  end

  @doc """
  A panel of the Caixa: the 28px-radius surface, an optional small caption
  (`eyebrow`) or display title, and controls on the right of the title.
  """
  attr :id, :string, default: nil
  attr :title, :string, default: nil
  attr :eyebrow, :string, default: nil
  attr :hint, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :action
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        "inbox-panel flex min-w-0 flex-col gap-3 rounded-[1.75rem] bg-base-100 p-5",
        @class
      ]}
      {@rest}
    >
      <div
        :if={@title || @eyebrow || @action != []}
        class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1"
      >
        <div class="min-w-0 flex-1">
          <span :if={@eyebrow} class="block text-xs uppercase tracking-[0.06em] text-muted">
            {@eyebrow}
          </span>
          <h2 :if={@title} class="font-display text-[1.25rem] font-semibold leading-tight">
            {@title}
          </h2>
          <p :if={@hint} class="mt-0.5 text-xs text-muted">{@hint}</p>
        </div>
        <div :if={@action != []} class="flex shrink-0 items-center gap-2">
          {render_slot(@action)}
        </div>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  A player's initials in a rounded tile, the lead of ticket rows and cards.
  """
  attr :name, :string, default: nil
  attr :tone, :string, default: "engine"
  attr :size, :string, default: "md", values: ~w(xs sm md lg)

  def avatar_tile(assigns) do
    ~H"""
    <span
      class={[
        "flex shrink-0 items-center justify-center font-bold",
        case @size do
          "xs" -> "size-8 rounded-[0.625rem] text-[0.6875rem]"
          "sm" -> "size-9 rounded-xl text-xs"
          "lg" -> "size-11 rounded-[0.875rem] text-sm"
          _md -> "size-[2.375rem] rounded-xl text-xs"
        end,
        avatar_tone(@tone)
      ]}
      aria-hidden="true"
    >
      {initials(@name)}
    </span>
    """
  end

  defp avatar_tone("allies"), do: "bg-allies/14 text-allies"
  defp avatar_tone("axis"), do: "bg-axis/16 text-axis"
  defp avatar_tone("primary"), do: "bg-primary/12 text-primary"
  defp avatar_tone("neutral"), do: "bg-secondary text-subtle"
  defp avatar_tone("olive"), do: "bg-[#3A3D2E] text-base-content"
  defp avatar_tone(_engine), do: "bg-accent/13 text-accent"

  @doc """
  Two letters for a player's tile: the first two letters or digits of the
  name.

      iex> HllConditionalActionsWeb.TicketComponents.initials("Kowalski [7DV]")
      "KO"
      iex> HllConditionalActionsWeb.TicketComponents.initials("_sgt_pepper")
      "SG"
      iex> HllConditionalActionsWeb.TicketComponents.initials(nil)
      "?"
  """
  @spec initials(String.t() | nil) :: String.t()
  def initials(name) when is_binary(name) do
    case name |> String.replace(~r/[^\p{L}\p{N}]/u, "") |> String.slice(0, 2) do
      "" -> "?"
      letters -> String.upcase(letters)
    end
  end

  def initials(_name), do: "?"

  @doc """
  The pill of a ticket's priority: orange for high, red for urgent, quiet
  otherwise.
  """
  attr :priority, :atom, required: true
  attr :class, :any, default: nil

  def priority_pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex shrink-0 items-center whitespace-nowrap rounded-full px-[0.5625rem] py-1 text-[0.6875rem] font-bold leading-none",
      case @priority do
        :urgent -> "bg-error/14 text-error"
        :high -> "bg-axis/14 text-axis"
        _other -> "bg-secondary text-subtle"
      end,
      @class
    ]}>
      {Labels.ticket_priority(@priority)}
    </span>
    """
  end

  @doc """
  The tabs of the ticket pages, beside the page title: back to the Caixa,
  then the pages that configure tickets.
  """
  attr :server, :any, default: nil, doc: "the server in scope, or nil for all of them"
  attr :current, :atom, required: true, values: [:tickets, :setup, :settings, :metrics]
  attr :can_manage?, :boolean, default: false

  def config_tabs(assigns) do
    base = if assigns.server, do: "/servers/#{assigns.server.id}/tickets", else: "/tickets"

    assigns =
      assign(assigns, :tabs, [
        {:setup, base <> "/setup", gettext("Wizard"), assigns.can_manage?},
        {:settings, base <> "/settings", gettext("Options"), assigns.can_manage?},
        {:metrics, base <> "/metrics", gettext("Metrics"), true}
      ])

    ~H"""
    <nav
      id="ticket-config-tabs"
      aria-label={gettext("Configure tickets")}
      class="-mx-1 flex max-w-full overflow-x-auto px-1"
    >
      <div class="flex shrink-0 items-center gap-1 rounded-full bg-base-100 p-1">
        <.link navigate={~p"/inbox"} class={config_tab_class(false)}>
          {gettext("Inbox entries")}
        </.link>
        <span class="mx-1.5 h-5 w-px bg-base-300" aria-hidden="true"></span>
        <span class="whitespace-nowrap pl-0.5 pr-1.5 text-xs text-muted">
          {gettext("Configure tickets")}
        </span>
        <.link
          :for={{key, path, label, shown?} <- @tabs}
          :if={shown?}
          navigate={path}
          aria-current={@current == key && "page"}
          class={config_tab_class(@current == key)}
        >
          {label}
        </.link>
      </div>
    </nav>
    """
  end

  defp config_tab_class(true),
    do:
      "flex h-9 items-center whitespace-nowrap rounded-full bg-base-content px-4 text-[0.8125rem] font-semibold text-base-100"

  defp config_tab_class(false),
    do:
      "flex h-9 items-center whitespace-nowrap rounded-full px-4 text-[0.8125rem] text-subtle transition-colors hover:text-base-content"

  @doc """
  The title of a ticket's conversation: its category, the rule that opened
  it, or the start of what the player wrote.

      iex> alias HllConditionalActionsWeb.TicketComponents
      iex> TicketComponents.ticket_title(%{category: "tiro amigo", source: :chat, rule: nil, messages: [], id: 3})
      "Tiro amigo"
      iex> TicketComponents.ticket_title(%{category: nil, source: :chat, rule: nil, id: 3,
      ...>   messages: [%{author: :player, body: "tem um cara matando o time no tanque"}]})
      "tem um cara matando o time no tanque"
  """
  @spec ticket_title(map()) :: String.t()
  def ticket_title(%{category: category}) when is_binary(category) and category != "",
    do: category_label(category)

  def ticket_title(%{source: :rule, rule: %{name: name}}) when is_binary(name), do: name

  def ticket_title(ticket) do
    ticket
    |> Map.get(:messages, [])
    |> Enum.find(&(&1.author == :player))
    |> case do
      %{body: body} -> shorten(body, 60)
      nil -> gettext("Ticket #%{id}", id: ticket.id)
    end
  end

  @doc """
  A category as a title: capitalised, and a short lower-case one ("tk")
  read as the abbreviation it is.

      iex> alias HllConditionalActionsWeb.TicketComponents
      iex> {TicketComponents.category_label("tk"), TicketComponents.category_label("tiro amigo")}
      {"TK", "Tiro amigo"}
  """
  @spec category_label(String.t()) :: String.t()
  def category_label(category) do
    if String.length(category) <= 3 and String.downcase(category) == category,
      do: String.upcase(category),
      else: capitalize(category)
  end

  defp capitalize(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  defp shorten(text, max) do
    text = String.trim(text)

    if String.length(text) <= max,
      do: text,
      else: (text |> String.slice(0, max) |> String.replace(~r/\s+\S*$/u, "")) <> "…"
  end

  # ── The conversation ───────────────────────────────────────────────────────

  @doc """
  The conversation with the player: the title, who and where on top with
  the ticket's actions, the messages (the player on the left, admins on the
  right, notes dashed across, what the player was told in the middle), and
  the answer box with the quick replies. Below the widest screens the
  player cards and the feed before the call join it. Drives the events of
  `HllConditionalActionsWeb.TicketLive.Conversation`.
  """
  attr :ticket, :map, required: true
  attr :reply, :any, required: true
  attr :settings, :map, required: true
  attr :others, :list, default: []
  attr :can_manage?, :boolean, default: false

  attr :can_act?, :boolean,
    default: false,
    doc: "whether the user may act on the players (message, punish, kick, ban)"

  attr :player_info, :any, default: nil
  attr :cited_info, :any, default: nil
  attr :ticket_count, :integer, default: 0
  attr :note_mode, :boolean, default: false
  attr :current_user, :map, required: true
  attr :class, :any, default: nil
  slot :lead, doc: "rendered before the title, e.g. a back link on phones"

  def conversation(assigns) do
    assigns =
      assigns
      |> assign(:cited, Conversation.cited(assigns.ticket))
      |> assign(:mine?, assigns.ticket.assigned_to_id == assigns.current_user.id)
      |> assign(:first_player, Enum.find(assigns.ticket.messages, &(&1.author == :player)))

    ~H"""
    <section
      id="ticket-conversation"
      aria-label={gettext("Ticket %{id}", id: @ticket.id)}
      class={[
        "inbox-panel flex min-h-0 min-w-0 flex-col overflow-hidden rounded-[1.75rem] bg-base-100 max-md:-mx-4 max-md:rounded-none max-md:bg-transparent max-md:shadow-none",
        @class
      ]}
    >
      <header class="flex shrink-0 flex-wrap items-center gap-x-3 gap-y-3.5 border-b border-(--inbox-line) px-4 pb-3 pt-4 md:px-[1.375rem] md:pb-[1.125rem] md:pt-5 min-[85rem]:px-6 min-[85rem]:py-5">
        {render_slot(@lead)}
        <div class="flex min-w-0 flex-1 flex-col gap-1 max-md:gap-px">
          <span class="text-xs text-muted md:hidden">
            #{@ticket.id} · {@ticket.server.name} ·
            <.clock id="ticket-opened-at-phone" at={@ticket.inserted_at} />
          </span>
          <div class="flex min-w-0 items-center gap-2.5">
            <h2
              id="ticket-title"
              class="truncate font-display text-[1.25rem] font-semibold tracking-[-0.01em] md:text-[1.375rem] md:tracking-normal"
            >
              {ticket_title(@ticket)}
            </h2>
            <.priority_pill :if={@ticket.priority != :normal} priority={@ticket.priority} />
            <span
              :if={@ticket.status != :open}
              class="inline-flex shrink-0 items-center rounded-full bg-secondary px-[0.5625rem] py-1 text-[0.6875rem] font-bold leading-none text-subtle"
            >
              {status_label(@ticket.status)}
            </span>
          </div>
          <p class="text-[0.8125rem] leading-[1.45] text-muted max-md:hidden">
            <span class="font-mono">#{@ticket.id}</span>
            · {@ticket.server.name} · {opened_by(@ticket)}
            <.clock id="ticket-opened-at" at={@ticket.inserted_at} />
            <span :if={@others != []} id="ticket-presence">
              <span
                :for={other <- @others}
                data-typing={to_string(other.typing?)}
                class={if(other.typing?, do: "font-medium text-warning", else: "text-accent")}
              >
                · {if other.typing?,
                  do: gettext("%{name} is typing an answer", name: other.name),
                  else: gettext("%{name} is viewing", name: other.name)}
              </span>
            </span>
          </p>
        </div>

        <button
          type="button"
          id="ticket-more"
          phx-click="more"
          aria-label={gettext("More options")}
          class="flex size-11 shrink-0 cursor-pointer items-center justify-center self-start rounded-full inbox-chip border border-base-300 transition-colors hover:border-base-content/30 min-[85rem]:order-last min-[85rem]:self-center"
        >
          <.icon name="hero-ellipsis-horizontal" class="size-[1.125rem]" />
        </button>

        <div
          :if={@can_manage?}
          id="ticket-actions"
          class="order-4 flex w-full gap-2 max-md:order-5 min-[85rem]:order-none min-[85rem]:w-auto"
        >
          <.button_close ticket={@ticket} />
          <button
            :if={@ticket.status != :closed and !@mine?}
            id="ticket-assign-me"
            type="button"
            phx-click="assign_me"
            class="inbox-solid order-1 h-11 flex-1 cursor-pointer rounded-full px-5 text-sm font-semibold transition-opacity hover:opacity-90 md:h-12 min-[85rem]:order-2 min-[85rem]:h-11 min-[85rem]:flex-none"
          >
            {gettext("Assign to me")}
          </button>
          <button
            :if={@ticket.status != :closed and @mine?}
            id="ticket-unassign"
            type="button"
            phx-click="unassign"
            class="order-1 h-11 flex-1 cursor-pointer inbox-chip rounded-full border border-base-300 px-5 text-sm transition-colors hover:border-base-content/30 md:h-12 min-[85rem]:order-2 min-[85rem]:h-11 min-[85rem]:flex-none"
          >
            {gettext("Release")}
          </button>
          <.punish_menu
            :if={@can_act? and @ticket.status != :closed}
            cited={@cited}
            class="order-2 flex-1 min-[85rem]:hidden"
          />
          <button
            :if={@ticket.status == :closed}
            id="ticket-reopen"
            type="button"
            phx-click="reopen"
            class="order-1 h-11 flex-1 cursor-pointer inbox-chip rounded-full border border-base-300 px-5 text-sm transition-colors hover:border-base-content/30 md:h-12 min-[85rem]:h-11 min-[85rem]:flex-none"
          >
            {gettext("Reopen")}
          </button>
        </div>

        <div class="order-5 grid w-full grid-cols-2 gap-2 max-md:order-4 min-[85rem]:hidden">
          <.link
            navigate={~p"/players/#{@ticket.player_id}"}
            class="flex min-h-12 min-w-0 items-center gap-2.5 rounded-2xl bg-secondary px-2.5 py-2 md:min-h-14 md:px-3 max-md:bg-base-100"
          >
            <.avatar_tile
              name={@ticket.player_name || @ticket.player_id}
              tone={player_tone(@player_info)}
              size="xs"
            />
            <span class="flex min-w-0 flex-col">
              <span class="truncate text-[0.6875rem] text-muted">
                {gettext("Called")}<span class="max-md:hidden">{caller_extra(@player_info)}</span>
              </span>
              <strong class="truncate text-[0.8125rem] font-semibold md:text-sm">
                {@ticket.player_name || @ticket.player_id}
              </strong>
            </span>
          </.link>
          <.link
            :if={@cited}
            navigate={~p"/players/#{elem(@cited, 0)}"}
            class="inbox-cited flex min-h-12 min-w-0 items-center gap-2.5 rounded-2xl border px-2.5 py-2 md:min-h-14 md:px-3"
          >
            <.avatar_tile name={elem(@cited, 1)} tone="axis" size="xs" />
            <span class="flex min-w-0 flex-col">
              <span class="inbox-cited-text truncate text-[0.6875rem]">
                {gettext("Reported")}{cited_tks(@cited_info)}<span class="max-md:hidden">{cited_watch(
                  @cited_info
                )}</span>
              </span>
              <strong class="truncate text-[0.8125rem] font-semibold md:text-sm">
                {elem(@cited, 1)}
              </strong>
            </span>
          </.link>
          <button
            :if={!@cited}
            type="button"
            phx-click="more"
            class="flex min-h-12 min-w-0 cursor-pointer items-center gap-2.5 rounded-2xl border border-dashed border-base-300 px-3 py-2 text-left text-xs text-muted md:min-h-14"
          >
            <.icon name="hero-user-plus" class="size-4 shrink-0" />
            {gettext("Nobody named. Who is it about?")}
          </button>
        </div>
      </header>

      <ol
        id="ticket-messages"
        phx-hook=".ScrollToEnd"
        class="flex min-h-48 flex-1 flex-col gap-3 overflow-y-auto px-4 py-3.5 md:min-h-0 md:gap-3.5 md:px-[1.375rem] md:py-[1.125rem] min-[85rem]:px-6 min-[85rem]:py-5"
      >
        <%= for message <- @ticket.messages do %>
          <.message message={message} ticket={@ticket} current_user={@current_user} />
          <li
            :if={message == @first_player and @ticket.context != []}
            id="ticket-feed-inline"
            class="flex flex-col gap-1.5 self-stretch rounded-[0.875rem] bg-base-100 p-3 max-md:border-0 md:rounded-2xl md:border md:border-(--inbox-line) md:bg-(--inbox-well) md:px-3.5 max-md:bg-secondary min-[85rem]:hidden"
          >
            <span class="text-[0.6875rem] uppercase tracking-[0.06em] text-muted">
              {gettext("In the feed before the call")}
            </span>
            <.context_line
              :for={{line, index} <- Enum.with_index(@ticket.context)}
              id={"feed-inline-#{index}"}
              line={line}
              reported_id={@cited && elem(@cited, 0)}
              reported_name={@cited && elem(@cited, 1)}
              inline
            />
          </li>
        <% end %>
      </ol>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToEnd">
        export default {
          mounted() { this.el.scrollTop = this.el.scrollHeight },
          updated() { this.el.scrollTop = this.el.scrollHeight }
        }
      </script>

      <p
        :if={@ticket.status == :closed}
        class="border-t border-(--inbox-line) px-6 py-4 text-sm text-muted"
        id="ticket-closed-note"
      >
        {gettext("This ticket is closed.")}
        <span :if={@ticket.close_reason}>
          {gettext("Reason: %{reason}.", reason: Labels.close_reason(@ticket.close_reason))}
        </span>
      </p>

      <div
        :if={@can_manage? and @ticket.status != :closed}
        class="flex shrink-0 flex-col gap-2.5 border-t border-(--inbox-line) px-3 pb-[1.125rem] pt-2.5 max-md:sticky max-md:bottom-24 max-md:z-10 max-md:bg-base-200 md:gap-3 md:px-[1.375rem] md:pb-5 md:pt-3.5 min-[85rem]:px-6 min-[85rem]:pt-4"
      >
        <p
          :if={@player_info not in [nil, :error] and @player_info.online == false}
          id="player-offline-warning"
          class="flex items-center gap-2 rounded-2xl bg-warning/13 px-3.5 py-2.5 text-sm text-warning"
        >
          <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
          {gettext("The player is not on the server right now: an answer will not reach them.")}
        </p>

        <div
          :if={Settings.reply_items(@settings) != []}
          class="flex gap-1.5 max-md:overflow-x-auto md:flex-wrap"
          id="quick-replies"
        >
          <button
            :for={{item, index} <- Enum.with_index(Settings.reply_items(@settings))}
            type="button"
            phx-click="quick_reply"
            phx-value-index={index}
            title={item["body"]}
            class="inbox-chip h-[2.125rem] max-w-64 shrink-0 cursor-pointer truncate rounded-full border border-base-300 px-3 text-xs transition-colors hover:border-primary/50 md:h-10 md:px-3.5 md:text-[0.8125rem] min-[85rem]:h-8 min-[85rem]:px-3 min-[85rem]:text-xs"
          >
            {item["title"]}
          </button>
        </div>

        <.form for={@reply} id="reply-form" phx-submit="reply" phx-change="typing">
          <div class={[
            "inbox-composer flex items-end gap-2 rounded-[1.375rem] border p-2 pl-3.5 transition-colors md:gap-2.5 md:p-2.5 md:pl-4 min-[85rem]:rounded-[1.25rem]",
            if(@note_mode,
              do: "border-dashed border-accent/50",
              else: "border-(--inbox-field-line) focus-within:border-primary/50"
            )
          ]}>
            <label class="flex min-w-0 flex-1 flex-col gap-0.5 md:gap-1">
              <span class={[
                "text-[0.6875rem] md:text-xs",
                if(@note_mode, do: "text-accent", else: "text-muted")
              ]}>
                {if @note_mode,
                  do: gettext("Internal note: only admins read it"),
                  else: gettext("Answer in game")}
              </span>
              <textarea
                id={@reply[:body].id}
                name={@reply[:body].name}
                rows="2"
                maxlength="250"
                placeholder={
                  gettext("Write to %{player}…", player: @ticket.player_name || @ticket.player_id)
                }
                class="w-full resize-none border-0 bg-transparent p-0 text-[0.9375rem] outline-none placeholder:text-muted focus:ring-0 min-[85rem]:text-sm"
              >{Phoenix.HTML.Form.normalize_value("textarea", @reply[:body].value)}</textarea>
            </label>
            <label
              class="flex h-11 shrink-0 cursor-pointer items-center gap-2 text-xs text-subtle max-md:w-11 max-md:justify-center max-md:rounded-full max-md:border max-md:border-accent/30 max-md:text-accent max-md:has-[:checked]:bg-accent/15 min-[85rem]:h-10"
              title={gettext("Only admins see it; nothing is sent to the player")}
            >
              <input
                type="checkbox"
                name="mode"
                value="note"
                checked={@note_mode}
                class="size-5 accent-[var(--color-accent)] max-md:sr-only min-[85rem]:size-[1.125rem]"
              />
              <.icon name="hero-pencil" class="size-[1.125rem] md:hidden" />
              <span class="max-md:sr-only">{gettext("Internal note")}</span>
            </label>
            <button
              type="submit"
              id="reply-send"
              aria-label={
                if @note_mode,
                  do: gettext("Save as internal note"),
                  else: gettext("Send to the player")
              }
              phx-disable-with
              class={[
                "flex size-11 shrink-0 cursor-pointer items-center justify-center rounded-full transition-transform hover:scale-105",
                if(@note_mode, do: "bg-accent text-accent-content", else: "inbox-send")
              ]}
            >
              <.icon
                name={if @note_mode, do: "hero-lock-closed", else: "hero-arrow-right"}
                class="size-[1.125rem]"
              />
            </button>
          </div>
        </.form>
      </div>
    </section>
    """
  end

  attr :ticket, :map, required: true

  defp button_close(assigns) do
    ~H"""
    <details
      :if={@ticket.status != :closed}
      id="close-menu"
      class="group relative order-3 min-[85rem]:order-1"
    >
      <summary class="flex h-11 cursor-pointer list-none items-center inbox-chip rounded-full border border-base-300 px-[1.125rem] text-sm transition-colors hover:border-base-content/30 md:h-12 md:px-5 min-[85rem]:h-11 min-[85rem]:px-[1.125rem] [&::-webkit-details-marker]:hidden">
        {gettext("Close")}
      </summary>
      <div class="absolute right-0 top-full z-20 mt-2 flex w-56 flex-col rounded-2xl border border-base-300 bg-base-100 p-1.5 shadow-lg">
        <span class="px-2.5 pb-1 pt-1.5 text-[0.6875rem] uppercase tracking-[0.06em] text-muted">
          {gettext("Why it is closed")}
        </span>
        <button
          :for={reason <- Conversation.close_reasons()}
          type="button"
          id={"close-#{reason}"}
          phx-click="close"
          phx-value-reason={reason}
          data-confirm={gettext("Close this ticket? The player is told it was closed.")}
          class="cursor-pointer rounded-xl px-2.5 py-2 text-left text-sm transition-colors hover:bg-secondary"
        >
          {Labels.close_reason(reason)}
        </button>
      </div>
    </details>
    """
  end

  attr :cited, :any, required: true
  attr :class, :any, default: nil

  defp punish_menu(assigns) do
    ~H"""
    <details id="punish-menu" class={["relative", @class]}>
      <summary class="flex h-11 w-full cursor-pointer list-none items-center justify-center gap-1.5 rounded-full border border-axis/45 bg-axis/10 px-4 text-sm font-semibold text-axis md:h-12 [&::-webkit-details-marker]:hidden">
        {if @cited, do: gettext("Punish reported"), else: gettext("Punish")}
        <.icon name="hero-chevron-down" class="size-4 max-md:hidden" />
      </summary>
      <div class="absolute left-0 top-full z-20 mt-2 flex w-56 flex-col rounded-2xl border border-base-300 bg-base-100 p-1.5 shadow-lg">
        <button
          :for={{action, label} <- act_buttons()}
          type="button"
          phx-click="act_open"
          phx-value-action={action}
          class="cursor-pointer rounded-xl px-2.5 py-2 text-left text-sm transition-colors hover:bg-secondary"
        >
          {label}
        </button>
      </div>
    </details>
    """
  end

  defp act_buttons do
    [
      {"message", gettext("Message")},
      {"punish", gettext("Punish")},
      {"kick", gettext("Kick")},
      {"temp_ban", gettext("Ban %{hours} h", hours: Conversation.quick_ban_hours())}
    ]
  end

  attr :message, :map, required: true
  attr :ticket, :map, required: true
  attr :current_user, :map, required: true

  defp message(%{message: %{author: :system}} = assigns) do
    ~H"""
    <li
      id={"message-#{@message.id}"}
      data-author="system"
      class="max-w-[92%] self-center rounded-full bg-secondary px-2.5 py-[0.3125rem] text-center text-[0.6875rem] text-muted md:px-3 md:py-1.5 md:text-xs max-md:bg-base-100"
    >
      <%= cond do %>
        <% @message.user -> %>
          <span class="font-medium text-subtle">{user_name(@message.user)}:</span>
          <span class="whitespace-pre-wrap break-words">{@message.body}</span>
        <% @message.delivery -> %>
          {gettext("The player received: “%{text}”", text: @message.body)}
          <span :if={@message.delivery == :failed} class="text-error" title={@message.delivery_error}>
            · {gettext("Not delivered")}
          </span>
        <% true -> %>
          <span class="whitespace-pre-wrap break-words">{@message.body}</span>
      <% end %>
    </li>
    """
  end

  defp message(%{message: %{author: :note}} = assigns) do
    ~H"""
    <li
      id={"message-#{@message.id}"}
      data-author="note"
      class="flex gap-2 self-stretch rounded-[0.875rem] border border-dashed border-accent/35 bg-accent/8 px-3 py-2.5 md:gap-2.5 md:rounded-2xl md:px-4 md:py-3"
    >
      <.icon name="hero-pencil" class="mt-0.5 size-3.5 shrink-0 text-accent md:size-4" />
      <p class="inbox-note-text min-w-0 text-[0.8125rem] leading-[1.45] md:text-sm md:leading-normal">
        <strong class="font-semibold">
          {gettext("Internal note · %{name}:", name: user_name(@message.user) || gettext("Admin"))}
        </strong>
        <span class="whitespace-pre-wrap break-words">{@message.body}</span>
      </p>
    </li>
    """
  end

  defp message(assigns) do
    assigns = assign(assigns, :admin?, assigns.message.author == :admin)

    ~H"""
    <li
      id={"message-#{@message.id}"}
      data-author={@message.author}
      class={[
        "flex max-w-[82%] flex-col gap-1 md:max-w-[78%] min-[85rem]:max-w-[70%]",
        if(@admin?, do: "items-end self-end", else: "items-start self-start")
      ]}
    >
      <span class="text-[0.6875rem] text-muted md:text-xs">
        <%= if @admin? do %>
          {if @message.user_id == @current_user.id,
            do: gettext("You"),
            else: user_name(@message.user) || gettext("Admin")} ·
        <% else %>
          {@ticket.player_name || @ticket.player_id} · {gettext("in game")} ·
        <% end %>
        <.clock id={"message-#{@message.id}-at"} at={@message.inserted_at} />
      </span>
      <p class={[
        "break-words px-3.5 py-2.5 text-sm leading-[1.45] md:px-4 md:py-3 md:text-[0.9375rem] md:leading-normal",
        if(@admin?,
          do: "rounded-[1.125rem] rounded-br-md bg-primary text-primary-content",
          else: "rounded-[1.125rem] rounded-bl-md bg-secondary"
        )
      ]}>
        <span class="whitespace-pre-wrap">{@message.body}</span>
      </p>
      <span
        :if={@message.delivery == :failed}
        class="text-[0.6875rem] text-error"
        title={@message.delivery_error}
      >
        {gettext("Not delivered")}
      </span>
      <span :if={@admin? and @message.delivery == :sent} class="text-[0.6875rem] text-muted">
        {gettext("delivered in game")}
      </span>
    </li>
    """
  end

  @doc "The pill tone of a ticket's status."
  @spec status_pill(atom()) :: String.t()
  def status_pill(:open), do: "warning"
  def status_pill(:answered), do: "engine"
  def status_pill(_closed), do: "neutral"

  defp status_label(:answered), do: gettext("Waiting for the player")
  defp status_label(:closed), do: gettext("Closed")
  defp status_label(_open), do: gettext("Waiting for an admin")

  defp opened_by(%{source: :rule, rule: %{name: name}}),
    do: gettext("opened by the rule %{rule} at", rule: name)

  defp opened_by(%{source: :rule}), do: gettext("opened by a rule at")

  defp opened_by(%{opened_with: command}) when is_binary(command),
    do: gettext("opened with %{command} at", command: command)

  defp opened_by(_ticket), do: gettext("opened at")

  defp user_name(nil), do: nil
  defp user_name(%{} = user), do: user.name || user.username

  # ── Beside the conversation ────────────────────────────────────────────────

  @doc """
  The cards beside a conversation on the widest screens: who called (the
  player card read from CRCON), what happened before the call, and the
  player the ticket is about with the actions on them.
  """
  attr :ticket, :map, required: true
  attr :player_info, :any, default: nil
  attr :cited_info, :any, default: nil
  attr :ticket_count, :integer, default: 0
  attr :can_manage?, :boolean, default: false
  attr :can_act?, :boolean, default: false
  attr :class, :any, default: nil

  def ticket_aside(assigns) do
    assigns = assign(assigns, :cited, Conversation.cited(assigns.ticket))

    ~H"""
    <div class={["flex min-h-0 min-w-0 flex-col gap-5", @class]}>
      <.panel id="ticket-player" eyebrow={gettext("Who called")}>
        <.link navigate={~p"/players/#{@ticket.player_id}"} class="flex items-center gap-3">
          <.avatar_tile
            name={@ticket.player_name || @ticket.player_id}
            tone={player_tone(@player_info)}
            size="lg"
          />
          <span class="flex min-w-0 flex-col">
            <strong class="truncate text-[0.9375rem] font-semibold">
              {@ticket.player_name || @ticket.player_id}
            </strong>
            <span class="truncate text-xs text-muted">{player_line(@player_info)}</span>
          </span>
        </.link>
        <div id="player-online" class="flex flex-wrap gap-1.5">
          <%= cond do %>
            <% @player_info == nil -> %>
              <span class={tag_class(:neutral)}>{gettext("Checking...")}</span>
            <% @player_info == :error or @player_info.online == :unknown -> %>
              <span class={tag_class(:neutral)}>{gettext("Unknown")}</span>
            <% @player_info.online == true -> %>
              <span class={tag_class(:live)}>{gettext("Online")}</span>
            <% true -> %>
              <span class={tag_class(:error)}>{gettext("Left the server")}</span>
          <% end %>
          <span class={tag_class(:neutral)}>{call_ordinal(@ticket_count)}</span>
          <span :if={@player_info not in [nil, :error]} class={tag_class(:neutral)}>
            {ngettext("1 penalty", "%{count} penalties", penalty_count(@player_info))}
          </span>
          <span :if={@player_info not in [nil, :error] and @player_info.vip?} class={tag_class(:live)}>
            VIP
          </span>
          <span
            :if={@player_info not in [nil, :error] and @player_info.watched?}
            class={tag_class(:warning)}
          >
            {gettext("Watchlist")}
          </span>
        </div>
      </.panel>

      <.panel
        :if={@ticket.context != []}
        id="ticket-context"
        eyebrow={gettext("Before the call")}
        class="gap-2.5"
      >
        <.context_line
          :for={{line, index} <- Enum.with_index(@ticket.context)}
          id={"context-#{index}"}
          line={line}
          reported_id={@cited && elem(@cited, 0)}
          reported_name={@cited && elem(@cited, 1)}
        />
      </.panel>

      <section
        id="ticket-cited"
        class="inbox-cited flex min-h-0 flex-1 flex-col gap-3 rounded-[1.75rem] border p-5"
      >
        <span class="inbox-cited-text text-xs uppercase tracking-[0.06em]">
          {gettext("Reported")}
        </span>
        <%= if @cited do %>
          <.link navigate={~p"/players/#{elem(@cited, 0)}"} class="flex items-center gap-3">
            <.avatar_tile name={elem(@cited, 1)} tone="axis" size="lg" />
            <span class="flex min-w-0 flex-1 flex-col">
              <strong class="truncate text-[0.9375rem] font-semibold">{elem(@cited, 1)}</strong>
              <span class="inbox-cited-text truncate text-xs">{cited_line(@cited_info)}</span>
            </span>
            <.icon name="hero-chevron-right" class="inbox-cited-text size-4 shrink-0" />
          </.link>
          <div
            :if={@can_manage? and @can_act? and @ticket.status != :closed}
            id="cited-actions"
            class="grid grid-cols-2 gap-2"
          >
            <button
              :for={{action, label} <- act_buttons()}
              type="button"
              id={"cited-#{action}"}
              phx-click="act_open"
              phx-value-action={action}
              class={[
                "h-11 cursor-pointer rounded-[0.875rem] text-[0.8125rem] transition-opacity hover:opacity-90",
                if(action == "temp_ban",
                  do: "inbox-cited-solid font-semibold",
                  else: "inbox-cited-button border"
                )
              ]}
            >
              {label}
            </button>
          </div>
          <span class="inbox-cited-text text-xs leading-[1.45]">
            {gettext("The action is recorded in the ticket and in the player's history.")}
          </span>
        <% else %>
          <p class="inbox-cited-text text-[0.8125rem] leading-relaxed">
            {gettext("The player did not name anyone, and nobody hurt them before the call.")}
          </p>
          <button
            :if={@can_manage?}
            type="button"
            phx-click="more"
            class="inbox-cited-button h-11 cursor-pointer rounded-[0.875rem] border text-[0.8125rem]"
          >
            {gettext("Pick who it is about")}
          </button>
        <% end %>
      </section>
    </div>
    """
  end

  @doc """
  One line of what happened before the call, written in the reader's
  language from the names it carries (older tickets keep their text).
  """
  attr :id, :string, required: true
  attr :line, :map, required: true
  attr :reported_id, :string, default: nil
  attr :inline, :boolean, default: false

  attr :reported_name, :string, default: nil

  def context_line(assigns) do
    line = HllConditionalActions.Tickets.Context.normalize(assigns.line)

    reported? =
      (assigns.reported_id && line["actor_id"] == assigns.reported_id) ||
        (assigns.reported_name && line["actor"] == assigns.reported_name)

    assigns =
      assigns
      |> assign(:line, line)
      |> assign(:actor_class, if(reported?, do: "font-semibold text-axis", else: "font-semibold"))

    ~H"""
    <div
      id={@id}
      data-kind={@line["kind"]}
      class={
        if @inline,
          do: "text-xs md:text-[0.8125rem]",
          else: "grid grid-cols-[2.75rem_minmax(0,1fr)] gap-2 text-[0.8125rem]"
      }
    >
      <.clock
        id={"#{@id}-at"}
        at={parse_at(@line["at"])}
        class={["font-mono text-[0.6875rem] text-muted", !@inline && "pt-0.5"]}
      />
      <span class="min-w-0 break-words">
        <%= case {@line["kind"], @line["actor"]} do %>
          <% {"team_kill", actor} when is_binary(actor) -> %>
            <strong class={@actor_class}>{actor}</strong>
            {gettext("team killed")}
            <strong class={if @inline, do: "font-normal", else: "font-semibold"}>
              {@line["target"]}
            </strong>
          <% {"kill", actor} when is_binary(actor) -> %>
            <strong class={@actor_class}>{actor}</strong>
            {gettext("killed")}
            <strong class="font-semibold">{@line["target"]}</strong>
          <% {"chat", actor} when is_binary(actor) -> %>
            <strong class={@actor_class}>{actor}</strong>
            {gettext("in chat: “%{text}”", text: @line["message"] || "")}
          <% _older -> %>
            {@line["text"]}
        <% end %>
      </span>
    </div>
    """
  end

  defp tag_class(tone) do
    [
      "inline-flex items-center rounded-full px-[0.5625rem] py-1 text-[0.6875rem] font-semibold leading-none",
      case tone do
        :live -> "bg-primary/12 text-primary"
        :error -> "bg-error/14 text-error"
        :warning -> "bg-warning/13 text-warning"
        _neutral -> "bg-secondary text-subtle"
      end
    ]
  end

  @doc """
  "2nd call": which call this is for the player, from how many tickets
  they opened.
  """
  @spec call_ordinal(non_neg_integer()) :: String.t()
  def call_ordinal(count) when count <= 1, do: gettext("1st call")
  def call_ordinal(2), do: gettext("2nd call")
  def call_ordinal(3), do: gettext("3rd call")
  def call_ordinal(count), do: gettext("%{count}th call", count: count)

  defp penalty_count(%{penalties: penalties}), do: penalties |> Map.values() |> Enum.sum()

  # "Aliados · nível 88 · 212 h"
  defp player_line(info) when info in [nil, :error], do: ""

  defp player_line(info) do
    [
      team_label(info.team),
      info.level && gettext("level %{level}", level: info.level),
      info.playtime_seconds && "#{div(info.playtime_seconds, 3600)} h"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # " · Aliados · nível 88", after "Called" on the compact card.
  defp caller_extra(info) when info in [nil, :error], do: ""

  defp caller_extra(info) do
    [team_label(info.team), info.level && gettext("level %{level}", level: info.level)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(&(" · " <> &1))
  end

  # "3 TKs nesta partida · watchlist"
  defp cited_line(info) when info in [nil, :error], do: gettext("Checking...")

  defp cited_line(info) do
    [
      if(info.online == false, do: gettext("left the server")),
      is_integer(info.team_kills) &&
        ngettext("1 TK this match", "%{count} TKs this match", info.team_kills),
      info.watched? && gettext("watchlist")
    ]
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> gettext("on the server")
      parts -> Enum.join(parts, " · ")
    end
  end

  # " · 3 TKs" and " · watchlist", after "Reported" on the compact card.
  defp cited_tks(%{team_kills: count}) when is_integer(count),
    do: " · " <> ngettext("1 TK", "%{count} TKs", count)

  defp cited_tks(_info), do: ""

  defp cited_watch(%{watched?: true}), do: " · " <> gettext("watchlist")
  defp cited_watch(_info), do: ""

  defp team_label(team) when team in ["allies", "Allies"], do: gettext("Allies")
  defp team_label(team) when team in ["axis", "Axis"], do: gettext("Axis")
  defp team_label(_team), do: nil

  defp player_tone(%{team: team}) when team in ["allies", "Allies"], do: "allies"
  defp player_tone(%{team: team}) when team in ["axis", "Axis"], do: "axis"
  defp player_tone(_info), do: "neutral"

  defp parse_at(text) do
    case DateTime.from_iso8601(text || "") do
      {:ok, at, _offset} -> at
      _error -> nil
    end
  end

  # ── Sheets ─────────────────────────────────────────────────────────────────

  @doc """
  The sheets of a conversation: the text of an action on a player, and the
  ticket's other options (priority, owner, the reported player, the
  transcript, earlier tickets).
  """
  attr :ticket, :map, required: true
  attr :pending_act, :any, default: nil
  attr :act_form, :any, required: true
  attr :more_open?, :boolean, default: false
  attr :can_manage?, :boolean, default: false
  attr :assignable, :list, default: []
  attr :history, :list, default: []
  attr :transcript, :string, default: ""
  attr :history_path, :any, required: true, doc: "fn earlier_ticket -> path"

  def ticket_sheets(assigns) do
    ~H"""
    <.modal
      :if={@pending_act}
      id="act-sheet"
      title={act_title(@pending_act)}
      subtitle={gettext("It is recorded in ticket #%{id}.", id: @ticket.id)}
      on_cancel={JS.push("act_cancel")}
    >
      <.form for={@act_form} id="act-form" phx-submit="act" class="flex flex-col gap-4">
        <.input
          field={@act_form[:reason]}
          type="textarea"
          rows="3"
          maxlength="200"
          label={
            if @pending_act.action == :message,
              do: gettext("Message"),
              else: gettext("Reason the player reads")
          }
        />
        <p :if={@pending_act.action == :temp_ban} class="text-sm text-muted">
          {gettext("The ban lasts %{hours} hours.", hours: Conversation.quick_ban_hours())}
        </p>
        <div class="flex justify-end gap-2">
          <.button
            type="button"
            variant="outline"
            color="gray"
            phx-click="act_cancel"
            label={gettext("Cancel")}
          />
          <.button
            type="submit"
            id="act-confirm"
            color="primary"
            phx-disable-with={gettext("Sending...")}
            label={act_confirm(@pending_act.action)}
          />
        </div>
      </.form>
    </.modal>

    <.modal
      :if={@more_open?}
      id="ticket-more-sheet"
      title={gettext("Ticket #%{id}", id: @ticket.id)}
      subtitle={@ticket.server.name}
      on_cancel={JS.push("more_close")}
    >
      <div class="flex flex-col gap-6">
        <section :if={@can_manage? and @ticket.status != :closed} class="grid gap-4 sm:grid-cols-2">
          <form id="priority-form" phx-change="set_priority">
            <label class="flex flex-col gap-1.5 text-sm">
              <span class="text-xs text-muted">{gettext("Priority")}</span>
              <select name="priority" class="pc-text-input w-full">
                <option
                  :for={{label, value} <- Labels.ticket_priority_options()}
                  value={value}
                  selected={value == to_string(@ticket.priority)}
                >
                  {label}
                </option>
              </select>
            </label>
          </form>
          <form id="transfer-form" phx-change="transfer">
            <label class="flex flex-col gap-1.5 text-sm">
              <span class="text-xs text-muted">{gettext("Hand the ticket to")}</span>
              <select name="user_id" class="pc-text-input w-full">
                <option value="">{gettext("Nobody")}</option>
                <option
                  :for={user <- @assignable}
                  value={user.id}
                  selected={user.id == @ticket.assigned_to_id}
                >
                  {user_name(user)}
                </option>
              </select>
            </label>
          </form>
        </section>

        <form
          :if={@can_manage?}
          id="reported-form"
          phx-submit="set_reported"
          class="flex flex-col gap-3 rounded-2xl bg-secondary p-4"
        >
          <span class="text-sm font-semibold">{gettext("Who is it about")}</span>
          <select
            name="reported[pick]"
            class="pc-text-input w-full"
            aria-label={gettext("Who is it about")}
          >
            <option value="">{gettext("Nobody")}</option>
            <option
              :for={{id, name} <- Conversation.candidates(@ticket)}
              value={id}
              selected={id == @ticket.reported_player_id}
            >
              {name}
            </option>
          </select>
          <input
            type="text"
            name="reported[player_id]"
            placeholder={gettext("Or paste a player ID")}
            class="pc-text-input w-full"
            aria-label={gettext("Or paste a player ID")}
          />
          <div class="flex justify-end">
            <.button type="submit" size="sm" color="primary" label={gettext("Save")} />
          </div>
        </form>

        <section class="flex flex-col gap-2">
          <span class="text-xs uppercase tracking-[0.06em] text-muted">{gettext("Transcript")}</span>
          <.export_buttons
            id="ticket-export"
            text={@transcript}
            filename={"ticket-#{@ticket.id}.txt"}
          />
        </section>

        <section :if={@history != []} id="ticket-history" class="flex flex-col gap-1">
          <span class="text-xs uppercase tracking-[0.06em] text-muted">
            {gettext("Earlier tickets")}
          </span>
          <.link
            :for={earlier <- @history}
            navigate={@history_path.(earlier)}
            class="flex items-center justify-between gap-2 rounded-xl px-2 py-1.5 text-sm transition-colors hover:bg-secondary"
          >
            <span class="min-w-0 truncate">
              <span class="font-mono text-xs text-muted">#{earlier.id}</span>
              {earlier.server.name}
            </span>
            <.local_time
              id={"earlier-#{earlier.id}"}
              at={earlier.inserted_at}
              class="shrink-0 text-xs text-muted"
            />
          </.link>
        </section>

        <button
          type="button"
          phx-click="refresh_player"
          class="flex w-fit cursor-pointer items-center gap-1.5 text-sm text-subtle hover:text-base-content"
        >
          <.icon name="hero-arrow-path" class="size-4" /> {gettext(
            "Read the players from CRCON again"
          )}
        </button>
      </div>
    </.modal>
    """
  end

  defp act_title(%{action: action, target: {_id, name}}) do
    case action do
      :message -> gettext("Message %{player}", player: name)
      :punish -> gettext("Punish %{player}", player: name)
      :kick -> gettext("Kick %{player}", player: name)
      :temp_ban -> gettext("Ban %{player}", player: name)
      :watch -> gettext("Watch %{player}", player: name)
    end
  end

  defp act_confirm(:message), do: gettext("Send")
  defp act_confirm(:punish), do: gettext("Punish")
  defp act_confirm(:kick), do: gettext("Kick")

  defp act_confirm(:temp_ban),
    do: gettext("Ban %{hours} h", hours: Conversation.quick_ban_hours())

  defp act_confirm(:watch), do: gettext("Add to the watchlist")
end
