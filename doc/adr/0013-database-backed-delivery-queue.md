# 0013 — A database-backed delivery queue instead of a job framework

- **Status:** Accepted
- **Date:** Recorded retroactively 2026-08-09

## Context

Outbound ActivityPub delivery is the least reliable thing the system does. Each
activity fans out to many remote inboxes; individual hosts are slow, down,
rate-limiting, or permanently gone. Deliveries must survive a restart, retry
with backoff, and never block the web request that triggered them.

That is the classic case for a job framework — Oban being the obvious Elixir
choice. But Baudrate has exactly one job type, it already runs PostgreSQL, and
the target audience is sysops running a single node who benefit from every
dependency the release does not have.

## Decision

Implement delivery directly:

| Module | Role |
|---|---|
| `Federation.Publisher` | Builds the ActivityStreams JSON and enqueues |
| `Federation.DeliveryJob` | Ecto schema — the queue table |
| `Federation.Delivery` | Signs, POSTs, records outcome, schedules retry with exponential backoff |
| `Federation.DeliveryWorker` | GenServer polling the queue every 60 s |
| `Federation.TaskSupervisor` | Supervises the async delivery tasks |

Related decisions:

- Delivery runs in async `Task`s in production but **synchronously in tests**
  (`federation_async: false` in `config/test.exs`), because an async task does
  not own the Ecto sandbox connection and would fail with ownership errors.
- `Delivery.get_private_key/1` is the single signing chokepoint and is
  self-healing (ADR 0010).
- `Announce` routing is loop-safe by construction:
  `create_remote_article` does **not** trigger `publish_article_created`, so an
  inbound boost cannot start a re-announce storm.

## Consequences

- No Oban, no broker, no extra table migrations from a third party. `mix
  release` plus PostgreSQL is the whole deployment.
- Polling every 60 s means up to a minute of latency on a retry — acceptable
  for federation, where remote instances already batch and delay.
- We own the retry policy, dead-lettering and observability
  (`Federation.DeliveryStats`) that a framework would have supplied. If the
  system ever grows a second and third job type, revisit this: reimplementing
  Oban badly is the failure mode to watch for.
- The single-node polling design assumes one worker; running multiple nodes
  would need row locking to avoid double delivery.

## Alternatives considered

- **Oban.** Rejected for now on dependency-footprint grounds, with the explicit
  caveat above. This is the most likely ADR to be superseded.
- **Fire-and-forget `Task` with no persistence.** Rejected: a restart silently
  drops activities, and remote instances have no way to ask for them again.
