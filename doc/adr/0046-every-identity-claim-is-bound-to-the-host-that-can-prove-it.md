# 0046 — Every identity claim is bound to the host that can prove it

- **Status:** Accepted
- **Date:** 2026-09-19
- **Deciders:** Baudrate maintainers
- **Related:** the admission rules of
  [0003](0003-activitypub-federation.md) and
  [0004](0004-federation-gate-for-non-public-boards.md) decide *whether* an
  activity is allowed in; this decides *whose* it is. Recorded retroactively —
  the rules have been in the code for months, spread over three modules, with
  no record naming them as one decision.

## Context

An ActivityPub document is a bag of URIs supplied by whoever sent it. The
signature proves one thing only: which key signed this request. Everything
else — who wrote the object, where the object lives, which actor the activity
belongs to, where that actor's inbox is — is the sender's claim about someone
else, and a federated instance is asked to believe it.

Believing it is how the interesting attacks work, and they are not variations
on one attack. Each URI in the document is a separate opportunity:

| The claim | Believed without checking |
|---|---|
| a fetched actor document's own `id` | a host serves an actor claiming to *be* `@victim@other.example`, with its own key, and poisons the cached `remote_actors` row — every later signature from the real account fails, and the attacker's succeed |
| an activity's `id` | an activity is minted under another instance's URI namespace |
| a `Create`/`Update` object's `id` | the object squats a URI on a host that did not write it; because `ap_id` is unique, the genuine post later arrives and is dropped as a duplicate |
| a boosted object's `attributedTo` | a followed booster Announces an object claiming a victim wrote it, materialising attacker-chosen content under the victim's name and a chosen `ap_id` |
| an actor's `inbox` / `sharedInbox` | deliveries meant for one instance are addressed to another |
| the Follow named in an `Accept`/`Reject` | Follow ap_ids are minted locally and are not secret, so any verified actor flips a third party's follow |
| an Announce naming a local URI | a remote booster "re-homes" our own private-board article into public listings |

What these have in common is the remedy, and it is one sentence.

## Decision

**A claim about an identity is honoured only when it comes from the host that
could legitimately make it.** In practice: the host of the URI being claimed
must equal the host that is in a position to prove it — the host we fetched
the document from, or the host of the signing actor.

`Validator.same_host?/2` is the one comparison, and it is deliberately strict:
it requires both sides to parse to a non-empty host, so a pair of hostless
URIs is not "the same origin". The surfaces, each with its own refusal reason
so the log says which claim failed: `:actor_id_origin_mismatch`,
`:activity_id_origin_mismatch`, `:object_origin_mismatch`,
`:object_id_origin_mismatch`, `:author_origin_mismatch`,
`:inbox_origin_mismatch`. `doc/development.md` lists where each is applied;
this record is about why they are all the same rule.

Two corollaries that are part of the decision, not incidental:

**A missing claim is not a failed claim.** An Announce whose object has no
`attributedTo` is attributed to the booster — the one actor whose signature we
verified. Refusing it instead would break ordinary Mastodon and Lemmy boosts,
which is how a security rule becomes a bug report and then gets relaxed.

**A local URI from a remote sender is never honoured.** `local_actor?/1`
refuses it outright rather than comparing hosts: there is no case where a
remote instance is the authority on one of our URIs.

## Alternatives considered

- **Trust `json["id"]`, the way the specification's happy path reads.** This
  is the default behaviour of a naive implementation and each row of the table
  above is what it costs.
- **One check at the edge instead of seven.** There is no single edge: an
  actor is fetched, an activity is signed, an object may be embedded or
  fetched later, and an Announce carries someone else's object. The claims
  arrive by different routes and each route has to check its own.
- **Allow a configurable list of hosts that may speak for each other**, for
  instances split across domains. Nobody asked, and it would reintroduce
  precisely the confusion the rule removes.
- **Compare full URI prefixes rather than hosts.** Stricter, and it breaks
  instances that serve actors and objects from different paths, which is
  normal.

## Consequences

- An instance that serves an actor document whose `id` disagrees with its own
  URL cannot federate with us. That is a misconfiguration on their side, and
  the refusal reason names it.
- Every new inbound path that reads a URI out of peer-supplied JSON has to ask
  the same question, and there is no chokepoint that will ask it for them —
  the claims arrive by too many routes. That is the standing cost of this
  decision, and the reason it is written down.
- These checks look like redundant host comparisons to a reader who does not
  know the table above. Before this record they were defended only by comments
  at each call site.
- **One definition, enforced.** Writing this record turned up a second,
  divergent `same_host?/2` private to `InboxHandler` which accepted two
  hostless URIs as same-origin where the Validator's rejects them. It now
  delegates. A security primitive with two definitions is one definition and
  one liability.

## Acceptance gate

`test/baudrate/federation/validator_test.exs`,
`actor_resolver_test.exs`, `object_resolver_test.exs` and `inbound_test.exs`
each cover their own refusals. A new origin check belongs in the test beside
its module, and a new inbound path that reads a peer-supplied URI without one
is the thing to look for in review.
