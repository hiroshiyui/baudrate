/**
 * WebShareHook — one button, two ways of handing the page on.
 *
 * `navigator.share` opens the OS share sheet, and exists on phones and
 * installed PWAs. On the desktop browsers most reading happens in, it does
 * not — and the button used to hide itself there and say nothing, so the site
 * had no sharing affordance at all on the machines where people write.
 *
 * So the control is revealed when *either* capability is present, and which
 * one runs is decided at click time. When only the clipboard is available the
 * button copies the link and relabels itself to say so, because a control
 * that says "share" and silently copies is worse than either.
 *
 * The server still renders it hidden and this hook reveals it: a button that
 * does nothing without JavaScript should not be visible without JavaScript.
 *
 * Element attributes (all server-rendered gettext, never defaulted in the
 * client — a missing label means the feedback is skipped, not written in
 * English):
 *   - `data-share-url`    — URL to share (defaults to `location.href`)
 *   - `data-share-title`  — title to share (defaults to `document.title`)
 *   - `data-share-text`   — text to share (defaults to `document.title`)
 *   - `data-copy-label`   — label to use when the button copies instead
 *   - `data-copied-label` — announced and shown after a successful copy
 */
import {clipboardSupported, copy, flash, cancelFlash} from "./clipboard"

const canShare = () => typeof navigator !== "undefined" && typeof navigator.share === "function"

const WebShareHook = {
  mounted() {
    this.shareable = canShare()
    this.copyable = clipboardSupported()

    if (!this.shareable && !this.copyable) {
      this.el.hidden = true
      this.el.classList.add("hidden")
      return
    }

    this.el.hidden = false
    this.el.classList.remove("hidden")

    // Say what the button will actually do. Only when it is the copy that
    // will run — the share label is already the server-rendered one.
    if (!this.shareable) {
      const copyLabel = this.el.dataset.copyLabel
      if (copyLabel) {
        this.el.setAttribute("title", copyLabel)
        this.el.setAttribute("aria-label", copyLabel)
      }
    }

    this.handler = async (e) => {
      e.preventDefault()

      const url = this.el.dataset.shareUrl || location.href

      if (this.shareable) {
        try {
          await navigator.share({
            title: this.el.dataset.shareTitle || document.title,
            text: this.el.dataset.shareText || document.title,
            url,
          })
          return
        } catch (err) {
          // Dismissing the sheet is not a failure, and must not fall through
          // to copying: the reader just said no.
          if (err && err.name === "AbortError") return
          if (!this.copyable) {
            console.warn("Web Share failed:", err)
            return
          }
          // The sheet could not open at all — copying is better than nothing.
        }
      }

      if (await copy(url)) flash(this.el, this.el.dataset.copiedLabel)
    }

    this.el.addEventListener("click", this.handler)
  },

  destroyed() {
    if (this.handler) this.el.removeEventListener("click", this.handler)
    cancelFlash(this.el)
  },
}

export default WebShareHook
