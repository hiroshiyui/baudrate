#!/bin/sh
# Run inside the CI image, from the repository root. Fails when the image's
# tools differ from what the project pins, so a version bump in
# .tool-versions or config/config.exs cannot silently run on an old image.
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

otp_version="$(cat "$(erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')/releases/$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')/OTP_VERSION")"
elixir_version="$(elixir -e 'IO.write(System.version())')"
esbuild_version="$("$MIX_ESBUILD_PATH" --version)"
tailwind_version="$("$MIX_TAILWIND_PATH" --help 2>&1 | sed -nE 's/.*tailwindcss v([0-9.]+).*/\1/p' | head -n1)"

check erlang "$otp_version" "$(pinned_tool erlang)"
check elixir "$elixir_version" "$(pinned_tool elixir)"
check esbuild "$esbuild_version" "$(pinned_asset esbuild)"
check tailwind "$tailwind_version" "$(pinned_asset tailwind)"

exit "$fail"
