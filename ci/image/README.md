# CI image

CI jobs (`.github/workflows/elixir.yml`, `dependency-drift.yml`) run inside
this image instead of installing toolchains on the runner. It is built from
`Dockerfile` by `.github/workflows/ci-image.yml`, published to
`ghcr.io/hiroshiyui/baudrate-ci`, and used only through the digest pinned in
`image.lock`.

## Why

Before, every CI run fetched and executed code from parties other than the
upstream projects: a third-party asdf action and its plugins, a third-party
Rust action with a floating toolchain, whatever Firefox and Java the runner
image shipped that week, unverified esbuild/Tailwind downloads, and actions
pinned only by movable tags. Any of them could run code with the workflow's
token. The image moves all of that to one reviewed, reproducible build.

## What is trusted

| Input | Source | Verification |
|---|---|---|
| Base OS | `debian:trixie-slim` | pinned by digest; Dependabot proposes updates |
| Build tools, Firefox ESR, OpenJDK 21, libssl, ncurses | Debian apt | Debian's signed repositories |
| PostgreSQL client, production's major version (`postgresql-client-15`) | the PostgreSQL project's apt repository (`apt.postgresql.org`, `trixie-pgdg`) | its signing key is the copy Debian ships in `postgresql-client-common`, checked by SHA-256; the repository is pinned below Debian, so it supplies only that one package |
| Erlang/OTP | upstream source tarball, built in the image | SHA-256 |
| Elixir | upstream precompiled release (`elixir-otp-28.zip`, BEAM bytecode) | SHA-256 |
| Hex, Rebar | `mix local.hex` / `mix local.rebar` | Mix checks the signed installer index |
| Rust | `rustup-init`, one pinned toolchain | SHA-256; rustup verifies components against the channel manifest |
| esbuild | npm registry package | SHA-256 |
| Tailwind CSS, Selenium Server | GitHub releases | SHA-256 |
| GeckoDriver | crates.io source crate, built in the image with its `Cargo.lock` | SHA-256; `cargo build --locked` checks every dependency's checksum |

The PostgreSQL client is the one package not taken from Debian. Tests must use
production's major version (Ansible's `postgres_version`, Debian 12's 15), and
trixie carries only 17, whose `pg_dump` and `pg_restore` write
`SET transaction_timeout` — a setting a 15 server rejects, which fails the
backup restore test. The key Debian ships (`apt.postgresql.org.asc`,
fingerprint `B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8`) was also compared byte
for byte with the one `postgresql.org` serves, and they are identical.

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

Still fetched at run time, outside the image: Hex packages (`mix deps.get`,
checked against `mix.lock`), Rust crates (checked against `Cargo.lock`), and
the precompiled libvips (`vix`) and MDEx NIFs, which are verified against
checksum files inside their Hex packages — the same way production builds get
them. The PostgreSQL service container is pinned by digest in the workflows.
The only actions used are GitHub's own, pinned to commit SHAs.

## How CI picks an image

1. `ci-image.yml` builds the image (on a `Dockerfile` change on `current`,
   weekly for Debian security updates, or by hand), checks its versions
   against `.tool-versions` and `config/config.exs`, smoke-tests it, pushes it,
   and records a build-provenance attestation.
2. It pushes a branch `ci-image/<date>-<commit>` that changes `image.lock` to
   the new digest and opens a pull request into `current` ("ci: use CI image
   …"). If the repository setting that lets Actions create pull requests is
   off, it opens a "CI image … is ready" issue with the compare link instead;
   open the pull request from there. A pull request created by a workflow does
   not start CI by itself; close and reopen it, or let CI run when it is
   merged. Before merging, `gh attestation verify oci://<image.lock value>
   --repo hiroshiyui/baudrate` should report one SLSA provenance attestation
   signed by `ci-image.yml` on `refs/heads/current`.
3. `ci-image-ref.yml` (called by every workflow that uses the image) reads
   `image.lock` and runs `gh attestation verify` before any job starts in the
   container: the digest must have been attested by `ci-image.yml` in this
   repository.
4. Each job runs `verify-toolchain.sh` first, so a version bump in
   `.tool-versions` or `config/config.exs` fails fast until the image is
   rebuilt.

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
3. Push to `current`; merge the proposed `image.lock` change once the image
   build has passed.

**PostgreSQL** follows production, not upstream. When production moves to a new
major version, change `postgres_version` in `ansible/inventory/group_vars/all.yml`,
`POSTGRES_MAJOR` in `Dockerfile`, and both `postgres:<major>@sha256:…` service
images in `.github/workflows/elixir.yml`, pinning the tag's current index digest.
`verify-toolchain.sh` fails while any of the three disagree. If Debian changes
`apt.postgresql.org.asc`, the build stops at its checksum. Compare the new file
with the key `postgresql.org` serves before updating `PGDG_KEY_SHA256`.

To inspect an image locally:

```sh
gh attestation verify oci://$(cat ci/image/image.lock) --repo hiroshiyui/baudrate
docker run --rm -it $(cat ci/image/image.lock) bash
```
