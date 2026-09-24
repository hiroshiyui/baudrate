/**
 * AnnouncementNoticeHook — lets a guest dismiss a site announcement (7B).
 *
 * A member's dismissal is an event the server records, so it holds on every
 * device. A guest has no account to record it against, so the ids they
 * dismissed are kept in this browser's localStorage and the notice is hidden
 * here. Storage can be unavailable (a private window, blocked site data):
 * every read and write is guarded, and then the notice simply stays.
 *
 * LiveView patches remove attributes the server did not render, `hidden`
 * among them, so the hide is applied again after every update.
 */
const STORAGE_KEY = "baudrate:dismissed-announcements"

function readDismissed() {
  try {
    const parsed = JSON.parse(window.localStorage.getItem(STORAGE_KEY) || "[]")
    return Array.isArray(parsed) ? parsed.map(String) : []
  } catch (_) {
    return []
  }
}

function writeDismissed(ids) {
  try {
    // Only the most recent ids: an old announcement is over anyway.
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(ids.slice(-50)))
  } catch (_) {
    // Nothing to do: the notice stays hidden for this page view only.
  }
}

const AnnouncementNoticeHook = {
  mounted() {
    this.applyHidden()

    if (this.el.dataset.guest !== "true") return

    this.button = this.el.querySelector("[data-announcement-dismiss]")
    if (!this.button) return

    this.handler = (e) => {
      e.preventDefault()
      const id = this.el.dataset.announcementId
      const ids = readDismissed()
      if (!ids.includes(id)) ids.push(id)
      writeDismissed(ids)
      this.dismissedHere = true
      this.applyHidden()

      const main = document.getElementById("main-content")
      if (main) main.focus()
    }

    this.button.addEventListener("click", this.handler)
  },

  updated() {
    this.applyHidden()
  },

  destroyed() {
    if (this.button && this.handler) this.button.removeEventListener("click", this.handler)
  },

  applyHidden() {
    if (this.el.dataset.guest !== "true") return
    if (this.dismissedHere || readDismissed().includes(this.el.dataset.announcementId)) {
      this.el.hidden = true
    }
  }
}

export default AnnouncementNoticeHook
