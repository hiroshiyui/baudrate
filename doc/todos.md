# Planned Features

## ActivityPub Federation

(no remaining items)

## Performance & Scalability

(no remaining items)

---

## Completed

<details>
<summary>System</summary>

- [x] Public API via existing ActivityPub endpoints (no separate REST API; AP endpoints serve as the public API)
- [x] Real-time updates via PubSub (BoardLive + ArticleLive re-fetch on content mutations)
- [x] Search indexing (CJK/multi-language support via pg_trgm + comment search with tab UI)

</details>

<details>
<summary>Content</summary>

- [x] Article editing and deletion UI (edit page, delete button, author/admin authorization)
- [x] Comment schema and federation support (threaded, local + remote)
- [x] Comment UI on article pages (threaded display, local posting, reply)
- [x] Markdown rendering for article body
- [x] Article search (PostgreSQL full-text search with tsvector, pagination)
- [x] Article pagination (offset pagination on board pages with DaisyUI controls)
- [x] File attachments on articles (upload, download, delete; image re-encoding, magic bytes validation)

</details>

<details>
<summary>Moderation</summary>

- [x] Admin settings UI (site name, registration mode)
- [x] Admin pending-users approval page
- [x] Content reporting system (remote + local, moderation queue with resolve/dismiss)
- [x] Board visibility (public/private) with guest access control
- [x] Board-level permissions (`min_role_to_view`, `min_role_to_post`, board moderators, pin/lock/delete)
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
<summary>Registration & User Features</summary>

- [x] Closed registration mode (invite-only with admin-managed invite codes)
- [x] Remove email from system (Swoosh/mailer removed; recovery codes are the sole recovery mechanism)
- [x] Password recovery via recovery codes (word-based codes issued at registration and setup)
- [x] Registration terms notice (system activity logging notice + admin-configurable End User Agreement)
- [x] User signatures (markdown, max 500 chars / 8 lines; displayed on articles, comments, and public profiles)

</details>

<details>
<summary>ActivityPub Federation — Phases 1–4b</summary>

- [x] Phase 1: Read-only endpoints (WebFinger, NodeInfo, actors, outbox, objects, key pairs)
- [x] Phase 2a: HTTP signatures, inbox, Follow/Undo(Follow), remote actor resolution, safe HTTP client
- [x] Phase 2b: Content activities (Create, Like, Announce, Delete, Update, Undo variants)
- [x] Phase 3: Delivery (publisher, delivery queue, exponential backoff, followers collection)
- [x] Phase 4a: Mastodon & Lemmy compatibility (span allowlist, content warnings, Page type, addressing)
- [x] Phase 4b: Article summary, hashtag tags, cross-post dedup, moderation tools, federation dashboard, blocklist/allowlist, Flag activities, kill switch, CSP, display name sanitization
- [x] Phase 5: Block activity (user-level blocks, Block/Undo(Block) federation), authorized fetch mode (optional HTTP signature requirement on GETs), key rotation (RSA keypair rotation with Update activity distribution), domain blocklist audit (compare local blocklist against external known-bad-actor lists)

</details>

<details>
<summary>Performance & Scalability</summary>

- [x] Shared inbox aggregation to reduce delivery volume (deduplication in `Delivery.resolve_follower_inboxes/1` and `enqueue_for_article/3`)
- [x] Background worker for stale actor cache cleanup (`StaleActorCleaner` GenServer — daily cleanup of remote actors older than 30 days, with reference-aware refresh/delete logic)

</details>
