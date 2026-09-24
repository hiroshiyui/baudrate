# 0074 — The dashboard reads the health checks behind the admin session

- **Status:** Accepted
- **Date:** 2026-09-24
- **Deciders:** Baudrate maintainers
- **Refines** [0035](0035-operational-visibility-stays-on-the-host.md): the
  report is still served whole only on the loopback listener, and an admin
  now also sees each check's status on `/admin`. Everything else in 0035,
  and 0044's alerting, stands.
- **Related:** Phase 7A and 7E; the circuit breaker of
  [0034](0034-federation-work-is-committed-before-it-is-acknowledged.md);
  the moderation log that records overrides; the role rules of
  [0042](0042-roles-are-ordered-and-capabilities-are-not-configurable.md).

## Context

Phase 7's goal is that running the site does not need a shell or SQL. Until
now, the state of the site was spread over a dozen admin pages, and part of
it was reachable only from the host: the health report
(`Baudrate.Health.report/1`) is served on a loopback port, deliberately.
0035 refused to serve it on the public endpoint because a path restricted
"to localhost" admits everyone behind nginx, and because the report is read
by anyone with a shell.

That left an admin who suspects a problem with two options: open a shell,
or wait up to two hours for 0044's alert. Neither suits a site run by
volunteers from a browser.

Two further gaps showed up while planning the delivery page:

- The per-domain bulk retry and abandon matched `LIKE '%domain%'` against
  the inbox URL, so `example.com` also meant `notexample.com` and
  `example.com.evil`. Nothing in the UI called them yet; a page would have.
- `retry_job/1` set any job back to `pending`, including a delivered one,
  which would send its activity twice.

## Decision

### 1. `/admin` shows each check's status, and serves no report

The dashboard runs `Health.report/1` after the page connects and shows, for
each check, a translated name, `OK` / `Failing` / `Not checked`, and a few
of its figures (queue lengths, free space, backup age).

- **Admins only.** It is behind the admin session and its ten-minute sudo
  re-verification, like every other admin page. That is authentication,
  not an address check, which is the distinction 0035 drew.
- **No report text.** The report's `reason` strings are English for the
  operator's shell, and the page never shows them.
- **No endpoint.** There is no JSON and no route that returns the report.
  The loopback listener stays the only place it is served whole, and the
  one an external monitor polls.

### 2. Moderators see the queues they work, and nothing else

A moderator's `/admin` shows open reports, held posts they could approve and
pending registrations, which are the three queues they act on. Members,
federation figures and health are for admins. Every figure is a count that
links to its queue; the page names no account, board or remote domain.

### 3. Members are counted once

The dashboard's member total and NodeInfo's `users.total` use one query,
`Auth.counted_members_query/0`: people, not bots, and neither banned nor
deleted. Two definitions of "member" drift, and the instance would then
report one size to the fediverse and another to its own admins.

### 4. Delivery actions match the stored domain exactly, and an override is logged

The delivery page (`/admin/federation/delivery`) filters jobs by
`delivery_jobs.domain` with equality, and the bulk actions act only on the
domain the page is filtered by, never a value carried in the event.

- **Retry and abandon are conditional.** Each is one conditional `UPDATE`
  from the states it makes sense in: retry from `failed`, abandon from
  `pending` or `failed`. A job the worker finished meanwhile is not dragged
  back.
- **Closing a circuit deletes its row.** No row already means healthy
  (0034). If the server is still down, five failures open the circuit again.
- **Two actions are logged.** Abandoning a domain's jobs drops activities
  for good, and closing a circuit overrides the breaker, so both go in the
  moderation log. Retrying only moves a job earlier in its queue, so it is
  not logged.

## Alternatives considered

- **Serving the report on the public endpoint behind the admin session.**
  A JSON route invites a monitor to poll it with an admin's cookie, which
  would be a long-lived admin credential sitting in a monitoring tool.
- **Rendering the report's reasons.** They are untranslated, and 0035 kept
  them terse because only the operator reads them.
- **A dashboard with history (charts of members and deliveries).** P2-D1
  declined metrics; a single instance does not need a time series, and
  counts over a window say what an admin needs.
- **Showing moderators everything.** The federation and health figures are
  operational, and a moderator can act on none of them.
- **Keeping the substring match and escaping it.** Escaping stops `%`
  matching everything; it does not stop `example.com` matching
  `notexample.com`. The column the jobs already carry is the right key.

## Consequences

- An admin can see a failing check without a shell, and 0044's alert now
  points at a page that shows it.
- The dashboard runs every check on each visit. The checks are bounded at
  five seconds each and run in parallel, and only admins trigger them.
- `test/baudrate_web/live/admin/dashboard_live_test.exs` checks that the
  report's reasons never reach the page and that moderators see only their
  section; `test/baudrate/dashboard_test.exs` checks the member count
  against NodeInfo; `delivery_live_test.exs` and `delivery_stats_test.exs`
  check the exact-domain match, the conditional transitions and the log.
