# 0081 — A syndicated article shows its lead and sends readers to the source

- **Status:** Accepted
- **Date:** 2026-11-01
- **Deciders:** Baudrate maintainers
- **Related:** [0041](0041-rss-and-atom-are-syndication.md) (what a feed bot
  posts), [0056](0056-boring-but-friendly.md) (the kind of place this is).

## Context

A feed bot posts each RSS/Atom entry as an article, body and all. Many feeds
carry the whole story, so its page here was a complete copy: a reader had no
reason to follow "View original", and the site that wrote it lost the visit,
the advertising that pays for the writing, and whatever else it offers its
readers. Syndication that only takes is a poor neighbour, and a public
information hub depends on the sources staying in business.

## Decision

**The page of a syndicated article shows its first paragraph and collapses
the rest, with a link to read it at the source.**

1. Every article by a feed bot (`users.is_bot`) is treated this way; there is
   no per-bot setting. A feed that sends only a summary has nothing to
   collapse.
2. The lead is the body up to and including the first paragraph with text of
   its own outside links (`HtmlParser.Native.split_lead/1`), so a leading
   image, heading or line of tag links stays with it. The split runs on the
   rendered, sanitized HTML (`SafeHTML.markdown_lead/1`).
3. The rest is **collapsed, not removed**: a native `<details>` ("Show the
   rest"), so it stays readable for anyone who needs it, keyboard and screen
   reader users included, and crawlers see the same page. Beside it, "Read
   the full article on <site>" links the entry's https URL.
4. **Display only.** The stored body, the federated object and Baudrate's own
   outgoing feeds keep the full text.

## Alternatives considered

- **Store or federate only the excerpt.** Other instances' readers would be
  sent to the source too, but it rewrites what was published and loses text
  for good; a display rule can be changed later, a truncated row cannot.
- **Hide the rest entirely.** The strongest push to the source, and it makes
  the article unreadable here for anyone the source's page fails (paywall,
  tracking, accessibility). A collapsed section costs the source little.
- **A per-bot toggle.** A migration, a form field and a choice for every
  admin, for a difference the feed itself already expresses.

## Consequences

- A syndicated article's page is shorter, and its "read on" link is the
  obvious next step.
- A member's article is never collapsed; the rule is about content this site
  did not write.
- The first-paragraph rule is a heuristic on markup it did not choose: a feed
  that writes paragraphs as `<br>`-separated text has no `<p>` and renders
  whole.

## Acceptance gate

`test/baudrate_web/live/article_live_test.exs` ("syndicated article body"),
`test/baudrate/html_parser/native_test.exs` ("split_lead/1").
