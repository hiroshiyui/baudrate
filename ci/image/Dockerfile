# syntax=docker/dockerfile:1
#
# Baudrate CI image: every tool the test and browser-test jobs need, from
# inputs that are pinned and verified here rather than fetched at CI run time.
# See ci/image/README.md for what is trusted, how it is built and updated.
#
#   * Base: Debian stable (slim), pinned by digest. Distribution packages
#     (build tools, Firefox ESR, Java, PostgreSQL client) come from Debian's
#     signed apt repositories.
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

# The base is written out in both stages (not an ARG) so Dependabot can
# propose digest updates; keep the two lines identical.

# ---------------------------------------------------------------------------
FROM debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132 AS otp

ARG OTP_VERSION=28.5.0.6
ARG OTP_SHA256=49d7a75e906334af54ae336ba53fc4e6ad100645e8e7efd3be008de284dab3ba

RUN apt-get update \
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
FROM debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132

ARG ELIXIR_VERSION=1.19.5
ARG ELIXIR_OTP_MAJOR=28
ARG ELIXIR_SHA256=ca481510feb6dabc875bba43e44b25c7abafa53bd7a103639851b7aeace8a022
ARG RUSTUP_VERSION=1.29.1
ARG RUSTUP_SHA256=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71
ARG RUST_TOOLCHAIN=1.98.1
ARG ESBUILD_VERSION=0.28.2
ARG ESBUILD_SHA256=9573bb2233aab0f9ea7647d5cca9726113cc1768de61d66b17267f4db84488f6
ARG TAILWIND_VERSION=4.3.3
ARG TAILWIND_SHA256=dc61b3ac6b8c9ca874c0cc4c57b2409791a64c5540404ca5f5367360babc313a
ARG GECKODRIVER_VERSION=0.37.1
ARG GECKODRIVER_CRATE_SHA256=79f38cf1541aaf57f6f7eb270f691bcb702485a95dbaaefe740141a8ea46f0ef
ARG SELENIUM_VERSION=4.49.0
ARG SELENIUM_SHA256=8221cb7bf687b8ca13c31c2bca9fb8cc12e9d4c808baff670c66cb0e450ceb35
# Production's PostgreSQL major version (`postgres_version` in Ansible). The
# key is the copy Debian ships in postgresql-client-common, not a download.
ARG POSTGRES_MAJOR=15
ARG PGDG_KEY_SHA256=0144068502a1eddd2a0280ede10ef607d1ec592ce819940991203941564e8e76

LABEL org.opencontainers.image.title="baudrate-ci" \
      org.opencontainers.image.description="Toolchain for Baudrate's CI test and browser-test jobs" \
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
    BAUDRATE_SELENIUM_DIR=/opt/selenium

# Signed Debian packages. `upgrade` picks up security fixes released after the
# base image digest was pinned; the weekly rebuild relies on it.
RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git rsync unzip xz-utils \
      build-essential pkg-config libncurses-dev libssl-dev \
      postgresql-client-common \
      firefox-esr openjdk-21-jre-headless \
 && ln -s /usr/bin/firefox-esr /usr/local/bin/firefox \
 && rm -rf /var/lib/apt/lists/*

# The PostgreSQL client must be production's major version, not Debian's:
# pg_dump and pg_restore 17 write `SET transaction_timeout`, which a
# PostgreSQL 15 server rejects, so the backup restore test cannot pass with a
# newer client. Debian trixie carries only 17, so this one package comes from
# the PostgreSQL project's repository.
#
# - The signing key is the copy Debian itself ships, checked by SHA-256, so
#   trust starts from Debian's signed archive rather than a download.
# - The repository is pinned below Debian (priority 100). Apt takes only
#   packages Debian does not have from it: libpq5 and the common scripts
#   stay Debian's.
RUN set -eux; \
    key=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc; \
    echo "${PGDG_KEY_SHA256}  ${key}" | sha256sum -c -; \
    printf '%s\n' \
      'Types: deb' \
      'URIs: https://apt.postgresql.org/pub/repos/apt' \
      'Suites: trixie-pgdg' \
      'Components: main' \
      "Signed-By: ${key}" \
      > /etc/apt/sources.list.d/pgdg.sources; \
    printf '%s\n' \
      'Package: *' \
      'Pin: origin apt.postgresql.org' \
      'Pin-Priority: 100' \
      > /etc/apt/preferences.d/pgdg; \
    apt-get update; \
    apt-get install -y --no-install-recommends "postgresql-client-${POSTGRES_MAJOR}"; \
    rm -rf /var/lib/apt/lists/*; \
    pg_dump --version | grep -q " ${POSTGRES_MAJOR}\."

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
    mkdir -p /opt/assets /opt/selenium; \
    curl -fsSL -o /tmp/esbuild.tgz \
      "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-${ESBUILD_VERSION}.tgz"; \
    echo "${ESBUILD_SHA256}  /tmp/esbuild.tgz" | sha256sum -c -; \
    tar -xzf /tmp/esbuild.tgz -C /tmp package/bin/esbuild; \
    install -m 0755 /tmp/package/bin/esbuild /opt/assets/esbuild; \
    rm -rf /tmp/esbuild.tgz /tmp/package; \
    curl -fsSL -o /opt/assets/tailwind \
      "https://github.com/tailwindlabs/tailwindcss/releases/download/v${TAILWIND_VERSION}/tailwindcss-linux-x64"; \
    echo "${TAILWIND_SHA256}  /opt/assets/tailwind" | sha256sum -c -; \
    chmod 0755 /opt/assets/tailwind; \
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

# Fail the build if any tool is missing or does not start.
RUN set -eux; \
    erl -noshell -eval 'io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt().'; \
    elixir --version; \
    cargo --version; \
    firefox --version; \
    java -version; \
    pg_dump --version; \
    /opt/assets/esbuild --version; \
    /opt/selenium/geckodriver --version
