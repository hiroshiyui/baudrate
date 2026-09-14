# Data Portability — Implementation TODOs

## Design reference

Phases 0 and 1 implement [ADR 0023](adr/0023-data-export-threat-model.md). Read it first: every
bullet below exists to prevent a specific way data could leak. When a TODO here conflicts with
the ADR, the ADR wins. Reuse the step-up re-authentication and account security notice machinery
from [ADR 0022](adr/0022-step-up-reauthentication-for-second-factor-changes.md).

---

## Phase 0: Account recovery prerequisites — HIGH PRIORITY (ships before Phase 1)

Without these, a user who notices a malicious export request cannot lock the attacker out while
logged in.

### 0.1 Change password (logged-in)

- `/profile/password`, or a section on `/profile`. Step-up via `Auth.verify_reauthentication/5`
  behind `RateLimits.check_reauth/1`.
- New password goes through the existing password rules (`User.password_reset_changeset/2`).
  Reject reuse of the current password.
- On success, revoke **all other** sessions and keep the current one, via rotation. Never leave
  the old session token valid.
- Always-delivered security notice `password_changed` (add to
  `Notification.Notification.security_types/0`, helpers text/icon, push, i18n).
- Tests: wrong password/TOTP refused and recorded; throttle survives reload; other sessions
  revoked; notice sent; recovery code not accepted.

### 0.2 Sign out everywhere

- Button on `/profile`. Also requires step-up, so a cookie-only attacker cannot use it to kick the
  real user out while keeping their own session.
- Revokes every session except the current one (`Sessions`: add `delete_other_sessions/2`).
- Always-delivered security notice `signed_out_everywhere`.
- Tests: other sessions invalid immediately (including LiveView sockets on next event / refresh
  plug), current session kept, notice sent.

### 0.3 `users.totp_enabled_at`

- Migration: `add :totp_enabled_at, :utc_datetime`. Backfill currently TOTP-enabled users with the
  **migration time**, not `updated_at`. That is conservative: the true enrolment time is unknown,
  so existing users wait 7 days after the deploy.
- `SecondFactor.enable_totp/2` sets it; `disable_totp/1` clears it.
- `Auth.totp_age_at_least?(user, days)` helper.

### 0.4 `articles.deleted_by_id`

- Migration: `add :deleted_by_id, references(:users, on_delete: :nilify_all)`; set in every
  soft-delete path (author delete, moderator/admin delete, federation `Delete`).
- Existing soft-deleted rows stay `NULL`, meaning attribution unknown, so the export excludes them.

---

## Phase 1: Data Export — HIGH PRIORITY

### 1.1 Schema: `export_requests`

Columns:
- `id`
- `user_id` (FK, `on_delete: :delete_all`)
- `status`: `pending` | `ready` | `completed` | `cancelled` | `expired`
- `requested_at`, `ready_at` (`requested_at + 24h`), `expires_at` (`ready_at + 48h`)
- `download_count` (default 0, max 3)
- `requested_session_id` (FK `user_sessions`, `nilify_all`)
- `requested_user_agent_family`: a short display string for the banner ("Firefox on Linux").
  **No IP.**
- `cancelled_at`, `cancel_reason`: `user` | `password_changed` | `totp_changed` | `banned` |
  `signed_out_everywhere`
- timestamps

Indexes / constraints:
- Partial unique index on `user_id` WHERE `status IN ('pending','ready')` (one active request).
- Index `(user_id, requested_at)` for the per-week cap.
- Rows are never deleted by users (immutable history). Purge after 1 year in `SessionCleaner`.

### 1.2 Context: `Baudrate.DataPortability`

Authorization lives here (ADR 0016), not in LiveViews.
- `eligibility(user)` returns `:ok` or
  `{:error, :not_active | :bot | :totp_required | {:totp_too_new, days_left}}`.
- `request_export(user, session, reauth_result)` checks eligibility, a DB-counted cap of 2 requests
  per 7 days, and the unique index. It sends the `data_export_requested` notice.
