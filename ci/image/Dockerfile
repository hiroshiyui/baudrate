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
#   * esbuild, Tailwind, GeckoDriver, Selenium Server: SHA-256 pinned.
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
ARG RUST_TOOLCHAIN=1.95.0
ARG ESBUILD_VERSION=0.28.2
ARG ESBUILD_SHA256=9573bb2233aab0f9ea7647d5cca9726113cc1768de61d66b17267f4db84488f6
ARG TAILWIND_VERSION=4.3.3
ARG TAILWIND_SHA256=dc61b3ac6b8c9ca874c0cc4c57b2409791a64c5540404ca5f5367360babc313a
ARG GECKODRIVER_VERSION=0.36.0
ARG GECKODRIVER_SHA256=0bde38707eb0a686a20c6bd50f4adcc7d60d4f73c60eb83ee9e0db8f65823e04
ARG SELENIUM_VERSION=4.27.0
ARG SELENIUM_SHA256=5481ca09814fc0ec8c2b8ff07b8574a467f49f0c285107b1525325d535408d6a

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

# Signed Debian packages only. `upgrade` picks up security fixes released
# after the base image digest was pinned; the weekly rebuild relies on it.
RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils \
      build-essential pkg-config libncurses-dev libssl-dev \
      postgresql-client \
      firefox-esr openjdk-21-jre-headless \
 && ln -s /usr/bin/firefox-esr /usr/local/bin/firefox \
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
    curl -fsSL -o /tmp/geckodriver.tar.gz \
      "https://github.com/mozilla/geckodriver/releases/download/v${GECKODRIVER_VERSION}/geckodriver-v${GECKODRIVER_VERSION}-linux64.tar.gz"; \
    echo "${GECKODRIVER_SHA256}  /tmp/geckodriver.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/geckodriver.tar.gz -C /opt/selenium geckodriver; \
    chmod 0755 /opt/selenium/geckodriver; \
    rm /tmp/geckodriver.tar.gz; \
    curl -fsSL -o "/opt/selenium/selenium-server-${SELENIUM_VERSION}.jar" \
      "https://github.com/SeleniumHQ/selenium/releases/download/selenium-${SELENIUM_VERSION}/selenium-server-${SELENIUM_VERSION}.jar"; \
    echo "${SELENIUM_SHA256}  /opt/selenium/selenium-server-${SELENIUM_VERSION}.jar" | sha256sum -c -

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
