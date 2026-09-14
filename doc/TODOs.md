# Data Portability — Implementation TODOs

## Design reference

Phases 0 and 1 implement [ADR 0023](adr/0023-data-export-threat-model.md). Read it first: every
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
- `Auth.valid_totp?/3` accepts only the current 30-second period, while
  `doc/sysop.md` promises ±30 s clock-skew tolerance. Decide whether to add a
  one-step grace window (with `:since` replay protection) or correct the doc.

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
