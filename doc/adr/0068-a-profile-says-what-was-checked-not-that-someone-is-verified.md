# 0068 — A profile says what was checked, not that someone is verified

- **Status:** Accepted
- **Date:** 2026-09-23
- **Deciders:** Baudrate maintainers
- **Related:** publishes a fact established by
  [0058](0058-account-recovery-is-anchored-outside-the-instance.md)'s anchor
  and [0067](0067-the-instance-issues-the-challenge-the-admin-still-verifies-it.md)'s
  challenge; bounded by [0056](0056-boring-but-friendly.md), which keeps this
  forum from scoring people against each other, and by
  [0054](0054-attention-follows-the-board-not-a-ranking.md)'s refusal to let
  the site decide who is worth reading.

## Context

An admin confirms, out of band, that an account controls the OpenPGP key on
its profile. Until now that fact lived only on `/admin/users/:id`, where staff
can see it. Members could not: impersonating a staff account — the attack this
forum is most exposed to, since an admin is who people are asked to trust
during a recovery — looked exactly like the real thing to a reader.

The obvious shape is a checkmark labelled **Verified**, and it is the wrong
one twice over.

- **It claims something nobody checked.** On every platform a reader has used,
  a verified badge means the operator confirmed *who this person is*. What was
  confirmed here is that whoever holds the account also holds a key. That is a
  smaller and much more precise claim, and the difference is the whole value
  of it.
- **It is a status marker**, and 0056 keeps those off this forum. A badge
  people can earn and compare is the same feedback loop as a ranking, on
  accounts instead of posts.

## Decision

1. **The badge states what was established**: *OpenPGP key confirmed*, with a
   title giving the date an admin confirmed it. The word "verified" does not
   appear on a profile, in any language.
2. **It is public**, like the role and bot badges beside it, because its value
   is to a reader deciding whether the account addressing them is the one they
   think. A mark only its owner can see defends nobody.
3. **It says nothing else.** Not the address, not the label, not the key, not
   how many anchors exist, not whether a reset was ever issued. The badge is
   present or it is not (`Recovery.key_confirmed_at/1` returns the earliest
   `verified_at` still standing, or `nil`).
4. **It follows the anchor.** Editing the address or the key drops the contact
   back to `pending` (0058), so the badge goes with it. A badge that outlived
   the confirmation would vouch for a key nobody checked.
5. **Having no badge means nothing about the member.** Most accounts will
   never have one, exactly as most are not moderators. Nothing anywhere ranks,
   sorts, filters or lists by it, and nothing may: that would be the status
   game 0056 refuses.

## Alternatives rejected

- **A checkmark labelled "Verified".** The Context, both halves. It was the
  request; the badge says what was actually checked instead.
- **Showing it only to the account's owner.** It leaks nothing, and it also
  does nothing: the reader who needs to know whether they are talking to the
  real admin is never its owner.
- **Marking accounts that have *no* key.** An absence rendered as a warning
  turns a defence somebody chose to set up into a penalty for everyone else,
  and reads as a site telling members whom to distrust.
- **Publishing the key or its fingerprint on the profile.** It is already on
  `/admin/users/:id` for the one person who needs it, and a fingerprint on a
  public page invites readers to verify signatures the site cannot check,
  which is the parser 0067 refused.

## Consequences

- **Verifying an anchor is now publicly visible**, which an admin should know
  before clicking; `doc/sysop.md` says so at the step.
- **A member can make the badge appear** by registering a key and asking an
  admin to confirm it. That is the intended path, and it costs the admin one
  round trip (0067).
- **It says when, not how.** The title carries the date; the procedure that
  produced it is in the guide, not on the profile.
- **The gate** is the badge block in
  `test/baudrate_web/live/user_profile_live_test.exs`: absent while a contact
  is pending, present and stating what was checked once confirmed, and gone
  again when the key changes.
