/**
 * Client-side emoji autocomplete for all textareas.
 *
 * Detects `:shortcode` typed in any textarea and shows a dropdown with
 * matching emoji suggestions. Entirely client-side — no server round-trip.
 *
 * - Type `:` followed by 2+ characters to trigger suggestions
 * - ArrowUp/Down to navigate, Enter/Tab to accept, Escape to dismiss
 * - Click a suggestion to insert it
 * - Selecting `:shortcode:` replaces it with the emoji character
 *
 * Accessibility: list autocompletion on the active textarea, which keeps its
 * native textbox role (role="combobox" is not allowed on <textarea>) —
 * aria-autocomplete="list", aria-controls
 * (#emoji-autocomplete-list) and aria-activedescendant pointing at the
 * highlighted option (`emoji-autocomplete-list-opt-${i}`, role="option",
 * aria-selected). The result count is announced via the shared polite live
 * region, using the translated `%{count}` template from the nearest
 * `data-i18n-suggestions` attribute (on the textarea or an ancestor);
 * nothing is announced when no such attribute exists.
 */
import EMOJI_MAP from "./emoji_data"
import { announceSuggestionCount } from "./autocomplete_announcer"

// Pre-build a sorted array of [shortcode, emoji] for search
const EMOJI_ENTRIES = Object.entries(EMOJI_MAP).sort((a, b) => a[0].localeCompare(b[0]))

const MAX_RESULTS = 8
const MIN_PREFIX_LENGTH = 2

let activeTextarea = null
let dropdown = null
let suggestions = []
let selectedIndex = -1

function detectEmojiPrefix(textarea) {
  const text = textarea.value
  const cursor = textarea.selectionStart
  const before = text.substring(0, cursor)

  // Match `:word_chars` at the end, not preceded by another `:`
  const match = before.match(/(?:^|[^:]):([a-zA-Z0-9_+-]+)$/)
  if (match && match[1].length >= MIN_PREFIX_LENGTH) {
    return { prefix: match[1].toLowerCase(), start: cursor - match[1].length - 1 }
  }
  return { prefix: null, start: null }
}

function searchEmoji(prefix) {
  const results = []
  for (const [shortcode, emoji] of EMOJI_ENTRIES) {
    if (shortcode.includes(prefix)) {
      results.push({ shortcode, emoji })
      if (results.length >= MAX_RESULTS) break
    }
  }
  return results
}

function acceptSuggestion(textarea, suggestion) {
  const { start } = detectEmojiPrefix(textarea)
  if (start === null) return

  const text = textarea.value
  const cursor = textarea.selectionStart
  const before = text.substring(0, start)
  const after = text.substring(cursor)

  textarea.value = before + suggestion.emoji + after
  const newPos = before.length + suggestion.emoji.length
  textarea.setSelectionRange(newPos, newPos)

  // Trigger input event so LiveView picks up the change
  textarea.dispatchEvent(new Event("input", { bubbles: true }))
  hideDropdown()
}

function positionDropdown(textarea) {
  if (!dropdown) return
  const rect = textarea.getBoundingClientRect()
  // Place below the textarea, aligned to the left edge
  dropdown.style.top = (rect.bottom + window.scrollY + 4) + "px"
  dropdown.style.left = rect.left + "px"
  dropdown.style.width = Math.min(rect.width, 288) + "px"
}

function showDropdown(textarea) {
  if (!dropdown) {
    dropdown = document.createElement("ul")
    // Use fixed positioning on document.body so LiveView DOM patching can't remove it
    dropdown.className = "autocomplete-listbox emoji-autocomplete-listbox menu bg-base-200 rounded-box shadow-lg z-50 max-h-52 overflow-y-auto"
    dropdown.style.position = "absolute"
    dropdown.setAttribute("role", "listbox")
    dropdown.id = "emoji-autocomplete-list"
    document.body.appendChild(dropdown)
  }
  textarea.setAttribute("aria-autocomplete", "list")
  textarea.setAttribute("aria-controls", dropdown.id)

  positionDropdown(textarea)
  renderDropdown(textarea)

  const i18nHost = textarea.closest("[data-i18n-suggestions]")
  announceSuggestionCount(i18nHost && i18nHost.dataset.i18nSuggestions, suggestions.length)
}

