# TODOs

**State (v2.0.0, 2026-09-25; production runs v2.0.0).** Every phase of the
2026-09-14 product review is complete (Phase 0 in v1.18.2 through Phase 8 in
v2.0.0). This file keeps only what is recorded nowhere else: the open items,
the risks accepted knowingly, the limits left standing on purpose, and an
index from the decision and stage ids that commits and ADRs cite to where
each is recorded. `CHANGELOG.md` has what shipped; the ADRs have why.

---

## Open

- **The security contact key expires on 2027-05-25.** Extend or replace it
  (`doc/security-contact.asc`) and update `SECURITY.md` before then.
- **Interop is unverified against real peers** (Phase 3). Against a real
  Mastodon account and a real Lemmy community: thread a reply, send a
  mention, edit a display name, post with a content warning, follow a
  community. All of it is met in code and none of it has been seen working;
  nothing depends on it, so nothing will make it happen by itself.
- **`SECRET_KEY_BASE` is not yet rotatable:** 130 recovery-code hashes still
  ride its derivation, and an HMAC cannot be re-keyed without the code, so
  they move only as members regenerate theirs. `Release.key_census/0` says
  when that reaches zero. (The separated keys were rotated end to end on
  production in 2026-09.)

## Accepted knowingly

Recorded so a later reader can tell a decision from an oversight.

- **Production allows SSH login as root** (key only), deferred by the
  operator: a drop-in sets `PermitRootLogin yes`, and sshd keeps the first
  value it reads, so the `common` role's `no` has no effect. The fix is for
  the role to manage the drop-ins and assert the effective value.
- **No restore rehearsal onto a fresh host, and no always-on puller**
  (2026-09-18). The rehearsal restored into a scratch database on the same
  machine, so rebuilding from nothing — including the key set a restore needs
  (ADR 0038) — is untested; off-host copies arrive only while the workstation
  runs.
- **Publishing releases to a registry** stays open under ADR 0037; worth it
  only if the artifact must reach the server again.
