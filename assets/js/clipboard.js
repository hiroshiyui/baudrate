/**
 * Copying to the clipboard, and saying so.
 *
 * Extracted from `copy_to_clipboard_hook.js` because the share button needs
 * the same behaviour when `navigator.share` is missing, and the part worth
 * sharing is not the one-line copy — it is the feedback: announce through a
 * shared polite live region, briefly swap the control's `title` and
 * `aria-label`, then put back exactly what was there, removing an attribute
 * that was absent rather than leaving it empty (an empty `aria-label` would
 * wipe the control's accessible name).
 *
 * `copy()` never throws and never rejects. `navigator.clipboard` is undefined
 * outside a secure context, so the old `navigator.clipboard.writeText(...)`
 * threw a synchronous TypeError inside a click listener; and a denied
 * permission rejected a promise nothing caught. Both produced no feedback
 * whatsoever, which is the one outcome a copy button must not have.
 *
 * Labels are server-rendered gettext strings passed in `data-*` attributes.
 * When one is missing nothing is announced — the client never falls back to
 * English, the rule `autocomplete_announcer.js` states.
 */

const ANNOUNCER_ID = "copy-announcer"
const FEEDBACK_MS = 2000

// Element → {timer, title, ariaLabel}. A WeakMap rather than a property on
// the hook, so the share button and the copy buttons share one definition of
// "is feedback currently showing on this element".
const feedback = new WeakMap()

/** Whether this browser can copy at all (false outside a secure context). */
export function clipboardSupported() {
  return typeof navigator !== "undefined" && typeof navigator.clipboard?.writeText === "function"
}

/** Copies `text`. Resolves true on success, false on any failure. */
export async function copy(text) {
  if (!text || !clipboardSupported()) return false

  try {
    await navigator.clipboard.writeText(text)
    return true
  } catch {
    return false
  }
}

function announcerNode() {
  let node = document.getElementById(ANNOUNCER_ID)
  if (!node) {
    node = document.createElement("div")
    node.id = ANNOUNCER_ID
    node.className = "copy-announcer sr-only"
    node.setAttribute("role", "status")
    node.setAttribute("aria-live", "polite")
    node.setAttribute("aria-atomic", "true")
    document.body.appendChild(node)
  }
  return node
}

/** Announces `text` in the shared polite live region. */
export function announce(text) {
  if (!text) return
  const node = announcerNode()
  // Clear first so repeating the same message is announced again.
  node.textContent = ""
  setTimeout(() => {
    node.textContent = text
  }, 50)
}

function restoreAttr(el, name, value) {
  if (value === null) el.removeAttribute(name)
  else el.setAttribute(name, value)
}

/**
 * Announces `label` and shows it on `el` for a couple of seconds.
 *
 * A second call within the window keeps the attributes captured by the first,
 * so repeated clicks cannot bake the feedback label in as the permanent one.
 */
export function flash(el, label) {
  if (!label) return

  announce(label)

  const existing = feedback.get(el)

  if (existing) {
    clearTimeout(existing.timer)
  } else {
    feedback.set(el, {
      timer: null,
      title: el.getAttribute("title"),
      ariaLabel: el.getAttribute("aria-label"),
    })
  }

  el.setAttribute("title", label)
  el.setAttribute("aria-label", label)
  el.classList.add("btn-success")

  const state = feedback.get(el)
  state.timer = setTimeout(() => {
    restoreAttr(el, "title", state.title)
    restoreAttr(el, "aria-label", state.ariaLabel)
    el.classList.remove("btn-success")
    feedback.delete(el)
  }, FEEDBACK_MS)
}

/** Cancels any pending feedback timer for `el` (call from `destroyed()`). */
export function cancelFlash(el) {
  const state = feedback.get(el)
  if (state?.timer) clearTimeout(state.timer)
  feedback.delete(el)
}
