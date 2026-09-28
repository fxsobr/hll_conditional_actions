// Client-side pieces of the rule builder that are pure view state: the
// searchable field picker and the chip input. Both only ever edit a hidden
// input the server rendered, then fire `input` on it so the form's
// phx-change posts the new value - LiveView stays the source of truth.

// Lower case without accents, matching RuleBuilder.fold/1 on the server.
function fold(text) {
  return text.normalize("NFD").replace(/\p{Mn}/gu, "").toLowerCase()
}

function notify(input) {
  input.dispatchEvent(new Event("input", {bubbles: true}))
}

// A combobox over the condition fields: type to filter by label,
// description or group; arrows move, Enter picks, Escape closes.
// Markup contract (see RuleBuilder.field_picker/1):
//   x-ref="value"   hidden input posted with the form
//   x-ref="search"  the visible text box (no name, so it never posts)
//   [role=option]   data-value, data-label, data-search
//   [data-group]    a group of options, hidden when none of them match
export function fieldCombobox() {
  return {
    isOpen: false,
    activeId: null,

    visible() {
      return [...this.$root.querySelectorAll("[role=option]")].filter(o => !o.hidden && !o.closest("[data-group]")?.hidden)
    },

    open() {
      if (this.isOpen) return
      this.isOpen = true
      this.filter("")
      this.$nextTick(() => this.$refs.search.select())
    },

    close() {
      this.isOpen = false
      this.activeId = null
      this.$refs.search.value = this.$refs.search.dataset.label || ""
    },

    filter(query) {
      if (!this.isOpen) this.isOpen = true
      const q = fold(query.trim())
      this.$root.querySelectorAll("[role=option]").forEach(option => {
        option.hidden = q !== "" && !option.dataset.search.includes(q)
      })
      this.$root.querySelectorAll("[data-group]").forEach(group => {
        // "Most used" repeats fields listed below; while searching it only
        // doubles every hit.
        const duplicate = q !== "" && group.dataset.group === "popular"
        group.hidden = duplicate || !group.querySelector("[role=option]:not([hidden])")
      })
      const empty = this.$root.querySelector("[data-empty]")
      if (empty) empty.hidden = this.visible().length > 0
      const current = this.visible().find(o => o.dataset.value === this.$refs.value.value)
      this.activate(q === "" && current ? current : this.visible()[0])
    },

    activate(option) {
      this.activeId = option ? option.id : null
      this.$root.querySelectorAll("[role=option]").forEach(o => {
        o.setAttribute("aria-selected", o === option ? "true" : "false")
      })
      if (option) option.scrollIntoView({block: "nearest"})
    },

    move(step) {
      if (!this.isOpen) return this.open()
      const options = this.visible()
      if (options.length === 0) return
      const index = options.findIndex(o => o.id === this.activeId)
      const next = (index + step + options.length) % options.length
      this.activate(options[next])
    },

    choose() {
      const option = this.activeId && document.getElementById(this.activeId)
      if (option) this.pick(option)
    },

    pick(option) {
      const value = this.$refs.value
      this.$refs.search.dataset.label = option.dataset.label
      this.$refs.search.value = option.dataset.label
      this.isOpen = false
      this.activeId = null
      if (value.value !== option.dataset.value) {
        value.value = option.dataset.value
        notify(value)
      }
    },
  }
}

// Chips over a comma separated value: Enter or a comma adds what was typed,
// Backspace on an empty box removes the last chip, each chip has its own
// remove button. The chips themselves are rendered by the server from the
// hidden input's value.
export function chipInput() {
  return {
    values() {
      return this.$refs.value.value.split(",").map(v => v.trim()).filter(v => v !== "")
    },

    write(values) {
      this.$refs.value.value = [...new Set(values)].join(",")
      notify(this.$refs.value)
    },

    add() {
      const typed = this.$refs.entry.value.split(",").map(v => v.trim()).filter(v => v !== "")
      if (typed.length === 0) return
      this.$refs.entry.value = ""
      this.write([...this.values(), ...typed])
    },

    remove(value) {
      this.write(this.values().filter(v => v !== value))
      this.$refs.entry.focus()
    },

    backspace() {
      if (this.$refs.entry.value !== "") return
      const values = this.values()
      values.pop()
      this.write(values)
    },
  }
}

export default function registerRuleBuilder(Alpine) {
  Alpine.data("fieldCombobox", fieldCombobox)
  Alpine.data("chipInput", chipInput)
  Alpine.magic("fold", () => fold)
}
