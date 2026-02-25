/**
 * CopyToClipboardHook — LiveView JS hook for one-click clipboard copy.
 *
 * Reads the text to copy from `data-copy-text` on the hook element.
 * On click, copies the text and briefly swaps the element's `title` and
 * `aria-label` attributes to the value of `data-copied-label` as visual
 * and screen reader feedback.
 */
const CopyToClipboardHook = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      e.preventDefault()
      const text = this.el.dataset.copyText
      if (!text) return

      navigator.clipboard.writeText(text).then(() => {
        const copiedLabel = this.el.dataset.copiedLabel
        if (!copiedLabel) return

        const originalTitle = this.el.getAttribute("title")
        const originalAriaLabel = this.el.getAttribute("aria-label")
        this.el.setAttribute("title", copiedLabel)
        this.el.setAttribute("aria-label", copiedLabel)
        this.el.classList.add("btn-success")

        setTimeout(() => {
          this.el.setAttribute("title", originalTitle || "")
          this.el.setAttribute("aria-label", originalAriaLabel || "")
          this.el.classList.remove("btn-success")
        }, 2000)
      })
    })
  },
}

export default CopyToClipboardHook
