# syntax=docker/dockerfile:1
#
# Baudrate's CI images: every tool the release build and the test jobs need,
# from inputs that are pinned and verified here rather than fetched at CI run
# time. See ci/image/README.md for what is trusted, how they are built and
# updated.
#
# Two targets share every toolchain layer:
#
#   * `build` (ghcr.io/…/baudrate-build): what `ci/release/build.sh` needs to
#     build the production release, and nothing else.
#   * `ci` (ghcr.io/…/baudrate-ci, the default target): `build` plus the test
#     jobs' tools (Firefox ESR, Java, Selenium, GeckoDriver, the PostgreSQL
#     client) and the mix_audit advisory list.
#
# The base is Debian 12 (bookworm), production's release, not Debian stable: a
# release carries its own Erlang runtime and Rust NIFs, linked against this
# system's glibc and OpenSSL, so it must be built on the system it runs on
# (`debian_version` in the Ansible inventory; the image workflow checks it).
#
#   * Distribution packages come from Debian's signed apt repositories.
#   * Erlang/OTP: built from the upstream source tarball (SHA-256 pinned).
#   * Elixir: the upstream precompiled release for this OTP major (SHA-256
#     pinned; it is BEAM bytecode, not native code). Hex and Rebar are
#     installed by Mix, which checks the signed installer index.
#   * Rust: rustup-init (SHA-256 pinned) installs one pinned toolchain; rustup
#     verifies the toolchain components against the channel manifest.
#   * esbuild, Tailwind, Selenium Server: SHA-256 pinned.
#   * GeckoDriver: built from its crates.io source crate (SHA-256 pinned) with
#     the Cargo.lock it ships, so every dependency is checksum-verified.
#
# Versions must match .tool-versions and config/config.exs; the image
# workflow checks this before publishing.

# The base is written out in both FROM lines (not an ARG) so Dependabot can
# propose digest updates; keep the two lines identical.

# ---------------------------------------------------------------------------
FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS otp

ARG OTP_VERSION=29.1.1
ARG OTP_SHA256=054e0143e39c780e091107fc9b345792a9c1a55f6bac1eca1c1101510fc06bf6

RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl build-essential autoconf m4 libncurses-dev libssl-dev \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    curl -fsSL -o /tmp/otp.tar.gz \
      "https://github.com/erlang/otp/releases/download/OTP-${OTP_VERSION}/otp_src_${OTP_VERSION}.tar.gz"; \
    echo "${OTP_SHA256}  /tmp/otp.tar.gz" | sha256sum -c -; \
    mkdir /tmp/otp; \
    tar -xzf /tmp/otp.tar.gz -C /tmp/otp --strip-components=1; \
    cd /tmp/otp; \
    ./configure --prefix=/opt/erlang \
      --without-javac --without-wx --without-debugger --without-observer \
      --without-et --without-odbc; \
    make -j"$(nproc)"; \
    make install; \
    rm -rf /tmp/otp /tmp/otp.tar.gz

# ---------------------------------------------------------------------------
# build: the release build toolchain.
FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS build

ARG ELIXIR_VERSION=1.20.4
ARG ELIXIR_OTP_MAJOR=29
ARG ELIXIR_SHA256=7863c546cda13fecc949e562e326042451dacf8fd8698a36783cb71eeb223b46
ARG RUSTUP_VERSION=1.29.1
ARG RUSTUP_SHA256=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71
ARG RUST_TOOLCHAIN=1.98.1
ARG ESBUILD_VERSION=0.28.2
ARG ESBUILD_SHA256=9573bb2233aab0f9ea7647d5cca9726113cc1768de61d66b17267f4db84488f6
ARG TAILWIND_VERSION=4.3.3
ARG TAILWIND_SHA256=dc61b3ac6b8c9ca874c0cc4c57b2409791a64c5540404ca5f5367360babc313a

