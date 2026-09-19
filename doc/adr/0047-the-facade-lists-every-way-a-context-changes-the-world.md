# 0047 — The facade lists every way a context changes the world

- **Status:** Accepted
- **Date:** 2026-09-19
- **Deciders:** Baudrate maintainers
- **Amends** [0002](0002-context-facades.md), whose rule — "external callers …
  always call `Auth.f/n` or `Federation.f/n` and never reach into a
  sub-module" — has never been what the code does. 0002's structure, its
  reasons and its consequences all stand; this narrows the one sentence that
  was written as absolute and was not.

## Context

A record-by-record audit of the ADRs against the code (2026-09-19) found 0002's
facade rule to be the largest gap between a record and practice — not a
regression that crept in, but a rule that was stricter on paper than it ever
was in fact:

- `Content.Markdown.to_html/1` has 16 web call sites and
  `Content.ArticleImageStorage.image_url/1` fifteen. Neither is delegated on
  `Content` at all, so the facade never covered them: this is not erosion, it
  is a rule that was never enforced.
- Every LiveView that subscribes to a topic addresses `Content.PubSub`,
  `Messaging.PubSub`, `Notification.PubSub` or `Federation.PubSub` directly.
- Every form that builds a changeset addresses the schema: `Setup.User`,
  `Content.Board`, `Bots.Bot`, `Setup.Rule`.
- The plugs verify signatures through `Federation.HTTPSignature`, and the
  ActivityPub controller admits activities through `Federation.Inbound`.
- The `/admin` dashboards read `Federation.DeliveryStats`,
  `InstanceStats`, `BlocklistAudit` and `Moderation.Log`.

Delegating all of that would add something like fifty `defdelegate` lines whose
only content is the name on the other side. The facade is supposed to be an
index of what a context can do; an index of everything is not an index.

But the audit also found a subset where the absence is not benign: admin
LiveViews calling **mutating** federation operations directly —
`DomainBlocks.block_domain/3`, `RemoteActors.suspend/3`,
`Delivery.deliver_flag/2`. Nothing on `Federation` said this instance can block
a domain or suspend an actor. Someone reading the facade to learn what
federation does would not find the two operations with the widest blast radius
in the context.

## Decision

**The facade lists every way a context changes the world.** An operation that
writes state a member, a moderator or a remote instance can observe is reached
through `Auth.f/n`, `Content.f/n`, `Federation.f/n`, and is named there.

Everything else **may** address a sub-module directly. The facade stays the
default for reads — most already go through it, and moving one there later
costs nothing — but it is not a rule, and these five categories are
deliberately outside it:

1. **Render helpers.** Pure functions called from templates:
   `Content.Markdown.to_html/1`, `ArticleImageStorage.image_url/1`. No
   database, no authorization, no state.
2. **Schemas.** Form changesets and compile-time constants —
   `Setup.User.bio_changeset/2`, `Content.ArticleImage.max_images_per_article/0`,
   `Moderation.Report.categories/0`. A delegate to a struct or a constant is an
   indirection with nothing behind it.
3. **PubSub topics.** A LiveView subscribing to a topic is not invoking an
   operation; there is nothing to delegate.
4. **Plumbing the web tier is half of.** `Federation.HTTPSignature` in the
   plugs, `Federation.Inbound.accept/4` in the ActivityPub controller,
   `Setup.InstallationKey` in `EnsureSetup`, `Auth.WebAuthnChallenges.pop/3` in
   `SessionController`. These implement the boundary rather than call across
   it.
5. **Admin read models.** Dashboard queries with no counterpart in the
   members' UI: `DeliveryStats`, `InstanceStats`, `BlocklistAudit`,
   `Moderation.Log`.

**The facade is not an authorization boundary.** 0002 already says so in its
consequences, and [0016](0016-authorization-at-the-context-boundary.md) is why:
checks live in the sub-module that performs the operation, precisely so that
the facade *can* be bypassed without bypassing them. Nothing in this record
changes that, and a new mutation must not rely on the facade to enforce
anything.

## Alternatives considered

- **Add the fifty delegates and keep 0002 as written.** The rule becomes true
  and the facade stops being an index. It also makes every template change that
  needs a new render helper a two-file change, for no reader's benefit.
- **Drop the facade rule entirely and let callers address sub-modules.** Loses
  what 0002 bought: a sub-module can be split or renamed without touching
  callers, and there is one place that answers "what can this context do".
  `Federation.Feed` → `Federation.Timeline`
  ([0039](0039-the-personal-stream-is-a-timeline.md)) is the worked example —
  it touched the facade and almost nothing else.
- **Draw the line at "touches the database" rather than "changes the world".**
  Puts every list and count on the wrong side, which is the fifty-delegate
  outcome again.
- **Leave it and note the gap in `doc/TODOs.md`.** Where it sat since the
  audit. A rule that everybody knows is not the rule teaches people to read the
  ADRs as aspiration.

## Consequences

- `Federation` gains `block_domain/3`, `unblock_domain/1`,
  `suspend_remote_actor/3`, `unsuspend_remote_actor/1` and `deliver_flag/2`,
  and the three admin LiveViews call those. The read models on the same screens
  stay as they are, under category 5.
- The rule is now checkable by a reader: find the mutations, check they are on
  the facade. It is deliberately *not* checked by a test — "changes the world"
  is a judgement, and a test that approximated it would either fail on render
  helpers or pass on things it should catch. The review question is "does this
  new function write something anyone can see?", and if so it is named on the
  facade.
- The five categories will need revisiting if one grows a mutation. The most
  likely is category 4: `KeyStore.ensure_*_keypair/1` is called from the
  ActivityPub controller and two LiveViews and *does* write, as self-healing
  plumbing behind a read. It is left directly addressed deliberately —
  `CLAUDE.md` documents calling it by name before enqueuing a signed activity —
  and this is the exception worth remembering, not a precedent for more.

## Acceptance gate

None, by the decision above. The nearest thing is
`test/baudrate/setup/permissions_are_enforced_test.exs`, which shows the shape
such a test would need — an explicit list of known exceptions that fails when a
new one appears — and the reason it works there is that permissions are a
closed catalogue. Context functions are not.