- `cancel_export(user, request_id, reason)`, scoped to the user. It sends `data_export_cancelled`.
- `cancel_active_exports(user, reason)`, called from password change, TOTP reset/disable,
  `ban_user/3`, and sign out everywhere.
- `claim_download(user, request_id)`: an atomic
  `UPDATE … SET download_count = download_count + 1 WHERE id = ? AND user_id = ? AND status = 'ready' AND now() BETWEEN ready_at AND expires_at AND download_count < 3 RETURNING *`.
  Status becomes `completed` at 3.
- `list_export_history(user)`, and an admin-only `list_export_requests/1`.
- Status transitions: a periodic job (or lazy on read) moves `pending → ready` and `ready → expired`.
  Send `data_export_ready` when a request becomes ready.
- New always-delivered security notice types: `data_export_requested`, `data_export_ready`,
  `data_export_downloaded`, `data_export_cancelled`.

### 1.3 Archive builder: `Baudrate.DataPortability.Archive`

- Build under the single instance-wide slot: `pg_try_advisory_lock(<constant>)`. Busy means "try
  again in a minute", with no queueing.
- Output is a `0600` file in `System.tmp_dir!()` (the unit has `PrivateTmp=true`; verify it is
  writable under `ProtectSystem=strict`). **Never** under `priv/static` or `shared/uploads`.
- Hard limits: build timeout (e.g. 120 s) and archive size cap (e.g. 500 MB). Abort and delete on
  breach.
- `Application.start` / boot: sweep leftover export temp files.
- Entries use the `:zip` module with stored or deflated entries. Entry names come from record ids
  (`articles/123.json`, `media/article_images/456.webp`), never titles or client filenames.
- Layout (JSON only, no CSV, no HTML viewer):
  ```
  README.txt           — what is included / excluded (translated), export timestamp
  profile.json         — username, display name, bio, signature, profile_fields, locales,
                         dm_access, notification preferences, role, created_at,
                         totp_enabled (bool), security_keys: [{label, added, last_used}]
  articles.json        — own, live, in currently viewable boards (+ board-less), incl. own
                         revisions and polls; own self-deleted flagged (deleted_by_id == user)
  comments.json        — own live comments; parent/article as URI only
  feed_replies.json    — own feed item replies; target feed item as URI only
  interactions.json    — likes, boosts (article/comment/feed item), poll votes, bookmarks: target URI only
  relationships.json   — following (local usernames / remote AP URIs + state),
                         followers (local via user_follows.followed_user_id, remote via
                         followers.actor_uri == the user's actor URI — no user_id column),
                         blocks, mutes
  messages.json        — conversations: counterpart handle only; messages SENT by the user only
  invites.json         — codes created: used/revoked/expired status + dates; active code values
                         masked; invitee identities omitted
  media/               — avatar (all sizes), article_images, comment_images,
                         feed_item_reply_images owned by the user
  ```
- **Excluded** (ADR 0023 §10): secrets, session IPs/UAs, notifications, reports about the user,
  moderation log, login_attempts, others' revisions, reading history (`article_reads`,
  `board_reads`, read cursors), moderator-removed content, content in boards the user can no
  longer view, `ap_private_key_encrypted`, push subscriptions.

### 1.4 Serializers: allow-list only

- One module per data type with an explicit field list. Never `Map.from_struct`, never
  `Jason.encode!(schema)`.
- Visibility rule: use the viewer-gated `Content.*_by_user` queries with `viewer: user` (the same
  predicate as `BaudrateWeb.ArticleHelpers.user_can_view_article?/2`; move it into the context if
  the export needs it, since the context must not call a web module). Never query by `user_id`
  alone.
- Files: resolve `storage_path` / avatar paths with `Path.expand`, require the result to sit under
  `Application.app_dir(:baudrate, "priv/static/uploads")` after following symlinks (`File.lstat`
  each segment, or compare `:file.read_link_all` results), and require a regular file. Anything
  else is skipped and logged.

### 1.5 Web: `DataExportLive` + `ExportController`

