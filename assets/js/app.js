// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/baudrate"
import topbar from "../vendor/topbar"
import AvatarCropHook from "./avatar_crop_hook"
import MarkdownToolbarHook from "./markdown_toolbar_hook"
import ScrollBottomHook from "./scroll_bottom_hook"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, AvatarCropHook, MarkdownToolbarHook, ScrollBottomHook},
})

// Theme switcher: apply saved theme and listen for toggle events
const setTheme = (theme) => {
  if (theme === "system") {
    localStorage.removeItem("phx:theme")
    document.documentElement.removeAttribute("data-theme")
  } else {
    localStorage.setItem("phx:theme", theme)
    document.documentElement.setAttribute("data-theme", theme)
  }
}
setTheme(localStorage.getItem("phx:theme") || "system")
window.addEventListener("phx:set-theme", (e) => setTheme(e.target.dataset.phxTheme))
window.addEventListener("storage", (e) => e.key === "phx:theme" && setTheme(e.newValue || "system"))

// Font size zoom: store zoom percentage in localStorage, apply to <html>
const FONT_SIZE_MIN = 75
const FONT_SIZE_MAX = 150
const FONT_SIZE_STEP = 25
const FONT_SIZE_KEY = "phx:font-size"

const setFontSize = (size) => {
  size = Math.max(FONT_SIZE_MIN, Math.min(FONT_SIZE_MAX, Number(size) || 100))
  localStorage.setItem(FONT_SIZE_KEY, String(size))
  document.documentElement.style.fontSize = size + "%"
}
setFontSize(localStorage.getItem(FONT_SIZE_KEY) || 100)
window.addEventListener("phx:font-size-increase", () => {
  setFontSize((Number(localStorage.getItem(FONT_SIZE_KEY)) || 100) + FONT_SIZE_STEP)
})
window.addEventListener("phx:font-size-decrease", () => {
  setFontSize((Number(localStorage.getItem(FONT_SIZE_KEY)) || 100) - FONT_SIZE_STEP)
})
window.addEventListener("storage", (e) => {
  if (e.key === FONT_SIZE_KEY) setFontSize(e.newValue || 100)
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

