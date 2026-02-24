# Baudrate — Project TODOs

Audit date: 2026-02-24

---

## Deployment & Infrastructure: Containerization

Containers: **app** (Phoenix OTP release), **db** (PostgreSQL), **nginx** (reverse proxy), **redis** (future caching)

### Files to Create

- [ ] **`Containerfile`** — Multi-stage build (build: Elixir + Rust + libvips-dev on Debian bookworm; runtime: Debian bookworm-slim with libvips42). Symlink `/app/lib/baudrate-0.1.0/priv/static/uploads` → `/data/uploads` for persistent volume. Entrypoint: `/app/bin/server`. Expose 4000.
- [ ] **`compose.yml`** — 4 services: `db` (postgres:17-alpine, healthcheck pg_isready), `redis` (redis:7-alpine, healthcheck redis-cli ping), `app` (built from Containerfile, depends_on db+redis healthy, env_file .env, uploads volume at /data/uploads, expose 4000), `nginx` (nginx:1-alpine, ports 80+443, mounts nginx.conf + certs). Named volumes: db_data, redis_data, uploads.
- [ ] **`container/nginx.conf`** — HTTP→HTTPS redirect; HTTPS proxy to `http://app:4000`; headers: X-Forwarded-For (SET, not append), X-Forwarded-Proto https, X-Real-IP, Host; WebSocket upgrade for `/live` (LiveView); SSL cert/key from `/etc/nginx/certs/` (user-provided); client_max_body_size 20M; gzip on.
- [ ] **`.env.example`** — DATABASE_URL, SECRET_KEY_BASE, PHX_HOST, PORT, POOL_SIZE, DATABASE_SSL, POSTGRES_USER/PASSWORD/DB.
- [ ] **`container/certs/.gitkeep`** — Placeholder for user-provided SSL certs (server.crt, server.key).

### Files to Update

- [ ] **`doc/sysop.md`** — Add "Container Deployment" section: build (`podman compose build`), start (`podman compose up -d`), migrations (`podman compose exec app bin/migrate`), self-signed cert generation for dev, logs, notes on real TLS certs.
- [ ] **`.gitignore`** — Add `.env`, `container/certs/*.crt`, `container/certs/*.key`.

### Design Decisions

- **Nginx proxies everything to Phoenix** (no shared static volume) — simpler, sufficient for most traffic
- **User-provided SSL certs** — mount into `container/certs/`, document self-signed generation for dev
- **Redis not wired into app code** — service available for future caching, no app changes needed
- **No upload path refactor** — symlink in Containerfile bridges priv/static/uploads → /data/uploads
- **No CI/CD** — separate task
- **No Certbot/ACME** — users add their own cert management later

### Verification

```bash
podman compose build app
podman compose up -d
podman compose ps                          # all 4 running
podman compose exec app bin/migrate        # run migrations
curl -k https://localhost/                 # verify response
podman compose logs app                    # check logs
mix test                                   # full suite still passes
```

## Planned Features

### Board-Level Remote Follows (Moderator-Managed)

Allow moderators to follow remote Fediverse actors on behalf of boards, pulling
their content into the board. Requires anti-loop and deduplication safeguards.

#### Anti-Loop / Anti-Duplication Rules

1. **Never re-announce an Announce** — content arriving via `Announce` is stored
   and linked to the board but does NOT trigger an outbound `Announce`. Only
   content arriving via `Create` (directly authored) gets announced to followers.
2. **Cross-board announce dedup** — before a board announces an article, check if
   any local board has already announced the same `ap_id`. First board wins.
3. **Origin/addressing check** — only announce articles where the board's actor
   URI appears in the activity's `to` or `cc` (intentionally addressed, not relayed).
4. **Outbound announce rate limit** — cap Announces per board per time window
   (e.g., 30/hour) to prevent flood from a prolific followed actor.

#### Implementation Notes

- Rules 1 + 2 are the minimum viable safeguards
- Rules 3 + 4 are defense-in-depth
- Need a new `board_follows` table (board_id, remote_actor_id, followed_by_id)
- Need UI in board moderator panel to manage follows
- Need to handle `Undo(Follow)` on unfollow

## Someday / Maybe

- [ ] Two-way visibility blocking (blocked users can still see public content)
- [ ] Per-user rate limits on authenticated endpoints (currently IP-only)
- [ ] Authorized fetch mode test coverage (signed GET fallback)
