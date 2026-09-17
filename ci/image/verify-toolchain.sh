#!/bin/sh
# Run inside a CI image (baudrate-ci or baudrate-build), from the repository
# root. Fails when the image's tools differ from what the project pins, so a
# version bump in .tool-versions, config/config.exs,
# lib/mix/tasks/selenium_setup.ex or the Ansible inventory cannot silently run
# on an old image. The test tools are checked only in baudrate-ci.
set -eu

fail=0
check() {
  if [ "$2" = "$3" ]; then
    echo "ok   $1 $2"
  else
    echo "::error::CI image has $1 '$2' but the project pins '$3'; rebuild the image (ci/image/README.md)"
    fail=1
  fi
}

pinned_tool() { awk -v t="$1" '$1 == t { print $2 }' .tool-versions; }
pinned_asset() {
  sed -nE "/^config :$1,/,/^[[:space:]]*\$/ s/^[[:space:]]*version: \"([^\"]+)\".*/\1/p" config/config.exs | head -n1
}
pinned_selenium_setup() {
  sed -nE "s/^[[:space:]]*@$1_version \"([^\"]+)\".*/\1/p" lib/mix/tasks/selenium_setup.ex
}

otp_version="$(cat "$(erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')/releases/$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')/OTP_VERSION")"
elixir_version="$(elixir -e 'IO.write(System.version())')"
esbuild_version="$("$MIX_ESBUILD_PATH" --version)"
# Same probe as the tailwind Hex package; NO_COLOR and stripping escape codes
# keep the version parseable when the CLI decides to print colours.
tailwind_output="$(NO_COLOR=1 "$MIX_TAILWIND_PATH" --help 2>&1 || true)"
tailwind_version="$(printf '%s\n' "$tailwind_output" | sed -E 's/\x1b\[[0-9;]*m//g' | sed -nE 's/.*tailwindcss v([0-9.]+).*/\1/p' | head -n1)"
if [ -z "$tailwind_version" ]; then
  echo "tailwind --help printed:"
  printf '%s\n' "$tailwind_output" | head -n 20
fi

check erlang "$otp_version" "$(pinned_tool erlang)"
check elixir "$elixir_version" "$(pinned_tool elixir)"
check esbuild "$esbuild_version" "$(pinned_asset esbuild)"
check tailwind "$tailwind_version" "$(pinned_asset tailwind)"

# Debian: production's release, because the release built here carries its
# own Erlang runtime and NIFs linked against this system (ADR 0036).
pinned_debian="$(sed -nE 's/^debian_version: "?([0-9]+)"?.*/\1/p' ansible/inventory/group_vars/all.yml)"
image_debian="$(. /etc/os-release && echo "${VERSION_ID:-}")"
check debian "$image_debian" "$pinned_debian"

if [ "${BAUDRATE_IMAGE:-}" = ci ]; then
  geckodriver_version="$("$BAUDRATE_SELENIUM_DIR/geckodriver" --version | sed -nE '1s/^geckodriver ([^ ]+).*/\1/p')"
  selenium_version="$(ls "$BAUDRATE_SELENIUM_DIR" | sed -nE 's/^selenium-server-(.+)\.jar$/\1/p' | paste -sd ' ' -)"
  check geckodriver "$geckodriver_version" "$(pinned_selenium_setup geckodriver)"
  check selenium "$selenium_version" "$(pinned_selenium_setup selenium)"
fi

# PostgreSQL: CI tests production's major version, taken from the Ansible
# inventory. The client lives in the ci image; the server is each workflow's
# service container, so a mismatch there means editing the workflow, not
# rebuilding the image.
pinned_postgres="$(sed -nE 's/^postgres_version: "?([0-9]+)"?.*/\1/p' ansible/inventory/group_vars/all.yml)"
if [ "${BAUDRATE_IMAGE:-}" = ci ]; then
  pg_client_major="$(pg_dump --version | sed -nE 's/^pg_dump \(PostgreSQL\) ([0-9]+)\..*/\1/p')"
  check postgresql-client "$pg_client_major" "$pinned_postgres"
fi

for workflow in .github/workflows/elixir.yml .github/workflows/release.yml; do
  service_majors="$(sed -nE 's/^[[:space:]]*image: postgres:([0-9]+)@sha256:[0-9a-f]{64}[[:space:]]*$/\1/p' "$workflow")"
  if [ -z "$service_majors" ]; then
    echo "::error::no digest-pinned postgres service image found in $workflow"
    fail=1
  fi
  for major in $service_majors; do
    if [ "$major" = "$pinned_postgres" ]; then
      echo "ok   postgres-service $major ($workflow)"
    else
      echo "::error::the postgres service in $workflow is $major but production runs $pinned_postgres (ansible postgres_version); update its image"
      fail=1
    fi
  done
done

exit "$fail"
