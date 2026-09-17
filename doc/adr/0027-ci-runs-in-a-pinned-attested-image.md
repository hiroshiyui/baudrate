# 0027 — CI runs in a digest-pinned, attested image built from verified inputs

- **Status:** Accepted; amended by
  [0036](0036-production-runs-releases-built-and-attested-in-ci.md), which
  splits the image into a release build image and a test image on
  production's Debian release
- **Date:** 2026-09-15
- **Deciders:** Baudrate maintainers
- **Related:** [0020](0020-testing-strategy.md) (testing strategy)

## Context

Every CI run installed its toolchain from the network before running the
tests, with the workflow's token in scope:

- `ynab/asdf-action` (a third party) installed asdf, whose Erlang and Elixir
  plugins were cloned from GitHub and built OTP from downloaded sources, with
  no checksum pinning. The same action failed the v1.19.2 run by rejecting the
  runner's CPU model.
- `dtolnay/rust-toolchain@stable` (a third party) ran
  `curl https://sh.rustup.rs | sh` and installed whatever "stable" was that day.
- Firefox and Java were whatever the GitHub runner image shipped that week.
- `mix assets.setup` downloaded esbuild and Tailwind without verifying them.
- The PostgreSQL service used the floating `postgres:17` tag, and every action
  was pinned by a major-version tag that its owner can move.

Any of these could run arbitrary code in CI. Baudrate treats security as its
top priority, and a compromised CI can tamper with what is tested, leak the
workflow token, or push to the repository.

## Decision

1. **One CI image, built in this repository.** `ci/image/Dockerfile` builds
   every tool the jobs need on a Debian stable-slim base pinned by digest:
   Erlang/OTP from its source tarball, Elixir's precompiled release, rustup
   with one pinned toolchain, esbuild, Tailwind, GeckoDriver and Selenium
   Server. Each download has a SHA-256 in the Dockerfile, cross-checked against
   the checksum the upstream project publishes. Firefox ESR, Java and the
   PostgreSQL client come from Debian's signed repositories.
2. **Published with provenance.** `.github/workflows/ci-image.yml` builds it
   with plain `docker build`, checks its versions against `.tool-versions` and
   `config/config.exs`, smoke-tests it, pushes it to
   `ghcr.io/hiroshiyui/baudrate-ci`, and records a GitHub build-provenance
   attestation.
3. **Used only by reviewed digest.** CI references the image through
   `ci/image/image.lock`. The image workflow proposes a new digest as a branch
   (and a pull request or an issue); nothing changes until it is merged.
4. **Verified before use.** `.github/workflows/ci-image-ref.yml` runs
   `gh attestation verify` on the pinned digest, requiring that this
   repository's `ci-image.yml` signed it, before any job starts in the
   container. Each job then runs `ci/image/verify-toolchain.sh` so a version
   bump in the project fails fast until the image is rebuilt.
5. **Rebuilt weekly** from `current`, so Debian security updates reach CI
   through the same review.
6. **Only GitHub-owned actions, pinned to commit SHAs.** The PostgreSQL
   service image is pinned by digest.

## Consequences

- CI no longer executes third-party action code or unverified downloads for
  its toolchain. What remains fetched at run time is verified against
  lockfiles: Hex packages (`mix.lock`), Rust crates (`Cargo.lock`), and the
  precompiled libvips and MDEx NIFs (checksum files inside their Hex packages,
  as in production builds).
- Changing Erlang, Elixir, Rust, esbuild, Tailwind, GeckoDriver or Selenium
  now means editing the Dockerfile (version and checksum) as well as the
  project pin, then merging the proposed digest. `ci/image/README.md` has the
  steps.
- A new image reaches CI a little later: after its build and a merge.
- The repository does not let Actions open pull requests, and pull requests a
  workflow creates do not start CI by themselves, so the update arrives as an
  issue with a compare link, and CI runs on the merge.
- The image is x86-64 only, like the runners.
- Jobs run as root inside the container, as GitHub expects for container
  jobs; the browser step sets `HOME=/root` because Firefox will not start as
  root in the runner-owned `/github/home`.
- Adding a third-party action, a `curl | sh`, or an unpinned download to a
  workflow undoes this; put new tools in the image instead.

## Alternatives considered

- **Pin the existing actions to SHAs.** Rejected: pinning freezes the action's
  code, but the actions still download and run unverified installers.
- **Official language images (`hexpm/elixir`, `erlang`).** Rejected: faster to
  build, but adds the image publisher as a trusted party for native code.
- **Reference the image by a moving tag.** Rejected: CI would silently run
  whatever was pushed last, with no review and no link to a reviewed digest.
- **Keep the digest in the workflow files.** Rejected: the workflow token may
  not modify `.github/workflows/`, so the weekly update could not be proposed
  automatically.
- **Self-hosted runners.** Rejected for now: more control over the host, but
  a machine to operate and secure, which the project does not have.
