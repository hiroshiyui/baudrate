# Troubleshooting Guide

Common issues and solutions for operators deploying and running Baudrate.
See the [SysOp Guide](sysop.md) for the comprehensive operational reference.

---

## Table of Contents

- [Setup & First Run](#setup--first-run)
- [Environment Variables](#environment-variables)
- [Database](#database)
- [Assets, Static Files & Build Dependencies](#assets-static-files--build-dependencies)
- [Reverse Proxy](#reverse-proxy)
- [Federation](#federation)
- [Syndication bots](#syndication-bots)
- [Authentication & Sessions](#authentication--sessions)
- [Rate Limiting](#rate-limiting)
- [A second node](#a-second-node)
- [Detailed health report](#detailed-health-report)
- [Deploys, releases and rollback](#deploys-releases-and-rollback)

---

## Setup & First Run

> **See the [SysOp Guide](sysop.md#installation) for the full installation
> and first-run setup guide.**

### Development setup

```bash
mix setup       # Install deps, create DB, run migrations, build assets
mix phx.server  # Start dev server at https://localhost:4001
```

The dev server uses HTTPS with a self-signed certificate. Generate one with:

```bash
mix phx.gen.cert
```

This creates `priv/cert/selfsigned_key.pem` and `priv/cert/selfsigned.pem`.
Your browser will show a security warning — this is expected for development.

### First-run wizard interrupted

If the setup wizard is interrupted partway through (e.g., roles seeded but no
admin account created), you can reset and re-run:

```bash
mix ecto.reset  # Drops, recreates, and re-migrates the database
```

### PostgreSQL `pg_trgm` extension missing

See [Database](#database) section below for resolution.

---

## Environment Variables

> **See the [SysOp Guide](sysop.md#environment-variables) for the complete
> reference of all environment variables and their defaults.**

### The keys that protect stored secrets

TOTP secrets, recovery-code hashes, actor private keys and the Web Push key
are encrypted or hashed with a key — `BAUDRATE_AUTH_KEYS` and
`BAUDRATE_SIGNING_KEYS`, or, until you set those, one derived from
`SECRET_KEY_BASE` (ADR 0038).

Until they are separated, **`SECRET_KEY_BASE` cannot be changed**: doing so
locks every member out of 2FA *and* out of their recovery codes, and makes
every actor identity and the push key unreadable. The boot log says whether
they are separated, and so does the detailed health report:

```bash
curl -s http://127.0.0.1:4001/health | jq .checks.encryption_keys
```

The [SysOp Guide](sysop.md#rotating-an-encryption-key) has the procedure for
separating and rotating them. Two rules matter most:

- **Never remove a key while stored values still reference it.** The census
  (`bin/baudrate rpc "Baudrate.Release.key_census()"`) says what is left, and
  the health report fails when something needs a key that is gone.
- **Recovery codes cannot be re-encrypted.** They move to a new key only when
  a member generates new codes, so the key that hashed them stays configured
  until then — they are also how a member without their authenticator gets
  back in.

After the keys are separated and nothing is left under `legacy`, changing
`SECRET_KEY_BASE` costs only in-flight things: sessions end, open pages
reconnect, and rendered image URLs re-sign.

#### The app refuses to start after setting the keys

`BAUDRATE_AUTH_KEYS` and `BAUDRATE_SIGNING_KEYS` are validated at boot in
production, and a bad value raises rather than starting with keys that would
write secrets nobody can read back. The message names the variable and the
position of the offending entry, never the key itself:

| Message | Cause |
|---------|-------|
| `the id "legacy" is reserved for the SECRET_KEY_BASE fallback` | `legacy` labels the values still protected by `SECRET_KEY_BASE`. A configured key of that name would be written with one key and read with another, and neither `key_census` nor the `encryption_keys` health check could see it |
| ``expected `id:key` `` | An entry has no colon. The format is `id:key`, current key first |
| `bad id: expected 1-16 of [A-Za-z0-9_-]` | Usually the `id:key` order reversed — the id is everything before the first colon |
| `the key for id … is not Base64` / `decodes to N bytes, not 32` | Each key is 32 random bytes in Base64: `openssl rand -base64 32` |
| `lists the same id twice` | An id labels one key in stored values, so each must appear once |

Pick any other id for a new key (`k1`, or a date such as `202609`). The id is
written into every value encrypted under it, so it cannot change afterwards.

---

## Database

### Development credentials

The default dev database config (`config/dev.exs`):

| Setting | Value |
|---------|-------|
| Username | `baudrate_db_user` |
| Password | `baudrate_database` |
| Database | `baudrate_dev` |
| Hostname | `localhost` |

### DATABASE_SSL defaults to true

In production (`config/runtime.exs`), `DATABASE_SSL` defaults to `"true"`.
If your database doesn't support SSL (common with local PostgreSQL), set:

```bash
export DATABASE_SSL=false
```

### Connection pool exhaustion

If you see `DBConnection.ConnectionError` or timeout errors under load,
increase the pool size:

```bash
export POOL_SIZE=20
```

The test configuration automatically scales the pool to
`System.schedulers_online() * 2`.

### pg_trgm extension missing

If migrations fail with:

```
ERROR: type "gtrgm" does not exist
```

Install the `pg_trgm` extension (requires superuser or the
`postgresql-contrib` package):

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
```

### Resetting the database

For development, reset the entire database:

```bash
mix ecto.reset  # drop + create + migrate
```

---

## Assets, Static Files & Build Dependencies

### Production asset build

Before deploying to production, compile and digest assets:

```bash
mix assets.deploy
```

This runs Tailwind (minified) + esbuild (minified) + `phx.digest` to
generate fingerprinted files and `priv/static/cache_manifest.json`.

**Symptom of missing asset build:** Pages load without CSS styling, or
JavaScript doesn't execute.

### Rust toolchain requirement

HTML sanitization uses a Rust NIF (Ammonia via Rustler). A stable Rust
toolchain must be installed before `mix compile` can succeed:

```bash
# Install via rustup (https://rustup.rs)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Verify
rustc --version
cargo --version
```

The NIF is compiled automatically by `mix compile`. First compilation
downloads Rust crate dependencies (~30s); subsequent builds are incremental.

**Symptom of missing Rust:** Compilation fails with
`Compiling crate baudrate_sanitizer ... error: no such command: 'rustc'`
or similar cargo/rustc not found errors.

### libvips requirement

Avatar and article image processing requires `libvips`. Install it:

```bash
# Debian/Ubuntu
sudo apt install libvips-dev

# macOS
brew install vips

# Alpine
apk add vips-dev
```

**Symptom of missing libvips:** Avatar uploads or article image uploads fail
with NIF-related errors.

### Uploads directory

User-uploaded files (avatars, article images) are stored in
`priv/static/uploads/`. This directory must be:

1. **Writable** by the application process
2. **Persistent** across deployments (not wiped on redeploy)

For containerized deployments, mount a persistent volume at
`priv/static/uploads/`.

---

## Reverse Proxy

### X-Forwarded-For header

Baudrate's `RealIp` plug extracts the client IP from the `X-Forwarded-For`
header (configurable in `config/prod.exs`). Your reverse proxy **must set**
(not append to) this header:

```nginx
# Nginx — correct
proxy_set_header X-Forwarded-For $remote_addr;

# Nginx — WRONG (appends, allowing IP spoofing)
# proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
```

**Symptom of incorrect configuration:** Rate limiting doesn't work (all
requests appear from the proxy IP), or attackers can bypass rate limits by
spoofing the header.

**Symptom: all users still share one rate-limit bucket after setting the
header.** The plug is fail closed — it believes `X-Forwarded-For` only from a
peer in the `trusted_proxies` allow-list, which defaults to loopback. If the
proxy runs on a different host, name it:

```bash
BAUDRATE_TRUSTED_PROXIES="10.0.0.0/8"
```

An invalid entry raises at boot with the offending value in the message.

### X-Forwarded-Proto header

Required for HTTPS detection behind a reverse proxy. Baudrate's `force_ssl`
config rewrites based on this header:

```nginx
proxy_set_header X-Forwarded-Proto $scheme;
```

**Symptom of missing header:** Infinite redirect loops between HTTP and HTTPS.

### WebSocket passthrough

Phoenix LiveView requires WebSocket connections. Configure your proxy to pass
through WebSocket upgrades:

```nginx
location / {
    proxy_pass http://127.0.0.1:4000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

**Symptom of blocked WebSockets:** Pages load initially but don't update
in real-time; forms may not submit properly; "connection lost" banners appear.

### HSTS

Production config enables HSTS with a 2-year expiry, subdomain inclusion, and
preload compatibility:

```elixir
force_ssl: [hsts: true, subdomains: true, preload: true, expires: 63_072_000]
```

Once HSTS is active, browsers will refuse to connect over HTTP for the
configured duration. Make sure HTTPS is fully working before enabling HSTS
preloading.

### `/robots.txt` answers 404, or the site will not install as an app

Both symptoms come from the same cause: a proxy serving from disk a path the
application generates.

**`/robots.txt` 404s** — with an nginx page rather than Baudrate's. It has been
a **route** since v1.33.0, not a file in `priv/static`, because its `Sitemap:`
directive needs an absolute URL that only the application knows. A rule like

```nginx
location ~ ^/(fonts|images|favicon[^/]*\.(ico|svg)|robots[^/]*\.txt|…) {
    root /path/to/baudrate/priv/static;
}
```

still matches it, finds no file, and answers before the router is consulted —
so the instance advertises no sitemap and no `Disallow` for `/ap/`, `/api/` or
`/exports/` at all, and nothing in the application can tell. **Remove
`robots[^/]*\.txt` from that rule.** Anything the application generates
belongs in `location /`; a proxy may serve from disk only what
`BaudrateWeb.static_paths/0` lists.

**The install prompt never appears** — check the manifest's content type:

```bash
curl -s -o /dev/null -w '%{content_type}\n' https://your.host/site.webmanifest
# want: application/manifest+json     not: application/octet-stream
```

Debian's `/etc/nginx/mime.types` has no `webmanifest` entry, so nginx falls
back to `default_type`. Give it a `location` of its own with
`default_type application/manifest+json` — **not** a `types { … }` block
inside the shared static rule, which *replaces* the inherited map for that
whole location and would turn every font, image and favicon beside it into
`application/octet-stream`.

`doc/examples/nginx.conf.example` and the Ansible template both have the
correct form; `test/ops/nginx_static_paths_test.exs` keeps them in step.

### The browser keeps showing an old version of the site

A service worker is registered on every page since v1.34.0
([ADR 0059](adr/0059-the-service-worker-caches-the-shell-and-never-content.md)).
It caches the offline page and the fingerprinted files under `/assets/` and
nothing else, so it cannot serve stale *content* — but a worker from an older
release can persist, because a browser only checks for a new one on
navigation.

In DevTools → Application → Service Workers, "Update on reload" plus a hard
reload replaces it. For a reader who cannot do that, the worker calls
`skipWaiting()` and `clients.claim()`, so the next navigation after the new
one downloads takes over without every tab being closed.

**If you see a new worker at a new URL after each deploy**, something has
changed `app.js` to register `~p"/service_worker.js"` instead of the bare
string. That resolves to the digest-stamped filename, so each release installs
a *separate* worker and the old ones never go away. Registration must stay a
literal path.

---

## Federation

### Clock synchronization (NTP)

HTTP Signatures include a `Date` header validated within **+/-300 seconds** (5 minutes).
If your server's clock is off, all incoming federation requests will be
rejected with signature verification failures.

**Fix:** Ensure NTP is configured and running:

```bash
timedatectl status        # Check current time sync
sudo systemctl enable ntp # Enable NTP
```

### Remote instance rejected with `public_key_too_weak`

Baudrate requires inbound actor public keys to be RSA of at least **2048 bits**
— the size Mastodon and Baudrate itself generate. A remote instance still using
a 1024-bit (or smaller) key cannot federate: a short modulus makes its
signatures forgeable by a third party, who could then impersonate that actor to
this instance.

The check runs both when caching an actor and when verifying a signature, so
actors cached before this rule existed are rejected too.

**Fix:** the remote operator must rotate to a 2048-bit key. There is no
configuration to lower the threshold.

### HTTPS-only enforcement

All federation actor URIs must be HTTPS. Baudrate will not:

- Fetch remote actors over HTTP
- Accept HTTP actor URIs in incoming activities
- Deliver to HTTP inbox URLs

**Exception:** plain HTTP to `localhost` or `127.0.0.1` is allowed in dev/test
only (`allow_http_localhost`). `::1` is **not** — use `127.0.0.1`.

### PHX_HOST must match your public hostname

`PHX_HOST` is used to generate all actor URIs, WebFinger responses, and
outgoing activity URLs. If it doesn't match your actual public hostname:

- WebFinger lookups will fail
- Remote instances can't resolve your actors
- HTTP Signature verification may fail (host header mismatch)

### Delivery queue

Delivery jobs are written in the same transaction as the post, like or follow
that causes them, and the `DeliveryWorker` is woken when it commits (see
[ADR 0034](adr/0034-federation-work-is-committed-before-it-is-acknowledged.md)
and the sysop guide's Delivery Queue section). The 60-second poll only picks up
retries and anything missed.

**Retry schedule for failed deliveries:**

| Failed attempt | Next try |
|----------------|----------|
| 1 | after 60 seconds |
| 2 | after 5 minutes |
| 3 | after 30 minutes |
| 4 | after 2 hours |
| 5 | after 12 hours |
| 6 | abandoned |

A final `4xx` response other than `401`, `408` and `429` abandons a job at
once. You can retry abandoned jobs from the admin federation dashboard
(`/admin/federation`).

**Symptom of stuck delivery:** Check the federation dashboard for jobs in
`failed` or `pending` state. Common causes:

- Remote instance is down (will retry automatically). After 5 unreachable
  results in a row its circuit opens and its jobs wait together, with one probe
  per interval; look for `federation.delivery_circuit_open` in the log and
  `SELECT * FROM delivery_circuits WHERE trips > 0;`. Jobs held for 7 days are
  abandoned.
- Deliveries only go out once a minute — the worker is not receiving
  notifications. Baudrate must connect to PostgreSQL directly, not through a
  pooler in transaction mode, which cannot carry `LISTEN`.
- Jobs with `last_error: ":timeout"` — the remote server did not answer within
  the request deadline; the attempt counts like any other failure.
- Clock skew causing signature rejection (fix NTP)
- Domain is blocked by the remote instance
- DNS resolution failure
- Board follow 422 errors — check delivery job `last_error` for the response body (includes remote server's rejection reason since v1.1.17)
- Jobs with `last_error: ":unknown_actor"` — the local user or board referenced by `actor_uri` was deleted after the job was queued. Since v1.5.9 these jobs are marked `failed` (and eventually `abandoned` via the normal retry schedule) rather than causing Task crashes that left the job stuck in `pending` forever.
- Jobs that previously crash-looped with a `CaseClauseError` from `Delivery.do_deliver/1` — caused by a local actor that existed but had no RSA keypair (e.g. a new user whose user-signed Like was delivered to a *board's* remote followers before their own actor was ever fetched). `Delivery.get_private_key/1` now self-heals: it lazily generates the keypair at signing time and normalizes the missing-key case to `{:error, :no_private_key}`, so such jobs deliver on the next worker pass instead of crashing.

### Inbound activities not taking effect

The inbox answers `202` once an activity is stored; the work happens afterwards
in `InboundWorker`. A remote follow, reply or like that does not show up has
left a row behind:

```sql
SELECT id, activity_type, status, attempts, last_error, inserted_at
FROM inbound_activities
ORDER BY id DESC LIMIT 20;
```

- `pending` for long — the worker is busy or stopped. Processing is 4 at a time
  and one per remote account, so one account's backlog does not delay others.
  With federation switched off, nothing is processed.
- `rejected` — the handler refused it; `last_error` gives the reason, such as
  `:not_found` (the local account or board does not exist), `:domain_blocked`
  (the domain was blocked after the activity arrived) or `:actor_suspended`
  (that one account was suspended instance-wide). The admission checks run
  again at processing time, which is why a decision taken after the 202 still
  takes effect.
- `failed` — processing crashed or ran past 5 minutes three times; the log has
  `federation.inbound_crashed` or `federation.inbound_timeout` with the id.

An activity refused at the door is answered `422` and never stored: the log
line is `federation.inbox_error` with the reason (for example `:actor_mismatch`).

### Replies from this instance arrive flat on Mastodon

A comment's `inReplyTo` names the comment it answers, and a remote instance
can only follow that if the id resolves. Until v1.31.0 a comment's id was
`https://your.host/ap/users/alice#note-42` — a URI *fragment*, which is never
sent to the server, so dereferencing it returned the author's profile.

**Fix:** run the backfill once after upgrading to v1.31.0:

```bash
cd /opt/baudrate   # not /root — see "`remote`, `rpc` or `eval` dies with a
                   # `persistent_term` error" below
set -a; . /opt/baudrate/env/baudrate.env; set +a
current/bin/baudrate eval "Baudrate.Release.backfill_ap_ids(dry_run: true)"
current/bin/baudrate eval "Baudrate.Release.backfill_ap_ids()"
```

See [`doc/sysop.md`](sysop.md), "Data Repair: `ap_id` Backfill". Comments
written *before* the rewrite keep answering to their old id as well, so
nothing already federated breaks; comments written after it thread correctly
whether or not the task has run.

### A `@user@domain` mention does not reach the person

Three ordinary reasons, in the order worth checking:

1. **The board does not federate.** A mention is a surface of the outbound
   gate, not an exception to it (ADR 0051): an article whose boards are all
   private or AP-disabled produces no `Mention` tag, no `cc`, no delivery —
   and does not even look the handle up. This is deliberate, and it is what
   stops a member sending a staff-only post anywhere by typing a handle.
2. **The handle did not resolve.** An unknown handle is looked up once, when
   the post is written, with a 3-second deadline and a 5-second budget for the
   whole step. A slow or unreachable server means the mention stays plain
   text, silently. `grep federation.mention_unresolved` in the log.
3. **The member is out of lookups.** 30 per hour per account, for handles
   nobody here has seen before. `grep federation.mention_resolve_throttled`.

A handle that has resolved once is cached in `remote_actors` and costs
nothing afterwards.

### Posts in a followed Lemmy community never appear

The board follows the community, the activities arrive, and nothing shows up.
Before v1.31.0 this was expected: a Lemmy community relays its members'
activities (`Announce` wrapping a `Create`), and only `Announce` wrapping an
*object* was understood, so every post was discarded (ADR 0053).

After v1.31.0, check in this order:

- the board follow is **accepted**, not pending (`/admin/federation`);
- the board is AP-enabled and guest-readable — the same gate as everything
  else;
- `grep federation.group_announce_refused` for a rejected relay, and
  `federation.group_announce_cross_origin_dropped` for one this instance
  deliberately would not honour.

The last is not a fault. A community may speak for actors **on its own host**;
a `Delete` or `Like` it relays on behalf of some third instance's user is
dropped, because the signature on the Announce proves only the community's own
host. A `Create` is unaffected — its object is verified through its own origin.

### Federation kill switch

Setting `ap_federation_enabled` to `false` (via `/admin/settings` or
`/admin/federation`) disables all federation:

- All `/ap/*` endpoints return 404
- Delivery worker skips all pending jobs
- WebFinger and NodeInfo remain available for discovery

### Allowlist mode

When `ap_federation_mode` is set to `"allowlist"`:

- **Only** domains in `ap_domain_allowlist` are accepted
- An **empty allowlist blocks all domains** (safe default)
- Both inbound (inbox) and outbound (delivery) are filtered

### Domain blocklist

Domains with a row in `domain_blocks` (managed at `/admin/federation`) are:

- Rejected at inbox (incoming activities return 202 but are silently dropped)
- Skipped during delivery (jobs marked as abandoned with reason `"domain_blocked"`)
- Not fetched **from**: actor and object resolution refuse with `:domain_blocked`,
  the reply-chain walk will not follow an `inReplyTo` into the domain
  (`federation.reply_chain_domain_blocked`), and the media proxy serves
  `/images/media-unavailable.svg` instead of its images
- Hidden from listings at query time — nothing is deleted and nothing is stamped
  on a row, so unblocking restores the content by itself
  ([ADR 0030](adr/0030-domain-blocks-are-rows-and-hiding-is-reversible.md))
- Domain comparison is case-insensitive

A single account can be suspended instead of its whole domain, from
`/admin/federation/instances/:domain`. It is the same predicate, so it hides and
refuses the same way. Staff pages deliberately keep showing hidden content:
moderators cannot judge what they cannot see.

---

## Syndication bots

### The feeds stopped

A bot that fails backs off **exponentially, up to a day**:
`min(5 × 2^(errors−1), 1440)` minutes, so the fifth consecutive failure pushes
the next attempt out by 80 minutes and the tenth by the full 24 hours (the
ninth is already 21 h 20 m)
(`Bots.mark_fetch_error/2`). A bot that has been failing for a while therefore
looks idle rather than broken — check `error_count` and `last_error` on
`/admin/bots` before assuming the worker is stuck.

Two things reset it: fixing the feed and waiting for the next attempt, or the
reset control on `/admin/bots`, which clears the counter and makes the bot due
immediately.

What to grep:

```bash
journalctl -u baudrate --since "1 hour ago" | grep bots.syndication_feed_worker
```

That prefix changed in v1.28.0 — it was `bots.feed_worker` before
[ADR 0041](adr/0041-rss-and-atom-are-syndication.md) renamed the RSS
vocabulary to "syndication". The worker's heartbeat key in the health report
changed with it, to `syndication_feed_worker`.

### A bot's avatar never appears

Favicon fetching gives up after **three** failures
(`Bots.avatar_needs_refresh?/1` returns `false` once `favicon_fail_count >= 3`)
and otherwise refreshes weekly. A site that blocks the fetch, or serves no
favicon, will leave the bot on its default avatar permanently. There is no
manual upload: the bot's account has a locked password, so nobody can sign in
as it, and neither `/admin/bots` nor `/admin/users/:id` offers a file field.
**Refresh Favicon** on `/admin/bots` re-tries the fetch, bypassing the
three-failure pause and resetting the counter on success.

### An entry was posted twice, or not at all

Deduplication is the `(bot_id, guid)` ledger in `bot_syndication_items`. A
publisher that changes an entry's `<guid>` gets a second post — that is the
feed's doing, not a bug here, and `Bots.already_posted?/3` also checks the URL
to catch the common case. **Never delete rows from that table**: a deleted row
is an entry the bot will publish again, and retention deliberately never
touches it
([ADR 0040](adr/0040-retention-deletes-what-nobody-touched.md)).

---

## Authentication & Sessions

### Session configuration

| Setting | Value |
|---------|-------|
| Cookie name | `_baudrate_key` |
| Cookie lifetime | 14 days |
| Same-site policy | `Lax` |
| Encryption | Signed + encrypted (separate salts) |
| Token rotation | Every 24 hours (via `RefreshSession` plug) |
| Max concurrent sessions | 3 per user (oldest evicted) |

### A member says the site is in the wrong language

The likely cause is that it is in the language they *chose*, once, and forgot.

`BaudrateWeb.Plugs.SetLocale` answers in this order: the `locale` cookie, then
the member's `preferred_locales` as cached in the session at login, then
`Accept-Language`, then `en`. The cookie is an explicit choice made in the
footer switcher, it lasts a year, and it deliberately outranks everything —
including a browser whose `Accept-Language` says something else, which is what
makes this look like a bug rather than a preference.

Ask them to press **Match my browser** at the foot of any page. That deletes
the cookie and hands the decision back to their account and then their browser.
It is the only thing that clears it; signing out does not, because the choice
is not kept in the session.

Two related cases:

- **A member changed their language on `/profile` and one page is still
  wrong.** The session copy of `preferred_locales` is written at login, and a
  LiveView cannot write the session, so `/profile` posts to `LocaleController`
  to refresh it. If that POST were blocked — a proxy stripping `Referer` will
  not do it, but a CSRF failure would — the first paint of every later page
  would keep the old language while the connected render corrected itself. Look
  for `POST /locale` in the access log.
- **Everyone is getting English.** Check that the catalogues shipped:
  `ls priv/gettext/*/LC_MESSAGES/*.po` inside the release. An empty `msgstr`
  renders the English source rather than failing, which is why the gap is
  silent; `test/baudrate_web/translation_coverage_test.exs` is what stops one
  reaching a release.

### Session cleanup

The `SessionCleaner` GenServer runs every hour and carries seventeen steps —
expired sessions, old login attempts, orphan images, delivery and inbox queue
hygiene, link previews, the media cache, the data-export and account-move
sweeps, old notifications, ended-sanction notices, closed-report evidence, the
retention purges below, and the health-alert check (ADR 0044), which is the
only one that keeps state between runs and so sits outside the uniform list. `doc/sysop.md` has the full table. Each step is
isolated, so one failing step no longer skips the rest of the hour.

### Content disappeared from the database

Expected, if it was deleted more than 90 days ago. `Baudrate.Retention`
([ADR 0040](adr/0040-retention-deletes-what-nobody-touched.md)) hard-deletes:

| What | When |
|------|------|
| Articles and comments with `deleted_at` set | 90 days after deletion, with their revisions, images and the image files |
| Timeline items nobody liked, boosted or replied to | 90 days after they arrived |
| `announces` | 180 days |

**Nothing a report points at is deleted, at any age** — so "why is *this* one
still here?" is usually a report referencing it.

A boost count that fell on old remote content is the `announces` purge:
`Federation.count_announces/1` reads that table, and the ADR records the
trade-off as accepted.

To see what a run would remove without removing it, and to check whether one
ran:

```bash
# brpc is the wrapper from the SysOp Guide, "Rotating an encryption key"; it
# sources the environment file so `rpc` has the server's RELEASE_COOKIE.
brpc() { sudo -u baudrate sh -c "cd /opt/baudrate && set -a; . /opt/baudrate/env/baudrate.env; set +a; exec /opt/baudrate/current/bin/baudrate rpc \"$1\""; }
brpc "Baudrate.Retention.run(dry_run: true)"
journalctl -u baudrate | grep retention:
```

It logs one line per run and **nothing when every count is zero**, so silence
means there was nothing to remove.

**A purge is not an erasure request.** The rows remain in backups until those
rotate out ([ADR 0028](adr/0028-backups-are-complete-folders-with-count-based-retention.md)).

### TOTP issues

If users report "invalid TOTP code" errors with correct codes:

1. **Code already used** — each code works once per account (ADR 0024). A
   user who signs in on a second device, or confirms two actions, within the
   same 30 seconds must wait for the next code
2. **Clock skew** — TOTP is time-based. A code is accepted for its own
   30-second period and the one after it, but never before its period starts,
   so a device clock running ahead fails first. Ensure both server and user's
   device have accurate time (NTP on server, auto time on device)
3. **The key changed, or was dropped** — TOTP secrets are encrypted with the
   `BAUDRATE_AUTH_KEYS` key, or one derived from `SECRET_KEY_BASE` while that
   is unset. If a key was removed while stored secrets still needed it, those
   secrets are unreadable: `jq .checks.encryption_keys` on the detailed health
   report names the missing id, and putting that key back fixes it. If the key
   is genuinely gone, members use recovery codes (only while the key that
   hashed *those* is still configured) and re-enrol.

### Login throttling

Failed logins trigger progressive delays per account:

| Failures (1-hour window) | Delay |
|--------------------------|-------|
| 0-4 | None |
| 5-9 | 5 seconds |
| 10-14 | 30 seconds |
| 15+ | 120 seconds |

Failed TOTP codes at login and failed re-authentication from a signed-in
session count as failures too; `/admin/login-attempts` shows which check each
attempt was for.

This is **not** a hard lockout — it's a delay. The account is never fully
locked out to prevent DoS via deliberate failed logins.

Admins can view login attempts at `/admin/login-attempts`.

### A member cannot get back into their account

Work down this list. **There is no email in this system**, so every step
before the last is something the member has to have arranged in advance.

1. **They know the password but not the TOTP code.** They sign in with a
   recovery code at `/totp/recovery`.
2. **They forgot the password but still have a recovery code.** They reset it
   at `/password-reset` with their username, one code and a new password. Each
   code works once. This signs out every session and cancels any pending data
   export or account move.
3. **They are signed in somewhere and are simply low on codes.** `/profile`
   shows how many are unused and issues a fresh set behind step-up
   re-authentication. The old ones stop working immediately.
4. **Password and codes are both gone.** This is the admin-assisted path, and
   it works only if they registered a recovery contact *before* losing access:
   an email address and an OpenPGP public key, verified by an admin. The
   procedure is [SysOp Guide → Account
   Recovery](sysop.md#account-recovery-when-the-codes-are-gone-too), and every
   cryptographic check in it happens in the admin's own mail client.
5. **They registered no recovery contact.** There is nothing to do, and saying
   so plainly is the correct answer. The account is not recoverable; they can
   register a new one. Members in this state see a dismissible notice on every
   page telling them so *before* it matters — that notice is the whole reason
   it exists.

Two things that look like this problem and are not:

- **`/admin/users/:id` shows no recovery section.** You are signed in as a
  moderator. Recovery contacts are admin-only: they are personal data and they
  are the anchor a reset rests on.
- **"Issue reset link" is missing next to a verified contact.** The target's
  role is at or above your own, which the instance refuses (ADR 0029's rule
  applied to recovery). Recovering staff needs the server console —
  [SysOp Guide §7](sysop.md#7-when-you-are-the-one-locked-out).

### An admin-issued reset link does not work

Every failure renders the same message on purpose, so the page cannot be used
to find out whether a link ever existed. Check `/admin/users/:id`, which now
says which of these it was:

| What it says | What happened |
|---|---|
| *…is outstanding until…* | still good; the member has not used it |
| *…was used on…* | redeemed already. Links work exactly once |
| *…was revoked and never used* | an admin called it back |
| *…expired unused on…* | 24 hours passed |

A redemption that failed on a weak password **also spends the link** — the
token is claimed before the password is validated, or a single-use link would
become a password-guessing oracle. Issue a fresh one rather than hunting for
the old.

---

## Rate Limiting

### Configuration

Rate limiting uses [Hammer](https://hexdocs.pm/hammer/) with an ETS backend:

| Endpoint | Limit | Window |
|----------|-------|--------|
| Login | 10 attempts | 5 minutes per IP |
| TOTP verification | 15 attempts | 5 minutes per IP |
| Registration | 5 attempts | 1 hour per IP |
| Password reset | 5 attempts | 1 hour per IP |
| Avatar upload | 5 changes | 1 hour per user |
| AP endpoints | 120 requests | 1 minute per IP |
| AP inbox | 60 requests | 1 minute per remote domain |
| Direct messages | 20 messages | 1 minute per user |

### Fails open

If the ETS rate-limit backend encounters an error (e.g., table doesn't exist),
requests are **allowed through** rather than blocked. This prevents an
infrastructure failure from causing a denial of service.

### Counters reset on restart

The Hammer ETS backend keeps its counters in the node's memory, so a restart
starts every limit from zero. That is expected. The counters are complete
because Baudrate runs on one node; see [A second node](#a-second-node).

### RealIp plug required in production

Without the `RealIp` plug correctly configured, all requests appear to come
from the reverse proxy's IP address. This means:

- A single IP-based rate-limit bucket for all users
- Rate limits trigger for everyone after a few requests

See [Reverse Proxy](#reverse-proxy) for configuration.

---

## A second node

Baudrate supports exactly one node per database
([ADR 0033](adr/0033-baudrate-runs-on-one-node.md)). Its caches, security-key
challenges, download tokens and rate limits are kept in memory, and its
background workers assume nothing else is doing their job.

### Symptoms

A second node running against the same database (a forgotten
`bin/baudrate start`, or a copy of the release started on another host)
shows up as:

- remote instances receiving the same activity twice;
- a domain block, or a change on `/admin/settings`, that works on some
  requests and not others;
- security-key sign-in or admin re-verification failing intermittently;
- a data export download answering "not found" although it was just offered.

### Checking

`bin/baudrate eval` and the backup service are not second nodes: they load the
application without starting it. On the host, look for more than one running
node:

```bash
pgrep -af 'beam.smp.*baudrate'
```

A backup or another `eval` task shows up here too while it runs; it exits on
its own.

On the database, the connections should come from one place and number about
`POOL_SIZE`, plus your own session:

```sql
SELECT client_addr, count(*)
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY client_addr;
```

### Fix

1. Stop the extra node.
2. **Restart the remaining service** (`sudo systemctl restart baudrate`), even
   though it looks healthy. A domain block or settings change made through the
   node you stopped never reached this node's caches; a restart reloads them
   from the database, which holds the change.

Deliveries already sent twice cannot be recalled.

---

## Detailed health report

The report is on the server only: `curl -s http://127.0.0.1:4001/health | jq`
(see the sysop guide's Detailed Health Report section and
[ADR 0035](adr/0035-operational-visibility-stays-on-the-host.md)).

### You do not have to poll it

A check that keeps failing reaches the admins by itself
([ADR 0044](adr/0044-the-instance-tells-its-admins-when-it-is-unwell.md)).
`Baudrate.Health.Alerts` runs hourly from `SessionCleaner`; when the same set
of checks fails on two consecutive polls it notifies every admin in-app — and
by Web Push for admins who subscribed — as a `health_alert` naming the failing
checks, repeated once a day while that set does not change. Recovery arrives
once, as `health_recovered`. The log carries `health.alert:` with the reasons
and `health.recovered`.

It cannot tell you the instance is **down**, because it runs inside the
instance, so an external check is still worth having — that is the half the
`OnFailure=` example in `doc/sysop.md` covers.

If you are reading this because an alert arrived, the notification names the
failing checks and the report below has the detail.

### Nothing answers on port 4001

- `HEALTH_DETAIL_PORT` is not in the environment. It is set by the Ansible env
  template; a hand-made install has to add it. Check with
  `grep HEALTH_DETAIL_PORT /opt/baudrate/env/baudrate.env`.
- The listener binds `127.0.0.1` only. From another machine it is unreachable
  by design; run the request on the server.

### A check fails

- `delivery_queue` — deliveries are due but not being sent. Look for
  `federation.delivery_crashed` or `federation.delivery_timeout` in
  `journalctl -u baudrate`, and check that the `workers` check shows
  `delivery_worker` running. A backlog towards one instance that is down does
  not fail this check: its circuit holds those jobs on purpose.
- `inbound_queue` — see [Inbound activities not taking effect](#inbound-activities-not-taking-effect).
- `workers` — a worker has not completed a run for three intervals. A crash
  loop looks the same as a stopped worker; search the log for the module name.
  Right after a restart, a worker that has not run yet counts as healthy until
  three intervals have passed.
- `disk` — below 1 GiB or 10% free under the uploads directory. Backups stop
  at the same floor. The media cache is safe to shrink (it is re-fetched on
  demand); backups in `/var/backups/baudrate` are not.
- `backup` — the newest backup is over 26 hours old, or there is none:
  `systemctl list-timers baudrate-backup` and `journalctl -u baudrate-backup`.
  A backup refused for lack of disk space shows both this and `disk` failing.
- `encryption_keys` — a stored secret names a key this instance does not have,
  so those rows cannot be read. `missing_keys` in the details names the id: put
  that key back in `BAUDRATE_AUTH_KEYS` / `BAUDRATE_SIGNING_KEYS` and restart.
  The check is skipped while both classes are still derived from
  `SECRET_KEY_BASE`. This is the one check whose failure locks members out of
  their own accounts, so treat it as urgent.
- A check reports `raised an error` — the check itself failed (for example a
  table missing because migrations did not run). The reason is deliberately
  generic; the log has the error.

---

## Deploys, releases and rollback

The Ansible deploy builds the release tag on the server
([ADR 0037](adr/0037-the-deploy-builds-on-the-server-again.md)). CI also
builds, smoke-tests and attests a release for each tag, for installing by hand
([SysOp Guide](sysop.md#release-artifacts)).

### Installing a CI-built tarball by hand fails to verify

Do not install it. `gh attestation verify` failing means the tarball was not
built by this repository's `release.yml` from that tag's commit on a
GitHub-hosted runner. Check also that:

- `gh auth status` succeeds, and the tag is in your clone (`git fetch --tags`),
  since the check compares the attestation with the commit the tag names *in
  your clone*;
- the release has a tarball at all — the Release workflow takes several
  minutes, and releases published before v1.26.0 have none.

### "RELEASE_COOKIE must be set to this server's own secret cookie"

The release refuses to join the Erlang distribution with the cookie it ships,
which is public. The systemd service gets `RELEASE_COOKIE` from
`/opt/baudrate/env/baudrate.env`; a shell does not. For `remote` or `rpc`,
source the file first, as the service user:

```bash
cd /opt/baudrate
sudo -u baudrate sh -c 'set -a; . /opt/baudrate/env/baudrate.env; exec /opt/baudrate/current/bin/baudrate remote'
```

The `cd` is not decoration: `sudo` and `runuser` keep root's working
directory, and a node that cannot search its cwd dies with an unrelated-looking
error — see below.

`bin/baudrate eval` (migrations, backups, dumps) needs no cookie. If the
service itself fails with this message, the environment file lacks the line:
re-run the deploy, which generates the cookie once per server.

### `remote`, `rpc` or `eval` dies with a `persistent_term` error

The whole output is a `Kernel pid terminated (logger)` line with a `badarg`
inside `persistent_term:get(code_server)`, then a promise to write
`erl_crash.dump` — which never appears. It looks like a corrupt release. It is
the **working directory**.

`sudo -u baudrate` and `runuser -u baudrate` both keep the *calling* shell's
cwd, so arriving from a root shell leaves the node in `/root`, mode 700. The
service account cannot search it, ERTS cannot start the code server, and the
first log call trips over its absence — so the one subsystem that would report
the problem is the one that is broken. The crash dump is written relative to
that same directory, so it does not land either.

```bash
cd /opt/baudrate        # anywhere the service account can search
```

Three things make this hard to recognise:

- it is the **search (`x`) bit**, not read — a mode 711 directory works, 700
  owned by someone else does not;
- `getcwd()` still succeeds, so `pwd` prints a perfectly good path from the
  same shell, as the same user;
- `eval` fails identically, though it starts no distribution and needs no
  cookie — so it is not a cookie or networking problem, and the usual fixes
  for those change nothing.

### `remote` or `rpc` cannot reach the node

With the cookie set, check the name: the node is `baudrate@127.0.0.1`, reached
over loopback. A release from before ADR 0036 is named `baudrate@<hostname>`
instead; after a rollback to one, set `RELEASE_NODE=baudrate@$(hostname -s)`
and `RELEASE_DISTRIBUTION=sname` for the command.

### A deploy fails while building on the server

The server builds the tag with the Erlang and Elixir versions that tag pins in
`.tool-versions`. Install them first
(`ansible-playbook playbooks/setup-server.yml --tags elixir`), or the build
fails; this is what makes deploying a very old tag awkward, and why the
rollback playbook exists. The deploy wipes `_build/prod` by itself when the
tag's toolchain differs from the last build's.

### "CI builds and tests on Debian 12/x86_64, and this host runs …"

The deploy's pre-flight refuses a host whose Debian release or architecture
disagrees with `debian_version` in `ansible/inventory/group_vars/all.yml`
(ADR 0036 decision 1). Since the deploy builds on the server (ADR 0037), a
mismatch no longer stops the release starting — which is exactly why the
check matters: the host would silently become the system the binary is built
against, while CI keeps building and testing on the other one.

`debian_version` also fixes the PostgreSQL client major that
`ci/image/Dockerfile` installs. A Debian 13 host ships a 17 client, whose
`pg_dump` writes `SET transaction_timeout` — which the PostgreSQL 15 server
rejects. So the first thing a drifted host breaks is not the deploy but the
pre-deploy dump and the nightly backups (ADR 0028).

Do not work around it by deleting the assert. Either move the host back, or
change `debian_version`, `POSTGRES_MAJOR` in `ci/image/Dockerfile` and the
digest-pinned `postgres:<major>` service images together, rebuild the CI image
and merge the `image.lock` change — `ci/image/verify-toolchain.sh` fails until
all of them agree.

### The rollback playbook refuses

"The database has N migration(s) that release does not contain": rolling back
the code would leave the schema newer than the code. Fix forward, or restore
the pre-deploy dump taken before those migrations and then roll back, as the
[SysOp Guide](sysop.md#rolling-back-a-deploy) describes. Use `-e force=true`
only after checking the older release works with the newer schema. Run the
playbook with `--check` first to see the target and the verdict without
changing anything.

### The Release build or Security checks job fails in CI

- **Release build:** the smoke test prints which step failed and the tail of
  the server log. It is the same script `release.yml` runs before publishing,
  so a red job here means the next release would not publish.
- **Security checks, Sobelow:** a new finding. Fix it, or check it and mark the
  function with `# sobelow_skip ["Check"]`
  ([development guide](development.md#security-checks)).
- **Security checks, mix_audit:** a dependency in `mix.lock` has a published
  advisory. Upgrade it; the list comes from the CI image, recorded by commit in
  the job output.

