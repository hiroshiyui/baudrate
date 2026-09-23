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
import DeviceTimeZoneHook from "./device_time_zone_hook"
import HashtagAutocompleteHook from "./hashtag_autocomplete_hook"
import PushManagerHook from "./push_manager_hook"
import DraftSaveHook from "./draft_save_hook"
import ChallengeHook from "./challenge_hook"
import FocusTrapHook from "./focus_trap_hook"
import {WebAuthnRegister, WebAuthnAuthenticate} from "./hooks/webauthn"
import WebShareHook from "./web_share_hook"
import YouTubeEmbedHook from "./youtube_embed_hook"
import "./emoji_autocomplete"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Client-owned ARIA state that LiveView's DOM patching would otherwise reset to
// the server-rendered value (or strip) on every patch of the element: the theme
// toggle's aria-pressed, an open dropdown's aria-expanded / Escape-dismissed
// state, the autocomplete wiring on a textarea, and the Markdown
// preview live region. Copied from the live node onto the incoming one.
const CLIENT_OWNED_ATTRS = [
  ["[data-phx-theme]", ["aria-pressed"]],
  [".dropdown [aria-haspopup]", ["aria-expanded"]],
  ["textarea[aria-autocomplete]", ["aria-autocomplete", "aria-controls", "aria-activedescendant"]],
  ["[id$='-md-preview']", ["aria-live", "aria-busy"]],
]
const preserveClientAria = (fromEl, toEl) => {
  if (fromEl.nodeType !== Node.ELEMENT_NODE) return
  for (const [selector, attrs] of CLIENT_OWNED_ATTRS) {
    if (!fromEl.matches(selector)) continue
    for (const attr of attrs) {
      if (fromEl.hasAttribute(attr)) toEl.setAttribute(attr, fromEl.getAttribute(attr))
    }
  }
  if (fromEl.classList.contains("dropdown") && fromEl.classList.contains("dropdown-close")) {
    toEl.classList.add("dropdown-close")
  }
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  dom: {onBeforeElUpdated: preserveClientAria},
  hooks: {...colocatedHooks, AvatarCropHook, MarkdownToolbarHook, ScrollBottomHook, CopyToClipboardHook, DeviceTimeZoneHook, HashtagAutocompleteHook, PushManagerHook, DraftSaveHook, ChallengeHook, FocusTrapHook, WebAuthnRegister, WebAuthnAuthenticate, WebShareHook, YouTubeEmbedHook},
})

const prefersReducedMotion = () =>
  window.matchMedia("(prefers-reduced-motion: reduce)").matches

// Theme switcher: resolve user preference (light/dark/system) to admin-configured DaisyUI theme
const getThemeConfig = () => ({
  light: document.documentElement.dataset.themeLight || "light",
  dark: document.documentElement.dataset.themeDark || "dark",
})

const normalizeThemePref = (pref) => (pref === "light" || pref === "dark" ? pref : "system")

// Reflect the active preference on the theme toggle buttons (aria-pressed), so
// screen readers announce which of System / Light / Dark is selected.
const syncThemeToggle = (pref) => {
  document.querySelectorAll("[data-phx-theme]").forEach((btn) => {
    btn.setAttribute("aria-pressed", btn.dataset.phxTheme === pref ? "true" : "false")
  })
}

const applyTheme = (rawPref) => {
  const pref = normalizeThemePref(rawPref)
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
  // Expose the *preference* (not the resolved theme) so the toggle indicator
  // can position itself via [data-theme-pref=...] regardless of which daisyUI
  // theme the admin mapped to light/dark.
  document.documentElement.dataset.themePref = pref
  syncThemeToggle(pref)
}

const setTheme = (rawPref) => {
  const pref = normalizeThemePref(rawPref)
  if (pref === "system") {
    localStorage.removeItem("phx:theme")
  } else {
    localStorage.setItem("phx:theme", pref)
  }
  applyTheme(pref)
}

const storedThemePref = () => {
  try {
    return localStorage.getItem("phx:theme") || "system"
  } catch (_e) {
    return "system"
  }
}

// Apply on load
applyTheme(storedThemePref())
document.addEventListener("DOMContentLoaded", () => syncThemeToggle(document.documentElement.dataset.themePref || "system"))
// LiveView navigation re-renders the header (and the toggle buttons with it),
// dropping the client-set aria-pressed — re-apply after every navigation.
window.addEventListener("phx:page-loading-stop", () => syncThemeToggle(document.documentElement.dataset.themePref || "system"))

// Listen for user toggle
window.addEventListener("phx:set-theme", (e) => setTheme(e.target.dataset.phxTheme))
window.addEventListener("storage", (e) => {
  if (e.key === "phx:theme") applyTheme(e.newValue || "system")
})

