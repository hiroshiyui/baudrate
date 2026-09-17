# 0037 — The deploy builds on the server again

- **Status:** Accepted
- **Date:** 2026-09-18
- **Deciders:** Baudrate maintainers
- **Related:** supersedes decision 3 of
  [0036](0036-production-runs-releases-built-and-attested-in-ci.md) (the deploy
  installs the attested tarball); the rest of 0036 stands — releases are still
  built, smoke-tested and attested in CI, the Erlang cookie is still per
  server, and the rollback playbook is unchanged

## Context

v1.26.0 shipped the artifact deploy from ADR 0036 and was deployed with it on
2026-09-18. The security gain is real and the deploy worked on the first
attempt, but the cost landed on the operator's link rather than on the server:

| | v1.25.0 (built on the server) | v1.26.0 (artifact) |
|---|---|---|
| Wall clock | 1 min 59 s | 13 min 10 s |
| Bytes over the operator's link | none | 46 MB down from GitHub, 46 MB up to the server |

About eleven of those thirteen minutes were the download. The operator's
connection to GitHub's asset host is slow and at times stalls entirely: the
same file took roughly eight minutes to fetch by hand earlier that day, and
Erlang's source tarball had to be abandoned in a local image build. The old
deploy was quick because the server kept a warm `_build` and compiled only what
had changed.

The artifact path also has no cheap variant that keeps verification on the
operator's machine: `gh attestation verify` hashes the file it is given, so the
bytes must be there. Moving them off the operator's link would mean either
publishing the release to a registry and pulling it on the server (verification
by digest, more machinery to build) or verifying on the server itself (the
GitHub CLI and GitHub API access on production, which 0036 deliberately
avoided).

## Decision

**The deploy playbook clones the release tag on the server and builds it
there**, as it did before v1.26.0: `mix deps.get --only prod`, `mix compile`,
`mix assets.deploy`, `mix release`, then the same install, migration, symlink
swap and health check. Nothing is downloaded from GitHub releases.

Everything else from 0036 stays:

- CI still builds the release in `baudrate-build` and runs
  `ci/release/smoke-test.sh` on every push and before publishing a release, so
  a change that breaks the release still fails before a tag exists.
- The release workflow still attests the tarball and attaches it to the GitHub
  release. Nothing in the deploy consumes it; it is there for installing by
  hand (`doc/sysop.md`, "Release artifacts"), for a host with no toolchain, and
  as a record of what the tag builds into.
- The Erlang distribution cookie is still generated per server and
  distribution still listens on loopback only — the security fix that mattered
  most, and independent of where the build happens.
- `rollback-baudrate.yml` is unchanged: it points `current` at a kept release
  and builds nothing.

**The build toolchain therefore stays on the production server**, which is
where it already was: the operator had declined to remove it.

## Consequences

- A deploy is again as fast as an incremental compile, and costs the operator's
  link only the Ansible traffic.
- **What runs in production is built on production, not the artifact CI
  tested.** The same commit, the same pinned toolchain and the same Debian
  release, but a different machine. CI's build and smoke test are a gate, not
  the thing that ships.
- **Dependency build code runs on the server again**: every Hex package's
  compile-time code and every crate's build script, on the host that holds the
  database credentials and `SECRET_KEY_BASE`. `mix.lock` and `Cargo.lock` pin
  what is fetched; nothing checks the toolchain the server installed through
  asdf and rustup, which is how it was before v1.26.0.
- Deploying an old tag rebuilds it with that tag's pinned toolchain, and fails
  if that toolchain is gone — the rollback playbook is the way back to a
  release still on the server.
- If the operator's link to GitHub improves, or the release is published to a
  registry so the server can pull it, the artifact deploy can come back without
  changing the release side: it is still built and attested.

## Alternatives considered

- **Pull the release from a registry** (GHCR) so the operator's machine
  verifies only a digest and the server fetches the bytes over its own link.
  The best of both, and still open, but it needs a publish step, a fetch step
  on the server and its own ADR; the operator chose the fast path now.
- **Verify on the server.** Rejected in 0036 and still: it puts the GitHub CLI
  and GitHub API access on production.
- **Cache the tarball on the operator's machine.** Helps only repeat deploys of
  one tag; the first deploy of each release still pays the download and the
  upload.
- **Shrink the tarball** (a smaller Erlang runtime, the system libvips instead
  of the one `vix` bundles). Saves maybe a third of it, ties image handling to
  Debian's libvips version, and does not change the shape of the problem.
- **Stop building and attesting in CI too.** Rejected: it costs the operator
  nothing and it is what catches a release that cannot start.
