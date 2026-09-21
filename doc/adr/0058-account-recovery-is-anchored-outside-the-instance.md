# 0058 — Account recovery is anchored outside the instance

- **Status:** Accepted
- **Date:** 2026-09-21
- **Deciders:** Baudrate maintainers
- **Related:** applies [0022](0022-step-up-reauthentication-for-second-factor-changes.md)
  (step-up re-authentication) and [0029](0029-sanctions-are-rows-with-an-explicit-end.md)
  (nobody acts on an account at or above their own role); reuses
  [0038](0038-encryption-keys-are-separate-and-rotatable.md)'s keyring for a
  new secret column; constrained by
  [0006](0006-media-proxy-no-third-party-subresources.md) (no third-party
  request) and [0056](0056-boring-but-friendly.md) (the shape of the nudge);
  the member-list half of [0057](0057-a-sitemap-invites-only-what-a-guest-sees.md)
  is why the reset needs an anchor rather than a story.

## Context

**Baudrate has no email.** No mailer dependency, no address column, nothing
that sends. That was never a decision anyone wrote down; it is simply how the
instance grew, and `doc/development.md` has recorded its one consequence for
some time: *"Recovery codes are the sole password recovery mechanism — there is
no email in the system."*

Reading that against the code in Phase 4D turned up what it actually meant.

- Recovery codes were minted at exactly three places, all at account creation,
  and **there was no way to generate more**. `/profile/recovery-codes` was a
  dead route reading a session key nothing ever wrote; `RecoveryCode`'s own
  moduledoc claimed a TOTP reset re-issued them, and it does not. A member who
  spent all ten was locked out of recovery permanently.
- There was no admin path either: no impersonation, no password reset, no way
  to clear another account's second factors. A member who lost their password
  and their codes had lost the account.

The obvious fix is an email-based reset, and it is the wrong one here. Adding a
mailer makes an SMTP server a runtime dependency of an instance that currently
needs Postgres and nothing else; it makes deliverability an operational
problem; and it makes the mailbox the thing that owns every account — which is
the same single point of failure, moved somewhere the operator controls less.

The other obvious fix is "an admin can reset a password", and on its own that
is worse. It turns the strongest account on the instance into a
social-engineering target: the entire security of every account becomes one
admin's judgement about a story told over some channel, under time pressure,
by somebody claiming to be locked out.

The operator's answer (2026-09-21) is to keep the second fix and give the admin
something to *verify* instead of something to believe.

## Decision

**Account recovery is anchored by an OpenPGP key the member registers here and
signs with elsewhere. Baudrate holds the anchor and never uses it.**

1. **The member registers the anchor, from their own session.** A recovery
   contact is an email address plus an armored OpenPGP public key, added at
   `/profile` behind step-up re-authentication (ADR 0022) and announced with an
   always-delivered notice. It arrives `pending`.

2. **An admin only confirms it.** Out of band: the member sends a signed
   message from the registered address, the admin verifies the signature
   against the key **from the profile page** in their own mail client, and
   marks the contact verified. There is deliberately **no function anywhere
   that creates a contact on somebody else's account**.

3. **Changing the address or the key drops the contact back to `pending`.**
   This is the property the scheme rests on. An attacker holding a stolen
   session can register a new anchor, but it arrives unverified, and verifying
   it means an admin checking a signature against a key the real member never
   published. Forging the anchor therefore needs the member's own session *and*
   an admin's mistake, or the member's own private key.

4. **Baudrate sends no mail, verifies no signature, and fetches no key.** No
   OpenPGP library, no keyserver lookup. The instance stores what the admin
   checks against and records the verdict; `doc/sysop.md` holds the procedure,
   including the recommendation to send a fresh nonce to sign, because an old
   signed message can be replayed.

5. **A reset link needs a verified contact.** `Recovery.issue/4` refuses
   otherwise. Without this the proof is optional and the social-engineering
   path sits open beside it.

6. **The password is the default; clearing second factors is a separate
   tick**, with its own audit line (`clear_second_factors`) and its own notice.
   "I lost my phone, take my 2FA off" is the ask a social engineer makes, and
   it must not ride along with the safe-sounding half.

7. **Never an account at or above the issuer's own role level** — ADR 0029's
   rule, applied here, because the residual threat the signature does not cover
   is an admin who claims a verification that never happened. Recovering an
   admin account is the **server console**'s job (`bin/baudrate eval`), which
   needs shell access to the host and cannot be talked into anything.

8. **The link is single-use, 24 hours, and stored hashed.** Only the SHA-256 of
   the token is kept, so reading the table yields nothing redeemable. Every
   redemption failure — unknown, expired, spent, revoked — answers identically,
   and the token is checked on submit rather than on mount, so the page is not
   an oracle. Redeeming revokes every session, cancels exports and moves, and
   issues fresh recovery codes.