// Listen for OS preference changes (when in "system" mode)
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  if (storedThemePref() === "system") applyTheme("system")
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
// DaisyUI dropdowns open while focus is inside `.dropdown` (both keyboard focus
// and mouse clicks focus the trigger), so focusin/focusout alone drive
// aria-expanded on the [aria-haspopup] trigger. A separate click toggle used to
// fight the mousedown focus (open -> click flipped it back to "false").
const dropdownTrigger = (dropdown) => dropdown.querySelector("[aria-haspopup]")

// Opening state for aria-expanded: open while focus is inside, unless the menu
// was dismissed with Escape (see below).
document.addEventListener("focusin", (e) => {
  const dropdown = e.target.closest(".dropdown")
  if (dropdown) {
    const trigger = dropdownTrigger(dropdown)
    const dismissed = dropdown.classList.contains("dropdown-close")
    if (trigger) trigger.setAttribute("aria-expanded", dismissed ? "false" : "true")
  }
})
document.addEventListener("focusout", (e) => {
  const dropdown = e.target.closest(".dropdown")
  if (dropdown) {
    setTimeout(() => {
      if (!dropdown.contains(document.activeElement)) {
        dropdown.classList.remove("dropdown-close")
        const trigger = dropdownTrigger(dropdown)
        if (trigger) trigger.setAttribute("aria-expanded", "false")
      }
    }, 0)
  }
})
// Escape closes the open dropdown and returns focus to its trigger. Because the
// daisyUI menu is shown via :focus-within, focusing the trigger would keep it
// visible, so the dropdown gets daisyUI's `dropdown-close` modifier until the
// user re-activates the trigger or focus leaves the dropdown.
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape" || !(e.target instanceof Element)) return
  const dropdown = e.target.closest(".dropdown")
  if (!dropdown || dropdown.classList.contains("dropdown-close")) return
  const trigger = dropdownTrigger(dropdown)
  dropdown.classList.add("dropdown-close")
  const active = document.activeElement
  if (active && dropdown.contains(active) && active !== trigger) active.blur()
  if (trigger) {
    trigger.setAttribute("aria-expanded", "false")
    trigger.focus({preventScroll: true})
  }
})
// Re-activating the trigger (click, Enter, Space, ArrowDown) re-opens it.
const reopenDropdown = (trigger) => {
  const dropdown = trigger.closest(".dropdown")
  if (!dropdown || !dropdown.classList.contains("dropdown-close")) return
  dropdown.classList.remove("dropdown-close")
  trigger.setAttribute("aria-expanded", "true")
}
document.addEventListener("mousedown", (e) => {
  const trigger = e.target instanceof Element && e.target.closest(".dropdown [aria-haspopup]")
  if (trigger) reopenDropdown(trigger)
})
document.addEventListener("keydown", (e) => {
  if (!["Enter", " ", "ArrowDown"].includes(e.key) || !(e.target instanceof Element)) return
  if (e.target.matches(".dropdown [aria-haspopup]")) reopenDropdown(e.target)
})

// Graceful reconnect: delay showing disconnect flash so brief interruptions
// (e.g. phone sleep/wake) don't flash a scary red error at the user.
// Only show after 2s of sustained disconnection; hide immediately on reconnect.
;(() => {
  const GRACE_MS = 2000
  let timer = null

  const setVisible = (id, visible) => {
    const el = document.getElementById(id)
    if (!el) return
    if (visible) {
      el.removeAttribute("hidden")
      el.style.display = ""
    } else {
      el.setAttribute("hidden", "")
      el.style.display = "none"
    }
  }

  const hideAll = () => {
    setVisible("client-error", false)
    setVisible("server-error", false)
  }

  const observer = new MutationObserver(() => {
    const cl = document.documentElement.classList
    const disconnected = cl.contains("phx-client-error") || cl.contains("phx-server-error")

    if (disconnected) {
      if (!timer) {
        timer = setTimeout(() => {
          const cl2 = document.documentElement.classList
          if (cl2.contains("phx-client-error")) setVisible("client-error", true)
          if (cl2.contains("phx-server-error")) setVisible("server-error", true)
        }, GRACE_MS)
      }
    } else {
      if (timer) { clearTimeout(timer); timer = null }
      hideAll()
    }
  })

  observer.observe(document.documentElement, {
    attributes: true, attributeFilter: ["class"]
  })
})()

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Set by the phx:scroll-to-top handler (pagination) so the focus handler below
// moves focus into the list the page scrolled to, not the first focus target.
let paginationFocusTarget = null

// The element the URL's fragment names inside `main`, or null.
function fragmentTarget(main) {
  try {
    const id = decodeURIComponent(window.location.hash.slice(1))
    return id ? main.querySelector(`[id="${CSS.escape(id)}"]`) : null
  } catch (_e) {
    return null
  }
}

