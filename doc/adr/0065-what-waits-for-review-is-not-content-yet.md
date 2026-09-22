# 0065 — What waits for review is not content yet

- **Status:** Accepted; validated against the code on 2026-09-22 by the
  security audit before v1.39.0, which found every decision held and the
  screening wider than decisions 8 and 13 list — remote `source.content`,
  attachment and poll option names, a post's own poll options and image
  descriptions, and posts imported by URL from `/search` are screened too,
  and a published image's description passes the sanction gate.
  `doc/development.md` (Content filters) has the full set.
- **Date:** 2026-09-22
- **Deciders:** Baudrate maintainers
- **Related:** a held post passes every gate a published one must — the
  sanction gate of [0029](0029-sanctions-are-rows-with-an-explicit-end.md) and
  the limits on new accounts of
  [0064](0064-a-new-account-is-slowed-down-not-shut-out.md), whose count of
  posts still up also decides which posts are an account's first; an edit is
  judged by what it adds, [0064](0064-a-new-account-is-slowed-down-not-shut-out.md)'s
  rule for links applied to filters; a rejected submission is kept like a
  removed post's copy (P1-D6) and purged with the rest by
  [0040](0040-retention-deletes-what-nobody-touched.md);
  the orphan image sweep spares a held post's uploads as
  [0062](0062-a-draft-is-kept-in-two-places-on-purpose.md) made it spare a
  draft's; a board moderator reviews only what is wholly inside their boards,
  the rule for a cross-posted article (P1-D5). Third release of Phase 5
  (anti-spam): stages 5C and 5D.

## Context

[0063](0063-the-door-is-defended-by-work-not-by-a-third-party.md) slowed the
door and 0064 slowed the account behind it. Neither lets a moderator see a
post before everyone else does, and neither lets an admin stop a wave that is
already here by what it says — the domain every spam post links to, the word
every one repeats. Phase 5's goal is that an instance with open registration
survives a wave without an admin deleting posts one by one, and that needs
both: a queue in front of new accounts, and filters an admin can write in the
middle of the wave.

Two shapes were obvious and both were wrong.

- **A held post as an article with a `held_at` column.** Nothing chokepoints
  the listings. `Content.Filters.apply_article_hidden_filters/3` returns the
  query untouched for guests, so it cannot host a check, and a new exclusion
  has to be added by hand to board lists, search and `/ap/search`, tag pages,
  the feeds, the sitemap, the outbox, user pages, bookmarks, the timeline
  merge and the unread badges. That is exactly how non-public remote content
  and blocked domains each shipped a leak, and why
  `remote_visibility_test.exs` and `blocked_domain_hiding_test.exs` exist.
- **Filters as regular expressions.** It is what every admin expects, and one
  pattern that backtracks catastrophically hangs every write on the instance.
  The person typing it during a spam wave is the one least placed to notice.

Reading the posting paths turned up four more things:

- **An edit is a second way in.** Articles and, since
  [0060](0060-an-edit-is-kept-and-the-history-is-public.md), comments are
  editable, so a filter applied only at creation is walked round by posting
  clean and editing dirty.
- **Only a composer can hold.** Bots, forwarding and federation create posts
  too, and there is nobody to tell that an RSS item is waiting, or nothing
  here to hold of something another server already published.
- **Remote content arrives by five routes**, not one: a `Create` of a note or
  an article, an `Update`, and an `Announce` whose object is embedded,
  fetched, or carried by a group.
- **A direct message is also text a filter could read**, and that is a
  different question from whether it should.

## Decision

1. **A held post is a row in its own table** (`held_posts`,
   `Baudrate.Moderation.HeldPost`) — not an article or a comment. It has no
   `ap_id` and no slug, and no listing reads the table, so it is in no feed,
   search, sitemap or outbox because it was never content, not because each
   of those remembered to exclude it.
2. **Only a composer can hold.** `Content.submit_article/3` and
   `Content.submit_comment/2` are the one way in and return
   `{:held, %HeldPost{}}`; `create_article/3` and `create_comment/2` refuse
   what a filter blocks and apply every other gate, but never hold.
   `test/baudrate/content/submit_path_test.exs` walks `lib/baudrate_web` and
   fails the build if a LiveView calls the creating functions.
3. **A held post has passed everything a published one must** — the sanction
   gate, a filter's `block`, the link and image limits and a place in the
   hourly bucket. A moderator is never asked to approve what the author could
   not have posted, and holding costs a new account its allowance as posting
   does.
4. **Approval is publication.** `HeldPosts.approve/2` replays creation as the
   author through the same `create_*` functions, so the `ap_id`, federation,
   mentions, notifications and link preview happen when a moderator approves,
   which is when the post publishes. Deleting the held row is the **first
   step of the same transaction**: a second approval finds nothing to delete
   and rolls its whole transaction back, so a post is published once however
   many moderators click. Approval re-checks what can have changed since —
   whether the author may still act (checked first, so the refusal names the
   real reason), each board (one the author can no longer post in is
   dropped; none left refuses), whether the article a comment answers is
   still there and open, and blocks — and does not take another place in the
   author's bucket.
5. **Staff review everything; a board moderator reviews what is wholly
   inside their boards** — an article whose every board they moderate, a
   comment on an article in only boards they moderate — because approving
   publishes into all of them (P1-D5). The scope is part of every query; the
   id comes from the client.
