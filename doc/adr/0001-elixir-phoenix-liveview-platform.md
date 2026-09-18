# 0001 — Elixir / Phoenix / LiveView on Bandit as the application platform

- **Status:** Accepted; the names in this record predate [0041](0041-rss-and-atom-are-syndication.md), which renamed `FeedWorker` to `SyndicationFeedWorker`
- **Date:** Project inception (recorded retroactively 2026-08-09)

## Context

Baudrate is a public bulletin board system that also federates over
ActivityPub. Two workloads sit in one application:

- **Interactive UI** — boards, threads, comments, DMs, notifications, all of
  which want live updates without a page reload.
- **Federation** — a continuous trickle of inbound signed HTTP POSTs and
  outbound deliveries to many remote hosts, each of which can be slow, dead, or
  hostile. Delivery must retry with backoff and must never block a user
  request.

The system is self-hosted by individual sysops on modest hardware. A design
that needs a separate job runner, a cache server, and a Node front-end build
would raise the operational floor beyond what that audience will accept.

## Decision

Build on **Elixir/OTP** with **Phoenix 1.8** and **LiveView 1.2**, served by
**Bandit**.

- The BEAM's process model handles fan-out delivery to hundreds of remote
  inboxes with per-target isolation: a hung host occupies one process, not a
  thread pool.
- OTP supervision gives us in-process background work (`DeliveryWorker`,
  `FeedWorker`, `SessionCleaner`, ETS caches) under the application supervision
  tree — no external scheduler, no Redis. See `lib/baudrate/application.ex`.
- LiveView delivers real-time thread/DM/notification updates over the existing
  WebSocket via `Phoenix.PubSub`, with no separate client-side application and
  no JSON API surface to secure twice.
- Bandit rather than Cowboy: pure-Elixir, actively maintained, and the
  Phoenix 1.8 default.

## Consequences

- **One OTP release is the whole deployment.** Runtime dependencies are
  PostgreSQL, libvips, and a Rust toolchain at build time (see ADR 0005).
- Authorization must be enforced on **every** LiveView event, because the
  socket is a long-lived, stateful attack surface — the mount check is not
  enough. This is why authorization lives at the context boundary (ADR 0016).
- LiveView's stateful mounts required their own rate limit
  (`:rate_limit_mount`, 60/min per IP) — a normal per-request limiter does not
  see WebSocket mounts.
- Server-rendered state means every authenticated LiveView must tolerate
  PubSub messages it did not ask for; a missing catch-all `handle_info/2`
  crashes the page when a DM arrives. This is a recurring bug class.
- Federation delivery runs in async `Task`s in production but synchronously in
  tests (`federation_async: false`) to stay inside the Ecto sandbox.

## Alternatives considered

- **A JSON API plus an SPA front-end.** Rejected: doubles the authorization
  surface and the build toolchain for a document-oriented forum whose
  interactions are mostly navigation and form posts.
- **Ruby/Rails or Python/Django with Sidekiq/Celery.** Rejected: federation
  fan-out to unreliable hosts is exactly the workload the BEAM is best at, and
  the alternatives all add a broker to the ops footprint.
