# 0023 — Self-service data export is designed against data leakage first

- **Status:** Accepted
- **Date:** 2026-09-14
- **Deciders:** Baudrate maintainers
- **Related:** builds on [0022](0022-step-up-reauthentication-for-second-factor-changes.md)
  (step-up re-authentication, account security notices),
  [0006](0006-media-proxy-no-third-party-subresources.md),
  [0016](0016-authorization-at-the-context-boundary.md)

## Context

Users should be able to download their data (GDPR-style right of access and
portability). An export is also the single most valuable thing an attacker can
take from a compromised account: one request turns a hijacked session into a
bulk copy of everything the account wrote, who it talks to, and whom it
blocks. Information security is this project's top priority, so the feature is
designed around how it could leak data rather than around convenience.

Facts that shaped the design (verified in the code, 2026-09-14):

- **No email channel.** In-app notices are the only way to reach the user, and
  a hijacker holding the session sees them too.
- **Many accounts have no second factor.** TOTP is optional for the `user`
  role. Malware that steals saved passwords usually takes cookies at the same
  time.
- **Before this design, a victim could not lock an attacker out while logged
  in.** There was no password change and no "sign out everywhere".
- **Everything under `priv/static/uploads` is served publicly** by `Plug.Static`,
  and the systemd unit makes only `shared/uploads` writable.
- **Several tables mix the user's data with other people's**: DM
  counterparts, reporters and moderator notes on reports against the user,
  revisions written by moderators, notification actors, and the IPs of login
  attempts made by others.
- **Soft deletion does not record who deleted an article**, and deleted articles
  keep their body.

## Decision

### Who may export

1. **Self-service export requires TOTP enabled for at least 7 days**
   (`users.totp_enabled_at`). An attacker who enrols their own TOTP cannot
   export for a week, during which the always-delivered `totp_enabled` notice
   is waiting for the real user.
2. **Only active, non-bot accounts can export.** Everyone else, including
   banned users and accounts without qualifying TOTP, goes through an
   **audited SysOp release task** after identity is verified out of band.
3. **Admins have no UI path to export another user's data.**
4. **Prerequisites ship first:** a logged-in **password change** and **sign out
   everywhere**, both behind step-up re-authentication and both sending
   security notices. Without them, spotting a malicious export gives the
   victim no remedy.

### How an export happens

5. **Request.** Step-up re-authentication with `Auth.verify_reauthentication/5`
   (password + TOTP; never a recovery code). This creates a pending **request
   record, not an archive**. An always-delivered notice goes out, and a banner
   that cannot be dismissed appears on every page.
6. **24-hour cooling-off.** Any of the user's sessions can cancel. "Cancel and
   sign out everywhere" is offered.
7. **48-hour download window, at most 3 downloads.** Every download repeats the
   step-up. The archive is **built at download time**:
   - it is written to a `0600` temp file outside every static root, under a
     build timeout and size cap;
   - it is streamed to the user, then deleted;
   - leftovers are swept at boot.

   No archive ever rests on disk, is backed up, or needs expiry.
8. **Automatic cancellation** on password change, TOTP reset or disable, ban,
   or sign out everywhere.

### What is exported

9. **Only what the user wrote or owns, and only what the UI still shows them.**
   - **Authored content:** articles, comments, feed-item replies, the user's
     own article revisions, polls authored, poll votes, likes, boosts,
     bookmarks.
   - **Relationships and settings:** follows and followers, blocks, mutes,
     profile and settings.
   - **Security metadata:** security key labels and dates, and whether TOTP
     is on.
   - **Files:** the user's own uploaded images and avatar.
10. **Excluded:**
    - every secret (password hash, TOTP secret, private keys, recovery codes,
      session and push tokens, WebAuthn key material, active invite codes)
    - session IPs and user agents
    - notifications
    - reports about the user and the moderation log
    - `login_attempts`
    - revisions written by others
    - reading history
    - content removed by moderators
    - the user's own content in boards they can no longer view
