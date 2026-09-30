defmodule HllConditionalActionsWeb.VipShopLive.Components do
  @moduledoc """
  The pieces the Loja VIP admin pages share, drawn after the boards: the
  panels, the chips and dots, the pill buttons, the switch, the provider
  tiles and the short local times ("21:32", "ontem", "27 set").
  Styles that utilities cannot express are in `assets/css/areas/vip.css`.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.VipShop

  @doc "A panel of the boards: 28px corners on the panel colour."
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :label, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def vip_panel(assigns) do
    ~H"""
    <section
      id={@id}
      aria-label={@label}
      class={["min-w-0 rounded-[1.75rem] bg-base-100", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc "A panel's title row: the title, then whatever sits on the right."
  attr :title, :string, required: true
  attr :class, :any, default: nil
  attr :size, :string, default: "md", values: ~w(sm md lg)
  slot :inner_block

  def vip_panel_head(assigns) do
    ~H"""
    <div class={["flex items-baseline gap-3", @class]}>
      <h2 class={[
        "min-w-0 flex-1 truncate font-display font-semibold",
        case @size do
          "sm" -> "text-lg"
          "lg" -> "text-[1.375rem]"
          _md -> "text-xl"
        end
      ]}>
        {@title}
      </h2>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "A small rounded label, tinted by tone."
  attr :tone, :string, default: "muted", values: ~w(muted ok warn eng err lime ink)
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def vip_chip(assigns) do
    ~H"""
    <span class={["vip-chip", chip_tone(@tone), @class]} {@rest}>{render_slot(@inner_block)}</span>
    """
  end

  defp chip_tone("ok"), do: "vip-chip-ok"
  defp chip_tone("warn"), do: "vip-chip-warn"
  defp chip_tone("eng"), do: "vip-chip-eng"
  defp chip_tone("err"), do: "vip-chip-err"
  defp chip_tone("lime"), do: "vip-chip-lime"
  defp chip_tone("ink"), do: "vip-chip-ink"
  defp chip_tone(_muted), do: nil

  @doc ~s(A coloured dot and a word: "à venda", "ao vivo".)
  attr :tone, :string, default: "ok", values: ~w(ok warn muted err)
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def dot_label(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 whitespace-nowrap",
      case @tone do
        "ok" -> "vip-ok"
        "warn" -> "vip-warn"
        "err" -> "vip-err"
        _muted -> "text-muted"
      end,
      @class
    ]}>
      <span class="vip-dot"></span>{render_slot(@inner_block)}
    </span>
    """
  end

  @doc "The header button that opens the public shop in a new tab."
  attr :class, :any, default: nil

  def open_shop_link(assigns) do
    ~H"""
    <a
      href={~p"/shop"}
      target="_blank"
      rel="noopener"
      id="open-public-shop"
      class={["vip-btn hidden sm:inline-flex", @class]}
    >
      {gettext("Open the shop")}<.icon name="hero-arrow-up-right" class="size-4" />
    </a>
    """
  end

  @doc """
  A checkbox drawn as a switch. `name` and `checked`; a hidden "false" goes
  first so switching it off is posted too.
  """
  attr :name, :string, required: true
  attr :checked, :boolean, default: false
  attr :label, :string, required: true
  attr :id, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :rest, :global

  def vip_switch(assigns) do
    ~H"""
    <label class="vip-switch" title={@label}>
      <input :if={!@rest[:"phx-click"]} type="hidden" name={@name} value="false" />
      <input
        type="checkbox"
        role="switch"
        id={@id}
        name={@name}
        value="true"
        checked={@checked}
        disabled={@disabled}
        aria-label={@label}
        {@rest}
      />
      <span aria-hidden="true"></span>
    </label>
    """
  end

  @doc """
  A list reordered by dragging: each item carries `data-sort-id` and a
  `data-sort-handle` element to grab it by. On drop the ids go to `event`,
  in their new order.
  """
  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def sort_list(assigns) do
    ~H"""
    <div id={@id} class={["vip-sortable", @class]} data-event={@event} phx-hook=".VipSort">
      {render_slot(@inner_block)}
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".VipSort">
      export default {
        mounted() {
          const item = (target) => target.closest("[data-sort-id]")
          this.el.addEventListener("pointerdown", (e) => {
            const row = item(e.target)
            if (row) row.draggable = !!e.target.closest("[data-sort-handle]")
          })
          this.el.addEventListener("dragstart", (e) => {
            const row = item(e.target)
            if (!row) return
            this.dragging = row
            row.classList.add("vip-dragging")
            e.dataTransfer.effectAllowed = "move"
            e.dataTransfer.setData("text/plain", row.dataset.sortId)
          })
          this.el.addEventListener("dragover", (e) => {
            if (!this.dragging) return
            e.preventDefault()
            const over = item(e.target)
            if (!over || over === this.dragging || over.parentNode !== this.dragging.parentNode) return
            const rect = over.getBoundingClientRect()
            const after = e.clientY > rect.top + rect.height / 2
            over.parentNode.insertBefore(this.dragging, after ? over.nextSibling : over)
          })
          this.el.addEventListener("drop", (e) => e.preventDefault())
          this.el.addEventListener("dragend", () => {
            if (!this.dragging) return
            this.dragging.classList.remove("vip-dragging")
            this.dragging.draggable = false
            this.dragging = null
            const ids = [...this.el.querySelectorAll("[data-sort-id]")].map((el) => el.dataset.sortId)
            this.pushEvent(this.el.dataset.event, {ids})
          })
        }
      }
    </script>
    """
  end

  @doc "The grip a sortable row is dragged by."
  attr :label, :string, required: true

  def grip(assigns) do
    ~H"""
    <span
      data-sort-handle
      class="flex size-3.5 cursor-grab items-center justify-center text-muted"
      aria-label={@label}
      title={@label}
    >
      <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
        <circle cx="9" cy="6" r="1.6" /><circle cx="15" cy="6" r="1.6" />
        <circle cx="9" cy="12" r="1.6" /><circle cx="15" cy="12" r="1.6" />
        <circle cx="9" cy="18" r="1.6" /><circle cx="15" cy="18" r="1.6" />
      </svg>
    </span>
    """
  end

  @doc "A button that copies `value` to the clipboard and says so for a moment."
  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, default: nil
  attr :class, :any, default: nil

  def copy_button(assigns) do
    assigns = assign(assigns, :label, assigns.label || gettext("Copy"))

    ~H"""
    <button
      type="button"
      id={@id}
      phx-hook=".VipCopy"
      data-copy={@value}
      data-done={gettext("Copied")}
      class={["inline-flex shrink-0 items-center gap-1.5 whitespace-nowrap", @class]}
    >
      <.icon name="hero-document-duplicate" class="size-3.5" /><span>{@label}</span>
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".VipCopy">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            const label = this.el.querySelector("span")
            const before = label.textContent
            navigator.clipboard?.writeText(this.el.dataset.copy).then(() => {
              label.textContent = this.el.dataset.done
              setTimeout(() => { label.textContent = before }, 1500)
            })
          })
        }
      }
    </script>
    """
  end

  @doc """
  A stored secret shown the way the boards show it: its prefix, dots and
  the last four characters ("rk_live_••••7Hc2").
  """
  @spec mask(String.t() | nil) :: String.t() | nil
  def mask(nil), do: nil
  def mask(""), do: nil

  def mask(value) do
    prefix =
      case Regex.run(~r/^((?:sk|rk|pk)_(?:live|test)_|TEST-|APP_USR-|whsec_|SG\.)/, value) do
        [prefix, _] -> prefix
        _none -> ""
      end

    prefix <> "••••" <> String.slice(value, -4, 4)
  end

  @doc "The initials tile of a payment provider (MP, ST, DO)."
  attr :provider, :string, required: true
  attr :size, :string, default: "md", values: ~w(sm md)
  attr :active, :boolean, default: false

  def provider_tile(assigns) do
    ~H"""
    <span class={[
      "flex shrink-0 items-center justify-center font-bold",
      if(@size == "sm",
        do: "size-8 rounded-[0.625rem] text-[0.6875rem]",
        else: "size-9 rounded-[0.625rem] text-xs"
      ),
      if(@active, do: "vip-chip-ok", else: "bg-base-300 text-subtle")
    ]}>
      {provider_initials(@provider)}
    </span>
    """
  end

  @doc "The two letters a provider is shown by."
  @spec provider_initials(String.t()) :: String.t()
  def provider_initials("mercado_pago"), do: "MP"
  def provider_initials("stripe"), do: "ST"
  def provider_initials("dodo"), do: "DO"
  def provider_initials("manual"), do: "—"
  def provider_initials(other), do: other |> String.slice(0, 2) |> String.upcase()

  @doc "A provider's name."
  @spec provider_name(String.t() | nil) :: String.t()
  def provider_name("mercado_pago"), do: "Mercado Pago"
  def provider_name("stripe"), do: "Stripe"
  def provider_name("dodo"), do: "Dodo Payments"
  def provider_name("manual"), do: gettext("Manual")
  def provider_name(nil), do: "—"
  def provider_name(other), do: other

  @doc "What a provider's checkout takes, as the boards write it."
  @spec provider_methods(String.t()) :: String.t()
  def provider_methods("mercado_pago"), do: gettext("Pix and card")
  def provider_methods("stripe"), do: gettext("International card")
  def provider_methods("dodo"), do: gettext("Pix and card · taxes on their side")
  def provider_methods(_other), do: ""

  @doc "An amount in cents, as the shop writes money."
  @spec money(integer() | nil, String.t() | nil) :: String.t()
  def money(nil, _currency), do: "—"
  def money(cents, currency), do: VipShop.format_money(cents, currency || "BRL")

  @doc ~s(A server's short name: "BR #1 Público" → "BR #1".)
  @spec short_server(String.t() | nil) :: String.t()
  def short_server(nil), do: "?"

  def short_server(name) do
    case Regex.run(~r/^(.*?#\s?\d+)/u, name) do
      [_all, short] -> short
      _none -> name
    end
  end

  @doc """
  A time in the viewer's timezone, short: `short` is "21:32" today, "ontem"
  yesterday and "27 set" before; `clock` is "21:45:12"; `ago` is "há 2 min";
  `date` is "31 out".
  """
  attr :id, :string, required: true
  attr :at, :any, required: true
  attr :format, :string, default: "short", values: ~w(short clock ago date datetime month)
  attr :class, :any, default: nil

  def vip_time(%{at: nil} = assigns), do: ~H"<span class={@class}>—</span>"

  def vip_time(assigns) do
    assigns =
      assign(
        assigns,
        :utc,
        case assigns.at do
          %DateTime{} = at -> at
          %NaiveDateTime{} = at -> DateTime.from_naive!(at, "Etc/UTC")
        end
      )

    ~H"""
    <time
      id={@id}
      datetime={DateTime.to_iso8601(@utc)}
      data-format={@format}
      data-yesterday={gettext("yesterday")}
      phx-hook=".VipTime"
      class={["whitespace-nowrap tabular-nums", @class]}
    >{Calendar.strftime(@utc, "%H:%M")}</time>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".VipTime">
      const lang = () => document.documentElement.lang || "en"
      const sameDay = (a, b) =>
        a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()

      function ago(date) {
        const seconds = (date.getTime() - Date.now()) / 1000
        const abs = Math.abs(seconds)
        const fmt = new Intl.RelativeTimeFormat(lang(), {numeric: "auto", style: "short"})
        if (abs < 60) return fmt.format(Math.round(seconds), "second")
        if (abs < 3600) return fmt.format(Math.round(seconds / 60), "minute")
        if (abs < 86400) return fmt.format(Math.round(seconds / 3600), "hour")
        return fmt.format(Math.round(seconds / 86400), "day")
      }

      function dayMonth(date) {
        return new Intl.DateTimeFormat(lang(), {day: "numeric", month: "short"})
          .format(date).replace(".", "").replace(" de ", " ")
      }

      export default {
        mounted() { this.render(); if (this.el.dataset.format === "ago") this.timer = setInterval(() => this.render(), 30000) },
        updated() { this.render() },
        destroyed() { if (this.timer) clearInterval(this.timer) },
        render() {
          const date = new Date(this.el.getAttribute("datetime"))
          const now = new Date()
          const yesterday = new Date(now.getTime() - 86400000)
          const hm = new Intl.DateTimeFormat(lang(), {hour: "2-digit", minute: "2-digit"}).format(date)
          this.el.title = new Intl.DateTimeFormat(lang(), {dateStyle: "short", timeStyle: "short"}).format(date)
          switch (this.el.dataset.format) {
            case "clock":
              this.el.textContent = new Intl.DateTimeFormat(lang(), {hour: "2-digit", minute: "2-digit", second: "2-digit"}).format(date)
              break
            case "ago":
              this.el.textContent = ago(date)
              break
            case "date":
              this.el.textContent = dayMonth(date)
              break
            case "month":
              this.el.textContent = new Intl.DateTimeFormat(lang(), {month: "long"}).format(date)
              break
            case "datetime":
              this.el.textContent = sameDay(date, now) ? hm : `${dayMonth(date)} ${hm}`
              break
            default:
              if (sameDay(date, now)) this.el.textContent = hm
              else if (sameDay(date, yesterday)) this.el.textContent = this.el.dataset.yesterday
              else this.el.textContent = dayMonth(date)
          }
        }
      }
    </script>
    """
  end
end
