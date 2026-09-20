# 0057 — A sitemap is an invitation, and it invites only what a guest sees

- **Status:** Accepted
- **Date:** 2026-09-21
- **Deciders:** Baudrate maintainers
- **Related:** discharges the forward reference in
  [0055](0055-unanswered-is-a-river-and-tags-is-a-ranking.md)
  ("an inventory of tags … is `sitemap.xml` in Phase 4B, where an inventory
  belongs"); applies [0056](0056-boring-but-friendly.md)'s fourth question to
  what the instance publishes about itself; shares its predicate with
  [0004](0004-federation-gate-for-non-public-boards.md)'s board gate and the
  syndication feeds ([0041](0041-rss-and-atom-are-syndication.md)).

## Context

Until now this instance said nothing to a crawler. `priv/static/robots.txt` was
the Phoenix generator's stub — five comment lines and no directives — there was
no sitemap, no page named itself canonically, no page described itself in a
sentence, and no page asked not to be indexed. A mistyped username redirected
to `/` with a flash rather than answering 404, which tells a crawler the page
*moved*: it keeps asking, and the home page collects the authority of every
wrong URL.

Adding a sitemap is not a neutral act, which is why it gets a record. Every
other listing on this site answers a person who asked for it — a board page, a
search, a feed someone subscribed to. A sitemap answers nobody: it exists to be
read by machines that will copy what it says, republish it, and keep it long
after the row is gone. **A URL in an index outlives the row it named.** That
makes the question *what goes in it* a privacy decision rather than a
completeness exercise, and it makes every exclusion look, to a later reader,
like an oversight worth "fixing".

## Decision

### 1. One predicate, and it is what a guest already sees

An article is in the inventory when it is **local** (`user_id` not nil), **not
soft-deleted**, **`visibility == "public"`**, and in **at least one board with
`min_role_to_view == "guest"`**. That is the gate the syndication feeds and
`Board.public?/1` already use, written once in `Baudrate.Content.Sitemap`.
Boards and tag pages inherit it: a board is listed when a guest may open it, a
tag when a listed article carries it.

Nothing widens this. A slug here is an existence signal, and unlike a listing
page there is no viewer to scope it to.

### 2. "Unlisted" means unlisted

An unlisted article is left out of the sitemap **and** its page carries
`<meta name="robots" content="noindex, follow">`.

Until now `unlisted` governed ActivityPub addressing only — the article was
listed on its board and carried in the site feed like any other. That is
defensible on this site's own terms, and it is not what the word in the
composer's dropdown says. Leaving it out of the sitemap *alone* would have
promised nothing: a sitemap is an invitation, not a gate, and the board page
links straight to it. `follow` keeps the board reachable; only this page is
held back.

The **syndication feeds are unchanged**. A feed is pulled by someone who asked
for it, which is what a board page is too; the thing being refused here is
being *catalogued*, not being read.

### 3. Member profiles are not enumerated

`/users/:name` stays public, crawlable, and linked from every byline. It is
simply not listed. Nobody opted into a machine-readable member list, and this
is the one surface that exists purely to invite crawlers — 0056's fourth
question ("does being here cost the reader something they did not agree to?").

### 4. Tag pages are enumerated

0055 refused a `/tags` index on the grounds that by use count it ranks topics
and alphabetically it is a sitemap. This is the sitemap. The ordering is
alphabetical, which is exactly the ordering 0055 called useless *as a page* and
correct *as an inventory*.

### 5. `noindex`, not `Disallow`

A page blocked in `robots.txt` can still be indexed from its inbound links —
URL and anchor text, no content — and its `noindex` is never read, because the
crawler never fetches it. Blocking is not the directive that removes a page
from an index.

So `robots.txt` disallows only endpoints meant for machines (`/ap/`, `/api/`,
`/exports/`), and the pages this instance does not want indexed — search, and
the pages of the sign-in flow — stay crawlable and say `noindex` themselves. A
`noindex` page gets **no** canonical link: the two directives contradict, and a
crawler is entitled to act on either.

`robots.txt` is therefore a **route**, not a file: its `Sitemap:` directive
takes an absolute URL, which a file in `priv/static` cannot know for an
arbitrary instance host.

### 6. Every indexable page names itself, once

A self-referencing canonical, including `?page=N` — not collapsed onto page 1,
and no `rel="prev"`/`"next"` (Google has ignored those since 2019, and a
self-canonical is what it and Bing both act on). Every other query parameter is
dropped, so a link decorated with tracking parameters still names the page it
landed on.

The `<meta name="description">` is the `og:description` the page already
computed. **One description per page, not two** — a second assign is a second
thing to keep in step, and the one that drifts is the one nobody looks at.

### 7. A page whose subject does not exist answers 404

Unknown **and banned** accounts, at `/users/:name`, `/users/:name/articles` and
`/@handle`, which must stay indistinguishable from each other. `/@handle`
redirects **301**, since it is a permanent alias for the canonical path.

## Alternatives considered

- **No sitemap at all.** Coherent with 0056 — the site does not chase
  attention — and rejected because this is not about attention. A forum nobody
  can find when they search for the thing it discusses is not boring, it is
  broken, and the reader searching for it is the one who asked.
- **Put member profiles in.** They are already public, so nothing new is
  disclosed by any single URL. Declined on aggregation: enumerating is a
  different act from publishing, and nothing else here publishes the member
  list in a form a script can read in one request.
- **Include unlisted articles, since `unlisted` is an addressing term here.**
  This is what the code did, and it is internally consistent. Declined because
  consistency with an internal model is worth less than keeping the promise the
  interface makes: the member read one English word and chose it.
- **`Disallow: /search` in `robots.txt`.** The intuitive move, and wrong for
  the reason in decision 5. It would also leave the search page eligible for a
  URL-only listing, which is the worst of both.
- **Collapse paginated canonicals onto page 1.** Common advice, and out of date
  since Google dropped `rel=prev/next`; it also hides pages 2..n from the index
  entirely, which is a strange thing to do to a board's older threads.
- **Pre-generate the sitemap on a schedule, or cache it on disk.** Unnecessary
  on one node ([0033](0033-baudrate-runs-on-one-node.md)) at this size: an
  hourly `Cache-Control`, `Last-Modified` with 304s, and a rate-limit bucket
  cover it, and a stale file on disk is a new thing that can be wrong.
- **Keep the redirect for unknown users and add `noindex` to `/`.** Treats the
  symptom. The page genuinely is not there, and 404 is the word for that.

## Consequences

- **The sitemap under-reports on purpose,** in four ways that each look like a
  bug. That is what this record is for: the next person to notice one of them
  has somewhere to read before "fixing" it.
- **A member who chooses Unlisted loses search traffic,** which is what they
  asked for and was not previously true. Articles written before this are
  affected too; nothing is rewritten, because the setting on the row is the
  member's own answer whenever they gave it.
- **`robots.txt` is dynamic,** so an operator cannot edit it without a deploy.
  A settings-backed version is a different decision (does the operator get to
  discourage indexing entirely?) and is not made here.
- **Two more things must stay in step:** a new public page needs a decision
  about `noindex` and a canonical, and a new listing surface needs a decision
  about the sitemap. Both are one module each — `BaudrateWeb.Crawlers` and
  `Baudrate.Content.Sitemap` — rather than a rule scattered across LiveViews.
- **A URL already in an index stays there** until the crawler revisits and sees
  the 404 or the `noindex`. Nothing here is retroactive, and that asymmetry is
  the reason the predicate is conservative.

## Acceptance gate

[`test/baudrate_web/crawler_surface_test.exs`](../../test/baudrate_web/crawler_surface_test.exs)
— the exclusions one by one (a private board, an article only in one, a
soft-deleted article, a remote article, an unlisted article, a tag reachable
only from a private board, and a member profile), that every listed URL is
absolute and answers 200, `noindex` and canonical being mutually exclusive, and
the description on every indexable page.

[`test/baudrate/content/sitemap_test.exs`](../../test/baudrate/content/sitemap_test.exs)
covers the queries directly, including the paging boundary the controller turns
into a 404.

What neither can check is whether a *new* surface should have been in the
inventory. That is the same limit 0054 records for its own gate, and it is a
judgement for review.
