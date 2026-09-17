# Baudrate — Ansible Playbooks

Ansible automation for provisioning Baudrate servers.

## Prerequisites

- **Ansible 2.14+** on the control machine
- **[SOPS](https://github.com/getsops/sops)** for secrets management
- **GPG key** for encrypting/decrypting secrets
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

| Role | Tag | Purpose |
|------|-----|---------|
| `common` | `common` | System packages, `baudrate` user, UFW firewall, SSH hardening, fail2ban, NTP |
| `postgresql` | `postgresql` | PostgreSQL 15, database + user, `pg_trgm` extension |
| `elixir` | `elixir` | asdf + Erlang 28.5.0.6 + Elixir 1.19.5 + Hex/Rebar |
| `rust` | `rust` | rustup with minimal profile (for Ammonia NIF) |
| `nginx` | `nginx` | nginx, Let's Encrypt SSL via certbot, reverse proxy config |

## Deploying Baudrate

After provisioning with `setup-server.yml`, deploy the application:

```bash
ansible-playbook playbooks/deploy-baudrate.yml
```

You will be prompted for:
- **Site domain** (or set `BAUDRATE_DOMAIN` env var)
- **Release tag** — a git tag like `v1.0.0` (required, no default)
- **Git repository** — defaults to the upstream repo; override for forks

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
| Pre-flight | Verify `baudrate` user and asdf exist; warn if deploying an older version |
| Directories | Create `releases/`, `shared/uploads/`, `env/` |
| Source | Clone repo and checkout the prompted release tag |
| Build | Wipe `_build/prod` if the tag's `.tool-versions` differs from the last build → `mix deps.get` → `mix compile` → `mix assets.deploy` → clean stale rel → `mix release` |
| Install | Copy release to `releases/<timestamp>/`, symlink shared uploads |
| Env file | Template `baudrate.env` with `DATABASE_URL`, `SECRET_KEY_BASE`, `HEALTH_DETAIL_PORT` (`health_detail_port`, default 4001), `BAUDRATE_BACKUP_DIR`, and `LOG_FORMAT` when `log_format` is set |
| Systemd | Install and enable `baudrate.service` |
| Pre-deploy dump | Dump the database with the new release into `/var/backups/baudrate/predeploy/`, keeping `backup_keep_predeploy` (3); a failure stops the deploy |
| Migrate | Run `bin/migrate` from the new release |
| Activate | Atomic symlink swap: `current` → new release |
| Health check | Poll `/health` until 200 (up to 60 seconds) |
| Cleanup | Remove old releases, keep `keep_releases` most recent (default: 5) |

### Server Directory Layout

```
/opt/baudrate/
  src/                                      # Git checkout (build workspace)
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
  env/
    baudrate.env                            # EnvironmentFile for systemd (mode 0600)

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

To roll back to a previous release, re-deploy with the older tag:

```bash
ansible-playbook playbooks/deploy-baudrate.yml -e release_tag=v1.0.0
```

The playbook will warn that the target version is older than the currently
deployed version and ask for confirmation before proceeding. Previous release
directories are kept on the server (up to `keep_releases`).

**Note:** Database migrations are **not** automatically rolled back. If the
newer version added migrations, you may need to handle rollback manually.

**Note:** Re-deploying rebuilds the older tag from source with the Erlang/Elixir
versions pinned in *that tag's* `.tool-versions`. If you have since uninstalled
that toolchain (e.g. Erlang 28.3.1, pinned up to v1.14.1), the build fails
until you reinstall it (`asdf install erlang <version>` as the `baudrate`
user). Each kept directory in `releases/` bundles its own ERTS, so for an
immediate rollback without rebuilding, repoint both symlinks at a kept release
and restart the service. nginx serves assets through `static`, which points
directly at a release rather than through `current`:

```bash
REL=/opt/baudrate/releases/<timestamp>
sudo -u baudrate ln -sfn "$REL" /opt/baudrate/current
sudo -u baudrate ln -sfn "$(readlink -f "$REL"/lib/baudrate-*/priv/static | tail -1)" /opt/baudrate/static
sudo systemctl restart baudrate
```

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
  roles/
    common/                                # System packages, firewall, SSH
    postgresql/                            # PostgreSQL 15 setup
    elixir/                                # asdf + Erlang/Elixir
    rust/                                  # rustup + Rust toolchain
    nginx/                                 # nginx + Let's Encrypt SSL
    deploy/                                # Build, release, and activate Baudrate
    backup/                                # Nightly backup timer, backup dirs, pull access
```
