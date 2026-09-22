# 0064 — A new account is slowed down, not shut out

- **Status:** Accepted
- **Date:** 2026-09-22
- **Deciders:** Baudrate maintainers
- **Related:** trust is decided by the clock and a count, never by a sweep, for
  [0029](0029-sanctions-are-rows-with-an-explicit-end.md)'s reason, and is
  enforced beside that record's gate at the same context functions; bots are
  exempt inside the predicate, as
  [0031](0031-terms-acceptance-is-recorded-and-versioned.md) found they must be
  for the terms; an invite confers nothing, which is the case
  [0063](0063-the-door-is-defended-by-work-not-by-a-third-party.md)'s
  invite-chain ban exists for; editing is a second way in since
  [0060](0060-an-edit-is-kept-and-the-history-is-public.md) made comments
  editable. Second release of Phase 5 (anti-spam): stage 5B.

## Context

ADR 0063 put a price on each registration. It does nothing about what an
account does once it exists, and an account that got through — by paying the
price, by a native client that barely notices it, or by a person paid to click
— can post immediately and at full speed: ten articles every fifteen minutes,
thirty comments every five, each carrying as many links as fit in 64 KB, and a
direct message to every member whose `dm_access` is left at `anyone`.

A spam account wants exactly three things from a forum: links, reach and
volume. A real newcomer needs almost none of them in their first days. The gap
between those two is where a limit can sit without anyone who belongs here
noticing it much.

Reading the posting paths against that turned up two things the plan had not
said:

- **An edit is a second way in, and a new one.** Articles were editable
  already; ADR 0060 made comments editable in v1.35.0. A limit checked only at
  creation is walked round by posting clean and editing dirty thirty seconds
  later. And the article edit page attached an uploaded image to the published
  article **as it landed**, with no check at all — not even ADR 0029's, so it
  was also a way for a silenced member to add pictures to a live post.
- **Counting links by reading `href` as text is bypassable.** A browser
  resolves `//host`, `/\host` and `http:host` (from an `https:` page) off the
  site, and the existing extractor, which looked for an `http(s)://` prefix,
  saw none of them. It also decided "same site" by string prefix, so
  `https://example.org.spam.example/` counted as this site's own.

## Decision

1. **Trust is earned by age *and* posts that are still up, and decided at the
   moment of asking** (`Baudrate.Auth.Trust`). The thresholds are P5-D2's —
   three days and three articles or comments not soft-deleted — held in two
   settings (`new_account_days`, `new_account_posts`, at most 30 and 20) so an
   operator can raise them during a wave; 0 and 0 trusts everyone. Nothing is
   stored. ADR 0029 refuses a background job that lifts a sanction because a
   missed run holds someone past their time; a `trusted` flag flipped by a
   sweep would do that to a member who had already earned their way out. It
   follows that trust can be **lost**: a moderator who removes the three
   warm-up comments takes it back with them.
2. **Bots are exempt inside the predicate's own query**, and admins and
   moderators by role. A bot has no conversation and an RSS item routinely
   carries several links, so a limit that did not exempt them would stop every
   feed the moment it was switched on — ADR 0031's finding, and its answer.
   **An invite confers nothing.**
3. **A reply to a remote timeline item does not count toward trust.** No
   moderator here can remove one, so it cannot be a post "not removed", and an
   account could otherwise earn trust where nobody on this site is looking.
4. **Until trusted, an account may put one external link and one image in a
   post, and post ten times an hour** — articles, comments and timeline
   replies, in **one** bucket. Images are the attached uploads plus any in the
   body.
5. **Every check is at the context boundary, beside ADR 0029's gate.**
   `Auth.check_post/4` runs in `create_article/3`, `update_article/3`,
   `create_comment/2`, `update_comment/3` and `create_timeline_item_reply/4`,
   and the hourly bucket is taken there too — not in the LiveViews, where the
   plan first put per-kind buckets and where a new way to post could forget
   them.
6. **An edit may not add; it never has to remove.** An edit is refused when it
   links somewhere the post did not already link and ends up over the limit,
   or raises the image count over it. A post made before the limits were
   switched on, or one an admin edited, can still have its typo fixed. Edits
   do not take a place in the hourly bucket.
7. **The edit page's image upload is checked where it attaches.**
   `Content.authorize_article_image/2` asks whether the uploader may edit the
   article, whether the account may act at all (ADR 0029) and whether a new
   account would go past its image limit — before the file is processed, and
   again in `add_article_image/3` as it is attached.
8. **Links are counted as a browser resolves them.** The HTML parser NIF gained
   `extract_urls/2`, which joins every `href` to the site's origin with a
   WHATWG URL parser (the `url` crate, already locked by the sanitizer) and
   compares **hosts**; `extract_first_url/2` is now the first of the same list,
   so link previews and the limit cannot disagree about what an external link
   is. The same page linked twice, or with two fragments, is one link.
9. **A new account messages only people who follow it, people who have written
   to it first, and staff** — whatever the recipient's `dm_access` says. An
   unsolicited message is what a spam account sends; a reply is not one, and a
   new member who cannot reach a moderator has nowhere to turn. The
   recipient's own refusal is reported first, so a member is told about the
   limit only when the limit is the reason.
10. **Every refusal names the limit and what is left for this member** — a
    date, a number of posts, or both. A post refused with a shrug is ADR 0029's
    complaint about sanctions, and a new member reads it as the site being
    broken.

## Alternatives rejected

- **A stored `trusted` column, set by a sweep.** Decision 1: a missed run
  restricts someone who has earned their way out, and nothing ever takes the
  flag back when the posts that earned it are removed.
- **Trust conferred by an invite.** An invite is not a vouch; ADR 0063's
  invite-chain ban exists because a chain can be one person.
- **Per-kind reduced rate limits in the LiveViews.** The plan's first shape.
  A new posting path has to remember them, and an account gains a fresh
  allowance by switching from articles to comments.
- **No links at all for a new account.** Stricter than the problem: a real
  newcomer answering a question often has exactly one source to cite.
- **Making an edit fit the limit.** It would trap every post made before the
  limits existed — a member could not fix a typo without deleting a link.
- **Hiding a new account's posts, or showing them only to itself.** A
  shadow-ban lies to the member and to moderators alike. Holding posts for
  review is 5C, an explicit opt-in with its own queue.
- **Counting timeline replies toward trust.** Decision 3.

## Consequences

- **It is a delay, not a wall.** A patient spammer waits three days and posts
  three harmless comments. What the limit takes away is the first three days
  of a wave — the part that arrives before anyone has looked — and removing
  the warm-up posts undoes the trust they bought.
- **The "Followers only" DM setting now admits followers on this instance.**
  It asked the `followers` table, which holds only *remote* followers of local
  actors, so it admitted no local member at all. Decision 9 needed the same
  "does X follow Y" question, which is how this surfaced.
- **An untrusted post renders its Markdown twice**, once to count and once to
  store. A trusted member's post costs one query and nothing else.
- **The test suite runs with the limits off** (`new_account_days: 0,
  new_account_posts: 0` in `config/test.exs`), as it does for the challenge;
  the tests about the limits turn them on.
- **`test/baudrate/auth/trust_test.exs` is the acceptance gate.** A new way to
  post goes in it, with a refusal and a pass.
