#!/bin/sh
# Pulls Baudrate backups from the server to this machine (ADR 0028).
#
# Backups live on the server for a week; this keeps a longer history somewhere
# the server cannot reach. It is a *pull*: the server holds no credential for
# this machine, and nothing here is ever sent back.
#
# Usage: pull-backups.sh   (settings come from the environment)
#
#   BAUDRATE_BACKUP_HOST         user@host of the restricted pull account
#   BAUDRATE_BACKUP_PORT         SSH port (default 22)
#   BAUDRATE_BACKUP_KEY          SSH key for it (default ~/.ssh/baudrate-backup-pull)
#   BAUDRATE_BACKUP_DEST         where to keep copies (default ~/Backups/baudrate)
#   BAUDRATE_BACKUP_KEEP         copies to keep here (default 30)
#   BAUDRATE_BACKUP_STALE_HOURS  warn above this age (default 36)
#
# Exit codes: 0 all good, 1 the pull or a check failed, 2 the newest backup is
# older than BAUDRATE_BACKUP_STALE_HOURS (backups may have stopped running).
#
# The newest copy is verified against the CHECKSUMS.sha256 the server wrote —
# the dump and every upload — so corruption in transit, or bit rot on either
# disk, shows up as a failure rather than as a backup nobody can restore.
#
# Needs rsync and GNU coreutils; pg_restore is used when present.
set -eu

HOST=${BAUDRATE_BACKUP_HOST:-baudrate-pull@baudrate.tw}
PORT=${BAUDRATE_BACKUP_PORT:-22}
KEY=${BAUDRATE_BACKUP_KEY:-$HOME/.ssh/baudrate-backup-pull}
DEST=${BAUDRATE_BACKUP_DEST:-$HOME/Backups/baudrate}
KEEP=${BAUDRATE_BACKUP_KEEP:-30}
STALE_HOURS=${BAUDRATE_BACKUP_STALE_HOURS:-36}

mkdir -p "$DEST/daily" "$DEST/predeploy"
chmod 700 "$DEST"

# -H keeps the server's hard links, so a week of backups costs about one copy
# of the uploads here too. No --delete: backups the server has since rotated
# away stay here, and a server someone took over cannot erase what it already
# handed over. The key on the far side may only read (rrsync -ro).
ssh_cmd="ssh -i $KEY -p $PORT -o IdentitiesOnly=yes -o BatchMode=yes"
rsync -aH --info=stats2 -e "$ssh_cmd" "$HOST:daily/" "$DEST/daily/"
rsync -aH --info=stats2 -e "$ssh_cmd" "$HOST:predeploy/" "$DEST/predeploy/"

newest=$(find "$DEST/daily" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)
if [ -z "$newest" ]; then
  echo "pull-backups: no backups in $DEST/daily" >&2
  exit 1
fi

# Reads one recorded hash out of the pretty-printed manifest, scoped to the
# block it belongs to: the manifest holds more than one sha256, so matching the
# first one in the file would silently compare the wrong thing.
manifest_sha256() { # <manifest> <block>
  sed -n "/\"$2\"/,/}/s/.*\"sha256\": *\"\([0-9a-f]\{64\}\)\".*/\1/p" "$1" | head -1
}

# The server records what it wrote; checking it here proves the copy arrived
# intact, not merely that rsync exited 0 — and, run nightly, that it has stayed
# intact since.
checksums="$newest/CHECKSUMS.sha256"

if [ -f "$checksums" ]; then
  # Verify the list itself before trusting it. A truncated or rewritten list
  # would otherwise happily certify a truncated backup.
  recorded=$(manifest_sha256 "$newest/MANIFEST.json" checksums)
  copied=$(sha256sum "$checksums" | cut -d' ' -f1)
  if [ -z "$recorded" ] || [ "$recorded" != "$copied" ]; then
    echo "pull-backups: CHECKSUMS.sha256 does not match the manifest in $newest" >&2
    exit 1
  fi

  # Covers the dump and every upload, so a silently corrupted image is caught
  # as readily as a truncated dump.
  if ! (cd "$newest" && sha256sum --quiet -c CHECKSUMS.sha256); then
    echo "pull-backups: files in $newest do not match their recorded checksums" >&2
    exit 1
  fi
else
  # A backup taken before the checksum list existed. The dump is all there is
  # to check; its uploads are verified from the next backup onwards.
  recorded=$(manifest_sha256 "$newest/MANIFEST.json" database)
  copied=$(sha256sum "$newest/db.dump" | cut -d' ' -f1)
  if [ "$recorded" != "$copied" ]; then
    echo "pull-backups: checksum mismatch for $newest/db.dump" >&2
    exit 1
  fi
  echo "pull-backups: $newest predates CHECKSUMS.sha256; only the dump was verified" >&2
fi

if command -v pg_restore >/dev/null 2>&1; then
  pg_restore --list "$newest/db.dump" >/dev/null || {
    echo "pull-backups: $newest/db.dump does not read as a dump" >&2
    exit 1
  }
fi

# Retention here counts complete copies, like the server's.
find "$DEST/daily" -mindepth 1 -maxdepth 1 -type d | sort | head -n "-$KEEP" |
  while read -r old; do rm -rf "$old"; done
find "$DEST/predeploy" -mindepth 1 -maxdepth 1 -name '*.dump' | sort | head -n "-$KEEP" |
  while read -r old; do rm -f "$old"; done

count=$(find "$DEST/daily" -mindepth 1 -maxdepth 1 -type d | wc -l)
age_hours=$(( ( $(date +%s) - $(date -r "$newest/MANIFEST.json" +%s) ) / 3600 ))
size=$(du -sh "$DEST" | cut -f1)

if [ "$age_hours" -gt "$STALE_HOURS" ]; then
  echo "pull-backups: newest backup is ${age_hours}h old (over ${STALE_HOURS}h): $newest" >&2
  echo "pull-backups: backups on the server may have stopped running." >&2
  exit 2
fi

echo "pull-backups: $count copies in $DEST ($size); newest $(basename "$newest"), ${age_hours}h old"
