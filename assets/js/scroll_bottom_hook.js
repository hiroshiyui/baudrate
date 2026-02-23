/**
 * ScrollBottom LiveView hook.
 *
 * Automatically scrolls the element to the bottom on mount and
 * whenever its DOM is updated (e.g. new message appended).
 */
const ScrollBottomHook = {
  mounted() {
    this.scrollToBottom()
  },
  updated() {
    this.scrollToBottom()
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}

export default ScrollBottomHook
