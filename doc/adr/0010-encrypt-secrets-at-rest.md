# 0010 — Encrypt TOTP secrets and federation private keys at rest

- **Status:** Accepted
- **Date:** Recorded retroactively 2026-08-09

## Context

Two classes of long-lived secret live in the database:

- **TOTP shared secrets.** A leaked secret defeats the second factor silently
  and permanently — the user has no way to notice, and rotating requires
  re-enrolment.
- **ActivityPub actor private keys.** A leaked RSA private key lets anyone
  forge signed activities as that user, board, or the instance itself. Remote
  instances have no way to distinguish forged from genuine.

A database dump — from a backup, a misconfigured replica, a SQL injection, or a
stolen disk — is a realistic threat for a self-hosted public service.

## Decision

Encrypt both at rest with **AES-256-GCM**, keyed from application
configuration (not from the database), through dedicated vault modules:

| Vault | Protects |
|---|---|
| `Baudrate.Auth.TotpVault` | TOTP shared secrets |
| `Baudrate.Federation.KeyVault` | Actor RSA private keys |

Related keying rules:

- Actor keypairs are RSA-2048, managed by `Federation.KeyStore`.
- Callers must `KeyStore.ensure_user_keypair/1` before enqueuing a signed
  outbound activity. As a backstop, `Delivery.get_private_key/1` — the single
  signing chokepoint for `send_accept`, `send_reject` and queued `do_deliver` —
  is **self-healing**: it lazily generates a keypair for any local user, board
  or site actor that lacks one, and never returns a bare `:error`. This covers
  the real gap where a brand-new user's activity is delivered to *board*
  followers before their own actor was ever fetched.
- **Inbound** remote public keys must be RSA ≥ 2048 bits
  (`HTTPSignature.validate_public_key_pem/1`), enforced both at `ActorResolver`
  ingest (so a weak key is never cached) and at verification time (so keys
  cached before the check are rejected too). Non-RSA keys return
  `:unsupported_key_type` — verification only implements `rsa-sha256`.

## Consequences

- A database disclosure alone does not yield working second factors or
  forgeable actor identities; the attacker also needs the application secret.
- The encryption key becomes part of the backup and disaster-recovery story:
  losing it means every actor keypair must be regenerated (breaking existing
  remote followers' signature expectations) and every user must re-enrol TOTP.
  This is documented in `doc/sysop.md`.
- Encryption is transparent at the schema boundary, so callers cannot
  accidentally read plaintext.

## Alternatives considered

- **Rely on disk/database-level encryption.** Rejected: protects against a
  stolen disk, not against a dump, a replica, or SQL injection.
- **Store TOTP secrets hashed.** Not possible — TOTP verification needs the
  secret itself.