LABEL org.opencontainers.image.title="baudrate-build" \
      org.opencontainers.image.description="Toolchain that builds Baudrate's production release" \
      org.opencontainers.image.source="https://github.com/hiroshiyui/baudrate" \
      org.opencontainers.image.licenses="AGPL-3.0-only"

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MIX_HOME=/opt/mix \
    HEX_HOME=/opt/hex \
    CARGO_HOME=/opt/cargo \
    RUSTUP_HOME=/opt/rustup \
    PATH=/opt/erlang/bin:/opt/elixir/bin:/opt/cargo/bin:/opt/mix/escripts:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    MIX_ESBUILD_PATH=/opt/assets/esbuild \
    MIX_TAILWIND_PATH=/opt/assets/tailwind \
    BAUDRATE_IMAGE=build

# Signed Debian packages. `upgrade` picks up security fixes released after the
# base image digest was pinned; the weekly rebuild relies on it. git fetches
# the one git dependency (heroicons); curl serves the release smoke test.
RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils \
      build-essential pkg-config libncurses-dev libssl-dev \
 && rm -rf /var/lib/apt/lists/*

COPY --from=otp /opt/erlang /opt/erlang

RUN set -eux; \
    curl -fsSL -o /tmp/elixir.zip \
      "https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-${ELIXIR_OTP_MAJOR}.zip"; \
    echo "${ELIXIR_SHA256}  /tmp/elixir.zip" | sha256sum -c -; \
    unzip -q /tmp/elixir.zip -d /opt/elixir; \
    rm /tmp/elixir.zip; \
    mix local.hex --force; \
    mix local.rebar --force

RUN set -eux; \
    curl -fsSL -o /tmp/rustup-init \
      "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/x86_64-unknown-linux-gnu/rustup-init"; \
    echo "${RUSTUP_SHA256}  /tmp/rustup-init" | sha256sum -c -; \
    chmod +x /tmp/rustup-init; \
    /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain "${RUST_TOOLCHAIN}"; \
    rm /tmp/rustup-init

RUN set -eux; \
    mkdir -p /opt/assets; \
    curl -fsSL -o /tmp/esbuild.tgz \
      "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-${ESBUILD_VERSION}.tgz"; \
    echo "${ESBUILD_SHA256}  /tmp/esbuild.tgz" | sha256sum -c -; \
    tar -xzf /tmp/esbuild.tgz -C /tmp package/bin/esbuild; \
    install -m 0755 /tmp/package/bin/esbuild /opt/assets/esbuild; \
    rm -rf /tmp/esbuild.tgz /tmp/package; \
    curl -fsSL -o /opt/assets/tailwind \
      "https://github.com/tailwindlabs/tailwindcss/releases/download/v${TAILWIND_VERSION}/tailwindcss-linux-x64"; \
    echo "${TAILWIND_SHA256}  /opt/assets/tailwind" | sha256sum -c -; \
    chmod 0755 /opt/assets/tailwind

# Fail the build if any tool is missing or does not start.
RUN set -eux; \
    grep -q '^VERSION_CODENAME=bookworm$' /etc/os-release; \
    erl -noshell -eval 'io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt().'; \
    elixir --version; \
    cargo --version; \
    /opt/assets/esbuild --version

# ---------------------------------------------------------------------------
# ci: the test and browser-test jobs. The default target.
FROM build AS ci

ARG GECKODRIVER_VERSION=0.37.1
ARG GECKODRIVER_CRATE_SHA256=79f38cf1541aaf57f6f7eb270f691bcb702485a95dbaaefe740141a8ea46f0ef
ARG SELENIUM_VERSION=4.49.0
ARG SELENIUM_SHA256=8221cb7bf687b8ca13c31c2bca9fb8cc12e9d4c808baff670c66cb0e450ceb35
# Production's PostgreSQL major version (`postgres_version` in Ansible), which
# Debian 12 ships itself.
ARG POSTGRES_MAJOR=15

LABEL org.opencontainers.image.title="baudrate-ci" \
      org.opencontainers.image.description="Toolchain for Baudrate's CI test and browser-test jobs"

ENV BAUDRATE_IMAGE=ci \
    BAUDRATE_SELENIUM_DIR=/opt/selenium \
    MIX_AUDIT_HOME=/opt/mix-audit/home

# The PostgreSQL client must be production's major version: pg_dump and
# pg_restore 17 write `SET transaction_timeout`, which a PostgreSQL 15 server
# rejects, so the backup restore test cannot pass with a newer client.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      rsync firefox-esr openjdk-17-jre-headless "postgresql-client-${POSTGRES_MAJOR}" \
 && ln -s /usr/bin/firefox-esr /usr/local/bin/firefox \
 && rm -rf /var/lib/apt/lists/* \
 && pg_dump --version | grep -q " ${POSTGRES_MAJOR}\."

RUN set -eux; \
    mkdir -p /opt/selenium; \
    curl -fsSL -o "/opt/selenium/selenium-server-${SELENIUM_VERSION}.jar" \
      "https://github.com/SeleniumHQ/selenium/releases/download/selenium-${SELENIUM_VERSION}/selenium-server-${SELENIUM_VERSION}.jar"; \
    echo "${SELENIUM_SHA256}  /opt/selenium/selenium-server-${SELENIUM_VERSION}.jar" | sha256sum -c -

# GeckoDriver comes from source, not the GitHub release binary: the 0.37.x
# release tarballs are signed only by a Mozilla subkey revoked on 2026-08-06
# as compromised. The crates.io crate is a separate channel; it ships its
# Cargo.lock, and `--locked` checks every dependency against it.
RUN set -eux; \
    curl -fsSL -o /tmp/geckodriver.crate \
      "https://static.crates.io/crates/geckodriver/geckodriver-${GECKODRIVER_VERSION}.crate"; \
    echo "${GECKODRIVER_CRATE_SHA256}  /tmp/geckodriver.crate" | sha256sum -c -; \
    mkdir /tmp/geckodriver; \
    tar -xzf /tmp/geckodriver.crate -C /tmp/geckodriver --strip-components=1; \
    cargo build --manifest-path /tmp/geckodriver/Cargo.toml --release --locked; \
    install -m 0755 /tmp/geckodriver/target/release/geckodriver /opt/selenium/geckodriver; \
    rm -rf /tmp/geckodriver /tmp/geckodriver.crate "${CARGO_HOME}/registry" "${CARGO_HOME}/git"

# The advisory list `mix deps.audit` reads, taken when the image is built so
# the security job fetches nothing at run time. mix_audit looks for it under
# $HOME and runs `git pull` when it finds a checkout, so no `.git` is kept:
# with nothing to pull, it reads what is here. The commit is recorded for the
# job to print. Advisories are YAML data, never executed.
RUN set -eux; \
    dest="${MIX_AUDIT_HOME}/.local/share/elixir-security-advisories-mirego"; \
    mkdir -p "$(dirname "$dest")"; \
    git clone --quiet --depth 1 https://github.com/mirego/elixir-security-advisories.git /tmp/advisories; \
    git -C /tmp/advisories rev-parse HEAD > /opt/mix-audit/ADVISORIES_COMMIT; \
    git -C /tmp/advisories log -1 --format=%cI > /opt/mix-audit/ADVISORIES_DATE; \
    rm -rf /tmp/advisories/.git; \
    mv /tmp/advisories "$dest"; \
    test -n "$(find "$dest/packages" -name '*.yml' | head -n1)"

# Static checks (Phase 8A). clippy is a rustup component of the pinned
# toolchain, verified against the channel manifest like the rest of it.
# ansible-lint and the collections the playbooks use (the `ansible` package:
# community.general, community.postgresql, community.sops, ansible.posix) come
# from Debian's signed archive, like Firefox and the PostgreSQL client above.
RUN set -eux; \
    rustup component add clippy; \
    apt-get update; \
    apt-get install -y --no-install-recommends ansible-lint ansible; \
    rm -rf /var/lib/apt/lists/*

# Fail the build if any tool is missing or does not start.
RUN set -eux; \
    cargo clippy --version; \
    ansible-lint --version; \
    firefox --version; \
    java -version; \
    pg_dump --version; \
    /opt/selenium/geckodriver --version; \
    cat /opt/mix-audit/ADVISORIES_COMMIT
