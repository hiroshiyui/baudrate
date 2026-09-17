# 0034 — Federation work is committed before it is acknowledged

- **Status:** Accepted
- **Date:** 2026-09-17
- **Deciders:** Baudrate maintainers
- **Related:** builds on [0013](0013-database-backed-delivery-queue.md) (the
  delivery queue), whose caveat about a second job type it answers; relies on
  [0033](0033-baudrate-runs-on-one-node.md) (one node, so jobs are claimed
  without row locks); implements Phase 2C of the product review

## Context

ADR 0013 made the delivery queue durable: once a `DeliveryJob` row exists, a
restart does not lose it. Three gaps were left around that queue.

- **Before the row existed, nothing was durable.** Every content change
  committed first, then started a `Task` that built the activity, resolved the
  follower inboxes and inserted the jobs. A restart, a deploy or a crash in
  that window saved the post, like, follow or direct message and dropped its
  activities without a trace. `Accept(Follow)` and `Reject(Follow)` never
  reached the queue at all: they were one POST from a task, so a single failed
  request left the remote side's follow pending for good.
- **Failing servers held the worker.** Each job for a server that was down
  waited out its own connection or request timeout, while deliveries to
  healthy servers queued behind it. The task timeout (45 s) was also shorter
  than the HTTP request deadline (60 s), and a killed task left its job
  untouched, so a slow server's job was retried on every poll and never
  abandoned.
- **Inbound work ran inside the sender's request.** Handling an activity can
  resolve unknown actors, walk a reply chain of up to five fetches, or fetch
  an announced object. All of it happened while the remote server's HTTP
  request waited, holding a web process and database connections. The pool is
  10 connections, so a remote instance sending many such activities could
  slow the site down for everyone.

New activities also waited up to a minute for the next poll.

ADR 0013 warned that a second job type should reopen the question of a job
framework, since "reimplementing Oban badly is the failure mode to watch for".
An inbound queue is that second job type.

## Decision

### 1. A change and its delivery jobs commit together

Publishing runs inside the transaction that makes the change: as a step of
the change's own `Ecto.Multi`, or through `Federation.federate/2`, which runs
the change, calls the publisher with its result, and commits both or neither.
Accept and Reject are queued like every other activity (`Delivery.enqueue_accept/3`,
`enqueue_reject/3`) in the transaction that writes the follower row.

A publisher that raises now rolls back the change: a member sees an error
instead of a post that is never federated. Every publisher reads only the
database, so the transaction never waits on a remote server.

`schedule_federation_task/1` stays for best-effort work only (fetching remote
images, warming the media cache, link previews). No function handed to it, or
to a `Task`, may publish or enqueue.

### 2. The worker wakes on commit

`Delivery.enqueue/3` inserts all of an activity's jobs in one statement and
calls `pg_notify`. PostgreSQL delivers a notification only when the sending
transaction commits, which is exactly when the jobs become visible, and a
rolled-back change wakes nobody. `DeliveryWorker` listens on a dedicated
connection (`Postgrex.Notifications`, reconnecting on its own). The 60-second
poll remains, for retries coming due and for notifications missed while the
listener reconnects.

### 3. Deliveries have a deadline and are always recorded

The worker keeps up to 10 deliveries in flight and starts another as soon as
one finishes, instead of waiting for a whole batch. A delivery still running
15 seconds after the HTTP request deadline is killed and counts as a failed
attempt, as does a task that crashes.

A final 4xx response (anything but 401, 408 and 429) abandons the job at once,
as Mastodon does, instead of retrying it five more times over fifteen hours.

### 4. A per-domain circuit breaker, kept in the database

`DeliveryCircuits` records unreachable results per inbox domain: connection
and TLS errors, timeouts, DNS failures, 5xx and 429. After 5 in a row, the
domain's jobs are held back together. When the wait ends, one job is sent as a
probe, with at most one probe in flight per domain, and probes use at most
half the slots. A failed probe reopens the circuit for the next step (5 min,
30 min, 2 h, 6 h, 12 h, then 24 h). Any response that shows the server is
reachable, including a 404, closes it.

The state is a table (`delivery_circuits`), not ETS, so a restart does not
send a burst to every server that was down, and the Phase 2D health view can
read it. Held jobs do not use up their attempts, so a job still waiting after
7 days is abandoned by age.

### 5. The inbox stores, answers, and processes later

After the plugs have verified the signature, limited the rate and capped the
body, the inbox runs the admission checks in their existing order
(`InboxHandler.admit/2`), stores the activity in `inbound_activities` and
answers `202`. An activity is unique per signing actor and activity id, so a
redelivery is answered and not stored again, and one account cannot claim an
id that another account on its server has yet to send.

