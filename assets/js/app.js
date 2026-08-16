// The one bundle the browser loads. Everything client side is imported here:
// there is no npm install in this project, so third party code comes either
// from a dep's own assets directory or from assets/vendor.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/hll_conditional_actions"
import PetalHooks from "../../deps/petal_components/assets/js/petal_components.js"
import Alpine from "../vendor/alpine"
import topbar from "../vendor/topbar"

// Alpine.js is the "A" of the PETAL stack. It owns small, purely client-side
// interactions (menus, disclosure, copy-to-clipboard) so they never require a
// server round trip. LiveView owns everything with server state.
window.Alpine = Alpine
Alpine.start()

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...PetalHooks},
  dom: {
    // Preserve Alpine's component state across LiveView DOM patches, and let
    // Alpine initialize nodes LiveView adds after the initial render.
    onBeforeElUpdated(from, to) {
      if (from._x_dataStack) {
        window.Alpine.clone(from, to)
      }
      // A dialog opened with showModal() carries `open` at runtime only - the
      // server never renders it - so any patch touching the element would
      // strip the attribute and close the sheet under the user. Carry it over
      // and the modal survives its own contents re-rendering.
      if (from.tagName === "DIALOG" && from.open) {
        to.setAttribute("open", "")
      }
    },
  },
})

// Show progress bar on live navigation and form submits, drawn in the
// current theme's brass rather than topbar's stock blue. Read lazily so a
// theme switch is picked up on the next navigation.
window.addEventListener("phx:page-loading-start", _info => {
  const brass = getComputedStyle(document.documentElement).getPropertyValue("--color-primary").trim()
  topbar.config({barColors: {0: brass || "#b48b3c"}, shadowColor: "rgba(0, 0, 0, .3)"})
  topbar.show(300)
})
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Opens a native <dialog> as a modal; paired with Ui.show_dialog/2.
window.addEventListener("app:show-dialog", e => e.target.showModal())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

