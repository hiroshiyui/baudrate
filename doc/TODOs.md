# Baudrate — Project TODOs

Audit date: 2026-02-26

---

## Feature Backlog

Identified via competitive analysis against Discourse, Lemmy, Flarum, NodeBB, and Misskey.

### High Priority — Core Forum Gaps

- [ ] **feat:** Notification system — in-app notification center (bell icon) for replies, mentions, new followers; DB-backed notification schema with read/unread state
- [ ] **feat:** @mention support — `@username` parsing in articles/comments, link to profile, trigger notification; federate as `Mention` tag in AP objects
- [ ] **feat:** Bookmarks / saved posts — users can bookmark articles and comments for later; simple join table, dedicated `/bookmarks` page
- [ ] **feat:** Drafts / autosave — auto-save article and comment drafts (DB-backed or localStorage); restore on revisit
- [ ] **feat:** Polls — inline polls in articles (single-choice, multiple-choice, with optional expiry); federate as `Question` AP object
- [ ] **feat:** Rich link previews (oneboxing) — auto-expand YouTube, GitHub, Wikipedia, etc. links into embedded cards with metadata

### Medium Priority — Moderation & Discovery

- [ ] **mod:** Watched words / auto-filters — admin-configurable keyword lists that auto-flag, auto-censor, or require approval
- [ ] **mod:** Spam detection integration — Akismet or StopForumSpam integration for registration and posting
- [ ] **mod:** Moderator notes on users — private mod-only notes on user profiles for context sharing between moderators
- [ ] **mod:** Similar topic suggestions — when creating an article, show existing articles with similar titles to prevent duplicates
- [ ] **mod:** Advanced search operators — filter by author, date range, board, tag, has:images in search
- [ ] **mod:** Tag management — admin-managed tag taxonomy with synonyms, hierarchy, and per-board required tags
- [ ] **mod:** Slow mode — per-topic reply rate limiting for heated threads
- [ ] **mod:** Split/merge threads — moderator tools to split off-topic replies into new threads or merge duplicate threads

### Medium Priority — Federation

- [ ] **federation:** ActivityPub relay support — connect to relays for wider content distribution across small instances
- [ ] **federation:** User-level instance blocking — users can block entire remote instances from their personal feed
- [ ] **federation:** Emoji reactions via federation — support custom emoji reactions beyond `Like`; interop with Misskey/Firefish
- [ ] **federation:** Account migration (Move) — implement the `Move` activity handler for user portability between instances
- [ ] **federation:** Federated moderation — allow remote moderators to act on boards they moderate

### Lower Priority — Engagement & Platform

- [ ] **feat:** Web Push notifications — push notifications via Web Push API for real-time alerts without visiting the site
- [ ] **feat:** Badges / achievements — milestone-based badges rewarding active contributors (first post, 100 articles, etc.)
- [ ] **feat:** Trust levels / reputation — automated privilege escalation based on user activity (post count, time spent, likes received)
- [ ] **infra:** Outbound webhooks — fire HTTP webhooks on events (article created, user registered, etc.) for Slack/Discord/CI integration
- [ ] **infra:** Public REST API — documented API for third-party client development and integrations
- [ ] **infra:** PWA manifest — make Baudrate installable as a mobile app from the browser
- [ ] **infra:** S3 / CDN object storage — external media storage for horizontal scaling (currently local filesystem only)
- [ ] **infra:** Admin analytics dashboard — DAU/MAU, posts/day, response times, community health metrics
- [ ] **a11y:** RTL language support — right-to-left layout for Arabic/Hebrew communities
- [x] **feat:** Theme engine — admin-configurable DaisyUI themes (35 built-in themes, light/dark selectors in admin settings)
- [ ] **infra:** Plugin / extension system — third-party extensibility API

---

## Implementation Plan: Notification System + Web Push + PWA Manifest

Baudrate currently has no notification system. Users receive no alerts for replies,
mentions, follows, or likes. This plan implements in-app notifications, @mention
parsing, Web Push (VAPID + RFC 8291), and a PWA manifest in 7 phases. Each phase
is independently functional and committable by topic.

### Phase 1: Notification Schema, Context, and PubSub (Foundation)

**Migration:** `priv/repo/migrations/YYYYMMDDHHMMSS_create_notifications.exs`

