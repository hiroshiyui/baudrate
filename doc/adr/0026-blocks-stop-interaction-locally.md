# 0026 — A block stops interaction in both directions, enforced on this site only

- **Status:** Accepted; the `feed item` functions named below were renamed to `timeline_item_*` by [0039](0039-the-personal-stream-is-a-timeline.md)
- **Date:** 2026-09-14
- **Deciders:** Baudrate maintainers
- **Related:** builds on [0016](0016-authorization-at-the-context-boundary.md) (authorization at the context boundary); follows the pattern of [0025](0025-account-migration.md) (read-only moved accounts)

## Context

Members could block local users and remote actors in the database
(`user_blocks`), but there was no control to do it, and a block did little: it
hid the blocked account's content from the blocker, refused DMs and dropped
notifications. The blocked account could still reply to the blocker's posts,
like, boost and forward them, and follow the blocker. The README promised
"block users to prevent interaction".

Baudrate is a public information hub. Hiding the blocker's public posts from
the blocked account would contradict that, and it would not work anyway: the
posts are readable signed out. What a member needs is that the other account
cannot reach them.

ActivityPub has a `Block` activity. Sending it tells the blocked person's
server, and often the person, about the block. Mastodon sends it; many members
do not want the blocked person to find out.

## Decision

1. **A block refuses new interaction in both directions.** Whoever blocked
   whom, neither account can comment on the other's articles, reply to the
   other's comments, like, boost or forward the other's content, follow the
   other, or send the other a DM. Undoing an earlier like or boost stays
   allowed.
2. **Enforced at the context boundary.** `Auth.blocked_with_author?/2` is
   checked in `Content.create_comment/2`, the like and boost toggles,
   `forward_*_to_board/3`, `Federation.create_local_follow/2`,
   `create_user_follow/2` and the feed item like, boost and reply functions.
   They return `{:error, :blocked}` (forwards `:unauthorized`, like their other
   refusals). A new way to interact must add the same check.
3. **Inbound activities are refused too.** When a local user has blocked a
   remote actor, the inbox refuses that actor's `Follow` of the user
   (`Reject(Follow)`), and drops its `Like`, `Announce` and replies on the
   user's articles and comments, returning `:ok` so the sender does not retry.
4. **Blocking removes follows both ways.** A local block deletes both local
   follows. A remote block deletes the user's follow of the actor with
   `Undo(Follow)` and the actor's follow of the user with `Reject(Follow)`
   (`Federation.sever_remote_follows/2`). Unblocking restores nothing; follows
   must be made again.
5. **No `Block` activity is sent** (decision P1-D1). `Reject(Follow)` is the
   standard way to remove a follower and says nothing about why.
6. **Visibility is unchanged.** The blocker still stops seeing the blocked
   account's content (`hidden_ids/1`); the blocked account can still read the
   blocker's public content.
7. **The refusal message is neutral.** "You cannot interact with this account."
   It does not say who blocked whom.

## Consequences

- The README's promise is true, and it is true for a client speaking the
  protocol directly, not only the web UI.
- A reply from a blocked remote actor to a blocker's article is not stored, so
  other readers of that thread do not see it either. The same applies to a
  local reply, so the rule is the same whichever server the account is on.
- Remote servers still show the blocker's posts to the blocked person, and
  may keep delivering activities that we then drop. Without `Block` this
  cannot be prevented, and public posts are public anyway.
- A blocked person can infer a block from a refused action. That is
  unavoidable once interaction is refused.
- Every new interaction path carries one more check.

## Alternatives considered

- **Send `Block` / `Undo(Block)`.** Rejected (P1-D1): it discloses the block to
  the blocked person's server for little benefit on a public hub.
- **Refuse only in the web UI.** Rejected by ADR 0016: federation and any
  future API would bypass it.
- **One-directional blocks** (only the blocked account is refused). Rejected:
  the blocker could still reply to and mention the blocked account, which
  invites retaliation the blocked account can no longer answer in place, and
  a symmetric rule is simpler to reason about.
- **Accept inbound interactions and only hide them from the blocker**
  (Mastodon's handling of likes). Rejected: the blocked actor's replies would
  still appear under the blocker's posts for everyone else.