`InboundWorker` processes stored activities:

- **Concurrency:** at most 4 at a time, below the database pool size.
- **Ordering:** one activity per remote actor at a time, oldest first, so a
  `Create` and the `Delete` sent after it cannot run in the wrong order and
  one busy actor cannot take every slot.
- **Admission, again:** processing runs `InboxHandler.handle/3`, which repeats
  the admission checks, because a domain may have been blocked or an actor
  suspended since the activity arrived.
- **Refusals:** an activity the handler refuses is marked rejected with its
  reason, as the 422 response used to record it.
- **Crashes:** a crash or a timeout (5 minutes) is retried after a backoff, at
  most 3 attempts in all. The attempt is counted before the work, so an
  activity that takes the node down with it is eventually given up.

The stored JSON, which can be a direct message, is cleared once processing
ends, whatever the outcome. The row stays for 7 days to recognise
redeliveries.

### 6. Still our own queue, not a job framework

The parts of this stage that carry the risk are the per-domain breaker and
processing one activity at a time per actor. In Oban both are paid Pro
features (partitioned queues and rate limits), so they would be built by hand
on top of a new dependency anyway. The two queues share only the pattern:
tasks under `Federation.TaskSupervisor`, a deadline, and a poll as the
fallback. What 0013 said still holds: if a third job type arrives, weigh
adopting a framework again before adding it.

## Alternatives considered

- **Adopt Oban.** Oban would supply transactional insert, pruning and rescue
  of orphaned jobs. The costs: a new dependency on the supply-chain surface
  ADR 0027 guards, migrating pending jobs, rewriting `DeliveryStats` and the
  admin delivery views, and building the breaker and per-actor ordering on top
  regardless. Declined for now (see decision 6).
- **Outbox rows expanded by a worker.** The transaction would store only an
  "article created" row, and a worker would later build the activity and
  resolve followers. Fan-out would leave the request, and a publisher bug
  would no longer block posting. But undo activities need values the change
  deletes (a like's `ap_id`), so the row would have to carry them, and each of
  some forty call sites would need a serialisable description of its
  activity. Building in the transaction is simpler, and fan-out to followers
  is one indexed query and one insert.
- **Wake the worker from application code after commit.** Ecto has no
  after-commit hook, and publishing runs deep inside other functions'
  transactions, so every call site would have to remember to wake it. The
  notification is tied to the commit by PostgreSQL itself.
- **Keep the breaker in ETS.** Correct on one node (ADR 0033), but lost on
  restart, which is when a burst to every dead server would do most harm, and
  invisible to the health view.
- **Keep processing inbound activities in the request, with a semaphore.** A
  limit on concurrent handlers would protect the pool, but the sender's
  request would still wait, and a remote server that times out and retries
  multiplies the work. A stored activity survives our restart, too.

## Consequences

- Nothing a member does is saved without its activities queued. The window
  where a restart lost them is gone, and so is the one where Accept was lost.
- Publishing errors now fail the change instead of passing silently.
- Deliveries start within moments of the commit. The instance holds one more
  PostgreSQL connection than `POOL_SIZE`. A connection pooler in transaction
  mode (PgBouncer) cannot carry `LISTEN`; without one it degrades to the poll.
- A server that is down costs one probe per interval instead of a slot for
  every job.
- Remote senders always get 202 for an admitted activity. Why the handler
  refused one is in the log and in `inbound_activities.last_error`, not in
  the response. Senders never acted on that response anyway.
- Inbound processing is at-least-once: a restart in the middle runs an
  activity again. The handlers were already idempotent under redelivery
  (unique `ap_id`s, follower rows), because remote servers retry too.
- Code that publishes must follow decision 1. The acceptance gate enforces
  it.

## Acceptance gate

`test/baudrate/federation/durable_delivery_test.exs` has three kinds of check:

- **Discarded tasks:** it discards every background task, as a restart would,
  and requires each kind of change to leave its delivery job.
- **Rollback:** it requires a rolled-back change to take its jobs with it.
- **No publishing from tasks:** it walks `lib/` and fails on any function
  handed to `schedule_federation_task/1` or a `Task` that publishes or
  enqueues.

Four more test files cover the queues themselves:

- `delivery_worker_test.exs`: the concurrency limit, waking on a committed
  `NOTIFY`, the deadline, probes.
- `delivery_circuits_test.exs`: what counts as unreachable, the schedule.
- `inbound_test.exs`: admission, duplicates, re-checking a domain blocked
  later, retries.
- `inbound_worker_test.exs`: one activity per actor, in order.
