# 0063 — The door is defended by work, not by a third party

- **Status:** Accepted
- **Date:** 2026-09-22
- **Deciders:** Baudrate maintainers
- **Related:** the refusal of a third-party CAPTCHA is
  [0006](0006-media-proxy-no-third-party-subresources.md)'s rule on the one page
  every new member must load; there is no email to confirm, per
  [0058](0058-account-recovery-is-anchored-outside-the-instance.md); the worker
  is same-origin and loaded by a bare literal for
  [0059](0059-the-service-worker-caches-the-shell-and-never-content.md)'s
  reason; an IP ban's expiry is decided by the clock as
  [0029](0029-sanctions-are-rows-with-an-explicit-end.md) decides a sanction's;
  the client address comes only through `RealIp`, which
  [0012](0012-rate-limiting-behaviour-and-failure-modes.md) records as
  fail-closed; the rest of the site stays public to a banned address for the
  reason [0026](0026-blocks-stop-interaction-locally.md) gives a block — it
  controls interaction, not visibility. First release of Phase 5
  (anti-spam): stages 5A and 5E.

## Context

Registration had two defences: a limit of five attempts an hour per address,
and the `approval_required` mode that puts a person between a new account and
posting. Both are real and neither is enough against a wave. The rate limit is
per address, and addresses are cheap; approval stops an account posting but
not being created, and every pending account sends a notice to every admin, so
a scripted wave in approval mode is a flood of notifications instead of a flood
of posts.

What was missing was a way to make each attempt *cost* something, a way to
refuse a network outright, and a way to act on a chain of accounts that were
evidently created by one person.

The obvious tool for the first is a CAPTCHA, and it is the one thing this
codebase refuses on principle.

## Decision

### The registration challenge (5A)

1. **Proof-of-work, self-hosted.** The server issues a random nonce and a
   difficulty; the browser finds a counter whose SHA-256 with the nonce starts
   with that many zero bits; the server checks the one hash. A hosted CAPTCHA is
   a subresource from a host we do not control on the one page every new
   member must load, and it hands that host every registrant's address and
   browser — ADR 0006, on the page where it matters most.

2. **In all three registration modes.** `approval_required` still lets a bot
   create pending accounts, and each one notifies every admin; `invite_only`
   still lets one solve be spent guessing invite codes if a solve were
   reusable. There is one code path and no mode in which it is skipped.

3. **Held in the socket and stored nowhere; one solve buys one attempt.** The
   challenge lives in the registering LiveView's assigns, so there is no
   table, no cleanup and nothing about a visitor kept. It is **re-issued after
   every attempt, success included.** The first design left a consumed
   challenge as `nil` — which is also how "switched off" is spelled — so a
   crafted socket could register once properly and then keep submitting on the
   same solve. `registration_challenge_test.exs` asserts both halves.

4. **18 bits by default, 22 at most, from a measured rate.** The solver
   manages about 1.2 million hashes a second in a desktop browser — measured —
   and a phone is taken to be about eight times slower, which is an estimate
   nobody has yet timed on a real one; the work is geometric, so an unlucky
   visitor takes three or four times the average. The approved plan set 20
   bits and expected "~1–2 s on a phone"; at that rate 20 is about seven
   seconds on a phone, long enough to look broken, and 24 nearly two minutes. So
   the default is the highest value an unlucky phone still finishes before the
   person does, and the cap is where registration stops being possible in
   practice — raising the setting during a wave is its purpose, and a slip of
   the keyboard must not close the door.

5. **The solver runs in a same-origin worker, falls back to the main thread,
   and never disables the button.** `worker-src` is `'self'`, so a `blob:`
   worker will not run; the worker is a built file at the site root loaded by
   the bare literal `/challenge_worker.js`, never `~p`, for ADR 0059's reason.
   If it cannot start, the same solver runs on the main thread in small
   batches. A submit that arrives before the answer is **held by the server**
   and completed when the answer lands, with a status line saying so: a
   disabled button that explains nothing is how "the site is broken" starts,
   and registration is the one page a visitor cannot route around. The JS
   SHA-256 and Erlang's `:crypto` are checked against each other byte for byte
   in the browser test, which asserts the **worker** answered — the fallback
   also registers people, so a broken worker would otherwise pass unnoticed.

### Banning an invite chain (5A)

