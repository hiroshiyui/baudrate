/**
 * WebShareHook — invokes the browser's Web Share API to share the current
 * page through the OS-level share sheet (e.g. on mobile / PWA).
 *
 * The element is hidden on mount when `navigator.share` is unavailable, so
 * it is only visible on platforms that can actually fulfill the request.
 *
 * Optional element attributes:
 *   - `data-share-url`   — URL to share (defaults to `location.href`)
 *   - `data-share-title` — title to share (defaults to `document.title`)
 *   - `data-share-text`  — text to share (defaults to `document.title`)
 */
const WebShareHook = {
  mounted() {
    if (typeof navigator === "undefined" || typeof navigator.share !== "function") {
      this.el.hidden = true
      this.el.classList.add("hidden")
      return
    }

    this.el.hidden = false
    this.el.classList.remove("hidden")

    this.handler = async (e) => {
      e.preventDefault()
      const data = {
        title: this.el.dataset.shareTitle || document.title,
        text: this.el.dataset.shareText || document.title,
        url: this.el.dataset.shareUrl || location.href,
      }
      try {
        await navigator.share(data)
      } catch (err) {
        if (err && err.name === "AbortError") return
        console.warn("Web Share failed:", err)
      }
    }
    this.el.addEventListener("click", this.handler)
  },

  destroyed() {
    if (this.handler) this.el.removeEventListener("click", this.handler)
  },
}

export default WebShareHook
