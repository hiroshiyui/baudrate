/**
 * LiveView hook for hashtag and @mention autocomplete in textareas.
 *
 * Attached to a wrapper div around the textarea. Detects `#prefix` or
 * `@prefix` typed by the user, sends a server event, and renders a
 * dropdown with suggestions. Supports keyboard navigation
 * (ArrowUp/Down, Enter/Tab to accept, Escape to dismiss).
 */
const HashtagAutocompleteHook = {
  mounted() {
    this.textarea = this.el.querySelector("textarea")
    if (!this.textarea) return

    this.dropdown = null
    this.suggestions = []
    this.selectedIndex = -1
    this.debounceTimer = null
    this.activeType = null // "hashtag" or "mention"

    this.textarea.setAttribute("aria-autocomplete", "list")

    this.textarea.addEventListener("input", () => this.onInput())
    this.textarea.addEventListener("keydown", (e) => this.onKeydown(e))
    this.textarea.addEventListener("blur", () => {
      setTimeout(() => this.hideDropdown(), 150)
    })

    this.handleEvent("hashtag_suggestions", ({ tags }) => {
      if (this.activeType !== "hashtag") return
      this.suggestions = tags.map(tag => ({ type: "hashtag", value: tag, display: "#" + tag }))
      this.selectedIndex = -1
      if (this.suggestions.length > 0) {
        this.showDropdown()
      } else {
        this.hideDropdown()
      }
    })

    this.handleEvent("mention_suggestions", ({ users }) => {
      if (this.activeType !== "mention") return
      this.suggestions = users.map(u => ({ type: "mention", value: u.username, display: "@" + u.username }))
      this.selectedIndex = -1
      if (this.suggestions.length > 0) {
        this.showDropdown()
      } else {
        this.hideDropdown()
      }
    })
  },

  destroyed() {
    this.hideDropdown()
    if (this.debounceTimer) clearTimeout(this.debounceTimer)
  },

  onInput() {
    const mention = this.detectMention()
    if (mention.prefix && mention.prefix.length >= 1) {
      this.activeType = "mention"
      if (this.debounceTimer) clearTimeout(this.debounceTimer)
      this.debounceTimer = setTimeout(() => {
        this.pushEvent("mention_suggest", { prefix: mention.prefix })
      }, 200)
      return
    }

    const hashtag = this.detectHashtag()
    if (hashtag.prefix && hashtag.prefix.length >= 1) {
      this.activeType = "hashtag"
      if (this.debounceTimer) clearTimeout(this.debounceTimer)
      this.debounceTimer = setTimeout(() => {
        this.pushEvent("hashtag_suggest", { prefix: hashtag.prefix })
      }, 200)
      return
    }

    this.hideDropdown()
  },

  onKeydown(e) {
    if (!this.dropdown) return

    if (e.key === "ArrowDown") {
      e.preventDefault()
      this.selectedIndex = Math.min(this.selectedIndex + 1, this.suggestions.length - 1)
      this.renderDropdown()
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      this.selectedIndex = Math.max(this.selectedIndex - 1, 0)
      this.renderDropdown()
    } else if ((e.key === "Enter" || e.key === "Tab") && this.selectedIndex >= 0) {
      e.preventDefault()
      this.acceptSuggestion(this.suggestions[this.selectedIndex])
    } else if (e.key === "Escape") {
      e.preventDefault()
      this.hideDropdown()
    }
  },

  detectHashtag() {
    const text = this.textarea.value
    const cursor = this.textarea.selectionStart
    const before = text.substring(0, cursor)

    const match = before.match(/#([\p{L}\w]*)$/u)
    if (match && match[1].length >= 1) {
      return { prefix: match[1], start: cursor - match[1].length - 1 }
    }
    return { prefix: null, start: null }
  },

  detectMention() {
    const text = this.textarea.value
    const cursor = this.textarea.selectionStart
    const before = text.substring(0, cursor)

    // Match @word at the end, preceded by start-of-string or whitespace
    const match = before.match(/(?:^|\s)@([\w]*)$/)
    if (match && match[1].length >= 1) {
      return { prefix: match[1], start: cursor - match[1].length - 1 }
    }
    return { prefix: null, start: null }
  },

  acceptSuggestion(item) {
    const detect = item.type === "mention" ? this.detectMention() : this.detectHashtag()
    const { start } = detect
    if (start === null) return

    const text = this.textarea.value
    const cursor = this.textarea.selectionStart
    const before = text.substring(0, start)
    const after = text.substring(cursor)
    const prefix = item.type === "mention" ? "@" : "#"

    this.textarea.value = before + prefix + item.value + " " + after
    const newPos = before.length + item.value.length + 2
    this.textarea.setSelectionRange(newPos, newPos)

    this.textarea.dispatchEvent(new Event("input", { bubbles: true }))
    this.hideDropdown()
  },

  showDropdown() {
    if (!this.dropdown) {
      this.dropdown = document.createElement("ul")
      this.dropdown.className = "menu bg-base-200 rounded-box shadow-lg absolute z-50 w-64 max-h-48 overflow-y-auto"
      this.dropdown.setAttribute("role", "listbox")
      this.dropdown.id = this.textarea.id + "-autocomplete-list"
      this.textarea.setAttribute("aria-controls", this.dropdown.id)

      this.el.appendChild(this.dropdown)
    }
    this.textarea.setAttribute("aria-expanded", "true")
    this.renderDropdown()
  },

  renderDropdown() {
    if (!this.dropdown) return

    this.dropdown.innerHTML = ""
    this.suggestions.forEach((item, i) => {
      const li = document.createElement("li")
      li.setAttribute("role", "option")
      li.setAttribute("aria-selected", i === this.selectedIndex ? "true" : "false")

      const a = document.createElement("a")
      a.textContent = item.display
      a.className = i === this.selectedIndex ? "active" : ""
      a.addEventListener("mousedown", (e) => {
        e.preventDefault()
        this.acceptSuggestion(item)
      })

      li.appendChild(a)
      this.dropdown.appendChild(li)
    })
  },

  hideDropdown() {
    if (this.dropdown) {
      this.dropdown.remove()
      this.dropdown = null
      if (this.textarea) {
        this.textarea.removeAttribute("aria-controls")
        this.textarea.setAttribute("aria-expanded", "false")
      }
    }
    this.suggestions = []
    this.selectedIndex = -1
    this.activeType = null
  }
}

export default HashtagAutocompleteHook
