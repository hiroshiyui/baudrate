# Baudrate — Project TODOs

Audit date: 2026-02-23

---

## High: Security

- [x] **Actor-signer mismatch validation** — inbox handler now validates that HTTP Signature actor matches `activity["actor"]` via `validate_actor_match/2`
- [x] **Undo(Like/Announce) actor ownership check** — Undo handlers now scope deletes by `remote_actor_id` via ownership-aware `delete_article_like_by_ap_id/2` and `delete_announce_by_ap_id/2`
- [x] **Nil guard on mute events** — `UserProfileLive` mute/unmute handlers now guard against nil `current_user` (silent no-op for guests)

## Medium: Security

- [ ] **Parser-based HTML sanitizer** — both federation `Sanitizer` and `Markdown.to_html` use regex-based HTML sanitization, which is fragile against crafted/malformed HTML; consider Floki or HtmlSanitizeEx (`federation/sanitizer.ex:70`, `content/markdown.ex`)
- [ ] **`String.to_integer/1` on user params** — crashes LiveView process on non-numeric input; use `Integer.parse/1` instead (multiple LiveViews, e.g., `users_live.ex:83`)
- [ ] **IPv4-mapped IPv6 SSRF bypass** — `::ffff:127.0.0.1` not covered by `private_ip?/1` (`http_client.ex:247-261`)

## Medium: Federation (AP Spec Compliance)

- [ ] **Missing `cc` on outgoing activity wrappers** — Create, Announce, Update, Delete activities lack `cc` with followers collection, causing improper Mastodon delivery routing (`publisher.ex:37-151`)
- [ ] **30-second signature max age too strict** — Mastodon uses 12 hours; 30s rejects legitimate requests from servers with slight clock drift (`config.exs:60`)
- [ ] **Missing `id` validation on incoming activities** — `validate_activity` doesn't check for required `id` field (`validator.ex:54-66`)
- [ ] **Sequential delivery processing** — `DeliveryWorker` processes jobs one at a time; a batch of 50 slow targets could take 25 minutes; use `Task.async_stream` (`delivery_worker.ex:66-68`)

## Medium: Code Quality

- [ ] **Extract duplicated helpers** — `parse_page/1` (6x), `password_strength/1` (3x), `upload_error_to_string/1` (4x), `translate_role/1` (3x), `participant_name/1` (2x), `schedule_federation_task/1` (2x); extract to shared modules
- [ ] **N+1 queries** — `hidden_filters/1` fires 4 DB queries per call; `board_ancestors/1` fires N for N levels; `load_unread_counts/2` fires N for N conversations; `can_delete_article?` preloads+checks per board (`content.ex:962`, `content.ex:67`, `conversations_live.ex:54`)
- [ ] **Add `@impl true`** consistently to all `handle_event`/`handle_info`/`handle_params` callbacks (~15 LiveView modules)
- [ ] **Non-atomic `save_settings/1`** — 8 separate `set_setting` calls without a transaction wrapper; partial updates possible on failure (`setup.ex:264-281`)
- [ ] **Non-atomic `register_with_invite`** — user creation and invite code consumption in separate operations (`auth.ex:376-383`)
- [ ] **Unbounded message list in `ConversationLive`** — PubSub appends messages to in-memory list indefinitely (`conversation_live.ex:90,137`)
- [ ] **Boards admin loads ALL active users** for moderator dropdown — no pagination/search (`boards_live.ex:111`)
- [ ] **`PendingUsersLive` approve crashes on nil user** — `Auth.get_user/1` return not checked (`pending_users_live.ex:22-24`)
- [ ] **Missing unique index on `settings.key`** — no index for frequently queried field

## High: Accessibility (WAI-ARIA)

- [ ] **Icon-only buttons missing `aria-label`** — locale up/down/remove buttons, conversation back link (`profile_live.html.heex:135-158`, `conversation_live.html.heex:3`)
- [ ] **Navigation menus not wrapped in `<nav>` landmarks** — desktop/mobile nav `<ul>` menus, breadcrumbs missing `<nav aria-label>` (`layouts.ex:27,103`, `board_live.html.heex:2`)

