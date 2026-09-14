/**
 * ScrollBottom LiveView hook.
 *
 * Scrolls the element to the bottom on mount. On later DOM updates (e.g. a
 * new message appended) it only follows the bottom when the user was already
 * within `STICK_THRESHOLD_PX` of it before the update, so someone scrolled up
 * reading history (or a screen-reader user reviewing earlier messages) is not
 * yanked away. When older messages are prepended (the first message changes)
 * it keeps the messages the reader was looking at in place. Never moves
 * keyboard focus.
 */
const STICK_THRESHOLD_PX = 80

const ScrollBottomHook = {
  mounted() {
    this.wasNearBottom = true
    this.scrollToBottom()
  },
  beforeUpdate() {
    this.wasNearBottom = this.isNearBottom()
    this.prevScrollHeight = this.el.scrollHeight
    this.prevScrollTop = this.el.scrollTop
    this.prevFirstId = this.firstMessageId()
  },
  updated() {
    if (this.wasNearBottom) {
      this.scrollToBottom()
    } else if (this.firstMessageId() !== this.prevFirstId) {
      this.el.scrollTop = this.prevScrollTop + (this.el.scrollHeight - this.prevScrollHeight)
    }
  },
  firstMessageId() {
    const first = this.el.querySelector(".message")
    return first ? first.id : null
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