6. **Shown, not cascaded, and nothing is pre-ticked.** Banning an account and
   the accounts it invited lists the whole chain, bounded at five levels and
   two hundred accounts, with each account's age and post count. A spammer's
   invitee is sometimes a real member, so the point of showing it is that
   somebody looked.

7. **The selection is the client's; the chain is the server's.** The ticked
   ids are intersected with a tree recomputed in the context, so an id edited
   into the page cannot reach an account outside the chain. Each account is
   authorized individually, so the rank rule holds per account. An account
   **already banned is skipped**, because banning it again overwrites its
   `ban_reason` with this one. It is logged in the context, one entry per
   account and one for the action, so no second caller can skip the log.

### IP and CIDR bans (5E)

8. **A ban refuses registration and sign-in, and never reading.** Public
   content stays public — the premise of the whole site — and an address is
   shared by everyone behind the same network, so a ban that blanked pages
   would be a wall only the innocent ever notice.

9. **Sign-in is checked where the session is minted.** `LoginLive` checks
   before the password is tested, so a banned address learns nothing about any
   account and adds nothing to `login_attempts`. The backstop is
   `SessionController`'s `establish_session/3`, which the password step, TOTP,
   recovery codes and first-time TOTP setup all end in: a check only at the
   login form would be bypassed by any sign-in path added later.

10. **Four refusals.** A loopback or private range — which is what every
    visitor looks like when the reverse proxy is misconfigured, so banning it
    bans the site — asked of `HTTPClient.private_ip?/1` at both ends of the
    range. Anything broader than a `/8` (IPv4) or `/16` (IPv6). A range
    containing the acting admin's own address, and any range at all when that
    address is unknown, since then the one mistake that locks the admin out of
    the page that would undo it is unguarded. And a range broader than a `/16`
    or a `/32` without a second, deliberate tick.

11. **Expiry is decided by the clock when the ban is read.** There is no sweep,
    and the cache holds expired rows too: a cache that dropped them at refresh
    would enforce a ban past its end until some unrelated write reloaded it —
    the missed-sweep failure ADR 0029 refuses, arriving through a cache
    instead of a job.

## Alternatives rejected

- **A hosted CAPTCHA.** The strongest defence against scripted sign-ups
  available, and a third-party request on every registration, carrying every
  registrant's address to somebody else. Decision 1.
- **Email confirmation.** There is no email in this system (ADR 0058), and a
  mailbox costs a spammer nothing.
- **Widening `worker-src` to `blob:`.** It would let the solver ship inline
  and make the policy weaker for every page, to save one build step.
- **Refusing a submit that arrives before the answer.** Simpler, and it asks a
  visitor to press the button twice for a reason they are never told.
- **An automatic cascade down the invite chain.** Fastest in a wave, and the
  version that bans a real member several levels down without anyone having
  looked at them.
- **A background job that lifts expired IP bans.** A missed run holds an
  address past its end — an address somebody else will inherit from their
  ISP.
- **PostgreSQL's `inet` type for the ban.** Native containment operators, and
  an Ecto type of its own for a table that holds tens of rows and is matched in
  memory from the cache anyway.

## Consequences

- **It does not stop a determined attacker.** Native code computes SHA-256 far
  faster than a browser, so a spammer with their own client pays milliseconds
  where a person's phone pays a second or two. The challenge is a *price*, and
  it makes an attacker run the protocol — hold a socket open, receive the
  nonce, answer — rather than replay a form post. Together with the rate
  limit, the bans and the approval queue, that turns a wave from free into
  cheap, which is the difference between a flood and a trickle a moderator
  can keep up with.
- **Registration requires scripting.** It already did — the page is a
  LiveView — so this adds no new requirement, but it is now a stated one.
- **An IP ban has collateral.** Everyone behind the same network is refused.
  The page says so, the message a banned visitor sees is one an innocent
  person can act on, and bans are meant to be narrow and to expire.
- **The test suite runs with the challenge off** (`registration_challenge_bits:
  0` in `config/test.exs`), so tests that are not about it are not made to
  answer one. The tests that are about it turn it on.
- **`test/baudrate/auth/registration_challenge_test.exs`,
  `ip_ban_test.exs` and `invite_chain_ban_test.exs` are the acceptance gates**,
  with the browser half in
  [`features/registration_challenge_test.exs`](../../test/baudrate_web/features/registration_challenge_test.exs).
