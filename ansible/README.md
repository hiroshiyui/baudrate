# Baudrate — Ansible Playbooks

Ansible automation for provisioning Baudrate servers.

## Prerequisites

- **Ansible 2.14+** on the control machine
- **[SOPS](https://github.com/getsops/sops)** for secrets management
- **GPG key** for encrypting/decrypting secrets
- **[GitHub CLI](https://cli.github.com/)**, signed in (`gh auth login`), and
  this repository cloned with its tags (`git fetch --tags`): the deploy
  verifies the release's build attestation on the control machine (ADR 0036)
- **Ansible collections:**
  ```bash
  ansible-galaxy collection install community.general community.postgresql community.sops
  ```
- **Target server:** Debian 12 (Bookworm) with SSH access
- **DNS:** domain pointed at the server's IP (required for Let's Encrypt)

## Quick Start

1. **Configure inventory** — edit `inventory/hosts.yml` with your server:

   ```yaml
   all:
     children:
       production:
         hosts:
           forum.example.com:
             ansible_user: root
   ```

2. **Configure SOPS** — edit `.sops.yaml` with your GPG fingerprint:

   ```bash
   # Find your fingerprint
   gpg --list-keys --keyid-format long

   # Edit .sops.yaml and replace the placeholder
   ```

   For multiple operators, list all fingerprints comma-separated. Each
   operator can decrypt with their own private key.

3. **Set up secrets:**

   ```bash
   cd ansible
   cp inventory/group_vars/all.sops.yml.example inventory/group_vars/all.sops.yml
   sops inventory/group_vars/all.sops.yml
   ```

   This opens your `$EDITOR` with the decrypted file. Set
   `postgres_db_password` to a strong value, save, and exit. SOPS
   encrypts it automatically on save.

   If you skip this step, the playbook will auto-generate a password and
   pause so you can save it before continuing.

4. **Run the playbook:**

   ```bash
   ansible-playbook playbooks/setup-server.yml
   ```

   No `--ask-vault-pass` needed — SOPS decrypts via your GPG key
   (unlocked by `gpg-agent`).

   You will be prompted for:
   - **Site domain** (or set `BAUDRATE_DOMAIN` env var)
   - **Let's Encrypt email** (or set `BAUDRATE_CERTBOT_EMAIL` env var)

## What `setup-server.yml` Does

Provisions infrastructure only — does **not** deploy the application.

Releases are built in CI and installed as a tarball (ADR 0036), so the `elixir`
and `rust` roles and the build packages in `common` are no longer needed to
deploy. They still run, and nothing removes them from a server: on a server
Baudrate has to itself you may remove `/opt/baudrate/.asdf`, `.cargo`,
`.rustup` and `src/`, and the build packages, by hand. On a shared server,
check first whether another application builds there.

| Role | Tag | Purpose |
|------|-----|---------|
| `common` | `common` | System packages, `baudrate` user, UFW firewall, SSH hardening, fail2ban, NTP |
| `postgresql` | `postgresql` | PostgreSQL 15, database + user, `pg_trgm` extension |
| `elixir` | `elixir` | asdf + Erlang 28.5.0.6 + Elixir 1.19.5 + Hex/Rebar. Deploys no longer use it (ADR 0036) |
| `rust` | `rust` | rustup with minimal profile. Deploys no longer use it (ADR 0036) |
| `nginx` | `nginx` | nginx, Let's Encrypt SSL via certbot, reverse proxy config |

## Deploying Baudrate

After provisioning with `setup-server.yml`, deploy the application:

```bash
ansible-playbook playbooks/deploy-baudrate.yml
```

You will be prompted for:
- **Site domain** (or set `BAUDRATE_DOMAIN` env var)
- **Release tag** — a git tag like `v1.0.0` (required, no default)
- **Release repository** — `owner/name` on GitHub, defaulting to
  `release_repo` (the upstream repository); set it for a fork

The release must already have its tarball: publishing a GitHub release starts
`.github/workflows/release.yml`, which builds, smoke-tests and attests the
release and attaches `baudrate-<version>-debian12-x86_64.tar.gz` to it. Wait
for that run to finish before deploying.

If `secret_key_base` is not in your SOPS secrets file, the playbook
auto-generates one and pauses so you can save it.

If `installation_key` is not defined, the playbook auto-generates a 32-character
random key and pauses so you can save it. This key is required to complete the
setup wizard at `/setup` after the first deploy — it prevents unauthorized users
from running the wizard. **The instance will refuse to serve any browser page
(503) until this key is set and setup is finished.** The key can be removed from
the env file once setup is complete.

Set `trusted_proxies` (a list of IPs or CIDR ranges) if nginx does not run on
the same host as the app; it is rendered into `BAUDRATE_TRUSTED_PROXIES`.
Without it the app believes `X-Forwarded-For` only from loopback, so all
requests would share one rate-limit bucket.

### What `deploy-baudrate.yml` Does

The `backup` role runs first, as root: it keeps the nightly backup timer and
the backup directories in place (see [Backups](#backups)). The `deploy` role's
tasks run as the `baudrate` system user by default (set at the role level).
Only systemd operations (service install, enable, reload, restart) escalate to
root.

| Phase | Description |
|-------|-------------|
| Pre-flight | Verify the `baudrate` user exists and the host runs Debian `debian_version` on x86_64; warn if deploying an older version |
| Fetch and verify (control machine) | Resolve the tag in this clone, download the release tarball with `gh release download`, and run `gh attestation verify`: it must have been signed by this repository's `release.yml`, on a GitHub-hosted runner, for `refs/tags/<tag>` at the commit the tag names here |
| Directories | Create `releases/`, `shared/uploads/`, `env/` |
| Install | Copy the verified tarball, check its SHA-256 on the server, unpack it into `releases/<timestamp>/`, check it is the tag's version, symlink shared uploads |
| Env file | Generate this server's Erlang cookie once (`env/release_cookie`), then template `baudrate.env` with `DATABASE_URL`, `SECRET_KEY_BASE`, `RELEASE_COOKIE`, `HEALTH_DETAIL_PORT` (`health_detail_port`, default 4001), `BAUDRATE_BACKUP_DIR`, and `LOG_FORMAT` when `log_format` is set |
| Systemd | Install and enable `baudrate.service` |
| Pre-deploy dump | Dump the database with the new release into `/var/backups/baudrate/predeploy/`, keeping `backup_keep_predeploy` (3); a failure stops the deploy |
| Migrate | Run `bin/migrate` from the new release |
| Activate | Atomic symlink swap: `current` → new release |
| Health check | Poll `/health` until 200 (up to 60 seconds) |
| Cleanup | Remove old releases, keep `keep_releases` most recent (default: 5) |

### Server Directory Layout

```
/opt/baudrate/
  releases/
    20260302_150000/                        # Timestamped release
      bin/server, bin/migrate, bin/baudrate
      lib/baudrate-1.0.0/priv/static/
        uploads -> /opt/baudrate/shared/uploads
  current -> releases/20260302_150000       # Symlink to active release
  static -> current/lib/baudrate-*/priv/static  # Stable path for nginx
  shared/
    uploads/                                # Persistent across deploys
      avatars/
      article_images/
  env/                                      # mode 0700
    baudrate.env                            # EnvironmentFile for systemd (mode 0600)
    release_cookie                          # This server's Erlang cookie (mode 0600)

/var/backups/baudrate/                      # baudrate:baudrate-backup, mode 2750
  daily/20260916T203000Z/                   # Nightly backup: db.dump, uploads/, MANIFEST.json
  predeploy/20260916T101500Z-v1.19.5.dump   # Dump taken before a deploy's migrations
```

### Backups

The `backup` role (ADR 0028, `doc/sysop.md` → Backup & Restore) installs
`baudrate-backup.timer`, which runs `Baudrate.Release.snapshot_backup/2` every
night at `backup_schedule` and keeps `backup_keep_daily` (7) complete backups.
The backup checks free space first and removes old backups only after a new
one succeeded. To change its settings or enable pull access
(`backup_pull_public_key`) without deploying, run only the role:

```bash
ansible-playbook playbooks/deploy-baudrate.yml --tags backup -e release_tag=<deployed tag>
```

### Rollback

`rollback-baudrate.yml` points `current` (and `static`) back at a release that
is still on the server, restarts the service and waits for `/health`. The
deploy keeps `keep_releases` (5) releases, each with its own Erlang runtime, so
nothing is downloaded or built:

```bash
# The release before the active one
ansible-playbook playbooks/rollback-baudrate.yml

# A particular kept release, by tag or directory name
ansible-playbook playbooks/rollback-baudrate.yml -e rollback_to=v1.24.0

# Only check: which release, and whether the schema allows it
ansible-playbook playbooks/rollback-baudrate.yml --check
```

It **refuses** when the database has migrations the target release does not
contain, and lists them. Rolling back code does not roll back the schema, and
the older code may fail against it or write data the newer schema expects in
another shape. Fix forward with a new release, or restore the pre-deploy dump
taken before those migrations and then roll back (`doc/sysop.md`, "Rolling
back a deploy"). `-e force=true` rolls back anyway, once you have checked the
older code works with the newer schema.

Re-deploying an older tag with `deploy-baudrate.yml` also works while its
release on GitHub carries a tarball (releases made after ADR 0036), but it runs that
release's migrations step and takes a pre-deploy dump; prefer the rollback
playbook for a release still on the server.

## Selective Execution

Run specific roles using tags:

```bash
# Only PostgreSQL
ansible-playbook playbooks/setup-server.yml --tags postgresql

# Only nginx (e.g., to update config)
ansible-playbook playbooks/setup-server.yml --tags nginx

# Multiple tags
ansible-playbook playbooks/setup-server.yml --tags "common,postgresql"
```

## Verification

```bash
# Syntax check (no server needed)
ansible-playbook playbooks/setup-server.yml --syntax-check
ansible-playbook playbooks/deploy-baudrate.yml --syntax-check
ansible-playbook playbooks/rollback-baudrate.yml --syntax-check

# Dry run (connects to server, shows what would change)
ansible-playbook playbooks/setup-server.yml --check --diff
ansible-playbook playbooks/deploy-baudrate.yml --check --diff
```

## Secrets Management

Secrets are managed with [SOPS](https://github.com/getsops/sops) and
encrypted with your OpenPGP key. No shared passphrase is needed — each
operator uses their own GPG private key.

SOPS encrypts only the **values** in YAML, not the keys. This means
`git diff` shows meaningful changes:

```yaml
# What git sees (keys readable, values encrypted)
postgres_db_password: ENC[AES256_GCM,data:abc123...,type:str]
```

The `community.sops.sops` vars plugin (enabled in `ansible.cfg`)
auto-decrypts `*.sops.yml` files in `group_vars/` and `host_vars/`
(files must be named after a group or host, e.g. `all.sops.yml`).

### Common SOPS Commands

```bash
# Edit secrets (decrypts → opens $EDITOR → re-encrypts on save)
sops inventory/group_vars/all.sops.yml

# Add a new operator's GPG key
# 1. Edit .sops.yaml to add their fingerprint
# 2. Re-encrypt with all keys:
sops updatekeys inventory/group_vars/all.sops.yml

# Rotate the data encryption key
sops --rotate --in-place inventory/group_vars/all.sops.yml
```

### Adding Team Members

1. Import their public GPG key: `gpg --import teammate.pub`
2. Add their fingerprint to `.sops.yaml` (comma-separated)
3. Run `sops updatekeys inventory/group_vars/all.sops.yml`

Now both operators can decrypt with their own private keys.

## Environment Variables

These can be set to skip interactive prompts:

| Variable | Purpose |
|----------|---------|
| `BAUDRATE_DOMAIN` | Default value for the domain prompt (both playbooks) |
| `BAUDRATE_CERTBOT_EMAIL` | Default value for the certbot email prompt (setup-server) |

## Directory Structure

```
ansible/
  .sops.yaml                               # SOPS config (GPG fingerprints)
  ansible.cfg                              # Ansible configuration
  README.md                                # This file
  inventory/
    hosts.yml                              # Server inventory
    group_vars/
      all.yml                              # Shared variables
      production.yml                       # Production overrides
      all.sops.yml.example             # Secrets template (copy → encrypt → all.sops.yml)
  playbooks/
    setup-server.yml                       # Server provisioning playbook
    deploy-baudrate.yml                    # Application deployment playbook
    rollback-baudrate.yml                  # Return to a release kept on the server
  roles/
    common/                                # System packages, firewall, SSH
    postgresql/                            # PostgreSQL 15 setup
    elixir/                                # asdf + Erlang/Elixir
    rust/                                  # rustup + Rust toolchain
    nginx/                                 # nginx + Let's Encrypt SSL
    deploy/                                # Verify, install, and activate a CI-built release
    rollback/                              # Point current back at a kept release
    backup/                                # Nightly backup timer, backup dirs, pull access
```