- **Profile text is not filtered** (outside ADR 0065's scope); **a refusal is
  an oracle by bisection**, slowed only by rate limits; **nothing classifies
  content by machine**, and there are no per-board filters or trust and no
  held DMs.

## Left standing on purpose

- The article history cannot show the most recent edit (a revision holds the
  state *before* a change); comments render the live text as a version, the
  article page does not.
- The article edit composer has no server draft — deferred, not refused (ADR
  0062's rejected alternatives).
- A remote poll a member voted in sends no notice when it closes (ADR 0069).
- Local comments from before `/comments/:id` keep their stored `url`;
  `ObjectBuilder` ignores it.
- The AP followers collection lists remote followers to anyone while
  `ap_authorized_fetch` is off (ADR 0070).
- No DM images to or from other servers; reporting an image-only message
  copies an empty text (ADR 0071).
- A deleted account's timeline replies stay, under "deleted account" (ADR 0072).
- `search_comments` lists comments on unlisted articles (ADR 0073).
- Muted words fold text, not images; titles-only lists are not folded.
- There is no About page; the contact line is in the footer and on the
  policy pages.
- A moved article's remote copies stay where they were (ADR 0075).
- A bot's skipped entries are skipped for good; re-posting one means deleting
  its `bot_syndication_items` row. The dry run uses the *saved* settings, and
  a bot keeps no fetch history.
- Announcements are plain text, at most three show, with no scheduled start.
- The comment tree (an EEx `for`) is not keyed (P8-D6).

## Settled — do not re-file

- **The Aqua themes keep their `.card > .card-body` selectors** (operator,
  2026-09-19). They normalise the shape of *any* card with an Aqua title bar
  — the component, not an element that could carry a handle — so they are
  not the structural selectors ADR 0018 refuses.
- **No `/admin/roles` screen:** roles are four and fixed (ADR 0042); revisiting
  it supersedes 0042 and needs a migration backfilling grants.
- **`Baudrate.Content.Feed` keeps its name** (operator, 2026-09-19).
- **Retention keeps a timeline item that has likes, boosts or replies** —
  P2-D4 said "bookmarked", but a timeline item cannot be bookmarked.
- **The home page's empty state never says whether boards exist**: "none for
  you" is exactly what `min_role_to_view` keeps.

## How the phases were worked

- **A stage's list is a prompt to go and read, never a specification.**
  Reading it against the code changed every stage of Phases 4 and 5.
- **A fix drifts to wherever a rule is written twice**; a gate over one of two
  copies reports a rule half enforced.
- **A number in a TODO goes stale**; recurring chores become gates
  (`translation_coverage_test.exs`).

---

## Decisions

| Id | Decision | Recorded in |
|---|---|---|
| D1 | Local posts are Public or Unlisted only; DMs are the private channel | `CLAUDE.md` (AP visibility) |
| D2 | One server | ADR 0033 |
| D3 | No email; recovery is anchored on an OpenPGP key | ADR 0058, 0067, 0068 |
| D4 | Export and move need TOTP enabled ≥ 7 days | ADR 0023, 0025 |
| P1-D1 – D9 | Trust and safety: blocks, sanctions, domain blocks, terms, rules, cross-posted moderation (P1-D5), evidence copies (P1-D6); no outbound `Block` (P1-D1) | ADR 0026–0032, `CLAUDE.md` |
| P2-D1 | No metrics endpoint: the loopback health report is the one place to poll | ADR 0035 |
| P2-D2 | No error-reporting service: a third party would receive request data | ADR 0035 |
| P2-D3 | Releases built and attested in CI — amended: the deploy builds on the server | ADR 0036, 0037 |
| P2-D4 | Retention: untouched timeline items 90 days, announces 180, soft-deleted rows after the 90-day evidence window | ADR 0040 |
| P3-D1 – D3 | Rewrite existing fragment ids; unknown handles resolve by WebFinger; a mention never widens the audience | ADR 0050, 0051 |
| P4-D1 – D3 | Nothing ranked or rivered; registering signs you in; recovery via a verified OpenPGP signature | ADR 0054–0056, 0058 |
| P5-D1 – D3 | Proof of work, not a CAPTCHA; trust is three days and three posts; filters block, hold or flag | ADR 0063–0065 |
| P6-D1 – D2 | Editing comments; what account deletion removes | ADR 0060, 0072 |
| P7-D1 – D4 | Three releases; announcements dismissed per member or browser; moving needs both boards' rights; the last-board leak fixed first (v1.42.1) | ADR 0075, `CLAUDE.md` |
| P8-D1 | Rust stays required: no precompiled NIFs; the dev container is the easy path | `CLAUDE.md` (CI) |
| P8-D2 | Vulnerabilities reported by email with OpenPGP | `SECURITY.md` |
| P8-D3 | `doc/door-apps-development.md` removed | Backlog |
| P8-D4 | Keyset pagination for the ActivityPub collections only | `CLAUDE.md`, `doc/api.md` |
| P8-D5 | Phase 8 as one major release | v2.0.0 |
| P8-D6 | Keyed comprehensions, not streams, for bounded lists | `CLAUDE.md` |
| P8-D7 | One Erlang/Elixir version everywhere; the type checker is followed | `CLAUDE.md` |

## Phases

Stage ids resolve here; the detail is in the records and `CHANGELOG.md`.

| Phase | Stages | Released | Records |
|---|---|---|---|
| 0 Correctness | the review's twelve bugs | v1.18.2 | `CHANGELOG.md` |
| 1 Trust and safety | 1A blocks, 1B report queue, 1C sanctions, 1D domain blocks, 1E terms, 1F rules | v1.19.0 – v1.21.0 | ADR 0026, 0029–0032 |
| 2 Operability | 2A backups and alerts, 2B one node, 2C committed federation, 2D health report, 2E deploy safety, 2F retention, 2G keys, 2H PostgreSQL drift | v1.23.0 – v1.30.0 | ADR 0028, 0033–0038, 0040, 0044 |
| 3 Federation reach | 3A threading and mentions, 3B object ids, 3C group announces, 3D actor updates, 3E content warnings, 3F NodeInfo | v1.31.0 | ADR 0050–0053 |
| 4 Discovery and onboarding | 4A home, 4B SEO and feeds, 4C search, 4D onboarding and recovery, 4E sharing and PWA, 4F language | v1.32.0 – v1.34.0 | ADR 0054–0059 |
| 5 Anti-spam | 5A proof of work, 5B new-account limits, 5C held posts, 5D filters, 5E IP bans | v1.37.0 – v1.39.0 | ADR 0063–0066 |
| 6 Member depth | 6A editing, alt text, drafts; 6B reading; 6C watching; 6D DMs; 6E-1 account pages, 6E-2 deletion, 6E-3 privacy | v1.35.0 – v1.42.0 | ADR 0060–0062, 0069–0073 |
| 7 Admin and content tools | 7A dashboard, 7B announcements, 7C moves, 7D bots, 7E delivery queue | v1.43.0 – v1.45.0 | ADR 0074, 0075 |
| 8 Contributor health | 8A CI checks, 8B repository files, 8C dev container, 8D performance | v2.0.0 | `CLAUDE.md`, `CONTRIBUTING.md` |

The 2026-09-19 ADR audit (ADR 0046–0049) is in `CHANGELOG.md` (v1.29.0–v1.30.0).

---

## Backlog (not planned)

None of these are scheduled; propose moving one into a phase before working on it.

- **Scale and storage:** multi-node clustering (ruled out by D2), S3-compatible storage, a CDN.
- **APIs:** a Mastodon-compatible client API, OAuth, a REST API, webhooks, plugins or themes.
- **Federation:** custom emoji and quote posts; relays and backfilling remote outboxes or threads; the `featured` collection, `Add`/`Remove` and `contentMap`; RFC 9421 signatures; silence and reject-media domain levels; outbound `Block` (ruled out by P1-D1).
- **Members:** group DMs, read receipts, emoji reactions, inline image placement, reply depth beyond 5, RTL layout, `hreflang` links.
- **Content tools:** splitting and merging threads, custom pages beyond Rules, Terms and Privacy.
- **Extensions:** interactive "door apps" (WASM plug-ins; P8-D3).
- **Legal:** a takedown and legal-request workflow, age gating.
- **Email:** ruled out by D3.
