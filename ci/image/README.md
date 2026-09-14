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
| Base OS | `debian:trixie-slim` | pinned by digest |
| Build tools, Firefox ESR, OpenJDK 21, PostgreSQL client, libssl, ncurses | Debian apt | Debian's signed repositories |
| Erlang/OTP | upstream source tarball, built in the image | SHA-256 |
| Elixir | upstream precompiled release (`elixir-otp-28.zip`, BEAM bytecode) | SHA-256 |
| Hex, Rebar | `mix local.hex` / `mix local.rebar` | Mix checks the signed installer index |
| Rust | `rustup-init`, one pinned toolchain | SHA-256; rustup verifies components against the channel manifest |
| esbuild | npm registry package | SHA-256 |
| Tailwind CSS, GeckoDriver, Selenium Server | GitHub releases | SHA-256 |

Every SHA-256 was cross-checked against the checksums the project publishes
(OTP `MD5.txt`, Elixir `.sha256sum`, rustup `.sha256`, npm `integrity`,
Tailwind `sha256sums.txt`), not only computed from one download.

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
   the new digest and opens a pull request into `current`. The repository does
   not allow Actions to open pull requests, so it opens an issue with the
   compare link instead; open the pull request from there. A pull request
   created by a workflow does not start CI by itself; close and reopen it, or
   let CI run when it is merged.
3. `ci-image-ref.yml` (called by every workflow that uses the image) reads
   `image.lock` and runs `gh attestation verify` before any job starts in the
   container: the digest must have been attested by `ci-image.yml` in this
   repository.
4. Each job runs `verify-toolchain.sh` first, so a version bump in
   `.tool-versions` or `config/config.exs` fails fast until the image is
   rebuilt.

## Changing a version

1. Change the version in the project (`.tool-versions`, `config/config.exs`,
   `lib/mix/tasks/selenium_setup.ex`) and the matching `ARG` in `Dockerfile`.
2. Download the new artifact, compute `sha256sum`, compare it with the
   upstream-published checksum, and update the `*_SHA256` argument.
3. Push to `current`; merge the proposed `image.lock` change once the image
   build has passed.

To inspect an image locally:

```sh
gh attestation verify oci://$(cat ci/image/image.lock) --repo hiroshiyui/baudrate
docker run --rm -it $(cat ci/image/image.lock) bash
```
