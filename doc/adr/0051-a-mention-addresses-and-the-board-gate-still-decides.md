# 0051 — A mention addresses, and the board gate still decides

- **Status:** Accepted
- **Date:** 2026-09-20
- **Deciders:** Baudrate maintainers
- **Related:** adds a sixth surface to
  [0043](0043-the-outbound-federation-gate-and-withdrawals.md), which decides
  whether content may leave at all — a surface *of* that gate, never an
  exception to it. Threading is only possible because
  [0050](0050-a-comment-and-a-poll-are-objects-with-their-own-uri.md) gave a
  comment a URI a peer can dereference. Resolution obeys
  [0030](0030-domain-blocks-are-rows-and-hiding-is-reversible.md) decision 9
  (a block stops us reaching out, not only listening) and the SSRF-safe fetch
  path of [0007](0007-single-ssrf-safe-http-client.md). Second stage of
  Phase 3 (federation reach).

## Context

Two things were missing, and they have the same shape: this instance produced
ActivityPub that named nothing a peer could act on.

**A reply was not a reply.** `Publisher.build_create_comment/2` set
`inReplyTo` to the *article* for every comment, including one written as a
reply to another comment. Threading on the receiving side is `inReplyTo` and
nothing else, so a Mastodon user saw every discussion flat, with no
indication of who was answering whom. Until 0050 there was nothing it could
have named — a comment's id was a fragment that dereferenced to the author's
profile — so this was not a regression but a thing that had never worked.

**A mention named the wrong person.** `Content.Markdown`'s mention pattern
matched a bare `@name` and treated `@` as a word boundary, so
`@alice@mastodon.social` matched `@alice` and linkified it to the **local**
`/users/alice`. A member writing to a remote correspondent got a link to
whoever happened to hold that name here, the remote person was told nothing,
and the published object carried no `Mention` tag and no addressing — so the
mention did not exist as far as the fediverse was concerned.

The second one is also where this record has to be careful. A mention is the
only place where a **member**, not an admin and not a board setting, picks an
outbound recipient — by typing. 0043 established that the board is the sole
answer to "may this content leave", at five surfaces. If a mention were a
sixth *exception* rather than a sixth *surface*, then one handle in one post
would send a staff-only article, in full, to any instance on the internet.

## Decision

1. **`inReplyTo` names the parent comment when there is one.**
   `ObjectBuilder.reply_target_uri/2` is the single definition, used by the
   published `Create(Note)`, by the object served at `/ap/comments/:id`, and
   by the `/ap/articles/:slug/replies` collection, so the three cannot
   disagree. A remote parent's own `ap_id` is used as it stands, which threads
   the reply back into the conversation on the instance it started from. A
   parent with no usable id falls back to the article: the right thread at the
   wrong depth beats a URI nobody can resolve.

2. **`@user@domain` is a distinct syntax from `@name`, and the parser knows
   it.** Two patterns, not one with a word-boundary accident:
   `@local_mention_re` refuses a match followed by `@`, and
   `@remote_mention_re` requires a full domain. Local handles keep the 3–32
   rule `Setup.User` enforces; remote ones allow 1–32, because the length rule
   is the other instance's to set. An email address never matches — it has no
   leading `@` and the lookbehind refuses a match that starts mid-word — and
   MDEx's autolinker, which turns the handle into a `mailto:` before
   linkification runs, is undone for exactly that shape and left alone
   otherwise.

3. **The board gate decides, at four points, not three.** `Federation.Mentions`
   is asked for tags, addressing and recipients only after
   `Delivery.article_boards_federated?/1` says the content may leave. That
   covers the `Mention` tag, the `cc`, and the delivery job. The fourth is the
   one that is easy to miss: **the lookup itself**. Resolving an unknown
   handle is an outbound request, so doing it for an article in a private
   board would tell that server a member here typed the handle. Smaller than
   delivering the article, and the same decision governs it.

4. **An unknown handle is resolved when the content is written, and never
   afterwards.** `Mentions.warm/2` runs **before** the write transaction —
   an HTTP call inside one holds a database connection open for the length of
   somebody else's timeout (0034) — and its only effect is to populate
   `remote_actors`. Everything downstream calls `Mentions.known/1`, which only
   reads. So the object served on a later fetch is identical to the one that
   was published, and building it costs one indexed query rather than a
   network round trip.

