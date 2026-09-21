# 0059 — The service worker caches the shell and never content

- **Status:** Accepted
- **Date:** 2026-09-21
- **Deciders:** Baudrate maintainers
- **Related:** applies [0056](0056-boring-but-friendly.md)'s fourth question
  ("does being here cost the reader something they did not agree to?") to what
  the site leaves on a reader's disk; the same instinct as
  [0023](0023-data-export-threat-model.md)'s "no archive is
  ever stored" and [0048](0048-a-poll-records-who-voted-and-nothing-reads-it-back.md)'s
  refusal to read back what it records; installability is the
  "federation reach" clause of 0056 decision 5, which says boring is never an
  argument against it.

## Context

Baudrate shipped a service worker for Web Push and nothing else. Three things
about it were wrong in ways that only showed up from outside:

- **It was registered on one page, and only sometimes.**
  `PushManagerHook.mounted()` returned early unless a VAPID public key was
  configured, and the hook mounted only on `/profile`. An instance that never
  set up Web Push therefore had **no service worker at all**, and was not
  installable as a PWA. Push availability and installability are unrelated
  questions, and nothing in the admin UI suggested one decided the other.
- **It had a `fetch` handler that did nothing.** `event.respondWith(fetch(event.request))`
  was added to satisfy Firefox's installability check. It routed every request
  on the site through the worker — defeating the browser's own no-worker fast
  path — and cached not one byte in return.
- **It had no lifecycle.** No `install`, no `activate`, no `skipWaiting`. An
  updated worker sat in `waiting` until every tab of the site was closed,
  which on a site people keep open is indistinguishable from the update never
  shipping.

Fixing the first two means the worker needs a cache, and that is the decision
worth recording. **A cache on a forum is a record of what somebody read.** It
sits on a disk that may not be theirs alone — a shared laptop, a library
machine, a phone that gets handed round — and unlike a session it is not
cleared by signing out. Offline reading is also the single most obvious
"improvement" anyone would propose next, and it is obvious precisely because
its cost is invisible.

## Decision

### 1. The worker is registered on every page, independently of push

`app.js` registers it once per page load, behind `"serviceWorker" in navigator`
and a `.catch()` that swallows the failure. `PushManagerHook` takes what is
already installed from `navigator.serviceWorker.ready`; its VAPID check now
means only "this instance cannot offer push".

Registration rejects routinely — in private windows, over plain HTTP, under
Selenium — so it must never surface as an error. `js_errors_test.exs` fails
the build on `console.error` and on an unhandled rejection, which is the gate
that keeps this honest.

### 2. The registration path is a string literal, and must stay one

`navigator.serviceWorker.register("/service_worker.js")`. **Never `~p`.**

`~p` resolves to the digest-stamped `/service_worker-<md5>.js?vsn=d`. Every
deploy would then register a *new* worker at a *new* URL, leaving the old one
installed and controlling clients for ever, with no mechanism to dislodge it —
an un-fixable PWA, shipped silently. `phx.digest` keeps the undigested
original beside the stamped copy and both `Plug.Static` and nginx serve it,
which is what makes the literal correct and preserves the same-URL byte-diff
update check browsers actually use.

This reads like an oversight to anyone tidying verified routes, which is why
it is written here as well as at the call site.

### 3. Two things are cached, and nothing else, ever

- **The offline page** (`/offline`), precached at install.
- **Fingerprinted files under `/assets/`**, cache-first — safe only because
  those names carry a content hash, so a changed file is a different URL and a
  cached entry cannot be stale. Bounded to 60 entries, trimmed in insertion
  order, because digested names change every deploy.

Navigations are network-first; a failed one gets the offline page. **A 404 or
a 500 is the server talking and is passed straight through** — the offline
page is for the case where there was no answer at all. Everything that is not
a navigation or an asset gets no `respondWith`, so the browser uses its own
path rather than being proxied through the worker.

