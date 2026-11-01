# 0080 — A revoked session's pages leave by redirect

- **Status:** Accepted
- **Date:** 2026-11-01
- **Deciders:** Baudrate maintainers
- **Related:** [0008](0008-server-side-dual-token-sessions.md) (sessions and
  their revocation), [0029](0029-sanctions-are-rows-with-an-explicit-end.md)
  (a suspension revokes every session).

## Context

Revoking a session (sign-out, sign out everywhere, a password change, a ban, a
suspension, a demotion, expiry) deletes its row and must also end the pages it
has open: a LiveView loaded its user at mount and `on_mount` never runs again,
so an open page would otherwise go on acting for a dead session. Until now,
`Auth.Sessions` did that with one `"disconnect"` broadcast to the session's
`live_socket_id`. Phoenix closed the socket, LiveView's client reconnected at
once, the auth hooks saw no session, and the page went to `/login`.

Phoenix 1.8.16 (PR 6880) stopped sending close code 1001 on that broadcast;
Bandit closes with 1000, and LiveView's client (1.2.13) answers 1000 not with a
reconnect but with a full reload after a 5–10 s random delay. A browser signed
out elsewhere sat on a dead page for up to ten seconds, so Phoenix was held at
1.8.15. The hold kept a patch release, and every later one, out of the tree.

## Decision

**A revoked session's open pages are told, and redirect themselves; the
socket close is the backstop, not the mechanism.**

1. `Sessions` deletes the rows, then broadcasts `{:session_revoked,
   live_socket_id}` on `Auth.revocation_topic/1`
   (`"<live_socket_id>:revoked"`), and sends `"disconnect"` to the
   `live_socket_id` **one second later**. Sent together, the close reaches the
   socket process before any LiveView's redirect and the redirect is lost.
2. `AuthHooks` (`:require_auth` and `:optional_auth`, signed in) subscribes a
   connected page to that topic. On the message it checks the session row
   again, never the message alone, and redirects to `/login?return_to=<the
   page>` with a flash. A LiveView process stops after a redirect, so a client
   that ignores it keeps nothing; the delayed `"disconnect"` closes whatever
   else the session had open.
3. `ForgetRevokedSession`, on the sign-in pages, drops a revoked session's
   auth keys (`session_token`, `refresh_token`, `refreshed_at`,
   `live_socket_id`) from the cookie. Otherwise the sign-in page opens its
   socket under the dead `live_socket_id`, the backstop closes it with 1000,
   and LiveView reloads it under someone typing a password.

## Alternatives considered

- **Keep the hold.** It works, and it freezes Phoenix at a version that will
  stop receiving fixes; the next security release would force this choice
  under time pressure.
- **Patch the client to reconnect on 1000.** Overriding LiveView's own
  failsafe in `app.js` is a fork of its close handling that every LiveView
  bump would have to re-check.
- **Send the redirect only, no `"disconnect"`.** A socket whose LiveViews do
  not watch the topic (a page outside the signed-in hooks) would stay open
  for a dead session. The backstop costs a second.

## Consequences

- A revoked page leaves at once regardless of the close code, so a Phoenix or
  LiveView bump that changes the close handling again no longer decides it.
- A public page browsed while signed in now goes to sign-in on revocation,
  rather than turning into a guest's view of itself; it says why, and
  `return_to` brings the member back.
- Only revocations may send `"disconnect"`. A test that needs a dropped socket
  kills its process (`reconnect_test.exs`), which is what a deploy does.

## Acceptance gate

`test/baudrate_web/live/auth_hooks_test.exs` ("session revocation"),
`test/baudrate/auth/session_revocation_test.exs`,
`test/baudrate_web/plugs/forget_revoked_session_test.exs`; in the browser,
`test/baudrate_web/features/sign_out_everywhere_test.exs` and
`profile_settings_test.exs` (the page leaves; the sign-in page's socket
survives the backstop) and `reconnect_test.exs` (a dropped socket that is not
revoked reconnects without a reload).