```
notifications table:
  - type: string, not null (reply_to_article|reply_to_comment|mention|new_follower|
    article_liked|article_forwarded|moderation_report|admin_announcement)
  - read: boolean, default false, not null
  - data: map (JSONB), default %{}, not null
  - user_id: references(:users, on_delete: :delete_all), not null
  - actor_user_id: references(:users, on_delete: :nilify_all), nullable
  - actor_remote_actor_id: references(:remote_actors, on_delete: :nilify_all), nullable
  - article_id: references(:articles, on_delete: :delete_all), nullable
  - comment_id: references(:comments, on_delete: :delete_all), nullable
  - timestamps(type: :utc_datetime)

Indexes:
  - (user_id, read)
  - (user_id, inserted_at)
  - unique (user_id, type, actor_user_id, article_id, comment_id) WHERE actor_user_id IS NOT NULL
  - unique (user_id, type, actor_remote_actor_id, article_id, comment_id) WHERE actor_remote_actor_id IS NOT NULL
```

**New files:**

| File | Purpose |
|------|---------|
| `lib/baudrate/notification/notification.ex` | Ecto schema with `@valid_types`, changeset |
| `lib/baudrate/notification/pubsub.ex` | PubSub helpers: topic `"notifications:user:<id>"`, events `:notification_created`, `:notification_read`, `:notifications_all_read` — follows `Messaging.PubSub` pattern |
| `lib/baudrate/notification.ex` | Context: `create_notification/1`, `unread_count/1`, `list_notifications/2` (paginated), `mark_as_read/1`, `mark_all_as_read/1`, `cleanup_old_notifications/1`, `create_admin_announcement/2` |
| `test/baudrate/notification_test.exs` | Context tests |
| `test/baudrate/notification/pubsub_test.exs` | PubSub tests (async: true, no DB) |

**Key logic in `create_notification/1`:**

- Reject self-notifications (`user_id == actor_user_id`)
- Check `Auth.blocked?/2` and `Auth.muted?/2` — skip if actor is blocked/muted
- On unique constraint violation (dedup index): return `{:ok, :duplicate}` silently
- On success: `PubSub.broadcast_to_user(user_id, :notification_created, %{notification_id: id})`

### Phase 2: @Mention Parsing + Notification Creation Hooks

**Modify `lib/baudrate/content/markdown.ex`:**

- `extract_mentions/1` — regex `@([a-zA-Z0-9_]{3,32})` on raw text, returns unique downcased usernames
- `linkify_mentions/1` — post-sanitize, converts `@username` to `<a href="/users/username" class="mention">@username</a>` (same skip pattern as `linkify_hashtags/1`)
- Add `linkify_mentions/1` to `to_html/1` pipeline after `linkify_hashtags/1`

**Notification hooks — files to modify:**

| File | Hook location | Notification type |
|------|--------------|-------------------|
| `lib/baudrate/content.ex` `create_comment/1` | After PubSub broadcast | `reply_to_article` → article author; `reply_to_comment` → parent comment author; `mention` → each @mentioned user |
| `lib/baudrate/content.ex` `create_article/2` | After PubSub broadcast | `mention` → each @mentioned user |
| `lib/baudrate/content.ex` `create_remote_article_like/1` | After insert | `article_liked` → article author |
| `lib/baudrate/content.ex` `forward_article_to_board/3` | After success | `article_forwarded` → article author |
| `lib/baudrate/federation.ex` `create_local_follow/2` | After insert | `new_follower` → followed user |
| `lib/baudrate/federation/inbox_handler.ex` Follow handler | After follower created | `new_follower` → local user being followed |
| `lib/baudrate/federation/inbox_handler.ex` Like handler | After like created | `article_liked` → article author |
| `lib/baudrate/federation/inbox_handler.ex` Create(Note) as comment | After remote comment | `reply_to_article` → author; `reply_to_comment` → parent author |
| `lib/baudrate/federation/inbox_handler.ex` Flag handler | After report created | `moderation_report` → all admins |
| `lib/baudrate/moderation.ex` `create_report/1` | After insert | `moderation_report` → all admins |

**Helper:** Add `admin_user_ids/0` to `lib/baudrate/setup.ex`.

**Tests:** `test/baudrate/content/markdown_test.exs`, `test/baudrate/notification_hooks_test.exs`

