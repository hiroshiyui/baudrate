// Service worker for Baudrate.
//
// Two jobs, and a rule about a third it must never take on.
//
//   1. Push notifications and notification clicks (unchanged behaviour).
//   2. An offline fallback for navigations, so a dropped connection shows the
//      site's own page instead of the browser's dinosaur.
//
// The rule (ADR 0059): **this worker caches the shell and never content.**
// Only two things are ever written to a cache — the offline page, and
// fingerprinted files under /assets/, which are immutable by construction.
// No article, comment, direct message or board page is written to disk. A
// forum's cache is a record of what somebody read, on a device that may not
// be theirs alone, and "cache pages for offline reading" is exactly the
// improvement this shape exists to refuse.
//
// That invariant is structural rather than a matter of care. A cache is
// written in exactly three places: the two `cache.add(OFFLINE_URL)` calls,
// and `cacheAsset()`, which re-checks the /assets/ prefix itself rather than
// trusting its caller. Nothing else in this file reaches a cache.

const SHELL_CACHE = "baudrate-shell-v1"
const ASSET_CACHE = "baudrate-assets-v1"
const CURRENT_CACHES = [SHELL_CACHE, ASSET_CACHE]

const OFFLINE_URL = "/offline"

// Digested filenames change on every deploy, so old entries would otherwise
// accumulate for ever. `cache.keys()` returns insertion order, so trimming
// from the front evicts the least recently added.
const MAX_ASSET_ENTRIES = 60

function isSameOrigin(url) {
  try {
    const parsed = new URL(url, self.location.origin)
    return parsed.origin === self.location.origin
  } catch {
    return false
  }
}

// --- install / activate -----------------------------------------------------
//
// Without these the worker had no lifecycle at all: an updated one sat in
// `waiting` until every tab of the site was closed, which on a site people
// keep open is indistinguishable from the update never shipping.

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(SHELL_CACHE)
      .then((cache) => cache.add(new Request(OFFLINE_URL, { cache: "reload" })))
      .catch(() => {})
      .then(() => self.skipWaiting())
  )
})

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((names) =>
        Promise.all(
          names.filter((name) => !CURRENT_CACHES.includes(name)).map((name) => caches.delete(name))
        )
      )
      .catch(() => {})
      .then(() => self.clients.claim())
  )
})

// --- fetch ------------------------------------------------------------------

self.addEventListener("fetch", (event) => {
  const { request } = event

  if (request.method !== "GET" || !isSameOrigin(request.url)) return

  if (request.mode === "navigate") {
    event.respondWith(handleNavigation(request))
    return
  }

  if (new URL(request.url).pathname.startsWith("/assets/")) {
    event.respondWith(handleAsset(request))
  }

  // Everything else is left entirely alone — no respondWith, so the browser
  // uses its own path rather than routing the request through this worker.
  // The previous version answered *every* request with a bare
  // `fetch(event.request)`, which added a hop and gave nothing back.
})

// Network-first. A navigation that fails is the only thing the offline page
// is for; a 404 or a 500 is the server talking, and is passed straight
// through.
async function handleNavigation(request) {
  try {
    const response = await fetch(request)
    refreshOfflinePage()
    return response
  } catch {
    const cached = await caches.match(OFFLINE_URL, { cacheName: SHELL_CACHE })
    if (cached) return cached
    throw new Error("offline and no offline page cached")
  }
}

// Cache-first, which is only safe because these names carry a content hash:
// a changed file is a different URL, so a cached entry can never be stale.
async function handleAsset(request) {
  const cached = await caches.match(request, { cacheName: ASSET_CACHE })
  if (cached) return cached

  const response = await fetch(request)
  if (response && response.ok) cacheAsset(request, response.clone())
  return response
}

function cacheAsset(request, response) {
  if (!new URL(request.url).pathname.startsWith("/assets/")) return

  caches
    .open(ASSET_CACHE)
    .then(async (cache) => {
      await cache.put(request, response)
      const keys = await cache.keys()
      const excess = keys.length - MAX_ASSET_ENTRIES
      for (let i = 0; i < excess; i++) await cache.delete(keys[i])
    })
    .catch(() => {})
}

// The offline page is translated and themed, so the copy taken at install is
// in whatever language was active then. Re-fetching it after a successful
// navigation keeps it in step with the language the reader actually uses,
// which is the one they will need it in.
let offlineRefreshPending = false

function refreshOfflinePage() {
  if (offlineRefreshPending) return
  offlineRefreshPending = true

  caches
    .open(SHELL_CACHE)
    .then((cache) => cache.add(new Request(OFFLINE_URL, { cache: "reload" })))
    .catch(() => {})
    .then(() => {
      offlineRefreshPending = false
    })
}

// --- push -------------------------------------------------------------------

self.addEventListener("push", (event) => {
  if (!event.data) return

  let data
  try {
    data = event.data.json()
  } catch {
    data = { title: "Baudrate", body: event.data.text() }
  }

  const options = {
    body: data.body || "",
    icon: data.icon || "/favicon.svg",
    badge: "/favicon.svg",
    data: { url: data.url || "/" },
    tag: data.type || "default",
    renotify: true,
  }

  event.waitUntil(self.registration.showNotification(data.title || "Baudrate", options))
})

self.addEventListener("notificationclick", (event) => {
  event.notification.close()

  const rawUrl = event.notification.data?.url
  const url = rawUrl && isSameOrigin(rawUrl) ? rawUrl : "/"

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clientList) => {
      // Focus an existing window if one matches
      for (const client of clientList) {
        if (client.url === url && "focus" in client) return client.focus()
      }
      // Otherwise open a new one
      if (self.clients.openWindow) return self.clients.openWindow(url)
    })
  )
})
