# 0029 — Sanctions are rows with an explicit end, enforced by one gate

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Baudrate maintainers
- **Related:** builds on [0016](0016-authorization-at-the-context-boundary.md)
  (authorization at the context boundary) and [0011](0011-role-levels-for-board-authorization.md)
  (role levels); generalizes the read-only gate of [0025](0025-account-migration.md);
  sits beside [0026](0026-blocks-stop-interaction-locally.md) (member blocks).
  Implements decisions P1-D2, P1-D3 and P1-D4 in [`doc/TODOs.md`](../TODOs.md).

## Context

The only thing staff can do to an account today is ban it, permanently. There
is nothing between a stern word nobody records and deleting a member from the
site. So a first offence either goes unanswered or ends the account, and a
moderator handling a bad week for one member has no proportionate move.

`users.status` holds `active`, `pending` or `banned`. A ban sets the status,
`banned_at` and `ban_reason`, revokes every session, cancels data exports and
account moves, and revokes invite codes. The status is read in at least seven
places — `authenticate_by_password/2`, `SessionController`, `AuthHooks`,
`FeedController`, `UserProfileLive`, `ConversationLive`, and
`Users.user_active?/1` / `can_create_content?/1` — and several of them ask
`status != "banned"` rather than `status == "active"`. A status value is also a
poor record: it has no end date, no author, no history, and unbanning erases
the reason.

Phase 1B gave board moderators a queue for reported content. It stops at the
content: a moderator who has removed the same person's posts three times this
week still has nothing to do about the person.

Meanwhile `AccountMigration.ensure_not_moved/1` already solves the shape of
this problem for a different reason: a moved account is read-only, enforced by
one function called from every context function that creates content or an
interaction. That gate is the thing to generalize — and to fold into, rather
than duplicate, because the failure mode of two parallel gates is a new
posting path that remembers one and forgets the other.

## Decision

1. **A sanction is a row in a `sanctions` table, not a new `users.status`
   value** (P1-D2). Columns: `user_id`, `kind` (`warn` / `silence` /
   `suspend`), `reason` (free text, shown to the member), `issued_by_id`,
   `issued_at`, `expires_at`, `lifted_at`, `lifted_by_id`, `lift_reason`, and
   an optional `report_id` linking the report that prompted it. Rows are
   append-only history: a sanction is lifted, never deleted or rewritten, so
   "why was this account silenced twice in March" has an answer. `users.status`
   keeps exactly `active | pending | banned`, and `reason` is length-bounded
   like every other string that reaches a column.

2. **A sanction is active or not by the clock, never by a sweep.** Active means
   `lifted_at IS NULL AND (expires_at IS NULL OR expires_at > now())`.
   Enforcement reads that condition directly; no background job sets or clears
   a flag. A failed hourly run therefore cannot keep a member silenced past
   their time, nor lift one early. `SessionCleaner` only sends the "it has
   ended" notice, and may miss a run without consequence.

3. **One gate.** `Auth.ensure_can_interact/1` returns `:ok` or
   `{:error, :account_moved | :account_silenced | :account_suspended | :banned}`
   in a single query, and **replaces** `AccountMigration.ensure_not_moved/1` at
   every call site: articles, article edits, comments, feed replies, likes,
   boosts, forwards, polls, follows, DMs and invites. `ensure_not_moved/1`
   stays as the moved-account predicate the gate itself uses, and nothing else
   calls it. A new way to post or interact calls the gate, exactly as it had to
   call the moved check before; the existing `{:error, :account_moved}` shape
   is preserved so current callers and flashes keep working.

   **The follow paths are the one place the two rules differ.** A move is a
   redirect, not a punishment: [ADR 0025](0025-account-migration.md)
   deliberately lets a moved account keep *following* people, so the person
   can carry their reading list to the account they moved to. A sanction has
   no such exception. The gate therefore takes a documented `moved: :allow`
   option, which only `create_local_follow/2` and `create_user_follow/3` pass
   — one gate with one exception, rather than a second gate with a second
   list of call sites. `AccountMigration.ensure_not_moved/1` survives for the
   *target* side of a follow ("this account is followed at its new address"),
   which is a different question from "may this account act", and the guard
   test allows it only there.

