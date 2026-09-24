# CI images

Every CI job runs inside one of two images built from `Dockerfile`, instead of
installing toolchains on the runner:

| Image | Target | Used by | Pinned in |
|---|---|---|---|
| `ghcr.io/hiroshiyui/baudrate-ci` | `ci` (default) | the test, browser-test and security jobs (`elixir.yml`, `dependency-drift.yml`) | `image.lock` |
| `ghcr.io/hiroshiyui/baudrate-build` | `build` | the release build and its smoke test (`elixir.yml`, `release.yml`) | `build-image.lock` |

Both are built by `.github/workflows/ci-image.yml` and used only through the
digests pinned in their lock files. `ci` is `build` plus the test tools, so the
tests and the production release share the same Erlang, Elixir and Rust
layers.

## Why

Before, every CI run fetched and executed code from parties other than the
upstream projects: a third-party asdf action and its plugins, a third-party
Rust action with a floating toolchain, whatever Firefox and Java the runner
image shipped that week, unverified esbuild/Tailwind downloads, and actions
pinned only by movable tags. Any of them could run code with the workflow's
token. The images move all of that to one reviewed, reproducible build
(ADR 0027).

## Why Debian 12

The base is production's Debian release (`debian_version` in
`ansible/inventory/group_vars/all.yml`), not the newest Debian. A release built
by `mix release` carries its own Erlang runtime and the Rust NIFs, linked
against the glibc and OpenSSL of the system that built it, and will not start
on an older one. Production installs the release built in `baudrate-build`
(ADR 0036), so that image must match production, and the tests run on the same
system. `ci-image.yml` fails when the Dockerfile's base and `debian_version`
disagree, and `verify-toolchain.sh` checks the running image.

## What is trusted

| Input | Image | Source | Verification |
|---|---|---|---|
| Base OS | both | `debian:bookworm-slim` | pinned by digest; Dependabot proposes updates |
| Build tools, libssl, ncurses, git | both | Debian apt | Debian's signed repositories |
| Firefox ESR, OpenJDK 17, PostgreSQL 15 client | `ci` | Debian apt | Debian's signed repositories |
| ansible-lint, and `ansible` for the collections the playbooks use (Phase 8A) | `ci` | Debian apt | Debian's signed repositories |
| Erlang/OTP | both | upstream source tarball, built in the image | SHA-256 |
| Elixir | both | upstream precompiled release (`elixir-otp-28.zip`, BEAM bytecode) | SHA-256 |
| Hex, Rebar | both | `mix local.hex` / `mix local.rebar` | Mix checks the signed installer index |
| Rust | both | `rustup-init`, one pinned toolchain | SHA-256; rustup verifies components against the channel manifest |
| clippy | `ci` | `rustup component add` for the pinned toolchain (Phase 8A) | rustup verifies it against the channel manifest |
| esbuild | both | npm registry package | SHA-256 |
| Tailwind CSS | both | GitHub release | SHA-256 |
| Selenium Server | `ci` | GitHub release | SHA-256 |
| GeckoDriver | `ci` | crates.io source crate, built in the image with its `Cargo.lock` | SHA-256; `cargo build --locked` checks every dependency's checksum |
| mix_audit advisory list | `ci` | `mirego/elixir-security-advisories`, cloned when the image is built | git over HTTPS; the commit is recorded in `/opt/mix-audit/ADVISORIES_COMMIT`. YAML data, never executed |

The PostgreSQL client is production's major version, which Debian 12 ships
itself. Tests must use it: `pg_dump` and `pg_restore` 17+ write
`SET transaction_timeout`, which a 15 server rejects, so a newer client fails
the backup restore test.

Every SHA-256 was cross-checked against the checksums the project publishes
(OTP `MD5.txt`, Elixir `.sha256sum`, rustup `.sha256`, npm `integrity`,
Tailwind `sha256sums.txt`, the crates.io index checksum, and the digest GitHub
records for a release asset), not only computed from one download.

GeckoDriver is built from source rather than taken from its GitHub release.
Mozilla revoked the subkey that signs the 0.37.x release tarballs
(`09BEED63F3462A2DFFAB3B875ECB6497C1A20256`) on 2026-08-06 as compromised,
after it leaked into a private repository, so those signatures no longer
establish anything. Before using a future release binary instead, check that it
is signed by a current, unrevoked subkey of Mozilla's release key
(`14F26682D0916CDD81E37B6D61B7B526D98F0353`).