6. **A rejection keeps the text**, for the author on `/drafts` and for staff,
   and is purged 90 days after review. The author may withdraw a pending
   submission and may not erase a rejected one. A pending one is never
   purged: only a moderator decides what happens to it. The orphan image
   sweeps spare the uploads a pending row names.
7. **`hold_first_posts` counts posts still up** (`Trust.count_posts/2`, the
   count trust is earned by), 0 turns it off and is the default, and staff
   and bots are never held. It is independent of the trust thresholds: an
   operator can hold first posts with the limits off, or the reverse.
8. **A filter is a kind and a pattern, never a regular expression**:
   `word` (whole words or a phrase), `substring` (anywhere; `*` for letters
   inside one word) or `domain` (a link's host or any host under it).
   Matching is substring search over words, over text, and a comparison of
   hosts — time proportional to the text, whatever the pattern. Text is
   compared in one normal form (NFKC, format characters removed, lower
   case), the body is matched **as a reader sees it** (rendered, markup
   stripped), and links are resolved as a browser resolves them
   (`extract_urls/2`, 0064), so a fullwidth letter, a zero-width space, an
   entity or an empty tag inside a word does not hide it.
9. **What a filter does depends on where the post came from:**

   | filter | composer | bot, timeline reply | edit | remote |
   |---|---|---|---|---|
   | block | refused | refused | refused | dropped |
   | hold | held | flagged | refused | flagged |
   | flag | flagged | flagged | flagged | flagged |

   A hold degrades to a flag where nothing can be held, except an edit: an
   edit that is merely flagged has already been published, so a filter meant
   to keep something off the site until a moderator has seen it refuses the
   edit instead.
10. **An edit is judged by what it adds.** A filter the stored version
    already matched does not stop its author fixing a typo — so a filter
    written after a post, or a post a moderator approved, stays editable.
11. **A refusal never names the filter or the pattern.** A filter that says
    which word failed is a word-guessing oracle. The member is told the site
    does not allow it and to ask the moderators, who can see which filter
    matched.
12. **Direct messages are never screened**, in either direction, and neither
    is forwarding. A filter reads what no moderator could, and a flag would
    copy a private message to staff without either person in the
    conversation choosing it — a member who wants staff to see a message
    reports it. Forwarding moves words already here, screened where they
    arrived.
13. **Remote content is screened at every route it arrives by** —
    `Create(Note)` that is not a message, `Create` of an article,
    `Update(Note/Article/Page)`, and `handle_announce_object/3`, which the
    embedded, fetched and group-carried paths all end in. A drop answers `:ok`
    like every other refusal in the inbox, so the sender does not retry.
14. **Every match is recorded, and never its text** (`content_filter_matches`:
    the filter, what was done, who, where, whether it was an edit), purged
    after 90 days. `/admin/filters` shows each filter's recent count, which
    is how a filter catching the wrong thing is found. A flag is an ordinary
    report with `content_filter_id` set and the pattern as it stood in
    `reason`; a flagged timeline reply, which has no page here, keeps a copy
    of its text as the report's evidence (P1-D6).

## Alternatives rejected

- **A `held_at` column on `articles` and `comments`.** The Context: every
  listing would have to remember it, and the two that forgot a similar rule
  are why two acceptance gates exist.
- **Holding in `create_article/3`.** Every caller — the bot worker, the
  forwarding path, approval itself — would have to handle a post that did not
  appear, and there is nobody to tell that an RSS item is waiting.
- **Admin-entered regular expressions, with PCRE's `match_limit` as the
  guard.** The limit turns a hang into an error, and then the filter has to
  choose: fail closed and refuse legitimate posts, or fail open and let a
  spammer who crafts a slow input straight past every filter. A matcher that
  is linear by construction has no such choice to make.
- **Holding remote content.** Another server has already published it;
  holding it here would mean deciding later whether something that exists
  exists, and nothing would tell its author.
- **Screening direct messages.** Decision 12.
- **Keeping the matched text with the match.** A blocked post was never
  published, and a table of refused text is a record of what people tried to
  say that nobody agreed to keep.
- **Recording matches in the moderation log.** It records what staff did; a
  wave would bury every human decision under thousands of automatic ones, and
  its entries need an actor.
- **Letting the author delete a rejected submission.** It is the record of
  what was refused, and a moderator may need it when the author disputes the
  decision.
- **Purging pending submissions after a while.** A queue nobody empties is a
  problem to surface, not to hide by deleting what is in it.

## Consequences

- **Approval can fail**, for reasons that arose after the submission — a
  sanction, a lost board, a locked thread, a block — and the queue says which.
  The row stays pending until someone approves or declines it.
- **A wave fills the queue**, one notification per held post to whoever can
  review it, as reports already do. The report queues and the admin menu link
  to it with the count.
- **A post costs one render more when any filter exists**, and nothing when
  none does: the screening returns before rendering when the cache holds no
  filter for that scope.
- **Word filters find nothing in a language written without spaces**, since
  there are no word boundaries to find; the form says to use `substring`
  there.
- **An internationalized domain is written in its `xn--` form**, which is
  what a resolved link carries; the form says so.
- **A composer that lands on `/drafts` after holding** is the one place a
  member sees the submission until it is decided.
- **The acceptance gates** are `test/baudrate/moderation/held_post_test.exs`,
  `test/baudrate/moderation/content_filter_test.exs` (a new way to post goes
  in it, with a refusal and a pass) and
  `test/baudrate/content/submit_path_test.exs`.
