# 0036 — Production runs releases built and attested in CI

- **Status:** Accepted
- **Date:** 2026-09-17
- **Deciders:** Baudrate maintainers
- **Related:** implements Phase 2E and decision P2-D3 (made 2026-09-17);
  amends [0027](0027-ci-runs-in-a-pinned-attested-image.md) (the CI image is
  now two images on production's Debian release); relies on
  [0028](0028-backups-are-complete-folders-with-count-based-retention.md) (the
  pre-deploy dump is what makes a refused rollback recoverable) and
  [0033](0033-baudrate-runs-on-one-node.md) (one node, so Erlang distribution
  serves only an operator's console)

## Context

Until this decision, the deploy playbook cloned the tag onto the production
server and ran `mix deps.get`, `mix compile`, `mix assets.deploy` and
`mix release` there, as the service user:

- **Build code ran on production.** Every Hex package's compile-time code and
  every crate's build script ran on the host that holds the database password,
  `SECRET_KEY_BASE` and the uploads, with network access. The host needed
  Erlang, Elixir, Rust, a C toolchain and git, installed by a `curl | sh` of
  rustup and asdf plugins with no checksum pinning, which ADR 0027 had already
  removed from CI.
- **What ran was never what was tested.** CI tested on Debian 13 with one
  toolchain build, and production compiled its own on Debian 12.
- **Rollback meant rebuilding.** Re-deploying an older tag rebuilt it from
  source with that tag's toolchain, which failed once the toolchain had been
  removed, and re-ran migrations for a release older than the schema.
- **The Erlang cookie was readable by other local users.** `mix release`
  writes a random cookie to `releases/COOKIE`, mode 0644, under
  `/opt/baudrate` (mode 0755), and the node listened for Erlang distribution on
  all interfaces. On the production server, which also runs another
  application under its own account (found 2026-09-17), that account could read
  the cookie and run code inside Baudrate, with its database credentials and
  secrets. The firewall kept the ports off the internet, but not off the host.

## Decision

### 1. Releases are built in CI, on production's Debian release

The CI image (ADR 0027) becomes one Dockerfile with two targets on
`debian:bookworm-slim`, pinned by digest:

- `baudrate-build`, only the release toolchain;
- `baudrate-ci`, the same layers plus the test tools.

A release carries its own Erlang runtime and Rust NIFs, linked against the
glibc and OpenSSL of the system that built it, so the build must run on the
Debian release production runs. The Ansible inventory records it
(`debian_version`). The image workflow refuses a Dockerfile whose base
disagrees, `verify-toolchain.sh` refuses an image that does, and the deploy
refuses a host that does. The tests move to Debian 12 with the build, so
what is tested runs on the same system and toolchain as what is shipped. The
PostgreSQL 15 client then comes from Debian itself, and the extra apt
repository ADR 0027's image needed goes.

`ci/release/build.sh` builds the tarball and `ci/release/smoke-test.sh` starts
it the way production does. The smoke test checks the cookie guard (below),
migrations, the public and detailed health endpoints, `rpc`, and that nothing
but the web port listens beyond loopback. Both run on every push to `current`,
so a change that breaks the release fails before a tag exists.

### 2. Publishing a release attaches an attested tarball

`.github/workflows/release.yml` runs when a GitHub release is published. It
builds and smoke-tests in `baudrate-build`, without caches, in a job with a
read-only token. A second job, which runs only GitHub's own actions and `gh`,
checks the tarball's digest, records a build-provenance attestation and
attaches `baudrate-<version>-debian12-x86_64.tar.gz` and its Sigstore bundle to
the release. The build job runs third-party code (Hex packages, crates); the
job that can sign and publish does not.

### 3. The deploy verifies on the controller, then installs

Before anything reaches the server, the playbook runs on the control machine:

1. resolves the tag in the operator's own clone;
2. downloads the tarball;
3. runs `gh attestation verify` with `--signer-workflow` set to this
   repository's `release.yml`, `--source-ref refs/tags/<tag>`,
   `--source-digest` set to the commit the tag names locally, and
   `--deny-self-hosted-runners`.

A tarball built by another workflow, from another commit, or for a tag moved on
GitHub after the operator fetched it, fails. The server receives only the
verified file and checks its SHA-256 before unpacking it. Nothing is compiled
on the server.

The build toolchains stay on the production server for now: the operator chose
not to remove them yet, and the server also hosts another application that may
use its build packages. New deploys do not use them. Removing them is
documented, not automated.

### 4. Erlang distribution needs the server's own cookie, on loopback

A published release's `releases/COOKIE` is public. The release is built with a
fixed placeholder cookie, so every build of a commit is the same.
`rel/env.sh.eex` refuses every command that joins the distribution (`start`,
`daemon`, `remote`, `rpc`, `stop`, `restart`, `pid`) unless `RELEASE_COOKIE`
is set and differs from the shipped one. `eval` and `version` need no cookie,
so migrations and dumps are unaffected.

Ansible generates a cookie once per server, into `env/release_cookie` (0600,
in the 0700 `env/` directory), and writes it into the environment file.
Distribution listens on 127.0.0.1 only: the node is `baudrate@127.0.0.1`, the
distribution port is bound to loopback in `vm.args`, and an epmd the release
starts binds to loopback. The operator chose to keep distribution, for the
remote console, over turning it off. So on a shared host, the cookie's file
permissions are what keep other local accounts out.

### 5. Rollback restores a kept release, and refuses an incompatible schema

`rollback-baudrate.yml` points `current` and `static` at a release still on the
server, restarts and waits for `/health`. It downloads and builds nothing. It
refuses when the database has migrations the target release does not contain:
rolling back code does not roll back the schema. The older release may fail
against the newer schema, or write rows the newer code later misreads.
`force=true` overrides it after the operator has checked. Otherwise the way
back is to fix forward, or to restore the pre-deploy dump taken before those
migrations (ADR 0028) and then roll back. The playbook runs in `--check` mode,
reporting the target and the schema verdict without changing anything.

### 6. Security checks run on every push

A Security job runs Sobelow and mix_audit. Every Sobelow finding fails it, at
every confidence level. A finding reviewed and judged not to be a
vulnerability is marked with `# sobelow_skip` directly above its function or
router pipeline, never in a fingerprint file: Sobelow's fingerprints include
line numbers, so a skip list breaks on unrelated edits, and a function-level
skip means that function was checked. mix_audit reads the advisory list the
`baudrate-ci` image took when it was built, recorded by commit, and fetches
nothing at run time (ADR 0027). The job fails if the list changed during the
run.

## Alternatives considered

- **Keep building on the server, but pin its toolchain.** Rejected: the build
  code still runs on the host with the secrets, and what runs is still not what
  was tested.
- **Build the release in the existing Debian 13 image.** Rejected: its Erlang
  runtime and NIFs need a newer glibc and OpenSSL than Debian 12 has, and the
  release would not start.
- **A separate Debian 12 build image, tests staying on Debian 13.** Rejected
  by the operator: two Dockerfiles repeating every version and checksum, and
  releases built on a system the tests never ran on.
- **Verify on the server.** Rejected: it needs `gh` and network access to
  GitHub's attestation API on production. The controller already holds the
  deploy's trust (SOPS keys), and the server checks the digest.
- **Checksums in the release notes instead of attestations.** Rejected: whoever
  can change the asset can change the notes. An attestation binds the file to
  the workflow, commit and ref that built it.
- **Turn Erlang distribution off** (`RELEASE_DISTRIBUTION=none`). Offered and
  declined by the operator, for the remote console. It remains a one-variable
  change.
- **Run without epmd on a fixed port.** Rejected for now: OTP needs matching
  flags in both `vm.args` files and a client-only mode for `rpc`, for little
  gain once distribution is on loopback behind a per-server cookie.
- **A Sobelow skip file** (`.sobelow-skips`). Rejected: it fingerprints by
  line number.
- **Fetch the advisory list on each mix_audit run.** Rejected: an unpinned
  download at run time, which ADR 0027 rules out; the list in the weekly image
  is at most as old as the last merged image update.
- **Remove the build toolchains from the server now.** Offered and declined by
  the operator for the time being.

## Consequences

- Publishing a GitHub release starts the release build. The deploy fails until
  that run has attached the tarball, and it needs `gh auth login` and the tag
  fetched on the control machine.
- Releases published before this decision have no tarball, so the deploy
  cannot install them. A kept release directory can still be rolled back to.
- A server that runs another Debian release, or another architecture, needs the
  inventory, the Dockerfile's base and the images changed together first.
- The node's name changes from `baudrate@<hostname>` to `baudrate@127.0.0.1`.
  `remote` and `rpc` need the environment file sourced, for the cookie.
- A new file operation, `send_file`, raw HTML or pipeline without CSRF
  protection fails CI until someone reviews it and adds a `# sobelow_skip`, or
  fixes it.
- The weekly image rebuild now also refreshes the advisory list, and both
  images arrive in one proposed lock-file change.

## Acceptance gate

- **Release:** `ci/release/smoke-test.sh`, in the Release build job of
  `elixir.yml` on every push and in `release.yml` before publishing.
- **Images:** `ci-image.yml` (the Dockerfile's base against `debian_version`,
  and smoke tests of both images) and `ci/image/verify-toolchain.sh` (every
  job).
- **Security:** the Security checks job in `elixir.yml`.
- **Rollback:** `rollback-baudrate.yml --check` against a server shows the
  target and the schema verdict without changing anything.
