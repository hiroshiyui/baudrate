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
import CopyToClipboardHook from "./copy_to_clipboard_hook"
import HashtagAutocompleteHook from "./hashtag_autocomplete_hook"
import PushManagerHook from "./push_manager_hook"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, AvatarCropHook, MarkdownToolbarHook, ScrollBottomHook, CopyToClipboardHook, HashtagAutocompleteHook, PushManagerHook},
})

// Theme switcher: resolve user preference (light/dark/system) to admin-configured DaisyUI theme
const getThemeConfig = () => ({
  light: document.documentElement.dataset.themeLight || "light",
  dark: document.documentElement.dataset.themeDark || "dark",
})

const applyTheme = (pref) => {
  const config = getThemeConfig()
  let theme
  if (pref === "light") {
    theme = config.light
  } else if (pref === "dark") {
    theme = config.dark
  } else {
    // "system" — detect OS preference
    theme = window.matchMedia("(prefers-color-scheme: dark)").matches
      ? config.dark
      : config.light
  }
  document.documentElement.setAttribute("data-theme", theme)
}

const setTheme = (pref) => {
  if (pref === "system") {
    localStorage.removeItem("phx:theme")
  } else {
    localStorage.setItem("phx:theme", pref)
  }
  applyTheme(pref)
}

// Apply on load
applyTheme(localStorage.getItem("phx:theme") || "system")

// Listen for user toggle
window.addEventListener("phx:set-theme", (e) => setTheme(e.target.dataset.phxTheme))
window.addEventListener("storage", (e) => {
  if (e.key === "phx:theme") applyTheme(e.newValue || "system")
})

// Listen for OS preference changes (when in "system" mode)
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  if (!localStorage.getItem("phx:theme")) applyTheme("system")
})

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

// Sync aria-expanded with DaisyUI dropdown open/close state.
// DaisyUI toggles via focus (keyboard) AND :active/:focus-within (click),
// so we handle both focusin/focusout and click events.
document.addEventListener("focusin", (e) => {
  const dropdown = e.target.closest(".dropdown")
  if (dropdown) {
    const trigger = dropdown.querySelector("[aria-haspopup]")
    if (trigger) trigger.setAttribute("aria-expanded", "true")
  }
})
document.addEventListener("focusout", (e) => {
  const dropdown = e.target.closest(".dropdown")
  if (dropdown) {
    setTimeout(() => {
      if (!dropdown.contains(document.activeElement)) {
        const trigger = dropdown.querySelector("[aria-haspopup]")
        if (trigger) trigger.setAttribute("aria-expanded", "false")
      }
    }, 0)
  }
})
document.addEventListener("click", (e) => {
  const trigger = e.target.closest(".dropdown [aria-haspopup]")
  if (trigger) {
    const expanded = trigger.getAttribute("aria-expanded") === "true"
    trigger.setAttribute("aria-expanded", expanded ? "false" : "true")
  } else {
    // Click outside any dropdown — close all
    document.querySelectorAll(".dropdown [aria-haspopup][aria-expanded='true']").forEach((el) => {
      el.setAttribute("aria-expanded", "false")
    })
  }
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

