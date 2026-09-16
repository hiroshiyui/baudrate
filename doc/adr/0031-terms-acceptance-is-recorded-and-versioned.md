# 0031 — Terms acceptance is recorded and versioned, and the pause runs through the interaction gate

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Baudrate maintainers
- **Related:** extends [0029](0029-sanctions-are-rows-with-an-explicit-end.md)
  (one gate decides whether an account may act) with a refusal that is not a
  sanction; relies on [0014](0014-ets-caches-for-settings-and-boards.md) (the
  settings cache) for the published version

## Context

Registration asked for agreement to an End User Agreement and then threw the
answer away. `terms_accepted` was a virtual field on `User`: the changeset
validated the checkbox with `validate_acceptance/2` and nothing was written to
the database.

That cost three things.

**There was no record of who agreed to what.** An admin editing the `eua`
setting silently changed the document every existing member had "accepted",
retroactively and with no trace. If anyone ever asked which text a given
account agreed to, nothing could answer — not even approximately, because
the setting keeps no history and the acceptance kept no date.

**The document could be read exactly once.** The EUA was rendered only inside
the registration form, in a 12rem scroll box. After registering there was no
URL that showed it. A member who wanted to re-read what they had agreed to,
or a prospective member who wanted to read it before starting, could not.

**There was nowhere to put rules or a privacy policy.** Both are ordinary
expectations of a public site, and neither existed; the footer was an empty
`<footer>` element.

## Decision

### 1. Three documents, three public pages

The terms (`eua`), the site rules (`rules`) and the privacy policy
(`privacy_policy`) are admin-authored markdown settings, published at `/terms`,
`/rules` and `/privacy`. They render through `Content.Markdown.to_html/1`, so
they are sanitized and their images pass through the media proxy like any post
— an admin-authored page is still read by guests, and a hotlinked image there
would disclose every reader's IP (ADR 0021).

They live in `live_session :public_browsable`, **not** `:public`: that session
carries `:redirect_if_authenticated` and would bounce a signed-in member off
the document they are being asked to accept.

The footer links the documents that have been written, and nothing while all
three are empty. A link to a page reading "not published yet" is worse than no
link.

### 2. Acceptance is a row on the user, not a virtual field

`users.terms_accepted_at` and `users.terms_version` record when a member
accepted and what. Neither is castable from parameters: a member who could set
`terms_version` in the registration form would accept a version that does not
exist yet and never be asked again.

Validating the checkbox and recording the acceptance are one function,
`User.accept_terms/1`. They were two steps before — validate, then discard —
and a registration path that performed only the first is exactly how this bug
existed. Both callers in `Auth.Users` go through it.

### 3. The version moves only when an admin says so

`settings.eua_version` is an integer, starting at 0 and incremented only by
`Setup.publish_terms_version/0`, behind a deliberate "require every member to
accept again" checkbox in the editor.

The rejected alternative was deriving the version from a hash of the text,
which needs no admin judgement and cannot be forgotten. It was rejected because
it cannot tell a new clause from a corrected typo: every edit would confront
the whole instance with a banner, and admins would learn to leave typos alone
rather than trigger one. Deciding what is material is a judgement, and the
person editing the document is the one making it.

An unreadable `eua_version` reads as 0, so nobody is asked to accept. This is a
courtesy prompt, not an access control, and a malformed settings row is a poor
reason to pause every member on the site.

### 4. The pause runs through `Auth.ensure_can_interact/1`

A member behind on the terms is refused with `{:error, :terms_not_accepted}` by
the same gate that carries bans, suspensions, silences and moves (ADR 0029).

This is the load-bearing choice. The alternative — checking the terms in each
LiveView that posts — is how a rule ends up enforced on articles and forgotten
on poll votes. Putting it in the gate means it applies to all 29 call sites at
once, and, just as importantly, that it inherits every exemption those call
sites already encode:

- undoing an earlier like or boost;
- deleting your own content;
- **reporting abuse** — a member who cannot report is a member who cannot ask
  for help, and changed terms are not a reason to take that away;
- everything about account security.

It is evaluated **last** among the refusals. A member who is silenced *and*
behind on the terms is told about the silence, because that is the one they
cannot lift themselves.

Reading is never affected. A terms pause that blocked reading would stop a
member reading the very terms they need to accept.

### 5. Bot accounts are exempt, inside the gate

A bot user cannot sign in, so it can never accept. Bot articles are created
through `Content.create_article/3` and pass the same gate, so without an
exemption the first publication of new terms would silently stop every RSS feed
on the instance — with no error anyone would see, because bot fetches log their
failures and carry on.

The exemption is a clause in the gate's own query, not a check at the bot call
site, for the same reason the pause itself lives there.

### 6. Existing accounts are treated as having accepted version 0

The migration stamps every existing user with `terms_accepted_at = inserted_at`
and version 0, level with the `eua_version` it creates.

The alternative was leaving them null, which is more truthful — we genuinely
have no record that they accepted anything — but would make the deploy itself
the disruption, confronting every member with a blocking banner because of an
upgrade rather than because an admin decided the terms had changed. The first
deliberate publication is what should prompt people.

### 7. Accepting happens on the page that shows the text

The banner appears on every page and carries a link, not an Accept button. The
button is on `/terms`, under the document. A one-click accept on a banner would
let someone agree to a document the page never showed them.

The version recorded is read inside the context at the moment of acceptance,
never carried in the form: the page may have been open since before the terms
changed.

## Consequences

- Publishing new terms pauses posting for every member at once. This is the
  intent, but it is a blunt instrument: there is no grace period and no
  staged rollout. If that becomes a problem, it needs a new ADR rather than a
  quiet exemption.
- Staff are paused too. An admin who publishes terms must accept them before
  posting, which is consistent, and administration itself is unaffected —
  admin actions do not run through `ensure_can_interact/1`.
- `users.terms_version` is a single integer per account, so acceptance history
  is not kept: we record the current answer, not every answer. A full audit
  trail would be a `terms_acceptances` table, and is not needed to answer the
  question this ADR exists for ("has this member accepted what is published
  now?").
- The rule that report categories can point to a specific rule (P1-D9) is
  **not** covered here. It needs the rules to be a list of records rather than
  one markdown document, and is deferred to its own change.

## Acceptance gate

`test/baudrate/auth/terms_gate_test.exs`. It checks the refusals, and — the
part that matters more — everything the pause must not stop: reading, undoing
a like, deleting your own post, reporting abuse, and bot posting. **Add any new
posting path to it.**
