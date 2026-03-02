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
| `elixir` | `elixir` | asdf + Erlang 28.3.1 + Elixir 1.19.5 + Hex/Rebar |
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
from running the wizard. The key can be removed from the env file after setup is
complete.

### What `deploy-baudrate.yml` Does

| Phase | Description |
|-------|-------------|
| Pre-flight | Verify `baudrate` user and asdf exist; warn if deploying an older version |
| Directories | Create `releases/`, `shared/uploads/`, `env/` |
| Source | Clone repo and checkout the prompted release tag |
| Build | `mix deps.get` → `mix compile` → `mix assets.deploy` → clean stale rel → `mix release` |
| Install | Copy release to `releases/<timestamp>/`, symlink shared uploads |
| Env file | Template `baudrate.env` with `DATABASE_URL`, `SECRET_KEY_BASE`, etc. |
| Systemd | Install and enable `baudrate.service` |
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
```
