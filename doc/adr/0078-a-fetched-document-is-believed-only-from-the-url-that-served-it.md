# 0078 — A fetched document is believed only from the URL that served it, and an embedded one only from its own host

- **Status:** Accepted
- **Date:** 2026-10-30
- **Deciders:** Baudrate maintainers
- **Related:** amends
  [0046](0046-every-identity-claim-is-bound-to-the-host-that-can-prove-it.md),
  whose rule this keeps and whose comparison this tightens; applies it to the
  carrier of [0053](0053-a-group-announce-is-a-carrier.md). Found by the
  2026-10-30 security audit.

## Context

0046 bound every identity claim to "the host that can prove it", and compared
hosts: a fetched actor document was accepted when its `id` was on the host the
URL named. It also rejected comparing full URIs, because instances serve
actors and objects from different paths.

Two things that rule does not cover turned up together.

**A host is not an authority on all of its paths.** Most instances let their
members put bytes on the instance's own origin — uploads, media, static
directories. A JSON file placed there, named by an inbox POST's `keyId`, is
fetched from `victim.example` and says `id: https://victim.example/users/alice`
with the attacker's public key. The host comparison passes; the cached
`remote_actors` row for alice is overwritten; the attacker signs as alice
until the cache expires, and alice's own deliveries fail meanwhile. An open
redirect on the victim's host does the same with no upload: the body then
comes from the attacker's host, but the comparison was against the URL asked
for. Mastodon fixed this class as CVE-2024-23832.

**An embedded object has no host to compare against.** Lemmy inlines the
announced object. The checks on it — attribution on the object's own host, no
local URIs — are self-consistency: a followed actor on `evil.example` can
Announce `{id: "https://mastodon.social/…/1", attributedTo:
"https://mastodon.social/users/alice", content: <anything>}` and every check
passes, because the document is consistent with itself. Nothing bound the body
to the signer, and the signer is on neither host. The result was alice's name
over the attacker's text, under alice's URI, which then made her genuine post
a "duplicate". The group-carrier path (0053) relayed a foreign `Create` the
same way, and its test asserted it.

## Decision

1. **An actor document's `id` must equal the URL its body was finally served
   from, after redirects.** Not the host, not the URL asked for.
   `HTTPClient.get/2` returns that URL as `url:`; `ActorResolver` compares
   against it, scheme and host case-insensitively and the rest as written.
   A `publicKey.owner` naming another actor is refused as well. The only
   request that proves an actor's `id` is a request to that `id`.
2. **A fetched object's `id` is bound to the host of that final URL**, in
   `ObjectResolver` and the Announce fetch. The host comparison stays for
   objects — 0046's reason stands, objects do move between paths — but it is
   made against where the body came from, not where we asked.
3. **An embedded object body is believed only when the booster is on the
   object's own host.** Then the Announce's signature is from the host that
   owns the object. From any other booster the body is discarded and the `id`
   is fetched, exactly as a bare-URI Announce is. The same rule covers a
   group-carried `Create`: the group is believed about its own members' posts
   and fetches everyone else's.
4. **The `keyId` fetch is the one unauthenticated request this instance
   makes, and it is bounded.** The `keyId` is read before any signature can be
   checked, so an unknown key is a GET sent on a stranger's say-so. A cached
   actor costs nothing; a miss is limited per target host and an unresolvable
   `keyId` is remembered for ten minutes.

## Alternatives considered

- **Keep the host comparison and add a path allow-list** (`/users/`, `/u/`,
  `/@`). Rejected: there is no list, and a new implementation's paths would
  arrive as a bug report against the list.
- **Re-fetch the document's own `id` when it differs from the fetched URL**,
  as Mastodon does. Equivalent in outcome and one request dearer; the exact
  comparison is simpler to reason about and the second request would only
  ever help a server that redirects its actor documents, which none does.
- **Trust the embedded body when `attributedTo` is on the object's host.**
  That was the rule, and it is the forgery above: consistency between two
  attacker-written fields proves nothing.
- **Never accept an embedded body.** Rejected: a Lemmy community announcing
  its own members' posts is the common case, and the fetch would be a request
  to the host that just signed the Announce.

## Consequences

- An instance that redirects its actor URL to another path, or serves an
  actor whose `id` is not its own URL, cannot federate with us. Mastodon
  refuses the same.
- A cross-host boost costs one signed GET where it cost none. Mastodon pays
  the same request for the same reason.
- `group_announce_test.exs` now asserts the fetch where it asserted the
  fall-back; the old assertion was the hole.

## Acceptance gate

`test/baudrate/federation/actor_resolver_test.exs` ("actor id /
fetch-origin binding", "resolve_by_key_id/1 is the unauthenticated fetch"),
`test/baudrate/federation/http_client_test.exs` ("reports where the body came
from"), `test/baudrate/federation/group_announce_test.exs` ("an embedded
object is believed only from its own host").
