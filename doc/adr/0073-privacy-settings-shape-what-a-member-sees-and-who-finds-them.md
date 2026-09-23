# 0073 — A member's privacy settings shape what they see and who finds them, never what others may read

- **Status:** Accepted
- **Date:** 2026-09-24
- **Deciders:** Baudrate maintainers
- **Related:** extends the per-viewer mutes and blocks
  ([0026](0026-blocks-stop-interaction-locally.md)), the listing filters of
  [0030](0030-domain-blocks-are-rows-and-hiding-is-reversible.md), the content filters'
  matching ([0065](0065-what-waits-for-review-is-not-content-yet.md)), the
  discovery rules of [0057](0057-a-sitemap-invites-only-what-a-guest-sees.md)
  and the follower list of [0070](0070-a-member-hears-about-what-they-chose.md).

## Context

Phase 6E-3 asks for four settings: mute a whole server, mute words, approve
followers manually, and opt out of search and indexing. Each is a setting
about one member — and each has a way of turning into a setting about
somebody else:

- A **domain mute** reuses machinery built for blocks. A block refuses
  interaction both ways; a mute must not.
- **Muting words by removing posts** from listings is the obvious shape, and
  offset pagination makes it wrong: a page shows fewer rows than it should
  and the total counts posts the reader never sees — the mismatch the
  timeline's count has been fixed for three times. Stored text is also not
  in the normal form the admin filters compare in.
- A **follow request** stored as a `followers` row would be a follower to
  every one of the nine places that read that table: `dm_access`, the
  delivery fan-out, the collection, the counts, the federation gate's
  exception, the export.
- **Opting out of discovery** could be read as "hide me", which ADR 0057
  refuses: a profile stays public and linked from every byline.

Building these found two older gaps: the timeline's comment strand applied
no visibility, instance or per-viewer filter to *remote* replies on a
member's threads — so a `followers_only` or `direct` reply from another
server was shown there — and the site search (and `/ap/search`) listed local
**unlisted** articles, which ADR 0057 keeps out of discovery.

## Decision

1. **A muted server is a domain predicate on the per-viewer filters, and
   never refuses an interaction.** `user_domain_mutes` rows; the listings add
   `remote_actors.domain <> ALL(muted)` on the join they already make, and the
   in-memory checks (DM push, notification creation, the conversations list)
   compare the actor's domain. It is not folded into the list of hidden
   accounts: for a large server that would be tens of thousands of ids on
   every query. `blocked_with_author?/2` and `dm_access` read blocks only, so
   replying to or messaging someone on a muted server still works.
2. **Muted words collapse, and never remove.** A matching post stays in its
   list behind "Hidden by your muted words — show", a `<details>` shaped like
   a content warning, so every page count stays right and the reader can
   open it. It is matched by `Baudrate.Moderation.PatternMatcher` — the same
   code, normal form and pattern rule as the admin filters — on the title,
   warning and stripped body, never rendering Markdown. It never names the
   word that matched (the screen may be shared), never folds the member's own
   posts, and never touches direct messages.
3. **A follow request is not a follower anywhere.** It is a `followers` row
   with `accepted_at IS NULL` (or a `pending` `UserFollow`), and every reader
   of either ignores it. No `Accept` is sent until the member approves; a
   repeated `Follow` only moves the row to the newest activity id. Declining
   is removal (`Reject(Follow)`). The one exception is the account's own
   `Delete(Person)` (ADR 0072), which a requester is owed too. **Turning the
   setting off approves everyone waiting**, in the transaction that publishes
   the new `manuallyApprovesFollowers`. Follows an account `Move` carries
   over bypass approval, so a migration never silently becomes requests.
4. **Opting out of discovery is `noindex`, the sitemap and member search —
   the pages stay public.** The profile, the member's articles and their
   feeds ask not to be indexed; the sitemap and the `/search` Users tab leave
   them out; the actor says `discoverable: false`, `indexable: false`.
   Mentions, the message picker and the site's own article search still find
   them: those are someone asking for them, not browsing.
5. **The two settings other servers can see are published** through
   `Federation.update_actor/3`, and **not** through the sanction gate: a
   sanctioned member must still be able to lock their account. The three
   terms are declared in `Federation.Context`.
6. **The comment strand and search are fixed** as every other listing is:
   the strand gets `exclude_unservable_remote/1` and the per-viewer filters
   (page and count), and search leaves out local unlisted articles except
   for their author.

## Alternatives considered

- **Removing muted-word posts in SQL.** Page counts stay right only if the
  count query repeats it, it matches raw stored text in no normal form, and
  it slows every listing for every member who uses it.
- **Folding a muted server into the hidden-account list.** One code path,
  and an unbounded parameter list on every query.
- **A table of follow requests.** A second place a follower relationship
  lives, and a migration between the two on approval; the nullable
  `accepted_at` already existed and was never read.
- **Hiding an undiscoverable member's articles from site search.** Makes the
  setting about what other members may find by asking, which ADR 0057 leaves
  to visibility, not to a discovery switch.

## Consequences

- A member can hide a whole server, or words, from their own views without
  anyone knowing, and still interact with it.
- A folded post is still one click away, and still counted.
- A locked account's followers are only the ones it approved; its posts are
  delivered to nobody else.
- `search_comments` still lists comments on unlisted articles — a smaller
  gap, accepted for now.

## Acceptance gate

`test/baudrate/privacy_settings_test.exs`, with the pages in
`test/baudrate_web/live/privacy_settings_live_test.exs`:

- a muted server is gone from board lists and counts, comments, both
  searches, the timeline (author, booster, total) and notifications, for the
  member only, and comes back on unmuting;
- muted words match as the admin filters do, are validated by their rule,
  and collapse someone else's post but never the member's own;
- a follow request sends no `Accept`, is no follower in any reader, moves to
  the newest `Follow` when repeated, and is approved or declined with the
  right activity; turning approval off approves all and publishes the
  `Update`; a `Move` bypasses it;
- an undiscoverable member is out of the member search and sitemap, still in
  mentions, and says so on the actor;
- the comment strand shows no non-public remote reply, and its count agrees.
