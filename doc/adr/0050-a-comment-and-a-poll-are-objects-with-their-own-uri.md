# 0050 — A comment and a poll are objects with their own URI

- **Status:** Accepted
- **Date:** 2026-09-19
- **Deciders:** Baudrate maintainers
- **Related:** the outbound identity rules in
  [0046](0046-every-identity-claim-is-bound-to-the-host-that-can-prove-it.md)
  (a URI is only honoured from the host that can prove it) and
  [0049](0049-user-facing-changesets-are-allow-lists.md) (`ap_id` is stamped by
  the system, never cast). Both hold here: `legacy_ap_id` is likewise never
  castable, and a remote comment is never served under one of our URIs. Poll
  counts stay bound by [0048](0048-a-poll-records-who-voted-and-nothing-reads-it-back.md).
  First stage of Phase 3 (federation reach).

## Context

Every local comment was stamped
`https://host/ap/users/alice#note-42`, and every local poll
`https://host/ap/articles/some-slug#poll`. Both are fragments.

A fragment never leaves the client. `GET https://host/ap/users/alice#note-42`
puts `GET /ap/users/alice` on the wire, and the server answers with the Person
document; the poll's URI answers with the Article. So the id we published for
an object resolved, reliably and silently, to a **different object**.

Everything that needs to dereference a comment therefore could not:

- **Threading.** A Mastodon user replying to a comment sends
  `inReplyTo: <that comment's id>`. The receiving instance fetches it to place
  the reply. It got an actor back, gave up, and threaded the reply flat under
  the article — for every conversation this instance has ever federated.
- **Voting.** A `Question` embedded in an Article had no `id` at all, so a
  remote client had nothing to address a vote to.
- **Citing.** A `Like`, `Announce`, `Delete` or `Flag` naming a comment named
  something the recipient could not verify.

Nothing was broken *locally*, which is why it survived: the ids are unique,
they round-trip through our own inbox, and every test passed. The failure was
only ever visible from another server.

The thing that makes this expensive is that an `ap_id` is a **public
identity**. Peers store it. ActivityPub has no way to say "this object's id has
changed" — `Move` exists for actors and nothing exists for objects. So
rewriting an id is not a refactor; it abandons every reference a peer holds,
unless something is done about it.

## Decision

**Every object this instance mints is reachable at a path.** Comments become
`/ap/comments/:id` and polls `/ap/polls/:id`, served by
`BaudrateWeb.ActivityPubController` and built by
`Baudrate.Federation.ObjectBuilder`.

1. **New rows are minted at the path.** `Federation.actor_uri/2` grows
   `:comment` and `:poll` clauses, so every URI this instance mints is still
   built in one place. `Comments.comment_ap_id_changeset/1` and the poll
   stamping step in `Articles` use them.

2. **Existing rows are rewritten, and the old id is kept.**
   `Baudrate.Release.backfill_ap_ids/1` moves the fragment id into a new
   `legacy_ap_id` column and writes the path into `ap_id`. Keeping the old
   value is what makes the rewrite safe rather than lossy, and it is
   load-bearing in **both** directions:

   - **Inbound, either id resolves.** `Content.get_comment_by_ap_id/1` and
     `Content.get_poll_by_ap_id/1` match `ap_id` *or* `legacy_ap_id`. These are
     the single lookups every inbound path goes through — seven call sites in
     `InboxHandler` for comments — so a `Like`, `Announce`, `Delete` or
     `inReplyTo` naming the old URI still lands on the right row.
   - **Outbound, a withdrawal names both.** `publish_comment_deleted/2` emits a
     second `Delete` under the legacy id when one is set. A `Delete` of an
     object the receiver has never seen is a no-op, so the duplicate costs one
     delivery job; without it, deleting a pre-rewrite comment would leave it
     standing on every instance that had it.

   `legacy_ap_id` is **matched, never asserted**. The object we serve and every
   activity we mint carry the current `ap_id`. It is an alias we answer to, not
   a claim we make.

