const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'

const FocusTrapHook = {
  mounted() {
    // For <dialog> elements, activation depends on the open attribute
    if (this.el.tagName === "DIALOG") {
      if (this.el.hasAttribute("open")) {
        this._activate()
      }
    } else {
      this._activate()
    }
  },

  updated() {
    // For <dialog>: detect open attribute changes
    if (this.el.tagName === "DIALOG") {
      if (this.el.hasAttribute("open") && !this._active) {
        this._activate()
      } else if (!this.el.hasAttribute("open") && this._active) {
        this._deactivate()
      }
    }
  },

  destroyed() {
    this._deactivate()
  },

  _activate() {
    this._active = true
    this._previousFocus = document.activeElement

    this._handleKeydown = (e) => {
      if (e.key !== "Tab") return
      const focusable = [...this.el.querySelectorAll(FOCUSABLE)]
      if (focusable.length === 0) return
      const first = focusable[0]
      const last = focusable[focusable.length - 1]
      if (e.shiftKey) {
        if (document.activeElement === first) {
          e.preventDefault()
          last.focus()
        }
      } else {
        if (document.activeElement === last) {
          e.preventDefault()
          first.focus()
        }
      }
    }
    this.el.addEventListener("keydown", this._handleKeydown)

    // Auto-focus first focusable element inside modal
    requestAnimationFrame(() => {
      const first = this.el.querySelector(FOCUSABLE)
      if (first) first.focus()
    })
  },

  _deactivate() {
    if (!this._active) return
    this._active = false
    if (this._handleKeydown) {
      this.el.removeEventListener("keydown", this._handleKeydown)
    }
    // Restore focus to trigger element
    if (this._previousFocus && this._previousFocus.isConnected) {
      this._previousFocus.focus()
    }
  },
}

export default FocusTrapHook