## Medium: Accessibility (WAI-ARIA)

- [ ] **Pagination component** — missing `<nav>` wrapper, `aria-current="page"`, and `aria-label` on prev/next buttons (`core_components.ex:541-578`)
- [ ] **Password strength indicators** — `<progress>` missing `aria-label`/`aria-valuetext`; requirement icons use color-only differentiation (`register_live.html.heex:146`, `setup_live.html.heex:211`)
- [ ] **Dropdown menus missing `aria-expanded`** — have `aria-haspopup` but no expanded state (`layouts.ex:31`, `profile_live.html.heex:170`)
- [ ] **Form inputs missing labels** — resolution note input and moderator select lack `aria-label` or `<label>` (`moderation_live.html.heex:127`, `boards_live.html.heex:130`)

## Test Coverage (77% → 90% target)

### Untested Security-Critical Modules (0% coverage)

- [ ] **`VerifyHTTPSignature` plug** — sole authentication gate for all inbound federation
- [ ] **`AttachmentStorage`** — file upload security (magic bytes, re-encoding)
- [ ] **`CacheBody` plug** — body caching for digest verification
- [ ] **`RateLimitDomain` plug** — domain-level federation abuse protection

### Modules Below 50% Coverage

- [ ] **`ProfileLive`** (23%) — locale management, unmute, DM access, remove_avatar
- [ ] **`ArticleEditLive`** (25%) — edit submission, permissions, preview
- [ ] **`ActorResolver`** (32%) — remote fetch, resolve_by_key_id, refresh
- [ ] **`TotpVerifyLive`** (33%) — code submission, lockout
- [ ] **`LoginLive`** (43%) — form submission, error paths
- [ ] **`HTTPClient`** (47%) — get/2, post/4, signed_get/4
- [ ] **`HTTPSignature`** (52%) — verify/1, verify_digest/1, verify_get/1

### Missing Controller/Context Tests

- [ ] **`SessionController`** (63%) — `totp_reset/2`, `recovery_verify/2`, `ack_recovery_codes/2`
- [ ] **`Messaging` context** (82%) — `can_receive_remote_dm?/2`, `unread_count_for_conversation/2`, `participant?/2`

## Medium: Feature Gaps

- [x] **RSS/Atom feeds** — `/feeds/rss`, `/feeds/atom`, `/feeds/boards/:slug/rss|atom`, `/feeds/users/:username/rss|atom`
- [ ] **Bulk moderation actions** — one-at-a-time only; no bulk delete/ban in admin
- [x] **User muting** — local-only soft-mute/ignore with SysOp board exemption, combined block+mute filtering

## Low: Deployment & Infrastructure

- [ ] **Create Containerfile** — no containerization support (Podman)
- [ ] **Create podman-compose.yml** — no local dev environment template
- [ ] **Add `rel/` release config** — `mix release` not configured for production
- [ ] **Write deployment guide** — no deployment documentation exists
- [ ] **Add `.env.example`** — no environment config template

## Low: Code Quality

- [ ] **Dead code** — unused `format_file_size/1` (`article_live.ex:488`), no-op `Repo.preload(board, [])` (`federation.ex:272`)
- [ ] **No stale delivery job cleanup** — `delivery_jobs` table grows indefinitely
- [ ] **CDATA injection in RSS/Atom feeds** — `]]>` sequences not escaped in feed content

## Low: Federation

- [ ] **No `formerType` on outgoing Tombstones** — AP spec recommends it (`publisher.ex:66-69`)
- [ ] **Actor self-deletion only removes followers** — remote articles/comments/DMs from deleted actor remain (`inbox_handler.ex:278-287`)
- [ ] **No `following` collection endpoint** — some AP clients expect it even if empty
- [ ] **No incoming `Accept`/`Reject`/`Move` activity handling** — needed for future outbound follows and account migration
- [ ] **No delivery job deduplication** — duplicate jobs possible on retry/race (`delivery.ex:67-87`)

