# Data Portability — Implementation TODOs

## Phase 1: Data Export (GDPR-style Takeout) — HIGH PRIORITY

Export ZIP structure (ActivityPub-compatible JSON):
```
baudrate-export-{username}-{date}/
  actor.json          — AP Person object (profile, public key)
  outbox.json         — OrderedCollection of Create(Article) activities
  comments.json       — OrderedCollection of Create(Note) activities
  likes.json          — OrderedCollection of Like activities
  boosts.json         — OrderedCollection of Announce activities
  bookmarks.json      — JSON array of {type, ap_id/slug, title}
  following.json      — OrderedCollection of Follow targets (AP URIs)
  followers.json      — OrderedCollection of follower AP URIs
  blocks.json         — JSON array of blocked usernames/AP URIs
  mutes.json          — JSON array of muted usernames/AP URIs
  messages.json       — conversations with messages (only sent by this user)
  media/
    avatars/          — all avatar sizes
    article_images/   — all article images
```

### 1.1 Create `export_jobs` migration

File: `priv/repo/migrations/TIMESTAMP_create_export_jobs.exs`

Columns:
- `id` (bigint PK)
- `user_id` (references users, NOT NULL, on_delete: delete_all)
- `status` (string, NOT NULL, default "pending") — values: pending, processing, completed, failed, expired
- `format` (string, NOT NULL, default "json") — values: json, csv
- `file_path` (string, nullable — set on completion)
- `file_size` (integer, nullable)
- `error_message` (string, nullable)
- `expires_at` (utc_datetime — 7 days after completion)
- `started_at` (utc_datetime, nullable)
- `completed_at` (utc_datetime, nullable)
- `inserted_at` / `updated_at` (timestamps)

Indexes:
- Index on `user_id`
- Partial unique index on `user_id` WHERE `status IN ('pending', 'processing')` to prevent concurrent exports

### 1.2 Create `ExportJob` Ecto schema

File: `lib/baudrate/data_portability/export_job.ex`

- Schema for `export_jobs` table
- `belongs_to :user, Baudrate.Setup.User`
- Fields: status, format, file_path, file_size, error_message, expires_at, started_at, completed_at
- `changeset/2` — validates required [:user_id, :format], validates inclusion of status and format
- `processing_changeset/1` — sets status to "processing", started_at to now
- `completed_changeset/2` — sets status to "completed", file_path, file_size, completed_at, expires_at (now + 7 days)
- `failed_changeset/2` — sets status to "failed", error_message
- `expired_changeset/1` — sets status to "expired", clears file_path

### 1.3 Create `DataPortability` context facade

File: `lib/baudrate/data_portability.ex`

Follow existing pattern in Auth, Content, Federation contexts. Public API:
- `request_export(user, format \\ "json")` — creates ExportJob if no pending/processing export exists; returns `{:ok, job}` or `{:error, :export_in_progress}`
- `get_export(user, id)` — fetches job scoped to user (security: only own exports)
- `list_exports(user)` — lists user's export jobs ordered by inserted_at desc
- `cancel_export(user, id)` — cancels pending export
- `delete_export(job)` — removes file from disk and deletes DB record
- `purge_expired_exports()` — finds completed exports past expires_at, deletes files, marks as expired

### 1.4 Create `DataPortability.Export` module

File: `lib/baudrate/data_portability/export.ex`

Core orchestrator function `generate_export(job)`:
1. Updates job status to "processing"
2. Queries all user data across contexts (batched/streamed for large datasets)
3. Builds JSON files per data type
4. Copies media files
5. Creates ZIP archive in `priv/exports/{user_id}/{job_id}.zip`
6. Updates job with file_path, file_size, completed_at, expires_at
7. Returns `{:ok, job}` or `{:error, reason}`