5. **A handle that does not resolve stays plain text, silently.** No error, no
   flash, no retry. The author sees locally what a peer will see: an
   unlinked handle. This is the documented degradation (P3-D2), not a
   swallowed failure.

6. **The lookup is bounded four ways**, because the handles come from
   attacker-chosen text and each unknown one costs another server two
   requests: `RateLimits.check_mention_resolve/1` (30/hour per user), a cap of
   8 unknown handles per post, a 3-second deadline per lookup, and a
   5-second budget for the whole step. The deadlines are new capability —
   `HTTPClient.get/2` takes a `:timeout` that can only *shorten* the
   configured ceiling — because the federation defaults (30 s per read, 60 s
   whole-request, twice) are sized for a delivery retrying in the background,
   and this runs while a member watches a spinner.

7. **A blocked domain's actor is never addressed**, even if the row is already
   cached. Blocking deletes nothing, so the row exists; addressing it would
   send that instance our content and invite the reply.

8. **Bots do not resolve mentions.** A feed body is not the bot's writing, and
   an RSS item containing an address would make this instance fetch from
   whatever domain it named, on a schedule.

9. **A handle on our own host is a local mention written out in full.**
   `@alice@our.host` folds into the local list, so it notifies `alice` like
   `@alice` does and never federates as a `Mention` of ourselves.

## Alternatives considered

- **Resolve only handles already in `remote_actors`, never fetching.** The
  tightest option, and it was on the table (P3-D2). It means a mention of
  someone this instance has never met silently never works — including the
  first message of every new correspondence, which is exactly when a mention
  matters most. Rejected in favour of decision 6's bounds.
- **Deliver to a mentioned actor regardless of the board**, on the grounds
  that the author addressed them deliberately (the other half of P3-D3).
  Rejected: it makes a member's typing override an admin's board setting, and
  a one-character typo a data leak.
- **Link a remote handle to `https://domain/@user`.** A guess at another
  server's URL scheme — right for Mastodon, wrong for Lemmy and others — and
  it puts an off-site link in every mention. The handle links to this site's
  own search instead, which resolves the actor and offers a follow.
- **Resolve mentions in a background task after the write.** Keeps the post
  fast, and means the *first* post mentioning someone never tags them, which
  is the case that matters. The short deadlines in decision 6 buy the same
  responsiveness without that.
- **Disable MDEx's autolink extension** so handles are never turned into
  `mailto:` links. It would also stop linkifying ordinary URLs, which is a
  feature people use. Undoing the one shape is smaller than losing that.

## Consequences

- Saving a post can now block on the network, for up to about 8 seconds in the
  worst case (the budget plus one in-flight lookup) and typically not at all —
  a known handle costs one indexed query and no request.
- `HTTPClient.get/2`, `ActorResolver.resolve/2` and
  `Discovery.lookup_remote_actor/2` grew an optional `:timeout`. It can only
  shorten, so no caller can use it to hold a connection longer than the
  configured ceiling.
- Every mention surface has to ask the gate. `Publisher.build_create_comment/2`
  did not preload `:boards`, so `article_boards_federated?/1` fell to its
  fail-closed clause and silently dropped every comment mention — caught by
  the gate test, which is the argument for having one.
- `Notification.Hooks` now reads local mentions through `Mentions.extract/1`
  rather than `Markdown.extract_mentions/1`, so the long form notifies too.
- Mentions are *not* rendered as links to a remote profile page, because there
  is no such page here. They link to the local search that resolves the actor.
- That link makes an outbound lookup **one click from any article**, where
  before it needed somebody to type a handle into the search box. The exposure
  is bounded by what was already there: `SearchLive` checks
  `RateLimits.check_search_by_ip/1` (10/min per guest IP) *before* dispatching
  the lookup, the fetch goes through the SSRF-safe, DNS-pinned client, a
  blocked domain is refused, and a resolved actor is cached so repeat clicks
  cost nothing. The domain is attacker-chosen either way — a post can already
  contain any link — so this adds convenience, not reach. Worth re-checking if
  the search page's rate limit is ever loosened.

## Acceptance gate

`test/baudrate/federation/mentions_test.exs`, and a case in
`test/baudrate/federation/publisher_test.exs`'s "withdrawals are never gated by
the board" — the list of outbound surfaces lives there and a sixth one belongs
on it. The gate checks the refusals as well as the happy path: no tag, no
`cc`, no delivery job and **no lookup** for a non-federated board, and no
addressing of a blocked domain's actor. Add a new mention surface to it.
