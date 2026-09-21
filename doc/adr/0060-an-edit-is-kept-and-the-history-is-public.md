# 0060 — An edit is kept, and the history is public

- **Status:** Accepted
- **Date:** 2026-09-21
- **Deciders:** Baudrate maintainers
- **Related:** the object identity it publishes under comes from
  [0050](0050-a-comment-and-a-poll-are-objects-with-their-own-uri.md), and the
  decision not to re-send under `legacy_ap_id` is that record's rule applied a
  second time; the activity commits with the change per
  [0034](0034-federation-work-is-committed-before-it-is-acknowledged.md); the outbound gate is
  [0043](0043-the-outbound-federation-gate-and-withdrawals.md), and an edit is
  deliberately on the *gated* side of it; the content warning it snapshots is
  [0052](0052-a-content-warning-is-a-field-not-a-prefix.md); the fields an edit
  may touch are bounded by
  [0049](0049-user-facing-changesets-are-allow-lists.md); the page it adds is
  held to [0057](0057-a-sitemap-invites-only-what-a-guest-sees.md)'s rules
  about what machines are invited to read. First stage of Phase 6 (member
  depth).

## Context

An article has been editable since the beginning, with a revision per edit and
a public history page at `/articles/:slug/history`. A comment has never been
editable at all. That asymmetry is the whole of the problem and none of the
difficulty.

The difficulty is that **an edit rewrites what other people have already
replied to**. Somebody answers "no, that is wrong, the figure is 40%"; the
author changes the figure to 40%; the reply now reads as a non-sequitur and
its author looks like they cannot read. Nothing on the page says this
happened. A forum where that is possible and invisible is one where a
disagreement can be quietly won after the fact, and where nobody can safely
quote anyone.

So the question is not whether to allow editing — refusing it makes every typo
permanent and pushes people into deleting and reposting, which orphans the
replies outright. The question is what an edit leaves behind.

Three further things had to be settled at the same time, because a comment is
not an article:

- **A comment is federated as an object with its own URI** (ADR 0050), and
  some comments still carry the `#note-N` fragment id they were minted with
  before that rewrite. `publish_comment_deleted/2` sends its `Delete` twice,
  once under each id, so peers that know only the old URI still honour the
  withdrawal.
- **A comment has no title**, so a history page for one is thin, and there is
  one per comment rather than one per article.
- **Local comments were unbounded.** `Comment.changeset/2` carried no
  `validate_length` on `:body` at all, where `Article` caps at 64 KB in four
  changesets. Inbound federation was covered by
  `Validator.validate_content_size/1`; the composer on this site was not.
  Revisions copy whole bodies, so editing would have multiplied that.

## Decision

**Every edit writes a revision, and the history is readable by anyone who can
read the thing it belongs to.**

1. **No time limit, and no exceptions.** `comment_revisions` holds the body and
   the content warning *as they stood before* the change, with the editor and a
   timestamp, inserted in the same `Ecto.Multi` as the update. There is no
   grace window inside which an edit goes unrecorded.

2. **The content warning is part of the record** — and
   `article_revisions` gains `summary` and `sensitive` in the same migration,
   closing the same gap on the older table. Removing a warning re-exposes what
   it hid, which makes it the edit most worth recording; snapshotting only the
   body lost it silently. Rows written before this keep NULL: the value is
   unknown, not known to have been absent.

3. **The history is public**, gated only by "can this viewer see the parent
   article?" — the predicate the article page itself uses. A history only the
   author can read tells the person who was replied to nothing, and they are
   exactly who needs it.

4. **The author alone may edit a comment.** Not admins, not board moderators —
   deliberately narrower than `can_edit_article?/2`, which admits an admin.
   Moderation's tool for a comment that has to go is deletion, which staff
   already have; an admin edit would rewrite attributed speech with nothing on
   the page to distinguish it from the author's own words, and would then sit
   inside a public history under that author's name. Enforced at the context
   boundary in `Content.update_comment/3`, not only in the LiveView.

