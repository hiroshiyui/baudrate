# 0077 — Production moves to Debian 13 and PostgreSQL 17, pinned by codename

- **Status:** Accepted
- **Date:** 2026-10-26
- **Deciders:** Baudrate maintainers
- **Related:** [0036](0036-production-runs-releases-built-and-attested-in-ci.md)
  decision 1 (CI builds and tests on production's Debian release),
  [0037](0037-the-deploy-builds-on-the-server-again.md) (the deploy builds on
  the server), [0028](0028-backups-are-complete-folders-with-count-based-retention.md)
  (backups and the pre-deploy dump), [0027](0027-ci-runs-in-a-pinned-attested-image.md)
  (pinned, attested CI inputs).

## Context

Production has run Debian 12 (bookworm) with PostgreSQL 15 since 0036 made
that release a build input: the release carries an Erlang runtime and Rust
NIFs linked against the host's glibc and OpenSSL, so CI builds and tests on
the same release, and the deploy refuses any other host. Debian 13 (trixie)
has been stable since 2025-08-09; bookworm is oldstable, and its regular
security support ended in June 2026, leaving it to the LTS team. Debian 13 ships PostgreSQL 17 and
no 15 server package.

The operator asked whether the host could follow Debian's `stable` channel
instead of a codename, so that it never falls behind again.

## Decision

### 1. Production is Debian 13 with PostgreSQL 17

`debian_version` is `13` and `postgres_version` is `17` in the Ansible
inventory. The CI images build from `debian:trixie-slim`, the PostgreSQL
service containers are `postgres:17`, and the release tarball is named
`debian13`. These change in one commit, as 0036 requires, and the first
release carrying them deploys only to a host already upgraded.

### 2. Sources are pinned by codename, never by channel

The host's apt sources name `trixie`, not `stable`. A channel pin would move
the host to Debian 14 under the running release at Debian's next transition:
the deploy would then be refused until CI caught up, and an ordinary package
upgrade in between would replace the OpenSSL and glibc the release was built
against. The same holds for the PostgreSQL major, which Debian ties to its
release, and whose client must match the server for the backups (0028). The
upgrade playbook refuses sources that name a channel.

### 3. PostgreSQL stays Debian's own package

Keeping 15 through apt.postgresql.org would have left the data untouched, but
it adds a third-party repository to production and to the CI image, against
0027 and 0036's pinned Debian inputs. The cluster is upgraded instead, with
`pg_upgradecluster` in copy mode so the old cluster remains until the operator
drops it.

### 4. The upgrade is a playbook, one major at a time

`ansible/playbooks/upgrade-debian.yml` moves a host to the release the
inventory pins and refuses a host that is not exactly one major behind. It
takes a backup first, upgrades the current release fully, rewrites the
codename, runs Debian's minimal then full upgrade, reboots, upgrades the
cluster, rebuilds Erlang against the new libraries, wipes the previous build
and starts the existing release until the deploy replaces it. The existing
release normally starts because glibc and OpenSSL 3 keep their ABI; the deploy
that follows is what makes the host conform to 0036 again.

## Consequences

- Deploying a release at or after this change to a Debian 12 host is refused
  by the deploy's pre-flight; the playbook runs first.
- Downgrading the PostgreSQL major is not possible once the old cluster is
  dropped; until then, the old cluster and the backup taken by the playbook
  are the way back.
- Vultr's images ship their own cloud-init, installed under `/usr/local` for
  the old release's Python; on the new release it cannot start, and every
  cloud-init unit fails at boot. The playbook switches off a cloud-init that
  no longer runs, with the marker file it honours: a provisioned server has
  no further use for it, and a repaired one could rewrite network or SSH
  settings on a later boot. Debian 13's packaged `nginx.conf` sets
  `server_tokens off` at the http level, so the site fragment sets it per
  server block instead.
- Java in the CI image moves from OpenJDK 17 to 21, the only runtime Debian 13
  ships; Selenium Server runs on it unchanged.
- Debian 14 will repeat this record's steps with the next codename; nothing
  here needs rewriting for it beyond the codename map in the role's defaults.

## Acceptance gate

Held by CI rather than the Elixir suite: `ci-image.yml` checks the
Dockerfile's base against `debian_version`, and `ci/image/verify-toolchain.sh`
checks the PostgreSQL client and service images against `postgres_version`.
