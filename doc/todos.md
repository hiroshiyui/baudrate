# Planned Features

## User Features
(none pending)

## Board Management
- [ ] Board-level permissions (beyond visibility)

## System
- [ ] Public API via existing ActivityPub endpoints (no separate REST API; AP endpoints serve as the public API)
- [ ] Real-time updates via PubSub (new articles, comments)
- [ ] Search indexing

## ActivityPub Federation (remaining)
- [ ] `Block` activity: communicate user-level blocks to remote instances
- [ ] **Performance & scalability**
  - [ ] Consider migrating delivery to Oban for persistent job queues
  - [ ] Shared inbox aggregation to reduce delivery volume
  - [ ] Background worker for stale actor cache cleanup
- [ ] **Security**
  - [ ] Authorized fetch mode (require signatures on GET requests, optional)
  - [ ] Key rotation mechanism for actor keypairs
  - [ ] Regular audit of domain blocklist against known-bad-actor lists

---

## Completed

<details>
<summary>Content (all done)</summary>

- [x] Article editing and deletion UI (edit page, delete button, author/admin authorization)
- [x] Comment schema and federation support (threaded, local + remote)
- [x] Comment UI on article pages (threaded display, local posting, reply)
- [x] Markdown rendering for article body
- [x] Article search (PostgreSQL full-text search with tsvector, pagination)
- [x] Article pagination (offset pagination on board pages with DaisyUI controls)
- [x] File attachments on articles (upload, download, delete; image re-encoding, magic bytes validation)

</details>

<details>
<summary>Moderation (all done)</summary>

- [x] Admin settings UI (site name, registration mode)
- [x] Admin pending-users approval page
- [x] Content reporting system (remote + local, moderation queue with resolve/dismiss)
- [x] Board visibility (public/private) with guest access control
- [x] Admin dashboard with user management (list, filter, search, role change)
- [x] User banning / suspension (ban with reason, unban, session invalidation, login rejection)
- [x] Admin UI for creating / editing / deleting boards
- [x] Moderation log (admin-visible audit trail of all moderation actions)

</details>

<details>
<summary>Navigation & Profiles</summary>

- [x] Sub-board navigation (breadcrumbs, sub-board listing on board pages)
- [x] User public profile pages (stats, recent articles, clickable author names)

</details>

<details>
<summary>Registration</summary>

- [x] Closed registration mode (invite-only with admin-managed invite codes)

</details>

<details>
<summary>User Features (all done)</summary>

- [x] Remove email from system (Swoosh/mailer removed; recovery codes are the sole recovery mechanism)
- [x] Password recovery via recovery codes (word-based codes issued at registration and setup; password reset page at /password-reset)
- [x] Registration terms notice (system activity logging notice + admin-configurable End User Agreement; checkbox required)
- [x] User signatures (markdown, max 500 chars / 8 lines; displayed on articles, comments, and public profiles)

</details>

<details>
<summary>ActivityPub Federation — Phases 1–4a (all done)</summary>

- [x] Phase 1: Read-only endpoints (WebFinger, NodeInfo, actors, outbox, objects, key pairs)
- [x] Phase 2a: HTTP signatures, inbox, Follow/Undo(Follow), remote actor resolution, safe HTTP client
- [x] Phase 2b: Content activities (Create, Like, Announce, Delete, Update, Undo variants)
- [x] Phase 3: Delivery (publisher, delivery queue, exponential backoff, followers collection)
- [x] Phase 4a: Mastodon & Lemmy compatibility (span allowlist, content warnings, Page type, addressing)
- [x] Phase 4b partial: article summary, hashtag tags, cross-post dedup, moderation tools, federation dashboard, blocklist/allowlist, Flag activities, kill switch, CSP, display name sanitization

</details>
