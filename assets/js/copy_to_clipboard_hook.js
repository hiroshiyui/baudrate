/**
 * CopyToClipboardHook — LiveView JS hook for one-click clipboard copy.
 *
 * Reads the text to copy from `data-copy-text` on the hook element.
 * On click, copies the text, announces `data-copied-label` through a shared
 * polite live region (`#copy-announcer`, created once on first use), and
 * briefly swaps the element's `title` and `aria-label` to that label as
 * visual feedback. The original attributes are restored afterwards — an
 * attribute that was absent is removed again rather than left empty (an empty
 * `aria-label` would wipe the button's accessible name).
 */
const ANNOUNCER_ID = "copy-announcer"
const FEEDBACK_MS = 2000

function announcer() {
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

function announce(text) {
  const node = announcer()
  // Clear first so repeating the same message is announced again.
  node.textContent = ""
  setTimeout(() => { node.textContent = text }, 50)
}

function restoreAttr(el, name, value) {
  if (value === null) {
    el.removeAttribute(name)
  } else {
    el.setAttribute(name, value)
  }
}

const CopyToClipboardHook = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      e.preventDefault()
      const text = this.el.dataset.copyText
      if (!text) return

      navigator.clipboard.writeText(text).then(() => {
        const copiedLabel = this.el.dataset.copiedLabel
        if (!copiedLabel) return

        announce(copiedLabel)

        if (this._restoreTimer) {
          // A second click within the feedback window: keep the originals
          // captured by the first click.
          clearTimeout(this._restoreTimer)
        } else {
          this._originalTitle = this.el.getAttribute("title")
          this._originalAriaLabel = this.el.getAttribute("aria-label")
        }

        this.el.setAttribute("title", copiedLabel)
        this.el.setAttribute("aria-label", copiedLabel)
        this.el.classList.add("btn-success")

        this._restoreTimer = setTimeout(() => {
          restoreAttr(this.el, "title", this._originalTitle)
          restoreAttr(this.el, "aria-label", this._originalAriaLabel)
          this.el.classList.remove("btn-success")
          this._restoreTimer = null
        }, FEEDBACK_MS)
      })
    })
  },

  destroyed() {
    if (this._restoreTimer) clearTimeout(this._restoreTimer)
  },
}

export default CopyToClipboardHook