Per-type query/serialization helpers:
- `export_profile(user)` — builds actor.json from User schema + `Federation.user_actor/1`
- `export_articles(user)` — streams articles with boards, revisions, images, polls; builds Create(Article) activities using Publisher format
- `export_comments(user)` — streams comments (non-deleted) as Create(Note)
- `export_likes(user)` — streams article_likes + comment_likes as Like activities
- `export_boosts(user)` — streams article_boosts + comment_boosts as Announce activities
- `export_bookmarks(user)` — simple list with slugs/AP IDs
- `export_following(user)` — UserFollow records (AP URIs for remote, local usernames)
- `export_followers(user)` — Follower records (AP URIs)
- `export_blocks(user)` — UserBlock records
- `export_mutes(user)` — UserMute records
- `export_messages(user)` — conversations + DirectMessages sent by user only (privacy: exclude other party's messages)
- `export_media(user, dest_dir)` — copies avatar files + article image files

### 1.5 Create `DataPortability.ExportWorker` GenServer

File: `lib/baudrate/data_portability/export_worker.ex`

Follow `DeliveryWorker` pattern:
- Polls every 30 seconds for pending export jobs
- Processes one job at a time (exports are CPU/IO intensive)
- Updates job status on success/failure
- Uses `Task.Supervisor` under `Baudrate.Federation.TaskSupervisor`
- Add to supervision tree in `application.ex`

### 1.6 Add expired export cleanup to `SessionCleaner`

File: `lib/baudrate/auth/session_cleaner.ex`

Add `DataPortability.purge_expired_exports()` call to the periodic `:cleanup` handler. Deletes files from disk and marks jobs as "expired" after 7 days.

### 1.7 Create `DataExportLive` LiveView

File: `lib/baudrate_web/live/data_export_live.ex` + `.html.heex`
Route: `/profile/export` in the `:authenticated` live_session

UI sections:
- "Request Data Export" button (disabled if export already in progress)
- List of past/current exports with status badge, file size, download link, expiry date
- Download link (only for completed, non-expired exports)
- Delete button for completed exports
- Explanation text about what's included in the export

### 1.8 Create `ExportController` for file download

File: `lib/baudrate_web/controllers/export_controller.ex`
Route: `GET /exports/:id/download` (authenticated)

- Validates ownership (current_user == job.user_id)
- Sends file with `send_download/3`
- Sets `Content-Disposition: attachment`
- Returns 404 if job not found, expired, or not completed

### 1.9 Add routes and rate limiting

Router: add to `:authenticated` live_session in `router.ex`:
- `live "/profile/export", DataExportLive`
- `get "/exports/:id/download", ExportController, :download`

Rate limiting: new `:data_export` action in `BaudrateWeb.RateLimits`:
- 1 concurrent export (enforced by DB partial unique index)
- 1 export request per 24 hours per user (via Hammer rate limiter)

### 1.10 Security considerations

- Exports scoped to requesting user only (enforced in all queries)
- Store export files in `priv/exports/` (NOT `priv/static/`) — served via controller after auth check only
- ZIP size cap: 500 MB max
- Password re-verification before requesting export
- Purge exports after 7 days automatically
- Log export requests in moderation audit log for admin visibility

### 1.11 Add i18n strings

All user-visible text wrapped in `gettext()`. Keys needed for:
- Export status labels: pending, processing, completed, failed, expired
- Button labels: "Request Data Export", "Download", "Delete", "Cancel"
- Flash messages: success, error, in-progress
- Description text explaining what's included
- Add translations to en, zh_TW, ja_JP locale files

### 1.12 Write tests

- `test/baudrate/data_portability_test.exs` — context tests for request_export, list_exports, purge
- `test/baudrate/data_portability/export_test.exs` — unit tests for each export_* serializer
- `test/baudrate/data_portability/export_job_test.exs` — changeset tests
- `test/baudrate_web/live/data_export_live_test.exs` — LiveView tests
- `test/baudrate_web/controllers/export_controller_test.exs` — download auth, ownership, 404

### 1.13 Update documentation

- Add DataPortability to context list in `doc/development.md`
- Add to Key Entry Points table in `CLAUDE.md`
- Add `@moduledoc` to all new modules

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

### 2.7 Fix inbound Move handler — add `alsoKnownAs` verification

File: `lib/baudrate/federation/inbox_handler.ex` — existing Move handler

Current code trusts the Move activity without verification. Security fix:
- After resolving target actor via `ActorResolver`, fetch its `alsoKnownAs` field
- Verify that `alsoKnownAs` contains the old actor's AP URI
- Reject Move if verification fails (log warning)
- This prevents unauthorized actor hijacking

### 2.8 Migrate feed items on inbound Move

File: `lib/baudrate/federation/inbox_handler.ex` or `federation.ex`

When processing a verified inbound Move from old_actor to new_actor:
- Update `feed_items.remote_actor_id` from old_actor.id to new_actor.id
- Update `feed_items.boosted_by_actor_id` where applicable
- Update `feed_item_replies.remote_actor_id`
- This ensures the user's feed shows content under the new identity

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
