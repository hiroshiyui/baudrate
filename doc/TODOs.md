# Baudrate — Project TODOs

Audit date: 2026-02-24

---

## Planned Features

### User-Level Outbound Follows

Allow authenticated users to follow remote Fediverse actors from their account,
receiving the actor's public posts in a personal feed.

#### Phase 1 — Backend Foundation (DONE)

- [x] `user_follows` table (user_id, remote_actor_id, state, ap_id, accepted_at, rejected_at)
- [x] `UserFollow` schema with state validation (`pending` / `accepted` / `rejected`)
- [x] `Federation.lookup_remote_actor/1` — WebFinger client + actor resolution
- [x] Context CRUD: create, accept, reject, delete, list, count, exists checks
- [x] `Publisher.build_follow/3` and `build_undo_follow/2`
- [x] `Delivery.deliver_follow/3`
- [x] `InboxHandler` — wired `Accept(Follow)` and `Reject(Follow)` handlers
- [x] `following_collection/2` — paginated collection for user actors
- [x] Rate limit: 10 outbound follows per hour per user
- [x] Tests for all new code

#### Phase 2 — Discovery UI (DONE)

- [x] Extend `/search` with remote actor lookup (`@user@domain` and `https://` actor URLs)
- [x] Follow / Unfollow buttons on remote actor card (with rate limiting)
- [x] `/following` management page — list followed actors with state badges, unfollow
- [x] Navigation links in mobile and desktop nav
- [x] i18n translations (en, zh_TW, ja_JP) for all follow-related UI text
- [x] Tests for search remote actor lookup and following management page

#### Phase 3 — Personal Feed (DONE)

- [x] `feed_items` table — stores posts from followed actors that don't land elsewhere
- [x] `FeedItem` schema with activity_type/object_type validation
- [x] `Federation.PubSub` — user-level feed event broadcasting
- [x] Feed item CRUD: create, list (paginated with hidden filter), get, soft-delete, cleanup
- [x] `migrate_user_follows/2` — Move activity support
- [x] Inbox routing fallback — Create(Note/Article/Page) → feed item when no board/reply target
- [x] Delete propagation — soft-deletes feed items on content/actor deletion
- [x] Move activity handler — resolves new actor, migrates follows with dedup
- [x] `/feed` LiveView — paginated personal timeline with real-time updates
- [x] Navigation links in mobile and desktop nav
- [x] i18n translations (en, zh_TW, ja_JP)
- [x] Tests for all new code

#### Phase 4 — Local User Follows (DONE)

- [x] `followed_user_id` column on `user_follows` table (nullable, with check constraint)
- [x] `UserFollow` schema: `belongs_to :followed_user`, validation for exactly one target
- [x] Local follow CRUD: `create_local_follow/2`, `delete_local_follow/2`, `get_local_follow/2`, `local_follows?/2`
- [x] Local follows auto-accept immediately (state = "accepted", no AP delivery)
- [x] `list_user_follows/1` preloads both `:remote_actor` and `:followed_user`
- [x] `following_collection/2` includes local follow URIs
- [x] `list_feed_items/2` includes articles from locally-followed users (union query)
- [x] `/search` — "Users" tab with local user search, follow/unfollow buttons
- [x] `/following` — shows both local and remote follows with appropriate badges
- [x] User profile — follow/unfollow button (with rate limiting)
- [x] `/feed` — renders both remote feed items and local articles
- [x] `local_followers_of_user/1` — for future PubSub integration
- [x] i18n translations (en, zh_TW, ja_JP)
- [x] Tests for all new code

#### Shared Remote Actor Lookup

Both user-level and board-level follows share a common
`Federation.lookup_remote_actor/1` function (WebFinger + actor fetch), but the
**UI entry points are separate** to avoid mixing user and admin contexts:

- `/search` — users discover remote actors to follow personally
- Board moderator panel (e.g., `/admin/boards/:slug/follows`) — moderators
  discover remote actors to follow on behalf of a board

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
- UI in board moderator panel with its own actor search field — uses shared
  `Federation.lookup_remote_actor/1` but separate from `/search`
- Need to handle `Undo(Follow)` on unfollow
