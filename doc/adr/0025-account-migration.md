# 0025 — Account migration (ActivityPub Move) is gated, delayed and reversible

- **Status:** Accepted
- **Date:** 2026-09-14
- **Deciders:** Baudrate maintainers
- **Related:** builds on [0022](0022-step-up-reauthentication-for-second-factor-changes.md) (step-up re-authentication), [0023](0023-data-export-threat-model.md) (data export: cooling-off, eligibility), [0024](0024-totp-codes-are-single-use-with-a-one-period-grace-window.md) (TOTP)

## Context

ActivityPub accounts move with two pieces:

- **Aliases.** The destination actor lists the old account in `alsoKnownAs`.
- **`Move`.** The old account sends `Move { object: old, target: new }` to its
  followers. Each follower's server checks that `target` claims `object` as an
  alias, then unfollows the old account and follows the new one.

Baudrate already accepts inbound `Move` with the alias check (`InboxHandler`,
`Federation.migrate_user_follows/2`, `migrate_feed_items/2`). It cannot send
one, and it does not publish `alsoKnownAs` or `movedTo` for local users.

**A Move is an audience takeover that remote servers cannot undo.** An
attacker who holds a session and the password can point an account at a
remote account they control, add the victim as that account's alias, and one
`Move` sends every follower to them. Remote followers are migrated by their own
servers; nothing Baudrate does afterwards brings them back.

A review of the shipped inbound path also found a bug. `migrate_user_follows/2`
repoints the local `user_follows` row at the new actor and leaves it
`accepted`, but never sends that actor a `Follow`. The new actor's server has no
record of the follower and never delivers to it, so the local user's feed
silently stops receiving anything from the account that moved.

## Decision

### Outbound: moving a local account away

1. **Aliases need step-up re-authentication.** Adding or removing an entry in
   `users.also_known_as` goes through `Auth.verify_reauthentication/5`. Input
   may be `@user@domain` or an actor URI; it is resolved through `ActorResolver`
   (HTTPS, SSRF-guarded) and the actor `id` is stored. Local actors, boards and
   duplicates are refused, with a cap on the number of aliases. Every change
   sends an always-delivered `account_alias_added` / `_removed` notice.
2. **Who may move.** The same gate as data export: an active, non-bot account
   with TOTP enabled for at least 7 days. Admins, moderators and board
   moderators are refused until demoted, so a hijack cannot leave the instance
   without staff. At most one move per account every 30 days.
3. **A request, then a 24-hour cooling-off.** Requesting a move needs step-up
   re-authentication and a target whose `alsoKnownAs` currently claims this
   account. It creates an `account_moves` row (`pending`), sends an
   always-delivered notice, and shows a non-dismissible banner on every page
   with "Cancel". The `Move` is sent 24 hours later by the hourly sweep.
   Password change, TOTP disable or reset, sign out everywhere, and a ban
   cancel it, as they cancel exports.
4. **Everything is re-checked at send time.** Still eligible, target still
   resolvable, still claiming the alias, and not itself moved (`movedTo`). A
   failed check marks the request `failed` and notifies the user. Nothing is
   sent.
5. **Sending.** One signed `Move` to the inboxes of the account's remote
   followers. `users.moved_to` and `moved_at` are set, the actor document gains
   `movedTo`, and the profile shows "This account has moved to …". A
   `account_moved` notice is sent.
6. **Local followers are moved by us.** For each local user following the
   moving account: create a pending follow of the target and deliver `Follow`
   on their behalf, remove the old local follow, and send an `actor_moved`
   notice.
7. **The old account becomes read-only, not disabled.** It can sign in, read,
   follow, export, and manage its security. It cannot create articles,
   comments, feed replies or DMs, like, boost, forward, vote, or generate
   invites. This is enforced at the context boundary, not only in LiveViews.
   Content is never deleted.
8. **The redirect can be removed.** "Remove redirect" (step-up, notice) clears
   `moved_to`, drops `movedTo` from the actor, and restores posting. Followers
   already migrated stay migrated; the 30-day limit still counts the move.
9. **`status` is not overloaded.** Moves use `moved_to` / `moved_at`, not a
   `"moved"` status. Ban, approval and login checks read `status`, and a moved
   account that is later banned must keep both facts.
10. **Local targets are refused.** Moving between two accounts on the same
    instance is not supported.

### Inbound: a followed account moves

11. **Follow the new actor properly.** After the alias check, each local
    follower gets a new pending `Follow` sent to the target (accepted when the
    target answers), the old follow is removed with `Undo(Follow)`, and feed
    items are migrated as today. Each follower gets an `actor_moved` notice
    (a configurable type, not a security notice).
12. **A move to a local account** (the target is a Baudrate user whose
    `also_known_as` claims the remote actor) turns local followers of the
    remote actor into local follows of that user, with the same notice.
13. **Boards are not switched over.** Board follows decide what appears in a
    board, so an inbound `Move` never repoints them. Admins get a notice naming
    the board and the new actor.
14. **Moves are bounded.** A `Move` is ignored when its target has `movedTo`
    set, and at most one `Move` per origin actor is processed every 30 days
    (`remote_actors.moved_to_ap_id`, `moved_at`). Without this, an actor could
    bounce between accounts it controls and make every local follower send a
    stream of `Follow` activities.

## Consequences

- Moving takes at least 24 hours. A user who notices a request they did not
  make has that long to cancel it, change the password, or sign out
  everywhere.
- Staff must be demoted before they can move, and users need a TOTP that is a
  week old. Accounts without TOTP must use an admin-assisted path (not built).
- The old account stays usable for reading and self-management, and the move
  can be undone locally. Remote followers cannot be recalled; the UI says so.
- Local followers of a moved account now actually receive the new account's
  posts, subject to its acceptance.
- `account_moves` is a request record like `export_requests`: no IP, only a
  coarse browser family for the banner.

## Alternatives considered

- **Send the Move immediately (Mastodon).** Rejected: a hijack cannot be
  stopped once confirmed, and its effect on remote followers is permanent.
- **Password only.** Rejected by ADR 0022, and too weak for an irreversible
  audience transfer.
- **A `"moved"` status.** Rejected: it collides with `banned` and `pending`,
  which gate login and approval.
- **Permanent read-only.** Rejected: a user who moved by mistake, or whose
  destination instance disappeared, would be stranded with no path back.
- **Notify local followers only, without refollowing.** Rejected: the follower
  expects a move to carry them over, which is what remote servers do.
- **Repoint board follows on inbound Move.** Rejected: it would let a remote
  actor choose which account feeds a public board.
