# 0014 — ETS caches for settings, boards and domain blocks

- **Status:** Accepted
- **Date:** Recorded retroactively 2026-08-09

## Context

Three lookups happen on nearly every request and are almost never written:

- **Site settings** — theme, registration mode, instance name; read by plugs
  (`SetTheme`, `EnsureSetup`) on every browser request.
- **Boards** — resolved by id, slug and hierarchy on every board and article
  page, and again for federation gating.
- **Domain blocks** — consulted for every inbound activity and every outbound
  delivery.

Hitting PostgreSQL for each of these on every request is pure overhead on a
read-dominated workload, and the domain-block lookup sits directly in the
federation hot path.

## Decision

Cache all three in ETS behind GenServers in the supervision tree:

| Cache | Backing |
|---|---|
| `Baudrate.Setup.SettingsCache` | `settings` table |
| `Baudrate.Content.BoardCache` | `boards` table |
| `Baudrate.Federation.DomainBlockCache` | domain block settings |

Invalidation is **write-through at the context boundary**, not TTL-based:

- `Setup.set_setting/2` refreshes the settings cache on success.
- `Content.create_board/update_board/delete_board/toggle_board_federation`
  refresh the board cache.
- Any direct DB write to `settings` (a migration, a console session) **must**
  call `SettingsCache.refresh/0` manually — the cache cannot see it.

**Startup order is a real dependency:** `SettingsCache` must start before
`DomainBlockCache`, because `DomainBlockCache.init/1` calls
`Setup.get_setting/1`. The order in `application.ex` is load-bearing and is
commented as such.

In tests, the settings cache is disabled (`settings_cache_enabled: false`) so
per-test setting changes take effect immediately; the board cache runs
normally, since board mutations go through the context.

## Consequences

- Settings and board lookups cost an ETS read.
- Stale data is possible only via a path that bypasses the context — which is
  exactly the rule stated above.
- Caches are per-node. Under clustering they would diverge and need PubSub
  invalidation; single-node is the assumed deployment (see ADR 0013).
- Reordering `application.ex` children can break boot in a way that is not
  obvious from the error.

## Alternatives considered

- **TTL expiry.** Rejected: introduces a window where an admin's change appears
  not to have worked, for no gain — writes are rare and go through one place.
- **No caching.** Rejected: several DB round trips added to every page render,
  including in the federation hot path.