11. **DMs:** only messages the user sent, with the counterpart identified by
    handle alone.
12. **Other people's content appears only as a URI** (e.g. the article a
    comment replies to, the target of a like), never as a title or body.
13. **Soft-deleted articles are included only when the user deleted them
    themselves.** Deletion gains `deleted_by_id`. Rows without attribution are
    excluded (fail closed).

### How leakage is prevented mechanically

14. **Allow-list serializers.** Each data type selects its fields explicitly;
    no struct is encoded whole. An acceptance test seeds unique canary values
    into every secret column and fails if any byte of them appears in a built
    archive, the same role `no_hotlink_test.exs` plays for ADR 0006.
15. **File paths from the database are confined** to the uploads root: the path
    is resolved, must be a regular file, and must not escape through a
    symlink. The JSON never contains a server path. Otherwise a tampered
    `storage_path` would turn export into arbitrary file read (e.g.
    `env/baudrate.env`).
16. **Downloads cannot be read by script and leave no reusable URL.**
    - A single-use token bound to the session and the request, valid for 60 s,
      is sent in a POST body.
    - The request must be a user-initiated top-level navigation
      (`Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document`,
      `Sec-Fetch-Site: same-origin`), so an XSS bug cannot `fetch()` the ZIP
      and exfiltrate it through a same-origin channel.
    - Responses carry `Cache-Control: no-store`,
      `Content-Disposition: attachment` and `nosniff`.
    - nginx does not buffer the response to disk (`proxy_buffering off`,
      `proxy_max_temp_file_size 0`).
17. **Limits live in PostgreSQL and fail closed, not in Hammer:**
    - a partial unique index allows one active request per user;
    - a count caps requests per user per 7 days;
    - `pg_try_advisory_lock` gives one build slot for the whole instance;
    - a conditional `UPDATE … RETURNING` enforces the download counter.
18. **JSON only, with archive entries named by record id.** No CSV (formula
    injection) and no HTML viewer (script running from a local file).
19. **The history is immutable and never goes to the moderation log.** The user
    sees their own export history, admins can see it, and `Logger` records the
    events. The moderation log would expose user activity to moderators.

## Consequences

- **Accounts without TOTP need extra steps to export.** They must enable
  TOTP and wait 7 days, or use the SysOp path. Legitimate users bear most of
  this cost; that is the intended trade.
- **An export takes at least 24 hours.** That is well within GDPR's one-month
  response window.
- **Content can change between request and download**, because the archive
  is built at download time. Every download shows the account as it is at
  that moment.
- **Rebuilding on every download costs CPU.** The single build slot and the
  per-user limits bound it.
- **Two prerequisite features, a migration** (`totp_enabled_at`,
  `deleted_by_id`, export requests) **and an nginx location change** precede
  the export itself.
- **The canary test becomes a permanent gate.** Every new column holding a
  secret must be added to it.

## Alternatives considered

- **A stored archive with a 7-day expiry** (the original TODO). Rejected: an
  at-rest bulk copy that ends up in backups, needs a writable path outside the
  systemd sandbox, and outlives the user's intent.
- **Exporting both sides of DM conversations.** Rejected: a hijacked session
  would exfiltrate other people's private messages in bulk.
- **Password-only step-up for accounts without TOTP.** Rejected: it is defeated
  by the most common credential theft (password-stealing malware that takes
  cookies too).
- **Accepting a freshly enrolled TOTP.** Rejected: enrol-then-export would make
  the factor requirement meaningless.
- **Admin-triggered export in the UI.** Rejected: it turns one compromised admin
  session into bulk exfiltration of every user.
- **Recording exports in the moderation log.** Rejected: moderators can read
  it.
- **Signed download URLs.** Rejected: URLs leak through history, logs and
  `Referer` headers, and they are replayable.
- **Including content from boards the user can no longer view.** Rejected:
  restricted (e.g. moderator) boards commonly contain other people's personal
  data, and the UI already hides it from the user.