- `/profile/export` in the `:authenticated` live_session:
  - Eligibility explanation. For users without qualifying TOTP it links to TOTP setup and shows
    days left.
  - "Request export": step-up form. On success it shows the pending state and the ready time.
  - "Cancel" and "Cancel and sign out everywhere" (Phase 0.2).
  - Download: step-up form. On success it signs a single-use token and submits a POST form
    through `phx-trigger-action`.
  - Immutable history table.
  - Server-driven focus and `role="status"` announcements; semantic ids/classes (ADR 0018);
    gettext.
- Global banner in the app layout while a request is `pending` or `ready`. It cannot be
  dismissed, names the requesting browser, and links to cancel.
- `POST /exports/:id/download` (`ExportController`):
  - Token: `Phoenix.Token` salted `"data_export_download"` with
    `%{request_id, user_id, session_token_hash}`, `max_age: 60`, single-use via an ETS nonce set.
    It is bound to the current session.
  - Require `Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document`, `Sec-Fetch-Site: same-origin`.
    Otherwise answer 403.
  - `claim_download/2`, then build, then `send_file` with `Content-Disposition: attachment`,
    `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`. Delete the temp file after the
    send (also on client abort).
  - Send the `data_export_downloaded` notice.
  - Answer 404 for a request that is not found, not the user's, not ready, expired, or exhausted.
    There is no ownership oracle.
- nginx (Ansible template): a `location` for `/exports/` with `proxy_buffering off;`,
  `proxy_max_temp_file_size 0;`, and no cache.
- `config :phoenix, :filter_parameters` adds `"token"` and `"code"` alongside `"password"`.

### 1.6 SysOp release task

- `Baudrate.Release.export_user_data(username, output_dir, operator: "...")` via `bin/baudrate eval`.
- Same archive builder and exclusions. It writes a `0600` file and refuses output directories
  inside any static root or `shared/uploads`.
- Records an `export_requests` row (`status: completed`, `cancel_reason: nil`,
  `requested_session_id: nil`, a note that it was a SysOp export) and a `Logger` line with the
  OS user.
- Document the out-of-band identity verification procedure in `doc/sysop.md`.

### 1.7 Tests (acceptance gates)

- **Canary test.**
  - Seed a user with unique marker strings or bytes in: `hashed_password`, `totp_secret`,
    recovery code hashes, session token hashes, WebAuthn `public_key_cbor`/`credential_id`, push
    `endpoint`/`p256dh`/`auth`, `ap_private_key_encrypted`, an active invite code, a
    `login_attempts.ip_address` from another IP, a session `user_agent`, a DM received from
    another user, a report filed about the user, and a moderator revision.
  - Build an archive and assert that none of the markers appears in any entry, whether raw,
    Base64 or hex.
- Visibility: content in a board the user lost access to is excluded; board-less and currently
  visible content is included.
- Deleted content: moderator-deleted excluded; self-deleted included; `deleted_by_id IS NULL`
  excluded.
- Path confinement: a `storage_path` pointing to `../../env/baudrate.env`, an absolute path
  outside uploads, or a symlink escape is skipped.
- Eligibility: no TOTP, TOTP less than 7 days old, bot, banned → refused. A recovery code never
  authorizes.
- Lifecycle: the 24 h gate; cancel from another session; automatic cancellation on password
  change, TOTP reset, ban, and sign out everywhere; the 48 h expiry; the 3-download cap under
  concurrent claims (two processes, one wins).
- Download endpoint: missing, wrong or expired token; token reuse; token from another session;
  missing or incorrect `Sec-Fetch-*` headers; a different user's request id returns 404.
- Build slot: a concurrent second build is refused. Timeout and size cap abort and delete the
  temp file.
- Notices are always delivered, including when preferences are stored as off.

### 1.8 Docs and i18n

- ADR 0023 is the design record. Update `doc/development.md` (DataPortability context, export
  flow), `doc/sysop.md` (SysOp task, nginx location, identity verification), `CLAUDE.md` (key
  gotchas: canary test gate, no archive at rest, path confinement), and README features.
