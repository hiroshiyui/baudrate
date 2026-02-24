# Baudrate — Project TODOs

Audit date: 2026-02-24

---

## Test Coverage (77% → 90% target)

### Modules Below 50% Coverage

- [x] **`ProfileLive`** (23%) — locale management, unmute, DM access, remove_avatar (2026-02-24)
- [x] **`ArticleEditLive`** (25%) — edit submission, permissions, preview (2026-02-24)
- [x] **`ActorResolver`** (32%) — remote fetch, resolve_by_key_id, refresh (2026-02-24)
- [x] **`TotpVerifyLive`** (33%) — code submission, lockout (2026-02-24)
- [x] **`LoginLive`** (43%) — form submission, error paths (2026-02-24)
- [x] **`HTTPClient`** (47%) — get/2, post/4, signed_get/4 (2026-02-24)
- [x] **`HTTPSignature`** (52%) — verify/1, verify_digest/1, verify_get/1 (2026-02-24)

### Missing Controller/Context Tests

- [x] **`SessionController`** (63%) — `totp_reset/2`, `recovery_verify/2`, `ack_recovery_codes/2` (2026-02-24)
- [x] **`Messaging` context** (82%) — `can_receive_remote_dm?/2`, `unread_count_for_conversation/2`, `participant?/2` (2026-02-24)

## Medium: Feature Gaps

- [x] **Bulk moderation actions** — checkbox-based bulk select/approve/ban on Users page, bulk resolve/dismiss on Moderation Queue (2026-02-24)

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
