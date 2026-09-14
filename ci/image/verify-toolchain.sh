#!/bin/sh
# Run inside the CI image, from the repository root. Fails when the image's
# tools differ from what the project pins, so a version bump in
# .tool-versions, config/config.exs or lib/mix/tasks/selenium_setup.ex cannot
# silently run on an old image.
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

geckodriver_version="$("$BAUDRATE_SELENIUM_DIR/geckodriver" --version | sed -nE '1s/^geckodriver ([^ ]+).*/\1/p')"
selenium_version="$(ls "$BAUDRATE_SELENIUM_DIR" | sed -nE 's/^selenium-server-(.+)\.jar$/\1/p' | paste -sd ' ' -)"

check erlang "$otp_version" "$(pinned_tool erlang)"
check elixir "$elixir_version" "$(pinned_tool elixir)"
check esbuild "$esbuild_version" "$(pinned_asset esbuild)"
check tailwind "$tailwind_version" "$(pinned_asset tailwind)"
check geckodriver "$geckodriver_version" "$(pinned_selenium_setup geckodriver)"
check selenium "$selenium_version" "$(pinned_selenium_setup selenium)"

exit "$fail"
