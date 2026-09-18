// Click-to-load for the YouTube link preview (ADR 0006, ADR 0045).
//
// The server renders a poster frame from the thumbnail it already fetched and
// stored locally, plus a play button. Nothing reaches Google until the reader
// asks for it: this hook builds the iframe on that click and not before, so a
// reader who scrolls past a video discloses nothing to a third party.
//
// The label on the button says where the player comes from, so the click is an
// informed one. That text is rendered by the server through gettext and read
// from data attributes here — a string built in JavaScript would be English
// for every locale.
export default {
  mounted() {
    this.el.addEventListener("click", (event) => {
      if (event.target.closest("button")) this.load()
    })
  },

  load() {
    const videoId = this.el.dataset.videoId
    // Already swapped: a second click must not rebuild the player and restart
    // whatever is playing.
    if (!videoId || this.el.querySelector("iframe")) return

    const iframe = document.createElement("iframe")

    // `autoplay=1` is what makes one click enough — the click is the user
    // gesture browsers require, and without it the reader has to press play
    // twice.
    iframe.src =
      `https://www.youtube-nocookie.com/embed/${encodeURIComponent(videoId)}?autoplay=1`
    iframe.title = this.el.dataset.frameTitle || ""
    iframe.className = "link-preview-video-frame w-full h-full"
    iframe.setAttribute("frameborder", "0")
    iframe.setAttribute(
      "allow",
      "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
    )
    iframe.setAttribute("allowfullscreen", "")
    // Send the origin only, never the article URL the reader is on.
    iframe.setAttribute("referrerpolicy", "strict-origin")

    this.el.replaceChildren(iframe)

    // The control that had focus has just been removed, so move focus into the
    // player rather than letting it fall to <body>.
    iframe.setAttribute("tabindex", "-1")
    iframe.focus()
  }
}
