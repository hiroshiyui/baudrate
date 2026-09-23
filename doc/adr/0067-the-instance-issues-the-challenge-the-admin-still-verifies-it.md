# 0067 — The instance issues the challenge; the admin still verifies it

- **Status:** Accepted
- **Date:** 2026-09-23
- **Deciders:** Baudrate maintainers
- **Refines** [0058](0058-account-recovery-is-anchored-outside-the-instance.md):
  every decision in it stands, including the one this record was written to
  re-examine — Baudrate parses no OpenPGP, verifies no signature and fetches
  no key. What changes is that the text the member signs is now issued here,
  single-use and expiring, instead of being composed by whoever happened to be
  asking.
- **Related:** the freshness it adds is what
  [0063](0063-the-door-is-defended-by-work-not-by-a-third-party.md)'s
  registration challenge does for a different door, for the same reason (a
  solved challenge must buy exactly one thing); expiry is read from the clock
  as in [0029](0029-sanctions-are-rows-with-an-explicit-end.md); the row is
  spent by one conditional `UPDATE`, the pattern of
  [0023](0023-data-export-threat-model.md)'s download claim.

## Context

0058 put an anchor outside the instance: a member registers an address and an
OpenPGP public key from their own session, and an admin confirms out of band
that a signed message from that address checks out against that key. Baudrate
holds the anchor and records the verdict; every cryptographic check is the
admin's, in their own client.

Reading that procedure against the code turned up two things.

- **The text being signed was nobody's in particular.** At enrolment the
  member sent "a signed message"; at a recovery request, `doc/sysop.md` told
  the admin to generate a nonce with `openssl rand -hex 16` and ask for it
  back. So the strongest check in the whole chapter lived in a paragraph, done
  by hand, by someone under pressure — and a signature over a message the
  member composed **cannot be told from one they signed last year**. Anyone
  who has ever seen one can present it again.
- **Nothing recorded what was asked.** The log said a contact was verified and
  a link was issued. It could not say what the member had been asked to sign,
  so a disputed decision had nothing to point at.

That raised the obvious question of whether Baudrate should verify the
signature itself — a challenge is exactly the shape a machine could check.
Deciding not to is half of this record.

## Decision

1. **Baudrate issues the challenge.** `Recovery.issue_challenge/2` writes a
   `recovery_challenges` row for one contact: a one-line ASCII phrase naming
   the instance, the account and the date, plus 16 random bytes from
   `:crypto.strong_rand_bytes/1`. It lives 72 hours — long enough for a
   locked-out member to read mail, short enough that a phrase found later is
   not still live — and expiry is read from the clock, so nothing sweeps it.
2. **The phrase says what it authorizes**, rather than being a bare token.
   Somebody asked out of the blue to "sign this string" may well do it; the
   same person asked to sign *"account recovery for @alice"* has been told
   what they are agreeing to. It is never translated and never wrapped: it is
   copied out, signed byte for byte and compared by eye on another machine.
3. **Marking a contact verified spends a challenge, and so does issuing a
   reset link.** Both refuse with `:no_live_challenge` when none is waiting.
   The second one matters most: a verification may be months old, so what
   authorizes a link is a signature over something asked for *now*.
   Withdrawing a verification needs no challenge — back to `pending` is the
   safe direction, and a check reachable only by issuing something is a check
   that stalls.
4. **Only the newest row for a contact ever counts**, and only while it is
   unconsumed and unexpired. Re-issuing therefore supersedes without a column
   saying so. Reading "the newest *live* row" instead would resurrect a
   superseded challenge the moment its successor was spent, putting the admin
   back to accepting a phrase they had already told the member to ignore.
5. **Spending is one conditional `UPDATE`.** Two admins acting on the same
   signature spend the same row, and the second is told there is nothing live
   rather than both being waved through.
6. **Rows are never deleted or reused**, and issuing one writes an
   `issue_recovery_challenge` audit entry carrying the phrase. The table is
   the record of what was asked and when it was answered, which is why it is
   not purged: it is evidence, not content.
7. **Baudrate still verifies nothing.** No OpenPGP is parsed, no signature is
   checked, no key is fetched. The instance asks the question; the admin's own
   client answers it.

## Alternatives rejected

- **Verifying the signature in code** — the member signs the challenge, the
  server checks it against the stored key. It is the obvious next step and it
  was refused for four reasons, any one of which is sufficient. It needs an
  OpenPGP implementation in our process, which 0058 refused on a security
  path. Done at enrolment it would prove possession of a key *from whatever
  session registered it*, so a stolen session could self-verify its own anchor
  — the takeover 0058's "changing the key drops it to pending" rule exists to
  prevent — unless possession were kept as a **separate** fact from an
  admin's verification, which is two flags where there is now one. Done at
  recovery it would remove the human from the loop entirely, making a key
  exfiltrated from an unlocked laptop a silent, complete takeover, with the
  audit line naming nobody. And it would put a parser for attacker-supplied
  armored blobs on an unauthenticated path, where today that parsing happens
  on the admin's own machine, deliberately.
- **Leaving the nonce to the admin** (`openssl rand -hex 16`, as the guide
  said). It works when it is done, and the failure mode is silent: a tired
  admin accepts a message the member composed and nothing anywhere knows the
  difference.
- **A challenge per account rather than per contact.** The question is "does
  whoever answers hold *this* key", and an account may have three.
- **Refusing to let an admin withdraw a verification without a challenge.**
  See decision 3; a safety valve that needs a round trip is not one.
- **Purging spent challenges.** They are the record of what was asked. The
  table grows by a row per recovery request, which is rare by construction.

## Consequences

- **Recovery now costs one round trip, always.** That is the point: the
  procedure's strongest step stops depending on whether anyone remembered it.
- **A challenge proves only freshness.** It does not prove the admin checked
  anything — an admin who marks a contact verified without reading the
  signature is still the residual threat 0058 named, and the server console is
  still the answer for an account at or above their own level.
- **An admin can re-issue freely**, and doing so invalidates what they sent
  before. The page says so, because otherwise the member's answer to the first
  phrase would look like a failure.
- **The moderation log gains a line per request**, naming the phrase. A
  disputed recovery can now be reconstructed: what was asked, who asked, what
  it authorized.
- **Existing anchors are unaffected.** A contact verified before this release
  stays verified; the next reset link issued against it needs a challenge like
  any other.

## Acceptance gate

`test/baudrate/auth/account_recovery_test.exs` — the challenge is spent once,
by verification and again by the link; an expired one stops counting with
nothing sweeping it; re-issuing supersedes and the superseded row does not come
back; the phrase is one line of ASCII and never repeats. The admin's path
through the page is in `test/baudrate_web/account_recovery_web_test.exs`.