// Auto-focus first content item after LiveView client-side navigation.
// Skips initial page load and pages with autofocus inputs (e.g., search).
;(() => {
  let isInitialLoad = true

  window.addEventListener("phx:page-loading-stop", () => {
    if (isInitialLoad) {
      isInitialLoad = false
      return
    }

    const paginated = paginationFocusTarget
    paginationFocusTarget = null

    const main = document.getElementById("main-content")
    if (!main || (!paginated && main.querySelector("[autofocus]"))) return

    // A link that names an element (`?page=3#comment-42`, from a notification
    // or "jump to the first new comment") gets focus there. LiveView scrolls
    // to the fragment itself; focus left on the list's first control would
    // sit far above what the reader is looking at. Read here rather than in
    // the scroll-to-top handler, which runs before the URL has changed.
    const target = fragmentTarget(main) || paginated || main.querySelector("[data-focus-target]")
    if (!target) return

    const focusable = target.querySelector(
      "a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])"
    )
    if (focusable) focusable.focus({ preventScroll: true })
  })
})()

// Server-requested focus: `push_event(socket, "focus", %{id: "..."})` moves
// keyboard / screen-reader focus to the element with that id (e.g. after a
// form submit replaces the content the user was on). Non-focusable targets
// get tabindex="-1" so they can receive programmatic focus without entering
// the tab order.
window.addEventListener("phx:focus", (e) => {
  const el = e.detail && e.detail.id ? document.getElementById(e.detail.id) : null
  if (!el) return
  if (!el.hasAttribute("tabindex") && !el.matches("a[href],button,input,select,textarea")) {
    el.setAttribute("tabindex", "-1")
  }
  el.focus()
})

// Scroll-to-top FAB: shown after scrolling past the header (~64px), hidden near top.
//
// Looks up the button by ID on every update rather than caching the reference,
// so stale element references after LiveView morphdom patches are never an issue.
// Click is handled via event delegation on document for the same reason.
;(() => {
  function updateFab() {
    const btn = document.getElementById("scroll-to-top-btn")
    if (!btn) return
    btn.classList.toggle("visible", window.scrollY > 64)
  }

  // Click via delegation — works regardless of whether the element was patched.
  document.addEventListener("click", (e) => {
    if (e.target.closest("#scroll-to-top-btn")) {
      window.scrollTo({ top: 0, behavior: prefersReducedMotion() ? "auto" : "smooth" })
    }
  })

  window.addEventListener("scroll", updateFab, { passive: true })
  window.addEventListener("phx:page-loading-stop", updateFab)
  document.addEventListener("DOMContentLoaded", updateFab)
})()

// Scroll to the paginated list when the page number changes
// (`BaudrateWeb.PaginationScrollHook`, on every paginated page): the pager's
// `data-scroll-target` element (e.g. an article's comments) or else the page's
// `[data-focus-target]`. Fired before phx:page-loading-stop, so the focus
// handler runs after it, moves focus into the same element, and does not
// fight the scroll position.
window.addEventListener("phx:scroll-to-top", () => {
  const main = document.getElementById("main-content")
  if (!main) return
  const scrollId = main.querySelector(".pagination-nav[data-scroll-target]")?.dataset.scrollTarget
  const target = (scrollId && document.getElementById(scrollId)) || main.querySelector("[data-focus-target]")
  if (!target) return
  paginationFocusTarget = target
  const headerHeight = document.getElementById("site-header")?.offsetHeight ?? 0
  const top = target.getBoundingClientRect().top + window.scrollY - headerHeight
  window.scrollTo({ top, behavior: "instant" })
})

// Register the service worker, on every page and independently of push.
//
// It used to be registered by PushManagerHook, which mounts only on /profile
// and returns early when no VAPID key is configured — so on an instance that
// never set up Web Push, no worker was ever registered anywhere and the site
// was not installable at all. Push availability and PWA installability are
// different questions; the hook still answers the first one.
//
// **The path is a bare string literal on purpose. Never make it `~p`.** That
// would resolve to the digest-stamped `/service_worker-<md5>.js?vsn=d`, so
// every deploy would register a *new* worker at a *new* URL and leave the old
// one controlling clients for ever, with no way to dislodge it. `phx.digest`
// keeps the undigested original next to the stamped copy, and both
// `Plug.Static` and nginx serve it, which is what makes the literal correct
// and what preserves the same-URL byte-diff update check.
//
// Failures are swallowed deliberately: registration rejects routinely in
// private windows, over plain HTTP and under Selenium, and
// `features/js_errors_test.exs` fails the build on `console.error` and on an
// unhandled rejection.
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/service_worker.js", {scope: "/"}).catch(() => {})
  })
}

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