- zh_TW and ja_JP for all UI text, notices, and `README.txt` in the archive.

---

## Phase 2: Account Migration (ActivityPub Move) — MEDIUM PRIORITY

### 2.1 Migration: add `also_known_as` and `moved_to` to users

File: `priv/repo/migrations/TIMESTAMP_add_also_known_as_and_moved_to_to_users.exs`

```elixir
alter table(:users) do
  add :also_known_as, {:array, :string}, default: []
  add :moved_to, :string
end
```

- `also_known_as` — AP URIs of other accounts this user claims ownership of (bidirectional alias per FEP-7628 / Mastodon convention)
- `moved_to` — AP URI of the account this user migrated to (set after sending Move)
- Add `"moved"` to valid values in user `status_changeset` validation

### 2.2 Include `alsoKnownAs` / `movedTo` in AP actor JSON

File: `lib/baudrate/federation.ex` — `user_actor/1`

- Add `"alsoKnownAs"` field (array of strings from `user.also_known_as`)
- Add `"movedTo"` field (string from `user.moved_to`, only if set)
- These fields are standard AP Person properties used by Mastodon, Pleroma, etc.

### 2.3 Add alias management UI in ProfileLive

File: `lib/baudrate_web/live/profile_live.ex` + template

New "Account Aliases" section:
- List current aliases (AP URIs in `also_known_as`)
- Add alias form: text input for AP URI
- Validation: must be valid HTTPS URI, must be resolvable as AP actor via `ActorResolver.resolve/1`
- Remove alias button per entry
- Explanation text: "Add aliases before migrating. The destination account must also add your Baudrate account as an alias."

### 2.4 Implement outbound Move

File: `lib/baudrate/federation/publisher.ex`