The advisory list is the one input taken at the latest commit rather than a
pinned version: its value is being current. It is taken when the image is
built, so a job fetches nothing: `mix deps.audit` looks for the list under
`$HOME` and runs `git pull` on a checkout it finds, and the image keeps no
`.git`, so there is nothing to pull. The security job points `HOME` at
`MIX_AUDIT_HOME` and fails if the list changed during the run. The list is as
current as the last image update merged into `image.lock`; Dependabot still
alerts on GitHub advisories as they are published.

Still fetched at run time, outside the images: Hex packages (`mix deps.get`,
checked against `mix.lock`), Rust crates (checked against `Cargo.lock`), and
the precompiled libvips (`vix`) and MDEx NIFs, which are verified against
checksum files inside their Hex packages. The PostgreSQL service container is
pinned by digest in the workflows. The only actions used are GitHub's own,
pinned to commit SHAs.

## How CI picks an image

1. `ci-image.yml` builds both images (on a `Dockerfile` change on `current`,
   weekly for Debian security updates and advisories, or by hand), checks their
   versions against `.tool-versions`, `config/config.exs` and the Ansible
   inventory, smoke-tests them, pushes them, and records a build-provenance
   attestation for each.
2. It pushes a branch `ci-image/<date>-<commit>` that changes both lock files
   to the new digests and opens a pull request into `current` ("ci: use CI
   images …"). If the repository setting that lets Actions create pull requests
   is off, it opens a "CI images … are ready" issue with the compare link
   instead; open the pull request from there. A pull request created by a
   workflow does not start CI by itself; close and reopen it, or let CI run
   when it is merged. Before merging, verify both digests:

   ```sh
   gh attestation verify oci://$(cat ci/image/image.lock) --repo hiroshiyui/baudrate \
     --signer-workflow hiroshiyui/baudrate/.github/workflows/ci-image.yml
   gh attestation verify oci://$(cat ci/image/build-image.lock) --repo hiroshiyui/baudrate \
     --signer-workflow hiroshiyui/baudrate/.github/workflows/ci-image.yml
   ```

   Each should report one SLSA provenance attestation signed by
   `ci-image.yml` on `refs/heads/current`.
3. `ci-image-ref.yml` (called by every workflow that uses an image, with
   `image: ci` or `image: build`) reads the lock file and runs
   `gh attestation verify` before any job starts in the container: the digest
   must have been attested by `ci-image.yml` in this repository.
4. Each job runs `verify-toolchain.sh` first, so a version bump in
   `.tool-versions`, `config/config.exs` or the Ansible inventory fails fast
   until the images are rebuilt.

## Running as root

Jobs run as the image's root user, as GitHub recommends for container jobs.
The runner mounts `HOME` (`/github/home`) owned by the runner's uid, and
Firefox refuses to start as root in a home it does not own, so the browser
test step sets `HOME=/root`. A non-root container user would add little
isolation on GitHub-hosted runners: the job VM is ephemeral and the runner
user already has passwordless `sudo` on it.

## Changing a version

1. Change the version in the project (`.tool-versions`, `config/config.exs`,
   `lib/mix/tasks/selenium_setup.ex`) and the matching `ARG` in `Dockerfile`.
2. Download the new artifact, compute `sha256sum`, compare it with the
   upstream-published checksum, and update the `*_SHA256` argument. For
   GeckoDriver that is the `.crate` file and the `checksum` crates.io lists for
   the version (`https://crates.io/api/v1/crates/geckodriver/versions`).
3. Push to `current`; merge the proposed lock file change once the image
   build has passed.

**PostgreSQL** follows production, not upstream. When production moves to a new
major version, change `postgres_version` in `ansible/inventory/group_vars/all.yml`,
`POSTGRES_MAJOR` in `Dockerfile`, and every `postgres:<major>@sha256:…` service
image in `.github/workflows/elixir.yml` and `release.yml`, pinning the tag's
current index digest. `verify-toolchain.sh` fails while any of them disagree.

**Debian** also follows production. When production moves to a new release,
change `debian_version` in the inventory and both base `FROM` lines in
`Dockerfile` (the tag and its index digest) in the same commit, and check the
Debian packages still exist under their names (`openjdk-17-jre-headless`,
`postgresql-client-15`). Deploy the first release built on the new base only
to a host already upgraded: the deploy refuses a host whose Debian release
differs from `debian_version`.

To inspect an image locally:

```sh
gh attestation verify oci://$(cat ci/image/image.lock) --repo hiroshiyui/baudrate
docker run --rm -it $(cat ci/image/image.lock) bash
```