## Low: Accessibility

- [ ] **Missing `<time datetime>` elements** — timestamps rendered as plain text throughout all listing pages
- [ ] **Tables missing `scope="col"` on `<th>`** — all admin tables
- [ ] **Setup layout `<main>` missing `id="main-content"`** — skip link broken on setup pages (`layouts.ex:242`)
- [ ] **Missing `aria-live` on dynamic content areas** — search results, moderation queue, user table
- [ ] **Alert SVG missing `aria-hidden="true"`** — recovery codes warning icon (`recovery_codes_live.html.heex:10`)

## Planned Features

### Board-Level Remote Follows (Moderator-Managed)

Allow moderators to follow remote Fediverse actors on behalf of boards, pulling
their content into the board. Requires anti-loop and deduplication safeguards.

#### Anti-Loop / Anti-Duplication Rules

1. **Never re-announce an Announce** — content arriving via `Announce` is stored
   and linked to the board but does NOT trigger an outbound `Announce`. Only
   content arriving via `Create` (directly authored) gets announced to followers.
2. **Cross-board announce dedup** — before a board announces an article, check if
   any local board has already announced the same `ap_id`. First board wins.
3. **Origin/addressing check** — only announce articles where the board's actor
   URI appears in the activity's `to` or `cc` (intentionally addressed, not relayed).
4. **Outbound announce rate limit** — cap Announces per board per time window
   (e.g., 30/hour) to prevent flood from a prolific followed actor.

#### Implementation Notes

- Rules 1 + 2 are the minimum viable safeguards
- Rules 3 + 4 are defense-in-depth
- Need a new `board_follows` table (board_id, remote_actor_id, followed_by_id)
- Need UI in board moderator panel to manage follows
- Need to handle `Undo(Follow)` on unfollow

## Someday / Maybe: Frontend Architecture

Decouple the frontend from Phoenix LiveView to allow free choice of UI framework
and component libraries. LiveView's tight coupling between server and UI limits
frontend technology options (e.g., Web Component libraries like Fluent UI are
incompatible with LiveView's DOM patching model).

### Approaches

- [ ] **JSON API backend** — convert Phoenix to a pure API server (`Phoenix.Controller` + `Phoenix.Router`), serve a standalone SSR frontend (Next.js, Nuxt, SvelteKit, Astro, etc.)
- [ ] **Incremental migration** — add new pages in the SPA framework while keeping existing LiveView pages, route via reverse proxy; migrate page-by-page over time
- [ ] **Hybrid approach** — keep LiveView for admin/internal pages, use a standalone frontend for public-facing pages only

### Trade-offs

| Gain | Loss |
|------|------|
| Free choice of UI framework/component library | LiveView's real-time WebSocket updates |
| Better frontend tooling ecosystem | Server-driven forms (no client state bugs) |
| Easier to hire frontend developers | Zero-API-layer simplicity |
| SSR framework flexibility (React, Vue, Svelte) | Must build and maintain a REST/GraphQL API |
| Independent frontend deployment | API versioning and compatibility burden |

### Preferred Frontend Framework

- **SvelteKit** — top candidate; compiled approach (no virtual DOM overhead), built-in SSR/SSG, form actions, file-based routing, small bundle size

### Prior Evaluation

- **Fluent UI Web Components v3** (2026-02-23): evaluated and rejected for use with LiveView due to Shadow DOM / DOM patching incompatibility, form binding friction, pre-release stability risk, and 5-7x bundle size increase over DaisyUI

## Someday / Maybe

- [ ] Two-way visibility blocking (blocked users can still see public content)
- [ ] Per-user rate limits on authenticated endpoints (currently IP-only)
- [ ] Authorized fetch mode test coverage (signed GET fallback)
