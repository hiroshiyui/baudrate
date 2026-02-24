# Baudrate — Project TODOs

Audit date: 2026-02-24

---

## Planned Features

### User-Level Outbound Follows

Allow authenticated users to follow remote Fediverse actors from their account,
receiving the actor's public posts in a personal feed.

#### Requirements

1. **Discovery** — extend the existing `/search` page to support remote actor
   lookup. When the query matches `@user@domain` or an actor URL, perform a
   WebFinger lookup + actor fetch and display the result alongside local
   search results.
2. **Follow / Unfollow** — send `Follow` activity to the remote actor's inbox;
   handle `Accept(Follow)` and `Reject(Follow)` responses (currently stub
   handlers in `InboxHandler`).
3. **Undo** — send `Undo(Follow)` when unfollowing.
4. **Following list** — populate the `/ap/users/:username/following` collection
   (currently returns empty `OrderedCollection`).
5. **Personal feed** — display incoming `Create` activities from followed actors
   in a user-facing "Following" feed/timeline.
6. **Inbox routing** — route inbound posts from followed actors to the
   follower's personal feed (distinguish from DMs and board content).

#### Shared Remote Actor Lookup

Both user-level and board-level follows share a common
`Federation.lookup_remote_actor/1` function (WebFinger + actor fetch), but the
**UI entry points are separate** to avoid mixing user and admin contexts:

- `/search` — users discover remote actors to follow personally
- Board moderator panel (e.g., `/admin/boards/:slug/follows`) — moderators
  discover remote actors to follow on behalf of a board

#### Implementation Notes

- New `user_follows` table (user_id, remote_actor_id, state, ap_id)
- `state` tracks follow lifecycle: `pending` → `accepted` / `rejected`
- Wire `Accept(Follow)` and `Reject(Follow)` stub handlers in `InboxHandler`
  to update follow state
- UI: follow button on remote actor profiles, "Following" page listing followed
  actors, personal feed page
- Rate limit outbound follow requests to prevent abuse
- Handle actor migration (`Move` activity) for followed actors

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
