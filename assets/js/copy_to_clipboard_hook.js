/**
 * CopyToClipboardHook — LiveView JS hook for one-click clipboard copy.
 *
 * Reads the text to copy from `data-copy-text` on the hook element.
 * On click, copies the text and briefly swaps the element's `title`
 * attribute to the value of `data-copied-label` as visual feedback.
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

        const original = this.el.getAttribute("title")
        this.el.setAttribute("title", copiedLabel)
        this.el.classList.add("btn-success")

        setTimeout(() => {
          this.el.setAttribute("title", original || "")
          this.el.classList.remove("btn-success")
        }, 2000)
      })
    })
  },
}

export default CopyToClipboardHook
