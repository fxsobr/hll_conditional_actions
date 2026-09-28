defmodule HllConditionalActionsWeb.TicketComponents do
  @moduledoc """
  The browser side of tickets: the sound and desktop notification when a
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
  The switch that turns alerts on or off in this browser.
  """
  attr :id, :string, required: true

  def alert_toggle(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-hook=".TicketAlertToggle"
      data-on={gettext("Alerts on")}
      data-off={gettext("Turn on alerts")}
      data-blocked={gettext("Notifications are blocked in this browser; only the sound will play.")}
      class="inline-flex cursor-pointer items-center gap-1.5 rounded-full border border-base-300 px-3 py-1.5 text-sm text-subtle transition-colors hover:border-primary/50 hover:text-primary data-[state=on]:border-primary/40 data-[state=on]:bg-primary/10 data-[state=on]:text-primary"
      title={gettext("A sound, and a notification when this tab is in the background")}
    >
      <.icon name="hero-bell" class="size-4" />
      <span data-label>{gettext("Turn on alerts")}</span>
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
          this.el.dataset.state = on ? "on" : "off"
          this.el.querySelector("[data-label]").textContent = on ? this.el.dataset.on : this.el.dataset.off
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
        class="inline-flex cursor-pointer items-center gap-1.5 rounded-full border border-base-300 px-2.5 py-1 text-xs text-subtle transition-colors hover:border-primary/50 hover:text-primary"
      >
        <.icon name="hero-clipboard-document" class="size-3.5" />
        <span data-label>{gettext("Copy as text")}</span>
      </button>
      <button
        type="button"
        data-export="download"
        class="inline-flex cursor-pointer items-center gap-1.5 rounded-full border border-base-300 px-2.5 py-1 text-xs text-subtle transition-colors hover:border-primary/50 hover:text-primary"
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
end
