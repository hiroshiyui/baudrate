# 0002 — Context facades over focused sub-modules

- **Status:** Accepted; the sub-module list names `Federation.Feed`, which
  [0041](0041-rss-and-atom-are-syndication.md) and
  [0039](0039-the-personal-stream-is-a-timeline.md) renamed to
  `Federation.Timeline`. The "never reach into a sub-module" rule is amended by
  [0047](0047-the-facade-lists-every-way-a-context-changes-the-world.md), which
  narrows it to the operations that change the world and names what is exempt
- **Date:** Recorded retroactively 2026-08-09

## Context

Phoenix contexts are the public API of the business logic. Baudrate's contexts
grew far past a comfortable file size: `Auth` covers registration, passwords,
sessions, TOTP, WebAuthn, invites, profiles and user moderation; `Federation`
covers actors, signatures, delivery, collections, inbox dispatch and feeds.

Two bad outcomes were available. Split the contexts into many top-level modules
and every caller has to know which one owns a function — a rename then touches
every LiveView. Or leave them as multi-thousand-line files and lose all
navigability.

## Decision

Keep **one context module as a facade** and delegate to focused sub-modules
under its namespace.

- `Baudrate.Auth` → `Auth.Users`, `Auth.Passwords`, `Auth.Sessions`,
  `Auth.SecondFactor`, `Auth.WebAuthn`, `Auth.Invites`, `Auth.Profiles`,
  `Auth.Moderation`
- `Baudrate.Federation` → `Federation.Discovery`, `ActorRenderer`,
  `ObjectBuilder`, `Collections`, `Follows`, `Feed`, `InboxHandler`,
  `Publisher`, `Delivery`, `ActorResolver`, `HTTPSignature`, `KeyStore`,
  `Validator`, `Visibility`
- `Baudrate.Content` → `Content.Articles`, `Comments`, `Likes`, `Interactions`,
  and friends

External callers — LiveViews, controllers, inbox handlers, tests — always call
`Auth.f/n` or `Federation.f/n` and never reach into a sub-module. Each module
lives in its own file; never nest modules in one file.

## Consequences

- Sub-modules can be split, merged or renamed without touching callers.
- The facade file doubles as an index of what the context can do.
- Cost: the facade is mostly `defdelegate` boilerplate that must be kept in
  sync, and a new function is easy to forget to expose. The delegation is
  mechanical enough that this is caught by the first caller.
- Authorization checks belong in the sub-module that owns the operation, so
  that the facade cannot be bypassed (ADR 0016).

## Alternatives considered

- **Flat contexts with no sub-modules.** Rejected: unnavigable at this size.
- **Many top-level contexts, no facade.** Rejected: leaks internal structure
  into every call site and makes reorganisation expensive.