### Phase 3: Real-Time Bell Icon + Unread Count Badge

**New:** `lib/baudrate_web/live/unread_notification_count_hook.ex` — follows `UnreadDmCountHook` pattern exactly.

**Modify `lib/baudrate_web/live/auth_hooks.ex`** — add notification count assign + hook attach in `:require_auth` and `:optional_auth`.

**Modify `lib/baudrate_web/components/layouts.ex`** — add bell icon (`hero-bell`) with `@unread_notification_count` badge in desktop nav and mobile menu. Use `badge-secondary`.

**Tests:** `test/baudrate_web/live/unread_notification_count_hook_test.exs`

### Phase 4: Notifications Page (LiveView)

**Route:** Add `live "/notifications", NotificationsLive` to `:authenticated` live_session.

**New files:**

| File | Purpose |
|------|---------|
| `lib/baudrate_web/live/notifications_live.ex` | LiveView: paginated list, `mark_read`, `mark_all_read`, real-time refresh via PubSub |
| `lib/baudrate_web/live/notifications_live.html.heex` | Per-type icon, actor link, target link, relative time, read/unread styling, pagination |

**Modify `lib/baudrate_web/helpers.ex`** — add `notification_text/1` with gettext per type.

**i18n:** New strings in all 4 gettext files (pot + en + zh_TW + ja_JP).

**Tests:** `test/baudrate_web/live/notifications_live_test.exs`

### Phase 5: Per-Type Notification Preferences

**Migration:** Add `notification_preferences :map DEFAULT '{}'` to users table.

**Modify `lib/baudrate/setup/user.ex`** — add `notification_preferences` field + changeset.

**Modify `lib/baudrate/notification.ex`** — check `in_app` preference before inserting.

**Modify `lib/baudrate_web/live/profile_live.ex` + `.html.heex`** — "Notification Preferences" section with per-type toggle checkboxes (in_app + push columns).

**Tests:** `test/baudrate/notification_preferences_test.exs`, update `test/baudrate_web/live/profile_live_test.exs`

### Phase 6: Web Push (VAPID + Service Worker + Encryption)

**New files:**

| File | Purpose |
|------|---------|
| `lib/baudrate/notification/vapid_vault.ex` | AES-256-GCM for VAPID private key (follows `KeyVault` pattern) |
| `lib/baudrate/notification/vapid.ex` | ECDSA P-256 key generation via `:crypto`, ES256 JWT signing |
| `lib/baudrate/notification/web_push.ex` | RFC 8291 aes128gcm encryption + delivery via `Req` |
| `lib/baudrate/notification/push_subscription.ex` | Ecto schema: endpoint, p256dh, auth, user_agent, user_id |
| `lib/baudrate_web/controllers/push_subscription_controller.ex` | POST/DELETE `/api/push-subscriptions` |
| `assets/js/service_worker.js` | `push` event → `showNotification`, `notificationclick` → `openWindow` |
| `assets/js/push_subscription_hook.js` | LiveView hook: register SW, subscribe PushManager, POST subscription |

**Migration:** `create_push_subscriptions` — user_id, endpoint (unique), p256dh, auth, user_agent.

**Modify existing files:** `config/config.exs` (esbuild service_worker target), `config/test.exs` (disable push), `mix.exs` (aliases), `lib/baudrate_web.ex` (static_paths), `lib/baudrate_web/router.ex` (routes + CSP), `assets/js/app.js` (hook), `lib/baudrate/notification.ex` (`maybe_send_push/1`), admin settings_live (VAPID key management), `root.html.heex` (`data-vapid-key`).

**Tests:** vapid_vault, vapid, web_push, push_subscription schema, push_subscription_controller

### Phase 7: PWA Manifest + Docs

**New:** `priv/static/site.webmanifest` — name "Baudrate", start_url "/", display "standalone".

**Modify `root.html.heex`** — `<link rel="manifest">` + `<meta name="theme-color">`.

**Update docs:** `doc/development.md`, `doc/sysop.md`, `doc/TODOs.md`.

### Verification

After each phase:
```bash
mix compile --warnings-as-errors
for p in 1 2 3 4; do MIX_TEST_PARTITION=$p mix test --partitions 4 --seed 9527 & done; wait
```

Manual for Phase 6-7: register SW in browser, accept push permission, trigger notification, verify push appears.
