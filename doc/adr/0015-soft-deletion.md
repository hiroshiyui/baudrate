# 0015 — Soft deletion via `deleted_at`

- **Status:** Accepted
- **Date:** Recorded retroactively 2026-08-09

## Context

Deletion in a federated forum is not a single event. A moderator removes an
article; the author withdraws a comment; a remote instance sends
`Delete(actor)` that must remove everything that actor ever wrote. Meanwhile
threads reference parents, the moderation log must still explain what was
removed and by whom, and the network needs a `Delete`/`Tombstone` activity that
refers to an object by an `ap_id` we would have thrown away.

Hard deletion also destroys the evidence a moderator needs when a removal is
disputed, and orphans reply chains.

## Decision

Articles, comments and direct messages are **soft-deleted**: a `deleted_at`
timestamp is set and the row stays. Federation emits `Delete` with a
`Tombstone` (including `formerType`) built from the retained `ap_id`.

Consequences that are easy to get wrong, and are therefore rules:

- **Queries must filter `deleted_at`.** `Repo.get/2` does not. Any code path
  that resolves a record from a **client-supplied id** must apply the filter
  itself, in the context — not in the LiveView.
- **Forwarding never resurrects deleted content.**
  `Content.forward_article_to_board/3`, `forward_comment_to_board/3` and
  `forward_feed_item_to_board/3` all return `{:error, :not_found}` when the
  source has a non-nil `deleted_at`, and `FeedLive`'s `submit_reply` refuses
  deleted feed items. The enforcement is in the context because the LiveView
  handlers fetch by a bare `Repo.get/2`.
- `Federation.feed_item_accessible?/2` likewise rejects soft-deleted items.

## Consequences

- Moderation is auditable and reversible; the moderation log's references stay
  resolvable.
- Reply threading survives the removal of an intermediate message.
- The database grows monotonically for these tables; purging is a deliberate,
  separate operation rather than a side effect of deletion.
- Every new read path is a chance to leak deleted content. The rule "filter in
  the context, never trust the caller's id" is the mitigation, and it is a
  standing code-review item.

## Alternatives considered

- **Hard delete.** Rejected: breaks threading, destroys the moderation trail,
  and leaves no `ap_id` to tombstone.
- **Move to an archive table.** Rejected: doubles the query paths and the
  chance of forgetting one, for the same storage cost.
