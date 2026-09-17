# 0038 — Encryption keys are separate, and rotatable

- **Status:** Accepted
- **Date:** 2026-09-18
- **Deciders:** Baudrate maintainers
- **Related:** implements Phase 2G; amends
  [0010](0010-encrypt-secrets-at-rest.md) (the keys still come from
  configuration, but no longer from `SECRET_KEY_BASE`) and
  [0028](0028-backups-are-complete-folders-with-count-based-retention.md) (a
  restore needs the matching key set, and the manifest now records which);
  reports through [0035](0035-operational-visibility-stays-on-the-host.md)

## Context

Everything Baudrate keeps secret was keyed off one value. `SECRET_KEY_BASE`
derived, through PBKDF2 with four different salts:

- the key that encrypts **TOTP secrets** (`users.totp_secret`);
- the key that hashes **recovery codes** (`recovery_codes.code_hash`);
- the key that encrypts **actor private keys** (users, boards, the site);
- the key that encrypts the **Web Push VAPID key**;

and, separately, the session cookie, LiveView tokens, short-lived
`Phoenix.Token`s and media-proxy URL signatures.

So `SECRET_KEY_BASE` could never be rotated. The sysop guide said as much —
"never change `SECRET_KEY_BASE` after deployment" — and ADR 0010 recorded the
consequence: losing it means every actor keypair regenerated and every member
re-enrolling TOTP. If the value ever leaked (a copied env file, a log line, an
operator's old laptop, a backup left somewhere), there was nothing to do about
it.

Two of those dependencies were not even written down. The recovery-code HMAC
made the documented remedy circular: a member whose TOTP secret has become
unreadable is told to use a recovery code, which the same rotation
invalidated. The VAPID key appeared in neither the warnings nor ADR 0010.

A second, quieter problem: the ciphertext was bound only to its vault, so a
value was portable between rows of the same table. Anyone able to write one
row — SQL injection, a selective restore, a careless support script — could
transplant a member's second factor onto another account, or an actor's
private key onto another actor.

## Decision

### 1. Two classes of key, one for each kind of secret

| Class | Protects | Variable |
|---|---|---|
| `:auth` | TOTP secrets, recovery-code hashes | `BAUDRATE_AUTH_KEYS` |
| `:signing` | user, board and site actor private keys; the VAPID key | `BAUDRATE_SIGNING_KEYS` |

The split follows what losing a key costs: an `:auth` key is a member's own
access, a `:signing` key is what remote parties expect of us. The VAPID key
sits with the actor keys for that reason.

The media-proxy signing key, session cookies and `Phoenix.Token`s stay on
`SECRET_KEY_BASE`. They protect nothing at rest: rotating them signs members
out and makes already-rendered image URLs re-sign on the next render, which is
a rotation's job, not a loss.

Each class key is expanded into one subkey per purpose
(`HMAC-SHA256(key, "baudrate:<purpose>:v1")`), so the value that encrypts TOTP
secrets is not the value that keys the recovery-code HMAC, and no key is used
for both AES-GCM and HMAC.

### 2. Keys come from the environment, never the database

Like `SECRET_KEY_BASE`: kept in SOPS, rendered into the 0600 env file, read at
boot. A key in the database would be carried in every dump alongside the
ciphertext it protects.

Each variable is a list of `id:key` entries, **current first**, retired keys
after it. A malformed entry raises at boot, with the command that generates a
key and without echoing any key material: starting with the wrong keys writes
secrets nobody can read later.

Ansible renders the keys when they are set but, unlike `secret_key_base`,
never generates one. A key the operator did not save would encrypt secrets on
one deploy and be gone on the next, and what was written in between would be
unrecoverable — silent, delayed and permanent.

### 3. Stored values say which key wrote them

```
"BK1" | id_len | key_id | iv(12) | tag(16) | ciphertext
```

The key id is what lets old and new values sit side by side during a rotation,
and what lets the census say when a retired key is safe to drop. The header is
authenticated along with the purpose and the row, so a tampered id fails
instead of selecting another key.

### 4. Values are bound to their row

The authenticated data names the owner — `user:<id>`, `board:<id>`,
`setting:<key>` — using the immutable surrogate key, never a username or slug.
A ciphertext moved to another row no longer decrypts.

### 5. No flag day, and the upgrade stays reversible

With no key configured, the app derives today's key from `SECRET_KEY_BASE`
with the same salts **and writes the old format with the old constant AAD**.
An upgrade therefore changes nothing on disk, and a release older than this
decision can still read what the new one wrote — so the deploy can be rolled
back.

That stops being true once a key is configured: values written afterwards
carry a key id the older release knows nothing about. Configuring the keys is
therefore a separate, deliberate change, after the deploy has settled.

Decryption accepts both formats permanently. A legacy blob whose random IV
happens to begin `BK1` (about one in 17 million) fails the key lookup or the
authentication tag and is then read as legacy: trial decryption is safe
because AES-GCM authenticates — a wrong key, a wrong AAD or a misread header
produces an error, never plausible-looking wrong plaintext.

### 6. Rotation is a resumable release task, safe against the live node

`Baudrate.Release.rotate_keys/1` re-encrypts what is not on the current key.
What remains is derived from the data, not a bookmark, so it resumes by being
run again and running it twice changes nothing. Each write is conditional on
the row still holding the value that was read: a member enrolling TOTP mid-run
keeps their new secret rather than having the older one written back. A value
it cannot decrypt is counted and logged, never written and never raised — the
data-export canary test puts marker bytes in exactly these columns.

It ends with a census: how many values sit under each key id, per column. A
retired key may be removed only when nothing is listed under it.

### 7. Recovery codes carry a key id, because they cannot be re-keyed

Only the member's own code can produce its hash, so a rotation cannot move it.
Each row records the key that hashed it, and verification hashes the input
under every configured key, so codes issued before a rotation keep working.

The column is advisory: it is never part of the lookup, because a 32-byte HMAC
does not collide across keys. A wrong or missing label therefore only makes
the census over-count, where the opposite error would be a member who cannot
get recovery codes at all.

Recovery codes are also how a member without their authenticator gets back in,
and Baudrate sends no email. So dropping an `:auth` key that recovery codes
still reference takes away someone's only way back into their account — which
is what the census and the health check exist to prevent. The rotation task
deliberately does **not** regenerate codes: that would invalidate a sheet a
member is relying on without telling them.

### 8. The state is visible

A boot log line names any class still on the fallback, and the detailed health
report gains an `encryption_keys` check (ADR 0035): ids and counts only.

It fails for one condition — a stored value naming a key that is not
configured, which means rows nobody can read — and stays quiet about an
instance still on the fallback, which was told it needs no action. A check
that complained about a supported state would teach the operator to ignore the
report.

### 9. Backups record the key ids

`MANIFEST.json` carries the ids that were current, never key material. The
dump holds ciphertext and no keys, so a restore needs the matching key set;
recording the ids makes a mismatch visible instead of looking like everyone's
second factor broke at once. A restore does not refuse an unknown key set:
recovering the content and accepting the loss of TOTP and actor keys is
sometimes exactly what an operator wants.

### 10. `SECRET_KEY_BASE` becomes rotatable

Once the census shows nothing under `legacy` — recovery codes included, which
in practice means every member with 2FA has regenerated their codes — rotating
`SECRET_KEY_BASE` costs only in-flight things: sessions end, LiveView and
short-lived tokens break until a reconnect, and rendered media-proxy URLs
re-sign on the next render.

## Consequences

- Three secrets must be kept offline instead of one, and a restore needs all
  of them.
- **A key dropped too early is unrecoverable.** The census and the health
  check are the only guards, and for recovery codes the wait is as long as it
  takes members to regenerate.
- Configuring the keys makes a rollback past that point lossy for anything
  written since, which is why it is a separate change from the deploy.
- An undecryptable actor key fails deliveries rather than regenerating the
  actor: `ensure_*_keypair/1` only acts when there is no public key, so a
  mis-pasted key does not silently change every actor's identity. The way out
  is rotating the keypair from `/admin/federation`, which republishes the
  public key.
- Every failure here is fail-closed: a wrong key refuses the right person, and
  never admits the wrong one.
- A 12-byte random IV under one key is birthday-bounded around 2³² values; an
  instance writes thousands, so this never binds, and the format carries a
  version for the day it might.
- The vaults keep their names and their `:error` returns, so nothing in the
  request path raises on a key problem.

## Alternatives considered

- **One key for everything, separate from `SECRET_KEY_BASE`.** Simpler to
  operate, but rotating a member-facing key would also rotate the instance's
  signing identity, and both would share one blast radius.
- **A current key and a previous key, with no ids in the ciphertext.**
  Decryption would try both, which works — but nothing could then answer "is
  it safe to drop the old key yet", and answering that wrong locks people out.
- **Hashing recovery codes like passwords** (bcrypt), removing the key
  dependency. Rejected: verification looks a code up by its hash, so this
  would mean scanning a member's rows, and the codes' ~41 bits of entropy is
  exactly where a keyed hash earns its place.
- **Regenerating recovery codes during a rotation.** Rejected: it invalidates
  a printed sheet without telling the member.
- **Keys in the database**, encrypted by `SECRET_KEY_BASE`. Rejected: a dump
  would carry both halves.
- **Requiring the keys in production.** Rejected by the operator: an upgrade
  that needs a procedure to avoid downtime is a worse default than a warning.
- **Auto-generating the keys in Ansible**, like `secret_key_base`. Rejected as
  the most dangerous option on the table: see decision 2.
- **Sobelow-style skip files or a bookmark table for rotation.** Rejected: the
  data already says what is left.

## Acceptance gate

- **Formats and keys:** `test/baudrate/crypto/vault_test.exs` (both formats,
  cross-class, cross-row and unknown-key refusals, the `BK1`-prefixed legacy
  blob) and `test/baudrate/crypto/keyring_test.exs`.
- **Rotation:** `test/baudrate/crypto/rekey_test.exs` — every column moves, an
  unreadable value is left alone, a secret written mid-run survives, and the
  census counts what is left.
- **Recovery codes:** `test/baudrate/auth/recovery_code_keys_test.exs`,
  including the lockout a dropped key would cause.
- **Configuration:** `test/baudrate/crypto/runtime_keys_test.exs` reads
  `config/runtime.exs` as a release does.
- **Reporting:** `test/baudrate/health_test.exs` and
  `test/baudrate/backup/snapshots_test.exs`.
