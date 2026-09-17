#!/bin/sh
# Builds the production release tarball (ADR 0036).
#
# Runs in the baudrate-build image (ci/image/), from the repository root, on a
# clean checkout. Writes the tarball to $OUT_DIR (default _build/artifacts),
# records its file name in $OUT_DIR/.tarball, and prints its path last. With
# RELEASE_TAG set, refuses to build unless the tag names
# the version in mix.exs.
#
# The tarball holds the release directory itself (bin/, erts-*/, lib/,
# releases/), without priv/static/uploads: the deploy links the server's
# shared uploads in. Its name records what it runs on:
# baudrate-<version>-debian<N>-<arch>.tar.gz.
set -eu

export MIX_ENV=prod

version="$(sed -nE 's/^[[:space:]]*version: "([^"]+)",[[:space:]]*$/\1/p' mix.exs | head -n1)"
if [ -z "$version" ]; then
  echo "::error::could not read the version from mix.exs" >&2
  exit 1
fi
if [ -n "${RELEASE_TAG:-}" ] && [ "$RELEASE_TAG" != "v$version" ]; then
  echo "::error::tag $RELEASE_TAG does not match mix.exs version $version" >&2
  exit 1
fi

. /etc/os-release
name="baudrate-${version}-debian${VERSION_ID:-unknown}-$(uname -m).tar.gz"
out="${OUT_DIR:-_build/artifacts}"
rel=_build/prod/rel/baudrate

mix deps.get --only prod
mix compile
mix assets.deploy
rm -rf _build/prod/rel
mix release

for uploads in "$rel"/lib/baudrate-*/priv/static/uploads; do
  rm -rf "$uploads"
done

# The public placeholder cookie, never a random one (mix.exs, rel/env.sh.eex).
if ! grep -q '^public-not-a-secret-' "$rel/releases/COOKIE"; then
  echo "::error::releases/COOKIE is not the public placeholder; check releases/0 in mix.exs" >&2
  exit 1
fi

mkdir -p "$out"
tarball="$out/$name"
tar --sort=name --owner=0 --group=0 --numeric-owner \
  --mtime="@$(git -c safe.directory="$PWD" log -1 --format=%ct)" \
  -C "$rel" -cf - . | gzip -n -9 > "$tarball"

printf '%s\n' "$name" > "$out/.tarball"
echo "$tarball"
