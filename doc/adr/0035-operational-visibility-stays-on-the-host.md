# 0035 — Operational visibility stays on the host

- **Status:** Accepted
- **Date:** 2026-09-17
- **Deciders:** Baudrate maintainers
- **Related:** implements Phase 2D and decisions P2-D1 (no metrics endpoint)
  and P2-D2 (no error reporting service), both made 2026-09-17; relies on
  [0033](0033-baudrate-runs-on-one-node.md) (one node, so worker liveness can
  live in memory); reports on [0028](0028-backups-are-complete-folders-with-count-based-retention.md)
  (backups) and [0034](0034-federation-work-is-committed-before-it-is-acknowledged.md)
  (the queues and circuit breaker)

## Context

Before this decision, the only thing an operator could poll was the public
`/health`, which runs `SELECT 1`. A delivery queue that had stopped moving, a
worker crashing on every run, a filling disk or a backup that had not run for
three days all answered `{"status":"ok"}`. The first sign would be a member
noticing, or a restore that found nothing recent.

P2-D1 declined a metrics endpoint (Prometheus, OpenTelemetry): more surface to
secure, for history a single instance does not need yet. P2-D2 declined an
error reporting service: sending exceptions to a third party sends request
data with them. That left a detailed health view and the logs, and two
questions:

- **Where can the detailed view be served?** "Only from localhost" is
  meaningless on the public endpoint. nginx runs on the same host and proxies
  every visitor from `127.0.0.1`, so a check on the peer address would admit
  the whole internet. A check on forwarding headers would depend on nginx
  configuration never drifting.
- **What does the view reveal?** Anyone with a shell on the host can read a
  loopback port, including the other applications that share this server.

## Decision

### 1. The detailed report has its own loopback listener

`BaudrateWeb.HealthDetail` is a separate Bandit listener, started only when
`HEALTH_DETAIL_PORT` is set.

- **Address:** bound to `127.0.0.1`. The address is fixed in code and cannot
  be configured, so no configuration change can expose the report.
- **Surface:** it answers `GET /health` and nothing else, with no router,
  session or cookies.
- **Not public:** nginx does not proxy the port and the firewall does not open
  it.

### 2. The report says whether the site works, not just whether it runs

`Baudrate.Health.report/1` returns `200` when every check passes and `503`
when one fails, so a monitor can alert on the status code alone. The checks:

- **database:** it answers.
- **delivery queue:** no delivery has been due for more than 15 minutes
  (excluding jobs an open circuit holds on purpose).
- **inbound queue:** no activity has waited for more than 10 minutes.
- **workers:** each has completed a run within three of its intervals.
- **disk:** free space under the uploads directory is above the floor backups
  keep.
- **backup:** the newest complete backup is under 26 hours old.

Each check runs with a time limit, so a hung dependency fails its check
instead of hanging the report.

Liveness means a **completed run**, not a live process. A worker calls
`Health.Heartbeat.beat/1` at the end of a successful run, into ETS, in
monotonic time. A worker that crashes on every run and is restarted each time
has a live process almost continuously, and it never beats.

### 3. The report holds counts, ages and statuses

There is no content, no account names and no remote domains in the report. A
check that raises reports a fixed reason, never the exception text, which
could hold query fragments or paths. The operator has the database for
detail; the report only has to say where to look.

### 4. Logs are the error channel, and JSON logs show no more than text

`LOG_FORMAT=json` swaps the default handler's formatter for
`Baudrate.Logger.JSONFormatter`, a small in-tree module rather than a library.

- **Fields:** `time`, `level`, `message`, and an allow-list of metadata
  (`request_id`, and `module` and `function` from the call site). Metadata a
  library adds never reaches the log.
- **One line per event:** a newline inside a message is escaped, so a message
  cannot fake a second log entry.
- **It never raises:** a formatter that raises gets its handler removed, which
  silently ends all logging. Invalid UTF-8 is replaced, and anything else
  falls back to a fixed line.

### 5. Baudrate does not notify

The operator chose, for Phase 2D, to document how to poll and alert rather
than to ship a notifier. The sysop guide shows a systemd timer with
`OnFailure=` and a monitor running on the host. The app has no email
(D3), no push channel, and no stored notification credentials.

## Alternatives considered

- **A metrics endpoint.** Declined by P2-D1.
- **An error reporting service.** Declined by P2-D2.
- **A path on the public endpoint restricted to localhost.** Every request
  already arrives from localhost through nginx. Restricting it by forwarding
  headers or nginx `deny` rules makes an exposure one misconfiguration away.
- **`bin/baudrate rpc` from a script.** It needs Erlang distribution and the
  release cookie. The cookie changes with each release build, so a poller
  breaks across deploys, and each poll starts a whole VM.
- **Liveness from `Process.whereis/1`.** A process that is restarted every
  minute is alive most of the time.
- **A JSON logging library.** A dependency for about a hundred lines of code,
  whose metadata handling would still need checking against what we allow.
- **Shipping a notifier** (a push service, a webhook, mail through a local
  MTA). Offered and declined for now. It remains open under 2A, "alert on a
  failed or stale backup".

## Consequences

- A stuck queue, a dead worker, a full disk and a stale backup each turn the
  report `503`, but only a monitor the operator sets up turns that into an
  alert.
- The instance listens on one more loopback port (4001 on Ansible installs).
- A new periodic worker must beat after each completed run and be added to
  `Health`'s worker list, or its failures will not show.
- A new check must keep to counts, ages and statuses, and must fail within its
  time limit instead of blocking.

## Acceptance gate

- **Checks:** `test/baudrate/health_test.exs` breaks each check's condition
  and requires it to fail (and to pass otherwise), including a check that
  times out and one that raises.
- **Listener:** `test/baudrate_web/health_detail_test.exs` requires the
  listener to be bound to `127.0.0.1` and its address not to be configurable.
- **Logs:** `test/baudrate/logger/json_formatter_test.exs` covers the metadata
  allow-list, escaped newlines, invalid UTF-8, and an event that cannot be
  formatted.
