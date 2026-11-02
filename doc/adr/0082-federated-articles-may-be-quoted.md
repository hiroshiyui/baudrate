# 0082 — Federated articles may be quoted

- **Status:** Accepted
- **Date:** 2026-11-02
- **Deciders:** Baudrate maintainers
- **Related:** [0004](0004-federation-gate-for-non-public-boards.md) (the inbound
  gate), [0026](0026-blocks-stop-interaction-locally.md) (blocks),
  [0030](0030-domain-blocks-are-rows-and-hiding-is-reversible.md) (domain blocks),
  [0034](0034-federation-work-is-committed-before-it-is-acknowledged.md) (durable publishing),
  [0043](0043-the-outbound-federation-gate-and-withdrawals.md) (the outbound gate),
  [0046](0046-every-identity-claim-is-bound-to-the-host-that-can-prove-it.md)
  (origin), [0050](0050-a-comment-and-a-poll-are-objects-with-their-own-uri.md)
  (objects at paths).

## Context

Mastodon 4.5 lets people quote posts, following FEP-044f. It quotes a remote
post only when the post's object says who may quote it
(`interactionPolicy.canQuote`). It reads a missing policy as "nobody", so
Mastodon users could not quote Baudrate articles at all.

Saying that quoting is allowed is not enough. Each quote is approved by the
quoted author's server: the quoting server sends a `QuoteRequest` (`object` is
our article, `instrument` its post), and the quote stays pending until it
receives an `Accept` whose `result` names a `QuoteAuthorization` stamp. Other
servers that see the quote fetch the stamp and check that its `attributedTo`,
`interactionTarget` and `interactingObject` equal the quoted author, the
quoted post and the quoting post.

A public information hub wants its articles cited, and a quote is a citation
that links back.

## Decision

**A local article that may federate can be quoted by anyone, and the approval
is automatic.**

1. **The policy follows the outbound gate.** A local, undeleted article with a
   federated board (`Delivery.article_boards_federated?/1`, ADR 0043), by an
   author who has not deleted their account (`Quotes.quotable?/1`), carries
   `interactionPolicy: {canQuote: {automaticApproval: [as:Public]}}`. No
   other article carries a policy, so the policy never invites a request we
   would refuse. The terms are declared in `Federation.Context` the way
   Mastodon declares them (GoToSocial's `gts:` vocabulary, FEP-044f's types).
2. **Answering a request.** `InboxHandler` handles `QuoteRequest`:
   - An article that is not ours, does not federate, or is deleted is
     **dropped without an answer**, like other refusals (ADR 0004). A `Reject`
     would confirm that a private board's slug exists.
   - The quoting post must be an https URI **on the signer's host** (ADR 0046).
     A server may ask approval only for its own posts.
   - An actor the author has blocked (ADR 0026), or a request to quote a
     deleted account's article, gets a `Reject(QuoteRequest)` so the quoting
     server stops waiting.
   - Otherwise a `quote_authorizations` row is stored and the `Accept` is
     enqueued **in one transaction** (`Federation.federate/2`, ADR 0034). The
     Accept is signed by the **article's author**, because the quoting server
     accepts it only from the quoted post's author. A repeated request for the
     same post reuses its row, so the stamp URI never changes under a quote
     that already cites it.
3. **The stamp is an object at a path**, `/ap/quote_authorizations/:id`
   (ADR 0050), served by `ActivityPubController.quote_authorization/2`.
4. **A stamp lasts only as long as the article may be quoted.** It is served
   only while its article is `quotable?/1` and the quoting actor is not hidden
   by a domain block or a suspension (ADR 0030). When an article is deleted,
   its board stops federating, or its author deletes their account, every
   stamp stops being served. Nothing is sent. A `Delete` of the quoting post
   from its own host removes the stamp row; rows go with their article or
   remote actor by foreign key.

## Alternatives considered

- **Manual approval, per author or per board.** Puts every quote through the
  author's review (`manualApproval`): a moderation queue, a notification type
  and a settings page, for content that is public anyway. Quoting does not
  change who can read the article. Automatic approval can still be narrowed
  later without changing the stamp format.
- **Allowing quotes without stamps.** Not an option. Mastodon keeps an
  unapproved quote pending forever.
- **Sending `Delete` for each stamp when an article is withdrawn.** Quoting
  servers already receive the article's own `Delete`, and stamps stop being
  served. A delivery per stamp would add traffic without changing what a
  reader sees.
- **Quotable comments.** Comments federate as `Note`s and could carry the
  same policy. Left for later: the request asked for articles, and a comment
  has a separate visibility gate to apply.

## Consequences

- Mastodon users can quote articles from federated boards. Peers that fetched
  an article before this change keep their copy without a policy until they
  fetch it again or receive an `Update`.
- No local notification yet tells the author that they were quoted.
- A locked article can still be quoted: a lock closes comments here, and a
  quote is a post on another server.

## Acceptance gate

`test/baudrate/federation/quotes_test.exs`.