9. **The address is encrypted at rest** under the `:auth` keyring class (ADR
   0038), like a TOTP secret and bound to its owner. This is a pseudonymous
   forum; the recovery contact is the one column linking an account to a
   real-world identity, and a database leak must not hand that over. The public
   key is published material and stays readable.

10. **Recovery codes can be replaced** (`regenerate_recovery_codes/1`, behind
    the same step-up), and a dismissible sitewide notice tells a member whose
    account cannot be recovered at all. ADR 0056's question 3 refuses anything
    whose purpose is the return visit; its decision 5 is explicit that boring
    is never an argument against safety work. The notice carries no count, no
    badge and no colour that shouts, and dismissing it is final.

## Alternatives considered

- **Add a mailer and send reset links.** The standard answer, rejected above:
  it makes an SMTP server a dependency of every deployment, makes deliverability
  an operational problem, and relocates the single point of failure into a
  mailbox rather than removing it. It also contradicts nothing less than the
  instance's own shape — this is a forum that has never needed to send anything
  to anyone.
- **Let an admin reset any account, with no anchor.** Simplest, and it is the
  thing this record exists to refuse. The whole cost of the scheme buys one
  property: the admin verifies arithmetic instead of a story.
- **Fetch the key from a keyserver by fingerprint.** Smaller column, and a
  third-party request on a security path — exactly what ADR 0006 refuses
  elsewhere, and it would make a stranger's availability part of account
  recovery. Storing the armored block also records *which* key was verified, so
  a later message signed by a different one is visibly not it.
- **Store only a fingerprint and a hash of the address.** Strongest privacy and
  it breaks the workflow: an admin comparing an incoming message by eye has to
  see the address, and a member checking what they registered has to read it.
- **Require a second admin to co-sign a reset.** Genuinely stronger on an
  instance with several admins, and on a single-admin instance — which this is
  — it means staff recovery never works, with more code to say so. The rank
  rule plus the console is the same protection without the machinery.
- **Delay the link, as ADR 0025 delays a move.** A 24-hour wait would let a
  live session cancel a reset the member did not ask for. But the person this
  feature serves is the one locked *out*, so in the case it targets there is
  nobody holding a session to see the warning. The delay would cost the
  legitimate user a day and buy the attacked user nothing.
- **Verify the signature server-side.** Adds an OpenPGP dependency and a
  parsing surface on an unauthenticated-adjacent path, and moves the check from
  a human who can notice something odd to code that cannot. The operator's
  framing is the better one: the verification facility is standalone, and
  decoupling it is what makes the trust network trustworthy.

## Consequences

- **A member who arranges nothing has no recovery.** No codes left and no
  verified contact means the account is gone. This is the honest cost of having
  no email, it is why the notice exists, and it is the first thing
  `doc/sysop.md` tells an operator to say when refusing a request.
- **The operator does real work.** Verifying a contact and handling a request
  are manual, out-of-band and unautomatable by design. An instance whose
  operator will not do that should leave recovery at codes alone and refuse
  requests — which is a supported position, not a degraded one.
- **The sole admin's escape hatch is the server console.** Whoever holds shell
  access holds the instance; that was already true, and this records it rather
  than pretending the web UI could do better.
- **A new keyring purpose joins the rotation census.** `:recovery_contact` is
  in `Keyring.@purposes` and `recovery_contacts.email_encrypted` in
  `Crypto.Rekey`'s targets, so `Rekey.usage/0` and the health check count it.
  Adding the target required splitting the vault owner from the row id in
  `Rekey` — the first secret column that does not live in its owner's own row.
- **The instance now holds personal data it did not before.** A recovery
  address is an email address on a pseudonymous forum. It is encrypted, never
  federated, never public, admin-visible only, and it belongs in the privacy
  policy — `doc/sysop.md`'s policy-writing section says so.
- **`bin/baudrate eval` is now load-bearing.** It was a maintenance tool; it is
  now the documented recovery path for a staff account, which means it has to
  keep working and the ops documentation has to keep saying how.

## Acceptance gate

`test/baudrate/auth/account_recovery_test.exs` — a reset needs a verified
contact, nobody resets at or above their own level, changing an address or a
key drops verification, a member cannot mark their own contact verified, the
token is single-use under concurrency, and second factors survive unless the
tick was set. `test/baudrate_web/account_recovery_web_test.exs` covers the
pages, including that every redemption failure is indistinguishable.

What neither can check is the part that matters most: whether the admin
actually verified a signature before clicking. No code can, which is why
`doc/sysop.md` carries the procedure as a procedure, and why decision 6 splits
the dangerous half into its own control and its own audit line — so the log can
at least say which decision was taken.
