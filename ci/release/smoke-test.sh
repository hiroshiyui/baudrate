#!/bin/sh
# Starts a built release the way production does and checks that it serves
# (ADR 0036).
#
#   ci/release/smoke-test.sh <tarball>
#
# Needs an empty PostgreSQL database in SMOKE_DATABASE_URL, and curl. Runs in
# the baudrate-build image in CI; SMOKE_PORT and SMOKE_HEALTH_PORT (default
# 4000 and 4001) move the listeners when those ports are taken locally, and
# SMOKE_LISTENERS=skip skips check 6 on a machine where other services listen
# (it reads every listener in this network namespace).
#
# Checks, in order:
#   1. the release refuses to start without a cookie of its own, or with the
#      public one it ships;
#   2. migrations run with `bin/migrate` (`eval`, which needs no cookie);
#   3. `bin/server` answers the public /health;
#   4. the detailed report answers on 127.0.0.1, and its database, queue and
#      worker checks pass (disk and backup depend on the machine);
#   5. `rpc` reaches the node with the server's cookie;
#   6. nothing but the web port listens on a non-loopback address;
#   7. `stop` shuts the node down.
set -eu

tarball="${1:?usage: smoke-test.sh <tarball>}"
: "${SMOKE_DATABASE_URL:?set SMOKE_DATABASE_URL to an empty database}"
port="${SMOKE_PORT:-4000}"
health_port="${SMOKE_HEALTH_PORT:-4001}"

work="$(mktemp -d)"
rel="$work/release"
mkdir "$rel"
tar -xzf "$tarball" -C "$rel"
for static in "$rel"/lib/baudrate-*/priv/static; do
  mkdir -p "$static/uploads"
done

export DATABASE_URL="$SMOKE_DATABASE_URL"
export DATABASE_SSL=false
export PHX_HOST=localhost
export PORT="$port"
export HEALTH_DETAIL_PORT="$health_port"
SECRET_KEY_BASE="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
export SECRET_KEY_BASE
cookie="$(head -c 32 /dev/urandom | base64 | tr -d '/+=\n')"
server_pid=""

fail() {
  echo "::error::smoke test: $*" >&2
  if [ -f "$work/server.log" ]; then
    echo "--- server log ---" >&2
    tail -n 60 "$work/server.log" >&2
  fi
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
  exit 1
}

step() { echo "--- $*"; }

step "1. refuses to start without a cookie of its own"
if RELEASE_COOKIE="" "$rel/bin/baudrate" start > "$work/refused.log" 2>&1; then
  fail "started without RELEASE_COOKIE"
fi
grep -q "RELEASE_COOKIE must be set" "$work/refused.log" || fail "no cookie error: $(cat "$work/refused.log")"
if RELEASE_COOKIE="$(cat "$rel/releases/COOKIE")" "$rel/bin/baudrate" start > "$work/refused.log" 2>&1; then
  fail "started with the public cookie"
fi
grep -q "RELEASE_COOKIE must be set" "$work/refused.log" || fail "no cookie error: $(cat "$work/refused.log")"

step "2. migrations"
"$rel/bin/migrate" || fail "bin/migrate failed"

step "3. public /health"
RELEASE_COOKIE="$cookie" "$rel/bin/server" > "$work/server.log" 2>&1 &
server_pid=$!
i=0
until curl -fs -o /dev/null "http://127.0.0.1:${port}/health"; do
  i=$((i + 1))
  if [ "$i" -ge 90 ]; then fail "/health did not answer within 90 s"; fi
  if ! kill -0 "$server_pid" 2>/dev/null; then fail "the server exited"; fi
  sleep 1
done

step "4. detailed health report"
code="$(curl -s -o "$work/report.json" -w '%{http_code}' "http://127.0.0.1:${health_port}/health")" \
  || fail "the detailed report did not answer"
case "$code" in 200 | 503) ;; *) fail "detailed report answered $code" ;; esac
REPORT="$work/report.json" "$rel/bin/baudrate" eval '
  %{"checks" => checks} = "REPORT" |> System.fetch_env!() |> File.read!() |> Jason.decode!()

  for name <- ~w(database delivery_queue inbound_queue workers) do
    status = get_in(checks, [name, "status"])
    IO.puts("#{name}: #{status}")
    if status not in ["ok", "skipped"], do: System.halt(1)
  end
' || fail "a check that must pass did not: $(cat "$work/report.json")"

step "5. rpc with the server's cookie"
RELEASE_COOKIE="$cookie" "$rel/bin/baudrate" rpc 'IO.puts("rpc ok from #{node()}")' > "$work/rpc.log" 2>&1 \
  || fail "rpc failed: $(cat "$work/rpc.log")"
grep -q "rpc ok from baudrate@127.0.0.1" "$work/rpc.log" || fail "unexpected rpc output: $(cat "$work/rpc.log")"

step "6. listeners beyond loopback"
# The process that owns a socket inode, for the report.
owner() {
  for fd in /proc/[0-9]*/fd/*; do
    if [ "$(readlink "$fd" 2>/dev/null)" = "socket:[$1]" ]; then
      pid="${fd#/proc/}"
      pid="${pid%%/*}"
      tr '\0' ' ' < "/proc/$pid/cmdline" | cut -c1-160
      return
    fi
  done
  echo "(owner not found)"
}
exposed="$port"
report=""
for table in /proc/net/tcp /proc/net/tcp6; do
  [ -r "$table" ] || continue
  # sl local remote state tx:rx timer:when retransmit uid timeout inode
  while read -r _ local _ state _ _ _ _ _ inode; do
    [ "$state" = 0A ] || continue # LISTEN
    # Loopback: 127.0.0.0/8, ::1 and ::ffff:127.0.0.0/104, as /proc writes
    # them (each 32-bit word in host byte order, so 127 is the last byte).
    # In a container, Docker's DNS resolver listens on 127.0.0.11.
    case "${local%:*}" in
      ??????7F | 00000000000000000000000001000000 | 0000000000000000FFFF0000??????7F) continue ;;
    esac
    listen_port="$(printf '%d' "0x${local##*:}")"
    exposed="$exposed $listen_port"
    if [ "$listen_port" != "$port" ]; then
      report="$report
  port $listen_port, address ${local%:*} ($table): $(owner "$inode")"
    fi
  done < "$table"
done
exposed="$(echo $exposed | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')"
echo "listening beyond loopback: $exposed"
if [ "${SMOKE_LISTENERS:-}" = skip ]; then
  echo "(not checked: SMOKE_LISTENERS=skip)"
elif [ "$exposed" != "$port" ]; then
  fail "expected only port $port beyond loopback, found: $exposed$report"
fi

step "7. stop"
RELEASE_COOKIE="$cookie" "$rel/bin/baudrate" stop > /dev/null 2>&1 || fail "stop failed"
i=0
while kill -0 "$server_pid" 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -ge 40 ]; then fail "the node did not stop within 40 s"; fi
  sleep 1
done
server_pid=""

rm -rf "$work"
echo "smoke test passed"
