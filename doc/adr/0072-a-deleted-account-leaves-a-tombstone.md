# 0072 — A deleted account leaves a tombstone, and its words stay unless the member takes them

- **Status:** Accepted
- **Date:** 2026-09-24
- **Deciders:** Baudrate maintainers
- **Related:** answers P6-D2 (`doc/TODOs.md`). Reuses the step-up
  re-authentication of [0022](0022-step-up-reauthentication-for-second-factor-changes.md),
  the waiting period and cancellation shape of
  [0025](0025-account-migration.md), the interaction gate of
  [0029](0029-sanctions-are-rows-with-an-explicit-end.md), the rule that
  publishing commits with the change
  ([0034](0034-federation-work-is-committed-before-it-is-acknowledged.md)),
  the withdrawals that are never gated
  ([0043](0043-the-outbound-federation-gate-and-withdrawals.md)), and the
  soft-delete-then-purge of [0040](0040-retention-deletes-what-nobody-touched.md).

## Context

Nothing let a member delete their own account; the terms told them to write
to the operator. Phase 6E asks for it, and a plain `DELETE FROM users` is the
one thing that must never happen:

- `articles.user_id` is `ON DELETE CASCADE`, and so are the comments under an
  article — so deleting an author deletes **other members'** replies, their
  likes, their bookmarks and their held posts with it.
- The direct message check constraints (`direct_messages_one_sender`,
  `conversations_two_participants`) make the delete **fail** for anyone who
  ever sent or received a message.
- Reports point at the account and at its content with `nilify_all`, so a
  deletion would empty the evidence of an open case; the sanctions against
  it would vanish.
- The account's own `Delete` and `Undo` activities are signed at **delivery**
  time with a key looked up by username — gone with the row, they could never
  be sent.

The operator decided on 2026-09-23 (P6-D2): the profile, keys, sessions,
drafts and the text of the member's direct messages always go; articles and
comments stay under "deleted account" by default and are withdrawn if the
member ticks that choice; the deletion waits seven days, and signing in
cancels it.

## Decision

1. **The row becomes a tombstone and is never deleted.**
   `User.tombstone_changeset/1` sets `status: "deleted"` and `deleted_at` and
   clears everything personal: names, bio, signature, profile fields, avatar,
   aliases, second factors, preferences, and the password (replaced by a
   bcrypt hash of random bytes). It keeps the username — which therefore stays
   reserved — the role, and what is a record rather than a profile: the ban
   and terms fields, `moved_to`, and `invited_by_id`, which is ban-chain
   lineage. Everywhere a name is shown, a tombstone is "deleted account", its
   avatar is a neutral mark and its name links nowhere.
2. **Asking needs the password, and nothing more.** Step-up
   re-authentication (password, plus the TOTP code when it is on) is checked
   inside the context. TOTP is not required: anyone may leave. Staff and board
   moderators are refused until they are removed, the same refusal an account
   move makes; bots are deleted by an admin.
3. **It waits seven days, and signing in cancels it.** Asking signs out every
   other session, cancels an export or move in progress and sends an
   always-delivered notice; the page then signs its own session out. The
   cancellation is checked in the one function every sign-in reaches, after
   the IP ban — so a banned address cannot cancel — and sends a notice of its
   own, so a member who did not sign in themselves learns that someone did.
4. **The sweep carries it out resumably.** The request is claimed
   (`pending → executing`) before any work, every step selects only what is
   still live, and `completed` is written in the same transaction as the
   tombstone. A crash half-way leaves an `executing` row the next sweep
   finishes; a sign-in that races the sweep loses, and is refused.
5. **The member's own content is withdrawn only if they chose it,** through
   the ordinary soft-delete paths — each publishes its `Delete(Tombstone)`,
   and Retention purges it after 90 days, keeping anything a report points
   at. **The text of their direct messages always goes**, per message, as a
   deleted message already does.
6. **The deletion is published with the tombstone.** In one transaction the
   account unfollows everyone (`Undo(Follow)` to each followed account), its
   `followers` rows go, the row becomes a tombstone and `Delete(Person)` is
   queued — to its followers, the accounts it followed, the other side of its
   remote conversations and the authors of posts it replied to.
7. **The keys stay until everything is out.** For a deleted account the actor
   URI, its collections and WebFinger answer `410 Gone`; the actor's body is a
   `Tombstone` that still carries `publicKey` while its deliveries are
   pending, because a server that never cached the actor must fetch the key
   to verify them. The keys are cleared 30 days on, once no pending or failed
   delivery job carries the actor, and **no key is ever generated for a
   deleted account** — a new one is only a key every server holding the old
   one rejects.
8. **A banned account is served bare, not deleted.** Its actor carries
   identity and key only — no name, summary, avatar or fields — and its outbox
   is empty, matching the profile page that already refuses it. It is not a
   `Tombstone`: a ban can be lifted, and a `410` would make other servers
   delete the account for good.

## Alternatives considered

- **Deleting the row.** Rejected for every reason in the Context: it deletes
  other members' words, fails outright for anyone with a direct message,
  empties moderation records, and cannot sign its own `Delete`.
- **Always withdrawing everything.** It takes every discussion the member
  started with it, other members' replies included; the operator chose to
  make that the member's decision, and the form says exactly what it takes.
- **Always keeping everything.** It gives a member no way to take back their
  words, which is what many people deleting an account want.
- **No waiting period.** A stolen password — or a moment of anger — would be
  irreversible. Seven days is long enough to notice and short enough to mean
  it; signing in is a cancellation nobody has to look up.
- **Re-federating kept content as "deleted account".** Most servers remove
  everything an actor posted when they receive `Delete(Person)`, whatever it
  was later called, and an `Update` per post would be the largest fan-out the
  instance ever sends, for nothing. "Anonymized" is a promise about this site
  only, and the page says so.
- **A plain 410 without the key.** Simpler, and it breaks verification of the
  account's own last activities at exactly the servers that most need them.

## Consequences

- A deleted account's posts stay on this site under "deleted account", with
  their discussions intact — unless the member withdrew them. On other
  servers they usually disappear with the account.
- The username is reserved for ever. Nobody can register it and pass as the
  person who left.
- Timeline replies — replies to posts on other servers — have no local
  withdrawal path, and stay under "deleted account" either way; their
  recipients get the `Delete(Person)`.
- Likes, boosts and poll votes are kept, so the counters other members see do
  not drift; reports, the moderation log, sanctions and filter matches are
  kept as records.
- An admin cannot bring a tombstone back: banning and unbanning it are
  refused.

## Acceptance gate

`test/baudrate/account_deletion_test.exs`, with the outside view in
`test/baudrate_web/account_deletion_web_test.exs`:

- asking needs re-authentication; staff, board moderators and bots are
  refused; other sessions end at once;
- signing in cancels a pending deletion and sends the notice, and is refused
  while one is executing;
- the sweep waits the seven days, runs once, and finishes a run that crashed
  after the claim;
- the tombstone is checked by walking every `User` column against an explicit
  keep-list, so a new personal column fails until it is cleared or listed;
- `Delete(Person)` is queued in the tombstone transaction to followers,
  followed accounts and correspondents, and `Undo(Follow)` to the followed;
- without the tick nothing of anyone else's disappears; with it the member's
  articles and comments are withdrawn as theirs; their messages are always
  blanked;
- the key stays while deliveries are pending, is then cleared, and is never
  regenerated; the actor answers 410 with and then without it;
- a banned actor carries no profile and an empty outbox.