4. **What each kind does.**
   - **Warn** — a notice to the member and an audit entry. Nothing is refused,
     and no acknowledgement is demanded: a "you must accept this to post again"
     gate is a silence wearing a different hat, and would be recorded as the
     wrong thing.
   - **Silence** — the account becomes read-only. No articles, edits, comments,
     replies, likes, boosts, forwards, poll votes, follows, DMs or invites, and
     no profile changes (display name, bio, avatar, links) — a bio is a
     billboard, and silencing someone who is then free to rewrite theirs at
     their target achieves nothing. Undoing an earlier like or boost stays
     allowed, as for a moved account, and so does deleting their own content.
     **Reporting stays allowed:** a silenced member must still be able to
     report abuse. Account security stays allowed: password, second factors,
     sessions and data export. `expires_at` is optional; an indefinite silence
     is allowed and must still be justified and audited.
   - **Suspend** — the account cannot sign in until `expires_at`, which is
     required. It is refused in `authenticate_by_password/2`, so every entry
     point inherits it, and re-checked in `AuthHooks` as defence in depth.
     Suspending revokes every session through `Auth.Sessions` (so open
     LiveViews disconnect) and cancels active data exports and account moves,
     as a ban does. It deliberately does **not** revoke invite codes: they
     expire in seven days by themselves, a suspended account cannot generate
     more, and a temporary sanction should leave nothing to put back by hand.
   - **Ban** is unchanged: permanent, admin-only, on `users.status`.

5. **Existing content stays up.** A sanction restricts what an account may do
   next; it never hides or removes what it has already posted. Removal is a
   content decision, made per item through the report queue, where it leaves
   evidence (P1-D6). This also keeps a silence from quietly deleting a
   member's history on a public hub.

6. **Sanctions stack forward, never backward.** Several active rows of the same
   kind are allowed and harmless: the account is silenced while *any* row is
   active, and the end shown is the furthest away. So issuing a sanction can
   only ever extend one. **To shorten or cancel, lift it** — lifting clears
   every active row of that kind in one action, each recording who lifted it
   and why. There is no partial-unique index, because "active" depends on the
   current time and cannot be expressed in one.

7. **Who may do what (P1-D3), checked in the context.**
   - Board moderators: nothing here. Their authority stays content in their own
     boards (Phase 1B).
   - Global moderators: warn, silence, suspend for **at most 30 days**, lift
     what they may issue, and refuse a pending registration.
   - Admins: the same without the cap, plus ban, unban and role changes.

   Two rules hold regardless of how roles are configured, and are checked in
   `Auth` rather than in a LiveView: **nobody sanctions themselves**
   (`{:error, :self_action}`, as `ban_user/3` already refuses), and **nobody
   sanctions an account whose role level is greater than or equal to their
   own** — so a moderator cannot silence another moderator or an admin. The
   30-day cap is enforced server-side against `issued_at`, not trusted from the
   form.

8. **Powers are role permissions, and a permission nothing checks is deleted.**
   The new authority is expressed as permission strings checked with
   `Setup.has_permission?/2`, so P1-D3 is configuration and not a hard-coded
   role name. In the same change, the permissions that exist today and are
   never checked — `moderator.mute_user` (muting became a member feature, open
   to everyone), `admin.manage_roles`, `admin.view_dashboard` — are either
   wired to a real check or removed. A listed permission that enforces nothing
   is a false statement about who can do what.

9. **The member is always told** (P1-D4), in three places, because a post that
   fails with a shrug is worse than the sanction and a control that simply
   vanishes explains nothing:

   - `sanction_applied`, `sanction_lifted` and `sanction_ended` notices,
     delivered whatever the notification preferences say, like account
     security notices;
   - the refusal they meet when they try to act, which names the restriction,
     the reason and the end time;
   - a banner on every page while the restriction stands, beside the existing
     moved-account and data-export banners.

   Notice text is built from the row through Gettext; the staff-written
   `reason` is rendered as data, never as markup.

10. **Refusing a pending registration is a ban with a reason, not a new
    status.** A refused account must not sign in, which is precisely what
    `banned` already means and enforces everywhere; adding a `rejected` status
    would have to be learned by every `status != "banned"` check in the
    codebase, and the ones that forget would admit the account. Authorization
    is on the act, not the state: a global moderator may refuse an account that
    is still `pending`; banning an active member stays admin-only. The audit
    entry is `reject_user`, with the reason. Deleting the row instead was
    rejected — there is no user-deletion path yet, and building one as a side
    effect of this work would decide account deletion by accident.