- `build_move_activity(user, target_uri)` — builds AP `Move` activity: `actor` = this user's AP URI, `target` = destination AP URI, `object` = this user's AP URI
- `publish_move(user, target_uri)` — validates bidirectional alias (fetch target actor, verify its `alsoKnownAs` contains this user's AP URI), then enqueues Move to all followers via delivery queue

### 2.5 Post-move account state

After sending Move:
- Set `user.moved_to` to target URI
- Set `user.status` to `"moved"`
- Display "This account has moved to {target}" on user's profile page and AP actor endpoint
- Disable posting (account becomes read-only) — reject article/comment/DM creation for moved users
- Do NOT delete content — existing articles/comments remain accessible

### 2.6 Add "Migrate Account" UI in ProfileLive

New section (below Account Aliases):
1. Instructions: "Set up an alias on your destination instance first"
2. Text input for destination account AP URI
3. "Verify & Migrate" button
4. Backend: verify bidirectional alias, confirm via password re-verification
5. Send Move activity to all followers
6. Display post-migration status banner

> **2.7 (inbound Move `alsoKnownAs` verification) — ✅ completed and shipped.**
> The handler verifies the moving actor appears in the target's `alsoKnownAs`
> (rejecting `{:error, :move_not_authorized}`) and stores aliases on
> `remote_actors.also_known_as`. The *outbound* side still needs `also_known_as`
> on the local **`users`** table — see 2.1.

> **2.8 (migrate feed items on inbound Move) — ✅ completed and shipped.**
> `Federation.migrate_feed_items/2` repoints both `feed_items.remote_actor_id`
> and `feed_items.boosted_by_actor_id`, and the Move handler calls it alongside
> `migrate_user_follows/2`. This was not cosmetic: feed membership is a
> query-time join on `user_follows`, so migrating only the follow made the
> actor's entire published history disappear from its followers' feeds and fail
> `feed_item_accessible?/2` (no like, boost, reply, or forward). The
> `feed_item_replies.remote_actor_id` bullet was mistaken — that table has only
> a local `user_id`. Articles and comments are deliberately *not* repointed:
> they are board content with their own permalinks and `ap_id`s, and remain
> published under the old actor on its own instance.

### 2.9 Notify local followers on inbound Move

When a followed remote actor sends Move:
- Create notification for each local user who followed the old actor
- Notification type: `"actor_moved"` (new type)
- Message: "{old_name} has moved to {new_name}"
- Link to the new actor's profile

### 2.10 Write tests for account migration

- `test/baudrate/federation/move_test.exs` — outbound Move: alias verification, activity building, delivery
- Update `test/baudrate/federation/inbox_handler_test.exs` — inbound Move: alsoKnownAs verification, feed item migration, reject unverified
- `test/baudrate_web/live/profile_live_test.exs` — alias management UI, migrate UI
- Changeset tests for `also_known_as`, `moved_to`, `"moved"` status

### 2.11 Update i18n and documentation

- Add strings for alias management, migration UI, notifications
- Translate to en, zh_TW, ja_JP
- Document Move support in `doc/development.md` federation section
- Update `CLAUDE.md` Key Gotchas if needed

---

## Phase 3: Data Import — LOW PRIORITY

Only practical imports for a BBS. Skip articles/comments/DMs (context is lost across platforms).

### 3.1 Create `DataPortability.Import` module

File: `lib/baudrate/data_portability/import.ex`

Functions:
- `import_following_list(user, csv_content)` — parse Mastodon-format CSV (`account` column with `user@domain`), resolve each via WebFinger, send Follow activities, rate-limited at 10/min
- `import_block_list(user, csv_content)` — parse CSV, create UserBlock records for each entry
- `import_mute_list(user, csv_content)` — parse CSV, create UserMute records
- `import_bookmarks(user, json_content)` — parse JSON array of AP URIs, resolve to local articles if they exist, create bookmarks

Each returns `{:ok, %{imported: N, skipped: M, failed: K}}`.

### 3.2 Implement following list CSV import

Mastodon export format: CSV with `account` column containing `user@domain` handles.

Steps per entry:
1. Parse `user@domain` from CSV row
2. Resolve via `Federation.WebFingerClient.finger/1`
3. Resolve actor via `ActorResolver.resolve/1`
4. Create UserFollow + send Follow activity via `Federation.follow_remote_actor/2`
5. Rate limit: 10 follows per minute (use `Process.sleep` between batches)
6. Skip already-followed actors, log failures

### 3.3 Implement block/mute list CSV import

Same CSV format as Mastodon. For each `user@domain` entry:
- Resolve to local user (if local) or remote actor
- Create UserBlock / UserMute record
- Skip duplicates

### 3.4 Implement bookmark import

JSON array of objects with `ap_id` or `url` fields:
- Resolve AP URI to local article via `Content.get_article_by_ap_id/1`
- Create bookmark if article exists locally
- Skip unresolvable entries

### 3.5 Create `DataImportLive` LiveView

File: `lib/baudrate_web/live/data_import_live.ex` + `.html.heex`
Route: `/profile/import` in the `:authenticated` live_session

UI per import type (following, blocks, mutes, bookmarks):
- File upload input (accept `.csv` or `.json`)
- "Import" button
- Progress indicator (for async following list imports)
- Results summary: "Imported N, skipped M, failed K"
- Max file size: 1 MB

### 3.6 Add routes and rate limiting for import

Router: add to `:authenticated` live_session:
- `live "/profile/import", DataImportLive`

Rate limiting:
- 1 import per hour per type per user
- Password re-verification before import

### 3.7 Security for imports

- Validate all CSV/JSON input at boundaries (malformed input must not crash)
- Follows are rate-limited at the outbound delivery level (existing delivery queue)
- Max file size 1 MB enforced at upload
- Never use `String.to_atom/1` on imported data
- Never put imported data in file paths
- Log import actions in moderation audit log

### 3.8 Write tests for imports

- `test/baudrate/data_portability/import_test.exs` — unit tests for each import function
- Test CSV parsing edge cases (empty, malformed, BOM, encoding)
- Test deduplication (already followed, already blocked)
- LiveView tests for upload and results display

### 3.9 Update i18n and documentation for imports

- Add strings for import UI, result summaries, error messages
- Translate to en, zh_TW, ja_JP
- Document import formats in `doc/development.md`