5. **An `Update(Note)` is published under the comment's current `ap_id` and
   nothing else.** No `legacy_ap_id` double-send. A `Delete` can be sent twice
   because a `Delete` of an object the receiver has never seen is a no-op; an
   `Update` is not — it invites the receiver to dereference the id, and a
   `#note-N` fragment resolves to the Person document, which is the precise
   failure ADR 0050 exists to end.

6. **An edit is gated like a publication, not a withdrawal.** No `intent:` is
   passed, so ADR 0043's default applies and a comment in a board that does not
   federate does not start federating because its author fixed a typo.

7. **Inbound edits write no revision.** `handle_update_note/2` rewrites a
   remote comment without a snapshot, as `handle_update_article/2` always has.
   A revision records an act taken *on this instance*; a remote author's
   history belongs to the instance that holds it. The page refuses a remote
   comment outright rather than showing an empty frame.

8. **Two refusals on the history page**, both 404 rather than a redirect
   (ADR 0057): a **soft-deleted** comment, because deletion replaces the body
   with a placeholder while the revisions still hold every earlier draft — and
   serving them would make withdrawing a comment a way of publishing what it
   used to say — and a **remote** comment, per decision 7.

9. **`/comments/:id/history` is `noindex` and names no canonical.** It is one
   thin page per comment. `/articles/:slug/history` stays indexable: that is
   existing public behaviour, and withdrawing it is a separate decision, not a
   side effect of this one.

10. **A local comment body is bounded at 64 KB**, on both changesets, matching
    `Article` and the ceiling inbound federation is already held to.

## Alternatives rejected

- **A grace window with no history** (edit freely for N minutes, record
  nothing). Cheaper, and it is the common pattern. It fails on the case that
  matters: a reply can arrive inside the window, and then what it answered can
  be un-said underneath it with no trace. It also contradicts how articles have
  always worked, leaving two rules for two kinds of writing.
- **History visible to the author and moderators only**, with a bare "edited"
  marker for everyone else. This keeps the record but withholds it from the
  reader who was replied to — the one person whose understanding of the thread
  the edit actually changed.
- **Admin-editable comments**, mirroring articles. Rejected under decision 4:
  editing somebody else's words under their name is impersonation however good
  the intent, and deletion already covers the moderation need.
- **Dual-emitting the `Update` under `legacy_ap_id`.** It is the only way to
  reach a peer that knows a pre-rewrite comment only by its old URI, and it was
  tempting precisely because `Delete` does it. Rejected under decision 5: it
  would re-mint the fragment URI that 0050 retired, and hand a receiver an id
  that dereferences to the wrong object.
- **Storing the diff rather than the snapshot.** Smaller, and wrong: a diff
  chain cannot be read without replaying every link, one corrupt link loses
  everything after it, and the history page has to render arbitrary old states
  anyway.

## Consequences

- **An edit to a pre-ADR-0050 comment never reaches a peer that knows only its
  old URI.** That instance shows the pre-edit text for ever. This is the
  accepted cost of decision 5 and it shrinks on its own as those comments age
  out.
- **Revision rows grow without bound** while their comment lives. They are
  removed only by the cascade when ADR 0040 hard-deletes the comment, 90 days
  after it was soft-deleted. A busy thread's history is small text, and no
  retention pass of its own is added.
- **The history page shows the current text as a version**, which
  `ArticleHistoryLive` does not. Revisions hold the state *before* each change,
  so a list of revisions alone can never show what the most recent edit did.
  The article page still has that gap; it is not fixed here.
- **Editing is offered on a surface that previously had only delete**, so the
  comment action row gains a control and the page gains a `revision_counts`
  query per render. It is one query for the whole page, not one per comment.
- **`test/baudrate/content/comment_revision_test.exs` is the acceptance
  gate**, with the federation half in `publisher_test.exs` (the board gate, and
  that no legacy activity is emitted) and the page in
  `comment_history_live_test.exs`.
