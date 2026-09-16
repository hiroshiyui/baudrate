# 0033 — Baudrate runs on one node

- **Status:** Accepted
- **Date:** 2026-09-17
- **Deciders:** Baudrate maintainers
- **Related:** implements D2 (made 2026-09-14) from the product review;
  [0028](0028-backups-are-complete-folders-with-count-based-retention.md) is the recovery
  path this decision leans on in place of redundancy

## Context

Baudrate shipped with Phoenix's default `DNSCluster` child, a
`DNS_CLUSTER_QUERY` variable, and a "Clustering" section in the sysop guide
explaining how to run several nodes. It said the background workers "run
independently on each node", and that this was "idempotent (safe but slightly
redundant)".

That was never true, and nothing in the code was built for it. Production has
always been one node, which is why nobody noticed. Pointing two nodes at one
database would have caused:

- **Duplicate deliveries.** `DeliveryWorker` selects due jobs with a plain
  `SELECT … LIMIT`, with no row lock or `SKIP LOCKED`, so both nodes deliver
  the same job at the same time.
- **Blocks and settings that apply on one node only.** `SettingsCache`,
  `BoardCache` and `DomainBlockCache` are refreshed on the node that made the
  change and nowhere else; no cache is invalidated over PubSub. A domain an
  admin blocked would keep reaching the inbox through the other node until
  it restarted.
- **Sign-ins and downloads that fail by chance.** `WebAuthnChallenges` and
  `DataPortability.DownloadNonces` live in ETS. A security key challenge
  issued by one node cannot be answered on the other, and neither can an
  export download token.
- **Rate limits multiplied by the node count.** Hammer's ETS backend counts
  per node, and that includes the per-account cap on admin sudo attempts.
- **Periodic jobs run once per node**: `SessionCleaner`, `StaleActorCleaner`
  and `FeedWorker` included.

D2 settled the direction: Baudrate officially supports a single node.

## Decision

### 1. One instance is one node

Running two Baudrate nodes against the same database is unsupported. There
is no cluster discovery code: `DNSCluster` and `DNS_CLUSTER_QUERY` are
removed. Keeping a switch for a mode nothing supports only invites someone to
turn it on, and what they would get is the list above.

### 2. Node-local state is intentional

With one node, each of these is complete rather than partial:

- the ETS caches (`SettingsCache`, `BoardCache`, `DomainBlockCache`,
  `Media.NegativeCache`), refreshed in-process after every write;
- single-use values in ETS (`WebAuthnChallenges`, `DownloadNonces`);
- Hammer's rate-limit counters;
- uploads and the media proxy cache on the local disk;
- `Phoenix.PubSub` for LiveView updates, with no distribution needed;
- periodic workers, each running exactly once.

What security depends on *across* requests was already kept in the database,
where it holds regardless: the TOTP replay marker (ADR 0024), login-failure
throttling in `login_attempts`, sanctions (ADR 0029) and download claims
(ADR 0023). This decision does not move any of that into memory.

### 3. Release tasks do not count as a second node

Backups, pre-deploy dumps and migrations run through `bin/baudrate eval`,
which *loads* the application without starting it (`load_app/0` in
`Baudrate.Release`), so
they never start a second set of workers. Deploys restart the one systemd unit.

### 4. Grow by making the host bigger

The sysop guide's scaling section covers a larger host, PostgreSQL tuning,
and static assets, which nginx already serves with year-long immutable cache
headers. A CDN, if an operator wants one, has to front the whole origin: CSP
and the no-third-party-subresources rule both forbid serving assets from a
different host.

## Alternatives considered

- **Support multi-node now.** This needs row claiming with
  `FOR UPDATE SKIP LOCKED`, singleton scheduling (advisory locks) for every
  periodic job, cache invalidation over PubSub, challenges and nonces in the
  database, a shared rate-limit store, and shared storage for uploads and the
  media cache. That is a lot of work with no present need. Worse, each item
  hides a security failure that only shows with two nodes, such as a domain
  block that applies on one of them. Tests run on one node, so none of them
  would catch it.
- **Keep `DNSCluster` but document the limitations.** This was the state
  before, and its documentation was wrong in the one way that mattered.

## Consequences

- The ceiling is the size of one host. For a forum that is high, since the
  database is usually the limit first, and PostgreSQL scales up well.
- There is no high availability: a host outage is downtime. Recovery rests on
  verified backups (ADR 0028) and, from Phase 2E, rolling back a release.
- Code may rely on running on one node. A periodic job may assume it runs
  once, and a cache refresh after a write reaches every reader. A change that
  needs more than one node must supersede this ADR and do the work listed
  under the first alternative.

## Acceptance gate

None automated: no test can observe how many nodes a deployment runs. The
review question for a change that adds in-memory state or a periodic job is
whether it is correct on *one* node. For a change that adds clustering, the
answer is that it needs a new ADR first.
