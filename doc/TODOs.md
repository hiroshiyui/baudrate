# Data Portability — Implementation TODOs

## Design reference

Phases 0 and 1 implement [ADR 0023](adr/0023-data-export-threat-model.md), and Phase 2
implements [ADR 0025](adr/0025-account-migration.md). Data import (a former Phase 3) was dropped
from the plan. Read the ADRs first: every
bullet below exists to prevent a specific way data could leak. When a TODO here conflicts with
the ADR, the ADR wins. Reuse the step-up re-authentication and account security notice machinery
from [ADR 0022](adr/0022-step-up-reauthentication-for-second-factor-changes.md).

---

## Phase 0: Account recovery prerequisites — ✅ done

Shipped on `current`: logged-in password change (`/profile/password`), sign out everywhere
(`/profile` → Sessions), session revocation that closes open LiveView sockets
(`live_socket_id`), `users.totp_enabled_at` with `Auth.totp_enabled_for_at_least?/2`, and
`articles.deleted_by_id`. See "Session Management" in `doc/development.md`. Phase 1 builds on these:
`cancel_active_exports/2` must be called from `Auth.change_password/3`,
`Auth.sign_out_other_sessions/2`, TOTP reset/disable and `ban_user/3`.

---

## Phase 1: Data Export — ✅ done

Shipped on `current` as designed in ADR 0023:
- request lifecycle: `export_requests`, `DataPortability`
- archive: `Collector`, `Files`, `Archive`, with the canary acceptance test
- web: `/profile/export`, `POST /exports/:id/download`, the warning banner, and the nginx `/exports/` location
- SysOp and admin: `Release.export_user_data/3`, `/admin/data-exports`

See "Data Export" in `doc/development.md` and `doc/sysop.md`.

Follow-ups:
- Move the registration, password reset and setup pages onto the shared
  `<.password_requirements>` component.

---

## Phase 2: Account Migration (ActivityPub Move) — MEDIUM PRIORITY

Designed in [ADR 0025](adr/0025-account-migration.md). Decisions: TOTP ≥ 7 days
and no staff roles; 24 h cooling-off with a banner and cancel; the old account
becomes read-only and the redirect can be removed; local followers are moved on
their behalf and notified.

Already shipped: inbound `Move` alias verification (`remote_actors.also_known_as`)
and feed item migration (`Federation.migrate_feed_items/2`).

### Stage 1 — Aliases and actor fields ✅ done

- Migration: `users.also_known_as` (`{:array, :string}`, default `[]`),
  `users.moved_to`, `users.moved_at`; `remote_actors.moved_to_ap_id`,
  `remote_actors.moved_at`.
- `ActorRenderer.user_actor/1`: `alsoKnownAs` (always) and `movedTo` (when set).
- `Federation.Migration` (or `Auth`-side) alias functions: add (handle or URI →
  `ActorResolver`, HTTPS, remote Person only, no duplicates, cap 5), remove;
  both behind `Auth.verify_reauthentication/5` inside the context.
- Security notices `account_alias_added` / `account_alias_removed`.
- `/profile/move` page: aliases list, add, remove, with explanations.
- Data export: `also_known_as` and `moved_to` in `profile.json`.

### Stage 2 — Outbound Move request lifecycle ✅ done (sending is Stage 3)

- `account_moves` table: `user_id`, `target_ap_id`, `status`
  (`pending`/`sent`/`cancelled`/`failed`), `requested_at`, `send_after`,
  `sent_at`, `cancelled_at`, `cancel_reason`, `failure_reason`,
  `requested_session_id`, `requested_user_agent_family`. Partial unique index:
  one pending per user.
- Eligibility: active, non-bot, TOTP ≥ 7 days, not admin/moderator, not a board
  moderator, no move sent in the last 30 days, not currently moved.
- Request: eligibility → target resolves and claims this account → step-up →
  insert → notice. Cancel (owner), `cancel_active_moves/2` hooked into password
  change, TOTP disable, sign out everywhere, ban.
- Banner on every page while pending (like the export banner).
- Sweep (hourly, `SessionCleaner`): due requests re-checked, then sent or marked
  `failed` with a notice.

### Stage 3 — Sending, post-move state and read-only enforcement ✅ done

- `Publisher.build_move/2`; deliver to remote follower inboxes.
- Set `moved_to` / `moved_at`; `account_moved` notice; profile banner
  "This account has moved to …".
- Local followers: pending follow of the target + `Follow` delivery, remove old
  local follow, `actor_moved` notice.
- Read-only at the context boundary: articles, comments, feed replies, DMs,
  likes and boosts (articles, comments, feed items), forwards, poll votes,
  invites. LiveViews hide the controls.
- "Remove redirect": step-up, clears `moved_to`/`moved_at`, notice.

### Stage 4 — Inbound Move fixes

- Replace the silent repoint: for each local follower send `Follow` to the
  target (pending) and `Undo(Follow)` to the origin; keep feed item migration.
- Target is a local user whose `also_known_as` claims the origin: create local
  follows instead.
- `actor_moved` notice (configurable type) for each migrated local follower.
- Board follows are never repointed; admins get a notice.
- Ignore a `Move` whose target has `movedTo`; one processed `Move` per origin
  every 30 days (`remote_actors.moved_to_ap_id` / `moved_at`).

### Stage 5 — Docs

- `doc/development.md` federation section, `doc/sysop.md`, `CLAUDE.md` gotchas,
  README features, zh_TW / ja_JP translations throughout.
