# 0028 — Backups are complete folders with count-based retention, pulled off-host

- **Status:** Accepted; amended by
  [0038](0038-encryption-keys-are-separate-and-rotatable.md): restoring the
  data needs the matching key *set*, not only `SECRET_KEY_BASE`, and
  `MANIFEST.json` records which key ids were current.
- **Date:** 2026-09-15
- **Deciders:** Baudrate maintainers
- **Related:** [0023](0023-data-export-threat-model.md)
  (the uploads directory resolution backups share with data export)

## Context

Until now production had no scheduled backup. `Baudrate.Release.backup/2`
(v1.18.2) wrote a database dump and a `.tar.gz` of the uploads, but nothing
ran it, nothing removed old backups, and nothing copied them off the host.

The production host is a small VPS (2 CPUs, 4 GB RAM, 75 GB disk). It also
runs PostgreSQL and the site, so a backup must not fill the disk or compete
with visitors. At the time of writing the database was 659 MB and the uploads
worth keeping 402 MB. The uploads are WebP images that never change once
written, so compression gains almost nothing and repeating them nightly is
wasted space.

## Decision

1. **A backup is a folder,** `daily/<YYYYMMDDTHHMMSSZ>/`, holding a
   `pg_dump -Fc` dump checked with `pg_restore --list`, a copy of the uploads
   (without `media_cache/`) and a `MANIFEST.json` with sizes and the dump's
   SHA-256 (`Baudrate.Backup.Snapshots`).
2. **Uploads are hard-link snapshots.** A file whose size and modification
   time match its copy in the previous backup is hard-linked to that copy, so
   each backup is complete on its own while unchanged files are stored once.
   Snapshotting is done in Elixir, without rsync, so it is tested in CI.
3. **A backup is complete or absent.** It is built under `.incomplete-…` and
   renamed only after every step succeeded; a failure removes what it wrote.
4. **Retention counts complete backups** (7 nightly, 3 pre-deploy), and runs
   only after a new backup succeeded.
5. **A backup refuses to start** when it would leave less than 1 GiB or 10% of
   the filesystem free, estimated from the last dump and the files to copy.
6. **Scheduling is systemd:** a timer at a quiet hour runs a oneshot service
   as the app user, at idle I/O priority, niceness 19, half a CPU and a memory
   ceiling, able to write only the backup directory. The deploy playbook dumps
   the database right before migrations.
7. **Off-host copies are pulled.** Another machine fetches backups over SSH
   with a key restricted to `rrsync -ro` of the backup directory and keeps its
   own history. The server holds no credentials for the copy's destination.

## Consequences

- A week of nightly backups costs about one copy of the uploads, seven
  compressed dumps and the uploads added during the week.
- Failing backups never delete the last good ones; a full disk stops a backup,
  not the site.
- Restoring is one command per folder (`Release.restore_snapshot/1`) or per
  dump (`Release.restore_db/1`), with the service stopped. Files added after
  the backup are left in place.
- Hard-linked files share storage between backups: editing a file inside a
  backup would change it in the others. Backups are never edited; restore
  copies out of them.
- The dump contains every account's data, including encrypted TOTP secrets
  and federation keys. The directory is readable only by the app user and the
  backup group, and restoring the data also needs the same `SECRET_KEY_BASE`,
  which lives in the SOPS secrets file and needs its own offline copy.
- Until a pull machine is set up, backups protect against mistakes and bad
  data, not against losing the server.
- A backup taken while users post can pair a dump with uploads a few minutes
  newer; the only effect is an unreferenced file or a missing image for
  content created during those minutes.

## Alternatives considered

- **Delete backups older than N days.** Rejected: if backups fail for N
  days, the cleanup removes every good copy.
- **A `.tar.gz` of the uploads each night.** Rejected: about 0.4 GB a night
  of the same images.
- **rsync `--link-dest` for snapshots.** Rejected for now: equivalent result,
  but another tool on the server and untestable in CI without adding it to
  the image.
- **Streaming the backup straight to another machine over SSH,** storing
  nothing on the server. Rejected: backups would stop whenever that machine is
  off, and it would hold a credential able to dump the whole database.
- **Pushing to object storage from the server.** Rejected for now: needs an
  account and a write credential on the server, which a compromise could use
  against the copies.
