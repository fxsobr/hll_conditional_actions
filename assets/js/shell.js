// The shell's client side: the command palette's keyboard and its opening.
//
// The palette is a native <dialog> rendered by the CommandPalette live
// component; the server answers the queries, and this hook owns everything
// that must feel instant - Ctrl K from anywhere, focus, the arrow keys, Enter
// and Tab - so none of it waits for a round trip.

export const CommandPalette = {
  mounted() {
    this.active = 0
    this.input = () => this.el.querySelector("#command-palette-input")

    this.onKey = (e) => {
      const k = e.key && e.key.toLowerCase()
      if ((e.ctrlKey || e.metaKey) && k === "k") {
        e.preventDefault()
        this.el.open ? this.el.close() : this.open()
      }
    }
    window.addEventListener("keydown", this.onKey)

    // Anything marked data-open-palette opens it: the header's search field.
    this.onClick = (e) => {
      if (e.target.closest("[data-open-palette]")) {
        e.preventDefault()
        this.open()
      }
    }
    document.addEventListener("click", this.onClick)

    // A click on the backdrop (the dialog itself) closes; picking a result
    // closes too, before the page under it changes.
    this.el.addEventListener("mousedown", (e) => {
      if (e.target === this.el) this.el.close()
    })
    this.el.addEventListener("click", (e) => {
      if (e.target.closest("a[data-option]")) this.el.close()
    })

    this.el.addEventListener("keydown", (e) => this.navigate(e))
    this.el.addEventListener("mousemove", (e) => {
      const option = e.target.closest("[data-option]")
      if (option) this.select(this.options().indexOf(option), false)
    })
  },

  updated() {
    const signature = this.el.dataset.results
    if (signature !== this.signature) {
      this.signature = signature
      this.select(0, false)
    } else {
      this.select(this.active, false)
    }
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKey)
    document.removeEventListener("click", this.onClick)
  },

  open() {
    if (!this.el.open) {
      this.el.showModal()
      this.pushEventTo(this.el, "opened", {})
    }
    const input = this.input()
    if (input) {
      input.value = ""
      input.focus()
    }
    this.select(0, false)
  },

  options() {
    return [...this.el.querySelectorAll("[data-option]")]
  },

  select(index, scroll = true) {
    const options = this.options()
    if (options.length === 0) {
      this.active = 0
      return
    }
    this.active = Math.max(0, Math.min(index, options.length - 1))
    options.forEach((option, i) => option.setAttribute("aria-selected", i === this.active ? "true" : "false"))
    if (scroll) options[this.active].scrollIntoView({block: "nearest"})
  },

  navigate(e) {
    const options = this.options()
    if (e.key === "ArrowDown") {
      e.preventDefault()
      this.select(this.active + 1)
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      this.select(this.active - 1)
    } else if (e.key === "Enter") {
      const option = options[this.active]
      if (option) {
        e.preventDefault()
        option.click()
      }
    } else if (e.key === "Tab" && options.length > 0) {
      // Tab jumps to the result's actions, then from group to group.
      e.preventDefault()
      const current = options[this.active]
      const actions = options.findIndex((o) => o.dataset.action)
      if (actions > this.active) return this.select(actions)
      const next = options.findIndex((o, i) => i > this.active && this.groupOf(o) !== this.groupOf(current))
      this.select(next === -1 ? 0 : next)
    }
  },

  // The heading an option sits under.
  groupOf(option) {
    let node = option.previousElementSibling
    while (node && !node.dataset.group) node = node.previousElementSibling
    return node ? node.dataset.group : null
  },
}

// Closes a native <dialog>; paired with the tab bar's "Mais" inside the sheet.
window.addEventListener("app:close-dialog", (e) => e.target.close())
