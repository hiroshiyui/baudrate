/**
 * DraftSaveHook — auto-saves form field values to localStorage.
 *
 * Data attributes on the hooked form element:
 *   data-draft-key       — localStorage key
 *   data-draft-fields    — comma-separated field `name` attributes to save
 *   data-draft-indicator — CSS selector for the indicator <span>
 *   data-draft-saved-text    — translated "Draft saved" text
 *   data-draft-restored-text — translated "Draft restored" text
 *
 * Behavior:
 *   - Save: debounced 1.5s on input; stores JSON with `_ts` timestamp
 *   - Restore: on mounted(), populates fields if draft < 30 days old
 *   - Clear: on form submit, removes draft from localStorage
 *   - Empty drafts (all fields blank) are removed instead of saved
 */
const DEBOUNCE_MS = 1500
const MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000 // 30 days
const INDICATOR_FADE_MS = 2000

const DraftSaveHook = {
  mounted() {
    this._debounceTimer = null
    this._fieldNames = (this.el.dataset.draftFields || "").split(",").filter(Boolean)

    this._onInput = () => this._scheduleSave()
    this._onSubmit = () => this._clearDraft()

    this.el.addEventListener("input", this._onInput)
    this.el.addEventListener("submit", this._onSubmit)

    this._restoreDraft()
  },

  destroyed() {
    if (this._debounceTimer) clearTimeout(this._debounceTimer)
    this.el.removeEventListener("input", this._onInput)
    this.el.removeEventListener("submit", this._onSubmit)
  },

  _draftKey() {
    return this.el.dataset.draftKey
  },

  _scheduleSave() {
    if (this._debounceTimer) clearTimeout(this._debounceTimer)
    this._debounceTimer = setTimeout(() => this._saveDraft(), DEBOUNCE_MS)
  },

  _saveDraft() {
    const key = this._draftKey()
    if (!key) return

    const data = {}
    let hasContent = false

    for (const name of this._fieldNames) {
      const el = this.el.querySelector(`[name="${name}"]`)
      if (el) {
        data[name] = el.value
        if (el.value.trim() !== "") hasContent = true
      }
    }

    try {
      if (hasContent) {
        data._ts = Date.now()
        localStorage.setItem(key, JSON.stringify(data))
        this._showIndicator(this.el.dataset.draftSavedText || "Draft saved")
      } else {
        localStorage.removeItem(key)
      }
    } catch (_e) {
      // quota exceeded or private browsing — silently ignore
    }
  },

  _restoreDraft() {
    const key = this._draftKey()
    if (!key) return

    let data
    try {
      const raw = localStorage.getItem(key)
      if (!raw) return
      data = JSON.parse(raw)
    } catch (_e) {
      return
    }

    // Check expiry
    if (!data._ts || Date.now() - data._ts > MAX_AGE_MS) {
      try { localStorage.removeItem(key) } catch (_e) { /* ignore */ }
      return
    }

    let restored = false

    for (const name of this._fieldNames) {
      if (data[name] != null && data[name] !== "") {
        const el = this.el.querySelector(`[name="${name}"]`)
        if (el && el.value.trim() === "") {
          el.value = data[name]
          el.dispatchEvent(new Event("input", { bubbles: true }))
          restored = true
        }
      }
    }

    if (restored) {
      this._showIndicator(this.el.dataset.draftRestoredText || "Draft restored")
    }
  },

  _clearDraft() {
    if (this._debounceTimer) clearTimeout(this._debounceTimer)
    const key = this._draftKey()
    if (!key) return

    try {
      localStorage.removeItem(key)
    } catch (_e) {
      // ignore
    }
  },

  _showIndicator(text) {
    const selector = this.el.dataset.draftIndicator
    if (!selector) return

    const indicator = document.querySelector(selector)
    if (!indicator) return

    indicator.textContent = text
    indicator.classList.remove("opacity-0")
    indicator.classList.add("opacity-100")

    setTimeout(() => {
      indicator.classList.remove("opacity-100")
      indicator.classList.add("opacity-0")
    }, INDICATOR_FADE_MS)
  },
}

export default DraftSaveHook
