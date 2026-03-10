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
    this._fadeTimer = null
    this._fieldNames = (this.el.dataset.draftFields || "").split(",").filter(Boolean)

    this._onInput = () => this._scheduleSave()
    this._onSubmit = () => this._clearDraft()

    this.el.addEventListener("input", this._onInput)
    this.el.addEventListener("submit", this._onSubmit)

    this._restoreDraft()
  },

  destroyed() {
    if (this._debounceTimer) clearTimeout(this._debounceTimer)
    if (this._fadeTimer) clearTimeout(this._fadeTimer)
    this.el.removeEventListener("input", this._onInput)
    this.el.removeEventListener("submit", this._onSubmit)
  },

  _draftKey() {
    return this.el.dataset.draftKey
  },

  _scheduleSave() {
    if (this._debounceTimer) clearTimeout(this._debounceTimer)
    this._showLoading()
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
        this._showIndicator()
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

  _showLoading() {
    const selector = this.el.dataset.draftIndicator
    if (!selector) return

    const indicator = document.querySelector(selector)
    if (!indicator) return

    if (this._fadeTimer) clearTimeout(this._fadeTimer)
    indicator.innerHTML = '<span class="loading loading-dots loading-xs"></span>'
    indicator.classList.remove("opacity-0")
    indicator.classList.add("opacity-100")
  },

  _showIndicator() {
    const selector = this.el.dataset.draftIndicator
    if (!selector) return

    const indicator = document.querySelector(selector)
    if (!indicator) return

    if (this._fadeTimer) clearTimeout(this._fadeTimer)
    indicator.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" class="size-5"><path stroke-linecap="round" stroke-linejoin="round" d="M12 16.5V9.75m0 0 3 3m-3-3-3 3M6.75 19.5a4.5 4.5 0 0 1-1.41-8.775 5.25 5.25 0 0 1 10.233-2.33 3 3 0 0 1 3.758 3.848A3.752 3.752 0 0 1 18 19.5H6.75Z"/></svg>'
    indicator.classList.remove("opacity-0")
    indicator.classList.add("opacity-100")

    this._fadeTimer = setTimeout(() => {
      indicator.classList.remove("opacity-100")
      indicator.classList.add("opacity-0")
    }, INDICATOR_FADE_MS)
  },
}

export default DraftSaveHook
