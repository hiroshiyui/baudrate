# 0053 — A group's Announce is a carrier, and the group speaks only for its own host

- **Status:** Accepted
- **Date:** 2026-09-20
- **Deciders:** Baudrate maintainers
- **Related:** the trust rule is
  [0046](0046-every-identity-claim-is-bound-to-the-host-that-can-prove-it.md)
  applied to a relay — a claim about an identity is honoured only from the
  host that can prove it. The content path it reuses is the one
  [0004](0004-federation-gate-for-non-public-boards.md) gates and
  [0030](0030-domain-blocks-are-rows-and-hiding-is-reversible.md) filters.
  Last stage of Phase 3 (federation reach).

## Context

A Lemmy community is not a user who boosts things. It is a **hub**: members
send activities *to* the community, and the community announces them to every
subscriber. So where a Mastodon boost is `Announce` wrapping an **object**, a
Lemmy community's is `Announce` wrapping an **activity** —
`Announce{Create{Page}}`, `Announce{Like}`, `Announce{Delete}`.

`InboxHandler.handle_announce_object/3` accepts an object of type `Note`,
`Article` or `Page` and returns `:ok` for anything else. A wrapped `Create` is
none of those, so **every post in every followed Lemmy community was silently
discarded** — the board followed the community, the Announces arrived, and
nothing appeared. FEP-1b12 describes the pattern; this instance did not
implement it.

The reason this needs a record rather than a patch is the trust question it
opens, which is the sharpest one in the inbox. The HTTP signature on the outer
`Announce` is the **group's**. The inner activity carries no signature that
can be checked. A relay is, by construction, an instance asserting something
about an activity it did not author. Honour that assertion without
qualification and any community on the fediverse can mint a `Delete`, a `Like`
or a `Create` for any actor on any host — precisely the impersonation 0046
exists to refuse, arriving through a door 0046 does not watch.

## Decision

**Unwrap one level, and split by what can be verified.**

1. **A carried `Create` goes to the announced-content path, whatever host its
   actor is on.** A `Create` names an object, and an object has an origin that
   can be checked: `handle_announce_content/4` binds the object's
   `attributedTo` to the object's own host, refuses a local URI, and refuses
   to re-home an article the announcer does not own. So the post arrives
   verified by the host that can prove it, and the group's assertion buys
   nothing it would not have got from a Mastodon boost of the same post.

   This is also the only routing that is *correct*. The post belongs in the
   boards that follow the **group**, not the boards that follow its author —
   whom nobody here need follow at all. `maybe_route_announce_to_boards/3`
   routes on the announcer while attributing the article to `attributedTo`,
   which is exactly the split required.

2. **Every other carried activity is honoured only when its actor is on the
   group's own host.** `Update`, `Delete`, `Like` and `Undo` are activities
   whose entire meaning is "this actor did this". There is nothing to fetch
   and verify, because the claim *is* the actor's. The group's signature
   proves the group's host; when the inner actor is on that host, the same
   instance vouches for both, which is the same trust it already has when it
   delivers its users' activities directly. When the actor is elsewhere, the
   activity is dropped.

   The comparison is `Validator.same_host?/2` — the shared, deliberately
   strict primitive — not a prefix or suffix test.

3. **An honoured activity faces every check it would have faced alone.**
   `Validator.validate_activity/1`'s id-to-actor binding, the local-actor
   refusal, the domain block, the suspension check — then `dispatch/3` with
   **its own** actor, not the group's, so the article is attributed to its
   author and the like is recorded as theirs. The one check that cannot apply
   is `validate_actor_match/2`, and decision 2's host comparison is what
   stands in for it.

4. **Wrapping is bounded to one level.** `Announce` is not a carried type, so
   an `Announce` inside an `Announce` is not unwrapped — otherwise the depth
   is the sender's to choose.

5. **A relay is not a boost.** No `announces` row is written. A community
   relaying its members' posts is not somebody boosting them, and recording it
   as one would show every post in a followed community as a boost.

6. **Only embedded activities are carried.** A bare URI pointing at an
   activity is not fetched and unwrapped. Lemmy embeds, so this costs nothing
   real — and fetching an activity from a host in order to then decide whether
   to trust that host is the same question with an extra request and an
   attacker-chosen URI in it.

## Alternatives considered

- **Trust the group for everything it relays.** What Lemmy-to-Lemmy
  federation effectively does, and it is coherent there because the community
  is the authority on its own content. It is not coherent for a `Delete` of a
  post on a third instance, and the failure is unbounded: one hostile
  community could delete or fake-like anything, anywhere.
- **Refuse every relay whose inner actor is not on the group's host.** The
  conservative reading, and it drops most of Lemmy's traffic: cross-instance
  posting into a community is the normal case, not the exception. Decision 1
  accepts those safely by checking the object instead of the assertion.
- **Fetch each inner activity from its own origin and verify it there.** The
  most rigorous option. Activities are frequently not dereferenceable, so it
  would refuse a great deal of legitimate traffic, and it adds an outbound
  fetch driven by an attacker-chosen URI to the inbox path. Decision 1 gets
  the same guarantee for the case that has an object, which is the case that
  matters.
- **Route a relayed `Create` to boards following the author.** What the
  ordinary `Create` path does, and wrong here: nobody follows the author, they
  follow the community. The post would arrive and land nowhere.

## Consequences

- Posts in followed Lemmy communities appear, attributed to their authors,
  in the boards that follow the community.
- A relayed `Delete` or `Like` from another instance is dropped rather than
  applied. If a Lemmy user on instance A deletes a post in a community on
  instance B, this instance learns of it only if A tells us directly. That is
  the cost of decision 2, and it is the right side to err on.
- The same activity can arrive twice — once relayed, once delivered directly —
  and `inbound_activities` deduplicates per *signing actor*, so both are
  stored and processed. The handlers' existing idempotency (unique `ap_id`) is
  what makes that harmless, and it is now load-bearing rather than incidental.
- `handle_announce_content/4` gains a second caller with different
  provenance. Its origin checks were already the strict ones; that is why it
  could take the new traffic without loosening anything.

## Acceptance gate

`test/baudrate/federation/group_announce_test.exs`. Most of it is refusals,
which is the shape of the risk: a foreign `Delete` leaves the post standing, a
foreign `Like` does not register, an inner activity whose id is on another
host is refused, a local-actor claim is refused, a suspended inner actor and a
blocked inner domain are refused, and an `Announce` inside an `Announce` is
not unwrapped. It also carries a **recorded Lemmy payload**
(`test/support/fixtures/lemmy_announce_create_page.json`) rather than only
hand-built maps, so a field Lemmy actually sends going missing shows up here,
and covers the other direction — a Lemmy user following one of our boards.
Add a carried activity type here with its refusals, not just its happy path.
