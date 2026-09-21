# 0062 — A draft is kept in two places, on purpose

- **Status:** Accepted
- **Date:** 2026-09-22
- **Deciders:** Baudrate maintainers
- **Related:** completes 6A, whose first half is
  [0060](0060-an-edit-is-kept-and-the-history-is-public.md) and
  [0061](0061-an-image-description-is-not-a-form-field.md); the fields a draft
  may hold are bounded by
  [0049](0049-user-facing-changesets-are-allow-lists.md); it is added to the
  export allow-list of [0023](0023-data-export-threat-model.md); the page it
  adds is held to [0057](0057-a-sitemap-invites-only-what-a-guest-sees.md);
  the rule that a limit is counted rather than stamped is
  [0029](0029-sanctions-are-rows-with-an-explicit-end.md)'s, applied to a
  quota instead of a sanction.

## Context

The composer has autosaved to `localStorage` for a long time. It works, it is
the reason nobody has lost a long post to a closed tab, and its two defects
were fixed alongside 6A's first half — the key is now per account, and a
submit the server rejects no longer throws the draft away.

What it cannot do is leave the machine. `localStorage` is scoped to one
browser on one origin, so a post begun on a phone is simply not on the laptop,
and a member who switches devices mid-thought starts again. It also reaches
only inputs that have a `name` attribute, which is the title and the body and
nothing else: the boards, the content warning, the images and the poll are
rebuilt by hand every time.

The obvious move is to put drafts on the server and delete the hook. That is
the decision this record exists to refuse.

## Decision

**Both halves stay, because they fail in opposite directions.**

1. **The browser hook keeps working with no connection**, which is the case
   that actually happens: a train, a lift, a flaky café network. A server
   draft cannot be written at all while the socket is down, and that is
   precisely when somebody is most likely to lose a tab.

2. **The server row follows the member to any device they sign in on**, which
   the hook can never do.

   Keeping both means losing a draft needs both failures at once. Deleting
   either half is a regression that will look like a simplification.

3. **The row holds the whole composer**, not the two fields the hook can
   reach: title, body, content warning, visibility, forwardable, the selected
   boards, the uploaded images and the poll.

4. **A fresh composer restores the most recent draft, and the hook fills only
   what is still empty.** The two cannot fight, because the hook already
   refuses to overwrite a field the server rendered into. Cross-device
   resumption therefore costs the member no action at all.

5. **Three places refuse to restore**, and each is a case where putting text
   in front of somebody is worse than unhelpful: a composer opened from the
   **PWA share target** (the member is posting what they just shared, and an
   old draft would bury it), a composer opened **from a board** (an unrelated
   draft addressed to other boards is a non-sequitur), and a draft that is
   **empty** (the residue of opening the composer and closing it, which put
   back would read as a bug).

6. **A draft is not content.** No `ap_id`, no listing, no feed, no sitemap, no
   federation, and no view for anybody but its owner — not moderators, not
   admins. Publishing is what turns one into an article, and the draft is
   deleted in the same transaction-adjacent breath.

7. **Every read is scoped to the owner in the query**, never fetched and then
   checked, and a draft belonging to somebody else returns exactly what a
   draft that never existed returns. A refusal distinguishable from a miss
   tells a stranger how many drafts an account has.

8. **The cap is 20 and is counted, never stored** —
   `Drafts.quota_remaining/1` is a `COUNT`, following
   `Auth.Invites.invite_quota_remaining/1`. It applies to *creating* a draft
   and never to updating one, so a member at the limit can still type into
   the composer they already have open. They are told, in the composer, that
   the server half has stopped and why.

9. **The orphan image sweep must spare an image a draft is holding.** An
   upload belongs to no article until the post is submitted — which is exactly
   the state a draft preserves — so the 24-hour sweep would otherwise unlink
   the pictures of anything drafted overnight. The draft's own 90-day purge is
   what releases them.

10. **Boards and images are re-checked at resume, not trusted from the row.**
    A board can be deleted, or the member's right to post in it withdrawn, in
    between; an image can have been attached to some other post. Anything that
    fails is dropped silently, because a composer that refuses to submit
    without saying which chip is the problem is worse than one that quietly
    has fewer chips.

## Alternatives rejected

- **Server drafts instead of `localStorage`.** The tidy version, and it makes
  the feature worse exactly when it matters: offline is when a tab gets lost,
  and that is the one case the server cannot cover. Decision 1.
- **A "Save draft" button.** Honest about when the save happened, and it means
  every draft anyone forgets to press it for is not saved. Autosave is what
  the member already has from the hook, and adding a button would make the two
  halves behave differently for no reason.
- **One draft slot per member.** Much simpler — no list, no cap, no id to
  carry through the composer. It also means starting a second post silently
  destroys the first, which is the failure the whole feature exists to
  prevent.
- **A `drafts_count` column on `users`.** Cheaper than a `COUNT`, and it has
  to be maintained by every path that creates or deletes a draft, including
  the hourly purge and the cascade when an account is deleted. It drifts
  silently in both directions the first time one of them is missed.
- **Join tables for a draft's boards and images.** The normalised shape, and
  it buys nothing: a draft is private scratch state, never queried by board or
  by image, and each table would need its own cascade and its own purge.
- **Drafts for the article *edit* composer too.** An unsaved rewrite of a
  published post is worth protecting, and the published text is never at risk
  in the meantime, so it is deferred rather than refused. It needs a draft that
  belongs to an *article* and a rule for what happens when that article is
  edited from elsewhere in between.

## Consequences

- **A member's unfinished writing now sits on the server**, where it did not
  before. It is private to them, excluded from every listing, carried in their
  data export, and removed 90 days after they last touch it — but an operator
  restoring a backup now restores drafts too, and that is worth knowing.
- **The composer does a database write every couple of seconds while somebody
  is typing.** It is debounced server-side and rate-limited
  (`RateLimits.check_draft_save/1`), and it is one `UPDATE` to one row.
- **A draft holds its images alive.** Twenty drafts of four images each is
  eighty files per member that the orphan sweep will not touch, until the
  draft is published, deleted, or purged at 90 days.
- **`test/baudrate/content/draft_test.exs` is the acceptance gate**, with the
  composer and the page in
  [`drafts_live_test.exs`](../../test/baudrate_web/live/drafts_live_test.exs).
  The image half is gated there too, because the failure it guards — a draft
  resumed with its pictures already deleted — is invisible until somebody
  comes back to a post a day later.