3. **A vote may address the article or the poll.** `InboxHandler`'s vote path
   resolves both, because the article URI is what we have always published (and
   what every peer that knows one of our polls learned), while the poll URI is
   what a peer votes against once it has fetched the standalone `Question`.

4. **The embedded `Question` and the standalone one are one object.**
   `ObjectBuilder.question_body/1` builds the body once; the Article embeds it
   and `poll_object/1` wraps it with the `@context`, addressing and `context`
   link a fetched object needs. Both carry the same `id`. The option `replies`
   collections still give `totalItems` and no `items` (0048).

5. **The gate on the new endpoints is the owning article's.**
   `publicly_servable?/1`, unchanged, plus three refusals that belong to the
   comment itself: a **remote** comment is never served (its id lives on
   another host — serving it here is the identity claim 0046 refuses), a
   soft-deleted one is not served (`Repo.get/2` does not filter `deleted_at`),
   and a non-public `visibility` is not served.

6. **The backfill derives its base URL from the running endpoint when there is
   one.** It has to keep a config fallback, because release tasks run with only
   the repo started — but preferring the endpoint removes the possibility of
   the task stamping a host the site does not answer on, which matters far
   more now that it rewrites in bulk rather than healing the occasional nil.

## Alternatives considered

- **Keep the old ids and mint paths only for new rows.** The original
  proposal, and the conservative one: nothing a peer holds is abandoned. It
  leaves every existing conversation permanently unthreadable, which is most of
  the conversations this instance has. Rejected by the operator in favour of
  fixing the whole table, with decision 2 covering the cost.
- **Rewrite without keeping the old id.** One column less, and it silently
  orphans every comment already delivered: an old comment's deletion would
  never propagate, and a remote reply to one would stop resolving. The saving
  is a nullable string.
- **Serve the fragment.** Make `/ap/users/:name` return the Note when a
  `#note-N` fragment is present. It cannot work — the fragment is not sent to
  the server — and it is recorded here because it is the first thing that comes
  to mind.
- **Announce the change with `Move`.** `Move` is defined for actors. There is
  no object equivalent, which is precisely why decision 2 has to carry the
  weight instead.
- **Give the poll the article's URI and a `Question` type.** Mastodon models a
  poll as the status itself. Here a poll is *part of* an article that has its
  own type and its own body, so one URI cannot be both. Hence `context` rather
  than `inReplyTo`: the poll belongs to the article, it is not a reply to it,
  and an `inReplyTo` would render as one.

## Consequences

- Two new unauthenticated endpoints serve stored content, so they carry the
  same gate as `/ap/articles/:slug` and are tested against it directly rather
  than by inspection.
- `legacy_ap_id` is filled only by the backfill and only once. A row created
  after it has none, and the double withdrawal is skipped for those — so the
  extra delivery job drains to zero over time by itself.
- The rewrite has to run on each instance: it is a release task
  (`bin/baudrate eval 'Baudrate.Release.backfill_ap_ids()'`), resumable and
  idempotent, with `dry_run: true` to read the counts first.
- A peer that cached a pre-rewrite comment and never hears from us again keeps
  the old id for ever. That is inherent to changing a public identity, and
  decision 2 bounds it to exactly that case.
- `Federation.Visibility` now owns both directions of the `to`/`cc` mapping
  (`to_addressing/2` next to `from_addressing/1`), because the comment object
  needs the same addressing the publisher builds and two copies would drift.

## Acceptance gate

`test/baudrate/federation/object_identity_test.exs`. It checks the three ways
this could go wrong rather than the happy path alone: that no minted id carries
a fragment, that `/ap/comments/:id` and `/ap/polls/:id` refuse exactly what the
article endpoint refuses (private board, AP-disabled board, soft-deleted,
remote, unknown), and that both ids resolve inbound while a withdrawal names
both. `test/baudrate/release_test.exs` covers the backfill itself — dry run,
rewrite, re-run, and that a remote row is never touched.
