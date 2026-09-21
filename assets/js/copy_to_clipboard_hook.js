/**
 * CopyToClipboardHook — LiveView JS hook for one-click clipboard copy.
 *
 * Reads the text to copy from `data-copy-text` on the hook element and, on
 * success, announces `data-copied-label` and shows it briefly on the control.
 * The copying and the feedback both live in `./clipboard`, which the share
 * button uses too when `navigator.share` is unavailable.
 *
 * A failed copy is silent here by design: the only ways it can fail are an
 * insecure context or a denied permission, neither of which the reader can do
 * anything about from this button, and both of which leave the text visible
 * on the page to select by hand.
 */
import {copy, flash, cancelFlash} from "./clipboard"

const CopyToClipboardHook = {
  mounted() {
    this.handler = async (e) => {
      e.preventDefault()

      const text = this.el.dataset.copyText
      if (!text) return

      if (await copy(text)) flash(this.el, this.el.dataset.copiedLabel)
    }

    this.el.addEventListener("click", this.handler)
  },

  destroyed() {
    if (this.handler) this.el.removeEventListener("click", this.handler)
    cancelFlash(this.el)
  },
}

export default CopyToClipboardHook
