/**
 * ScrollBottom LiveView hook.
 *
 * Scrolls the element to the bottom on mount. On later DOM updates (e.g. a
 * new message appended) it only follows the bottom when the user was already
 * within `STICK_THRESHOLD_PX` of it before the update, so someone scrolled up
 * reading history (or a screen-reader user reviewing earlier messages) is not
 * yanked away. Never moves keyboard focus.
 */
const STICK_THRESHOLD_PX = 80

const ScrollBottomHook = {
  mounted() {
    this.wasNearBottom = true
    this.scrollToBottom()
  },
  beforeUpdate() {
    this.wasNearBottom = this.isNearBottom()
  },
  updated() {
    if (this.wasNearBottom) this.scrollToBottom()
  },
  isNearBottom() {
    const el = this.el
    return el.scrollHeight - el.scrollTop - el.clientHeight <= STICK_THRESHOLD_PX
  },
  scrollToBottom() {
    // Never animate the jump: "auto" follows the container's CSS
    // scroll-behavior, which is reset to auto under reduced motion.
    this.el.scrollTo({ top: this.el.scrollHeight, behavior: "auto" })
  }
}

export default ScrollBottomHook