function renderDropdown(textarea) {
  if (!dropdown) return

  dropdown.innerHTML = ""
  const listId = dropdown.id
  suggestions.forEach((item, i) => {
    const li = document.createElement("li")
    li.id = `${listId}-opt-${i}`
    li.className = "autocomplete-option emoji-autocomplete-option"
    li.setAttribute("role", "option")
    li.setAttribute("aria-selected", i === selectedIndex ? "true" : "false")

    const a = document.createElement("a")
    a.className = i === selectedIndex ? "active" : ""

    const emojiSpan = document.createElement("span")
    emojiSpan.textContent = item.emoji
    emojiSpan.className = "emoji-autocomplete-char text-lg"
    // The shortcode alongside is the option's name; the glyph would be read
    // as its (English, platform-dependent) emoji name first.
    emojiSpan.setAttribute("aria-hidden", "true")

    const codeSpan = document.createElement("span")
    codeSpan.textContent = ":" + item.shortcode + ":"
    codeSpan.className = "emoji-autocomplete-shortcode text-sm opacity-70"

    a.appendChild(emojiSpan)
    a.appendChild(codeSpan)
    a.addEventListener("mousedown", (e) => {
      e.preventDefault()
      acceptSuggestion(textarea, item)
    })

    li.appendChild(a)
    dropdown.appendChild(li)
  })

  if (selectedIndex >= 0) {
    const active = document.getElementById(`${listId}-opt-${selectedIndex}`)
    textarea.setAttribute("aria-activedescendant", active.id)
    active.scrollIntoView({ block: "nearest" })
  } else {
    textarea.removeAttribute("aria-activedescendant")
  }
}

function hideDropdown() {
  if (dropdown) {
    dropdown.remove()
    dropdown = null
    if (activeTextarea) {
      // Only undo what this widget set — the hashtag/mention hook may own
      // aria-controls on the same textarea.
      if (activeTextarea.getAttribute("aria-controls") === "emoji-autocomplete-list") {
        activeTextarea.removeAttribute("aria-controls")
      }
      const desc = activeTextarea.getAttribute("aria-activedescendant")
      if (desc && desc.startsWith("emoji-autocomplete-list-opt-")) {
        activeTextarea.removeAttribute("aria-activedescendant")
      }
    }
  }
  suggestions = []
  selectedIndex = -1
  activeTextarea = null
}

// Event delegation on document — works for all textareas including
// those added dynamically by LiveView
document.addEventListener("input", (e) => {
  if (e.target.tagName !== "TEXTAREA") return

  const textarea = e.target
  const { prefix } = detectEmojiPrefix(textarea)

  if (prefix) {
    const results = searchEmoji(prefix)
    if (results.length > 0) {
      activeTextarea = textarea
      suggestions = results
      selectedIndex = -1
      showDropdown(textarea)
    } else {
      hideDropdown()
    }
  } else {
    hideDropdown()
  }
})

document.addEventListener("keydown", (e) => {
  if (!dropdown || !activeTextarea) return
  if (e.target !== activeTextarea) return

  if (e.key === "ArrowDown") {
    e.preventDefault()
    selectedIndex = Math.min(selectedIndex + 1, suggestions.length - 1)
    renderDropdown(activeTextarea)
  } else if (e.key === "ArrowUp") {
    e.preventDefault()
    selectedIndex = Math.max(selectedIndex - 1, 0)
    renderDropdown(activeTextarea)
  } else if ((e.key === "Enter" || e.key === "Tab") && selectedIndex >= 0) {
    e.preventDefault()
    acceptSuggestion(activeTextarea, suggestions[selectedIndex])
  } else if (e.key === "Escape") {
    e.preventDefault()
    hideDropdown()
  }
})

document.addEventListener("focusout", (e) => {
  if (e.target === activeTextarea) {
    // Delay to allow click on dropdown items
    setTimeout(() => hideDropdown(), 150)
  }
})
