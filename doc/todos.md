# Baudrate — Project TODOs

Audit date: 2026-02-23

---

## Critical: Test Coverage Gaps

- [x] **Write inbox handler tests** — `test/baudrate/federation/inbox_handler_test.exs` covers 39 tests across Follow, Create, Like, Announce, Update, Delete, Flag, Block, and Undo variants
- [x] **Write admin moderation live test** — `test/baudrate_web/live/admin/moderation_live_test.exs` covers access control, report filtering, resolve/dismiss, and content deletion (9 tests)
- [x] **Write admin federation live test** — `test/baudrate_web/live/admin/federation_live_test.exs` covers access control, delivery job management, domain blocking, board federation toggle, key rotation, and stats display (8 tests)

## High: Security & Performance

- [ ] **Paginate admin user list** — `Auth.list_users()` in `UsersLive` loads all users unbounded; will degrade with scale
- [ ] **Paginate article comments** — `ArticleLive` loads entire comment tree; no pagination for threads with many replies
- [ ] **Add database index on `articles.deleted_at`** — soft-delete filtering queries lack index
- [ ] **Add database index on `comments.deleted_at`** — same as above
- [ ] **Per-account brute-force protection** — add progressive per-account delay (exponential backoff after N failed login attempts, e.g. 5s after 5 failures, 30s after 10, 2min after 15) combined with per-account attempt tracking visible in admin panel; hard lockout is avoided because it creates a DoS vector (attacker can lock out any user by submitting wrong passwords); existing defenses: IP-based rate limiting + mandatory TOTP for admin/moderator roles

## Medium: Missing Test Files

- [x] **Write home live test** — `test/baudrate_web/live/home_live_test.exs` covers guest/auth board visibility and welcome messages (5 tests)
- [x] **Write recovery code verify live test** — `test/baudrate_web/live/recovery_code_verify_live_test.exs` covers session redirect, form rendering, invalid/valid code handling (4 tests)
- [x] **Write recovery codes live test** — `test/baudrate_web/live/recovery_codes_live_test.exs` covers auth redirect, empty codes redirect, codes display (3 tests)
- [x] **Write TOTP reset live test** — `test/baudrate_web/live/totp_reset_live_test.exs` covers enable/reset modes, invalid password, lockout (5 tests)
- [x] **Expand auth hooks test** — `test/baudrate_web/live/auth_hooks_test.exs` now covers optional_auth, require_admin, and banned user handling (18 total tests)

## Medium: Feature Gaps

- [ ] **RSS/Atom feeds** — no feed endpoints; common expectation for forums (`/boards/:slug/feed.xml`, `/articles/feed.xml`)
- [ ] **Markdown live preview** — toolbar exists (`MarkdownToolbarHook`) but no side-by-side preview toggle
- [ ] **Article edit history** — no version tracking; edits are silent with no audit trail
- [ ] **Bulk moderation actions** — one-at-a-time only; no bulk delete/ban in admin
- [ ] **User muting** — blocking exists (AP Block activity) but no local-only soft-mute/ignore

## Medium: Accessibility (WAI-ARIA)

- [ ] **Add skip-to-content link** in app layout for keyboard navigation
- [ ] **Add `aria-live` regions** for dynamic LiveView updates (flash messages, real-time comment additions)
- [ ] **Add `aria-describedby` on form error inputs** — link error messages to their fields
- [ ] **Add `aria-expanded` on collapsible sections** (comment reply forms, admin panels)
- [ ] **Audit all icon-only buttons for `aria-label`** — some `phx-click` buttons lack accessible names

## Low: Deployment & Infrastructure

- [ ] **Create Dockerfile** — no containerization support
- [ ] **Create docker-compose.yml** — no local dev environment template
- [ ] **Add `rel/` release config** — `mix release` not configured for production
- [ ] **Write deployment guide** — no deployment documentation exists
- [ ] **Add `.env.example`** — no environment config template

## Low: Documentation

- [ ] **Write AP endpoint API guide** — endpoints are well-structured but no external-facing documentation
- [ ] **Write troubleshooting guide** — common issues and solutions
- [ ] **Remove legacy `visibility` column** — kept in sync via `Board.sync_visibility/1` but no longer the source of truth; clean up in a future migration

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

## Someday / Maybe

- [ ] Private messaging / DMs (user-to-user, possibly via AP)
- [ ] Email notification system (currently no email field in User schema — by design)
- [ ] Two-way visibility blocking (blocked users can still see public content)
- [ ] Per-user rate limits on authenticated endpoints (currently IP-only)
- [ ] Authorized fetch mode test coverage (signed GET fallback)
