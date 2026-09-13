/**
 * Shared polite live region for autocomplete result counts.
 *
 * Used by the hashtag/mention hook and the emoji autocomplete. The node lives
 * on <body> (outside any LiveView container) so DOM patches never remove it,
 * and it is visually hidden with `sr-only`.
 *
 * `template` is a server-translated string (gettext) containing a `%{count}`
 * placeholder, read from a `data-i18n-suggestions` attribute. When it is
 * missing, nothing is announced — the client never falls back to English.
 */
const ANNOUNCER_ID = "autocomplete-announcer"

let pending = null

function announcerNode() {
  let node = document.getElementById(ANNOUNCER_ID)
  if (!node) {
    node = document.createElement("div")
    node.id = ANNOUNCER_ID
    node.className = "autocomplete-announcer sr-only"
    node.setAttribute("role", "status")
    node.setAttribute("aria-live", "polite")
    node.setAttribute("aria-atomic", "true")
    document.body.appendChild(node)
  }
  return node
}

export function announceSuggestionCount(template, count) {
  if (!template) return
  const node = announcerNode()
  const message = template.replace(/%\{count\}/g, String(count))
  if (pending) clearTimeout(pending)
  // Clear, then set on a later tick so an identical message is re-announced.
  node.textContent = ""
  pending = setTimeout(() => {
    node.textContent = message
    pending = null
  }, 100)
}