No article, comment, direct message, board page, or API response is written to
a cache. The invariant is structural rather than a matter of care: a cache is
written in exactly three places in `assets/js/service_worker.js`, and the one
that takes a URL re-checks the `/assets/` prefix itself rather than trusting
its caller.

### 4. The offline page is a route, refreshed opportunistically

`/offline` is rendered by `PageController`, not a file in `priv/static`, so it
is translated and themed like every other page. The worker re-fetches it after
each successful navigation, so the cached copy follows the language the reader
actually uses rather than freezing whichever was active when the worker
installed.

It carries `noindex` — it is not a page anyone should arrive at from a search.

## Alternatives considered

- **Cache visited pages for offline reading.** The obvious feature, and the
  reason this record exists. It writes private-board content and direct
  messages to disk, where they outlive the session that was allowed to read
  them and are reachable by anyone else using that device. Doing it safely
  would need a purge on sign-out (which cannot run if the session simply
  expires), a scope that understands board permissions the client does not
  know, and its own privacy analysis. Refused — and if it is ever revisited,
  it supersedes this record rather than amending the worker.
- **Cache API responses / a stale-while-revalidate shell.** Same objection,
  smaller surface; a cached listing is still a list of what someone could see
  at the time, and the permissions may have changed since.
- **No service worker at all.** Gives up installability and the offline page
  together. ADR 0056 decision 5 is explicit that boring is never an argument
  against federation reach, accessibility or correctness, and an installable
  site that survives a dropped connection is in that family: it removes a
  surprise rather than manufacturing a reason to return.
- **A static `priv/static/offline.html` instead of a route.** Simpler, and it
  is what nginx's 502 page is. Rejected because it cannot be translated — the
  502 page is English-only and that is a known wart, not a model to copy.
- **Precaching the digested asset names at install.** Would need the worker to
  read `cache_manifest.json`, which it cannot know at build time. Runtime
  cache-first gets the same result after one visit, with a bound.

## Consequences

- **There is no offline reading, and there will not be.** A reader who loses
  their connection gets a page saying so, not the article they were on. That
  is the trade, stated so the next person does not have to rediscover it.
- **Two "we're down" experiences now exist.** nginx's `502.html` (which
  auto-reloads after five seconds) answers when the application is restarting
  and the worker is not involved; the offline page answers when the network
  is gone. They will never both be visible, but they look different, and the
  502 page lives outside the worker's scope so it cannot be unified.
- **The asset cache is bounded, not correct.** Sixty entries is a guess sized
  for "one deploy's worth plus a margin". A site that grows many more
  fingerprinted files would evict usefully-cached ones; the symptom is a
  slower first paint offline, never a wrong answer.
- **`priv/static/service_worker.js` is no longer tracked in git.** It is an
  esbuild bundle, and it was the only build output under `priv/static`, so the
  file browsers actually run could drift from its source with nothing to catch
  it. `mix assets.build` and `mix assets.deploy` produce it.
- **A cache version bump is now a thing that has to be remembered.**
  `SHELL_CACHE` and `ASSET_CACHE` are named constants; `activate` deletes
  every cache not in the current list.

## Acceptance gate

There is no single test, and this record says so rather than naming a
plausible one. What is gated:

- `test/baudrate_web/security_headers_test.exs` — `worker-src 'self'` must
  stay in the CSP, or registration fails on some engines only.
- `test/baudrate_web/controllers/page_controller_test.exs` — `/offline`
  renders for a guest and carries `noindex` and no canonical.
- `test/baudrate_web/crawler_surface_test.exs` — `/offline` is in the
  noindex list.
- `test/baudrate_web/features/js_errors_test.exs` — registration now runs on
  every crawled page; a throw or an unhandled rejection fails the build.

**What no test can check is decision 3.** Whether a new `cache.put` is caching
the shell or somebody's reading is a judgement, and it is the one review has
to make. `doc/baudrate-spec.md` lists it among the rules with no automated
gate, with that reason.
