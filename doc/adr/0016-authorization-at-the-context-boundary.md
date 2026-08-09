# 0016 — Enforce authorization at the context boundary, not in LiveViews

- **Status:** Accepted
- **Date:** Recorded retroactively 2026-08-09

## Context

It is tempting to check permissions where the UI is: hide the button, check in
`mount/3`, act in `handle_event/3`. In LiveView that is unsound. The socket is
long-lived and stateful, so a check performed at mount does not cover an event
sent minutes later after the underlying state changed. Events carry
**client-supplied ids**, so `socket.assigns` is not proof of what the user is
allowed to touch. And the same context functions are reachable from
controllers, the ActivityPub inbox handler, bots and the console — none of
which run the LiveView's checks at all.

Three real defects made the point:

- **DMs.** Authorization was checked when a conversation was started. Blocks
  and `dm_access` changes made afterwards did not apply to subsequent messages.
- **Comment forwarding.** Local comments default to `visibility: "public"`
  regardless of the board's `min_role_to_view`, so a visibility check alone let
  a user guess a comment id in a private board and exfiltrate its body into a
  public one.
- **Article forwarding.** The check relied on the LiveView's mount-time
  `socket.assigns.article` being view-gated.

## Decision

Authorization is enforced **inside the context function that performs the
operation**, against freshly loaded state, for every operation that can be
triggered by a client-supplied identifier.

- `Messaging.create_message/3` enforces block / `dm_access` on **every**
  message and returns `{:error, :not_allowed}`.
- `Content.forward_comment_to_board/3` checks that the actor can view the
  comment's **source board** (`Interactions.article_visible_to_user?/2`)
  *before* the `comment.visibility` gate, and returns `{:error, :unauthorized}`.
- `Content.forward_article_to_board/3` carries the same gate at the context
  boundary.
- `Federation.feed_item_accessible?/2` gates every feed-item entry point (like,
  boost, reply, forward). `feed_items` rows are **global** — membership is a
  query-time join on `user_follows`, not a per-user column — so an id alone
  proves nothing. The source actor is `boosted_by_actor_id` for an `Announce`
  and `remote_actor_id` for a `Create`; using `remote_actor_id` unconditionally
  breaks boosts, because for an `Announce` it holds the original author, whom
  the local user need not follow.

LiveView-level checks remain, but only as **UX** — hiding an action the user
cannot perform. They are never the enforcement point.

## Consequences

- The same rule applies to every caller, including the federation inbox.
- Some checks are performed twice (UI and context). That redundancy is
  intentional and cheap.
- Reviewing a new mutation means asking one question: *does the context
  function re-verify authorization against freshly loaded state?*

## Alternatives considered

- **A policy layer / plug-style authorization in the web tier.** Rejected: the
  inbox handler and bots do not pass through the web tier, and per-object
  decisions need the object anyway.