11. **Sanctions are local.** Nothing is sent over ActivityPub, following P1-D1:
    no `Block`, no `Flag`, no suspension activity. Remote servers are told
    nothing, and a silenced account simply stops producing activities to
    deliver.

12. **Audited and rate-limited.** Every issue and lift goes through
    `Moderation.log_action/3` with the new actions (`warn_user`,
    `silence_user`, `suspend_user`, `lift_sanction`, `reject_user`) added to
    the `Moderation.Log` allow-list, and through a new `RateLimits.check_sanction/1`:
    a stolen moderator session should not be able to suspend a hundred accounts
    in a minute.

13. **The gate's completeness is tested, not remembered.** Besides a refusal
    test per interaction path, a guard test walks the AST of every file in
    `lib/` and fails if `ensure_not_moved/1` is *called* anywhere outside the
    two files allowed to ask about the followed account, so a new posting path
    cannot quietly enforce the old, narrower rule. A second guard fails if any
    permission in the catalogue is never checked (decision 8). This is the same
    tactic as the moderation log's call-site test and `no_hotlink_test.exs`.

14. **What a user detail page may show.** Global moderators and admins see
    role, status, sanction history, reports by and against the account, recent
    content, inviter and invitees. **IP addresses and login attempts are
    admin-only:** they are personal data, and judging behaviour does not
    require them.

## Consequences

- A moderator gets a proportionate answer, and the site gets a record of it.
  A repeat offender's history is one query, not an archaeology of the log.
- Every interaction path carries one gate rather than one per rule, and the set
  of paths is the set that already existed for moved accounts.
- Checking the gate costs one indexed query per interaction, the same order as
  the moved check it replaces. It is deliberately not cached: sanction state
  must not lag a lift by a cache TTL. If measurement ever says otherwise, the
  cache goes behind the same function.
- Sanctions and bans are two mechanisms for related things, and both must be
  checked at sign-in. That is the price of not multiplying status values.
- A suspended member learns of the suspension when they next try to sign in,
  and reads the notice after it ends. With no email there is no way around
  this.
- An indefinite silence is possible, so it can be forgotten. The user detail
  page and the sanction list are where that becomes visible; no timer will
  clean it up.
- A silenced spammer's existing posts stay until someone removes them. That is
  the intended split between "this account may not act" and "this content must
  go", but it does mean two actions during a spam wave.

## Alternatives considered

- **New `users.status` values (`silenced`, `suspended`).** Rejected (P1-D2):
  every existing status check would have to learn them, and the several that
  ask `status != "banned"` would silently admit a silenced or suspended
  account. A status also has no end date, no author and no history.
- **Denormalized `silenced_until` / `suspended_until` columns on `users`.**
  Rejected: a second source of truth that drifts from the history rows the
  first time a write path forgets one of them. The gate query is cheap and
  indexed; correctness is worth more than the join it saves.
- **A sweep that applies and lifts sanctions.** Rejected: enforcement must not
  depend on a job having run. A missed run would hold someone past their time,
  which is exactly the failure a time-limited sanction exists to prevent.
- **A separate `ensure_not_silenced/1` beside `ensure_not_moved/1`.** Rejected:
  two lists of call sites, one of which will be incomplete. One function, one
  list, one guard test.
- **At most one active sanction per kind, with a partial unique index.**
  Rejected: "active" depends on `now()` and cannot be indexed; the workarounds
  are an app-maintained `status` column (which needs a sweep) or lifting
  expired rows on every issue (which makes "lifted" mean two things).
- **Mastodon-style silence that also hides the account from public listings.**
  Rejected: it contradicts the public-hub principle and P1-D2, and it would
  remove a member's history from view without anyone deciding that any
  particular post should go.
- **Federating sanctions** (sending `Block` or a suspension signal). Rejected,
  as for member blocks (P1-D1): it tells the other server about a local
  decision and gains nothing.
- **Requiring a warned member to acknowledge the warning before posting.**
  Rejected: that is a silence with a self-service exit, and it would be
  recorded as a warning while behaving like a restriction.
