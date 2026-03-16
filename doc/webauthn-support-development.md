# WebAuthn / FIDO2 Support — Developer Guide

This document describes the design and implementation plan for adding WebAuthn
(FIDO2) security key support as a second-factor option alongside the existing
TOTP. It covers the database schema, library integration, authentication flows,
LiveView/JS wiring, and security requirements.

---

## Background and Goals

The existing second-factor mechanism uses TOTP (time-based one-time passwords
via `Auth.SecondFactor` and `TotpVault`). TOTP requires the user to read a
6-digit code from an authenticator app and type it within a 30-second window.

WebAuthn replaces that step with a hardware security key tap (YubiKey, etc.)
or a platform authenticator (Touch ID, Windows Hello). Security properties:

| | TOTP | WebAuthn |
|-|------|----------|
| Phishing resistant | No — code can be relayed | Yes — signature is origin-bound |
| Server stores secret | Yes (encrypted) | No — public key only |
| Physical presence | No | Yes (user gesture required) |
| Replay attacks | 30-second window | No — per-challenge nonce |
| Typing / timeout pressure | Yes | No |

**Design goals:**

- WebAuthn is an **additional** option, not a replacement. Users without a
  hardware key continue to use TOTP unchanged.
- A user may enrol multiple credentials (multiple keys for backup).
- The feature gates on the same policy points as TOTP: sudo-mode
  re-verification for admins, and the login second-factor step for all users
  with 2FA enabled.
- No third-party service dependency — everything is verified server-side.

---

## Library

Add [`wax_`](https://hex.pm/packages/wax_) to `mix.exs`:

```elixir
{:wax_, "~> 0.7"}
```

`wax_` is a pure-Elixir FIDO2/WebAuthn RP (relying party) library. It handles
challenge generation, attestation verification (registration), and assertion
verification (authentication). CBOR decoding of authenticator data is included.

---

## Database Schema

### New table: `webauthn_credentials`

```sql
CREATE TABLE webauthn_credentials (
  id               bigserial PRIMARY KEY,
  user_id          bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  credential_id    bytea  NOT NULL,          -- raw credential ID from authenticator
  public_key_cbor  bytea  NOT NULL,          -- COSE public key, CBOR-encoded
  sign_count       bigint NOT NULL DEFAULT 0, -- replay protection counter
  aaguid           uuid,                      -- authenticator model identifier
  label            text   NOT NULL DEFAULT '', -- user-assigned name, e.g. "YubiKey 5C"
  last_used_at     timestamptz,
  inserted_at      timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX webauthn_credentials_credential_id_idx
  ON webauthn_credentials (credential_id);

CREATE INDEX webauthn_credentials_user_id_idx
  ON webauthn_credentials (user_id);
```

Migration file: `priv/repo/migrations/<timestamp>_create_webauthn_credentials.exs`

### Schema module

`lib/baudrate/auth/webauthn_credential.ex`

Key fields:

- `credential_id` — `:binary` — the raw credential ID bytes returned by the
  browser. Used as the lookup key during authentication.
- `public_key_cbor` — `:binary` — the COSE-encoded public key. Passed directly
  to `Wax.authenticate/4`.
- `sign_count` — `:integer` — monotonically increasing counter from the
  authenticator; must be checked and updated on every successful authentication
  to detect cloned keys.
- `aaguid` — `:binary` (UUID bytes) — identifies the authenticator model.
  Informational; useful for displaying the key type in the UI.
- `label` — `:string` — user-assigned name shown in the credentials list.

---

## Auth Context Changes

All WebAuthn operations are added to `lib/baudrate/auth/webauthn.ex` (new
module) and delegated through `lib/baudrate/auth.ex`:

```elixir
# lib/baudrate/auth.ex (additions)
defdelegate list_webauthn_credentials(user), to: WebAuthn
defdelegate create_webauthn_credential(user, attrs), to: WebAuthn
defdelegate delete_webauthn_credential(user, credential_id), to: WebAuthn
defdelegate begin_registration(user), to: WebAuthn
defdelegate finish_registration(user, attestation_object, client_data_json, challenge), to: WebAuthn
defdelegate begin_authentication(user), to: WebAuthn
defdelegate finish_authentication(user, credential_id, authenticator_data,
                                  client_data_json, signature, challenge), to: WebAuthn
defdelegate webauthn_enabled?(user), to: WebAuthn
```

### Challenge lifecycle

WebAuthn challenges are short-lived (60 seconds) and single-use. Store them in
ETS (same pattern as `SettingsCache`) rather than the DB — they are ephemeral
and high-frequency:

```elixir
# lib/baudrate/auth/webauthn_challenges.ex
# GenServer-backed ETS table :webauthn_challenges
# %{key => {challenge_bytes, user_id, expires_at}}
# Sweeps expired entries every 30 seconds
```

The challenge key is a random token included in the LiveView session or a
hidden form field, used to correlate the browser's response back to the stored
challenge. Do **not** store the challenge in the cookie session — it must be
validated server-side in the controller where it is consumed.

---

## Registration Flow

Registration enrolls a new security key for an already-authenticated user from
their profile settings page (`/profile`).

```
Browser (LiveView)                   Server
       |                                |
       |── "begin_registration" event ─>|
       |                                |── WebAuthn.begin_registration(user)
       |                                |   • generate challenge
       |                                |   • store in ETS (60s TTL)
       |                                |   • build PublicKeyCredentialCreationOptions
       |<── push_event "webauthn_register", options ──|
       |                                |
       | JS hook calls                  |
       | navigator.credentials.create() |
       | (user taps key)                |
       |                                |
       |── POST /auth/webauthn/register ─────────────>|
       |   attestation_object (b64)     |── finish_registration/4
       |   client_data_json (b64)       |   • Wax.register/4
       |   challenge_token              |   • verify origin, challenge, rpid
       |   label                        |   • extract credential_id, public_key
       |                                |   • insert webauthn_credentials row
       |<── redirect /profile ──────────|
```

### LiveView side (`WebAuthnRegisterLive` or inline in `ProfileLive`)

```elixir
def handle_event("begin_registration", _params, socket) do
  user = socket.assigns.current_user
  {challenge_token, options_json} = Auth.begin_registration(user)

  {:noreply,
   socket
   |> assign(:challenge_token, challenge_token)
   |> push_event("webauthn_register", %{options: options_json})}
end
```

### JS hook (`assets/js/hooks/webauthn.js`)

```javascript
WebAuthnRegister: {
  mounted() {
    this.handleEvent("webauthn_register", async ({ options }) => {
      const opts = decodeCreationOptions(options) // base64url-decode binary fields
      const credential = await navigator.credentials.create({ publicKey: opts })
      const form = document.getElementById("webauthn-register-form")
      document.getElementById("attestation_object").value =
        encodeBase64url(credential.response.attestationObject)
      document.getElementById("client_data_json").value =
        encodeBase64url(credential.response.clientDataJSON)
      form.requestSubmit()
    })
  }
}
```

### Controller action (`SessionController.webauthn_register/2`)

```elixir
def webauthn_register(conn, %{
      "attestation_object" => att_obj_b64,
      "client_data_json" => cdj_b64,
      "challenge_token" => token,
      "label" => label
    }) do
  user = get_authenticated_user(conn)

  with {:ok, challenge} <- WebAuthnChallenges.pop(token, user.id),
       {:ok, credential} <-
         Auth.finish_registration(user, att_obj_b64, cdj_b64, challenge),
       {:ok, _} <-
         Auth.create_webauthn_credential(user, Map.put(credential, :label, label)) do
    conn
    |> put_flash(:info, gettext("Security key registered successfully."))
    |> redirect(to: "/profile")
  else
    {:error, reason} ->
      Logger.warning("auth.webauthn_register_failed: user_id=#{user.id} reason=#{inspect(reason)}")

      conn
      |> put_flash(:error, gettext("Security key registration failed. Please try again."))
      |> redirect(to: "/profile")
  end
end
```

**`finish_registration/4` wraps `Wax.register/4`:**

```elixir
def finish_registration(user, att_obj_b64, cdj_b64, challenge) do
  attestation_object = Base.url_decode64!(att_obj_b64, padding: false)
  client_data_json   = Base.url_decode64!(cdj_b64, padding: false)

  case Wax.register(attestation_object, client_data_json, challenge) do
    {:ok, {authenticator_data, _result}} ->
      {:ok, %{
        credential_id:   authenticator_data.attested_credential_data.credential_id,
        public_key_cbor: authenticator_data.attested_credential_data.credential_public_key,
        aaguid:          authenticator_data.attested_credential_data.aaguid,
        sign_count:      authenticator_data.sign_count
      }}

    {:error, _} = err ->
      err
  end
end
```

---

## Authentication Flow

Authentication is used in two places:

1. **Login second-factor** — after password verification, if the user has
   WebAuthn credentials enrolled (and optionally TOTP too), they are offered a
   "Use security key" button alongside the TOTP code entry.
2. **Admin sudo-mode re-verification** — the `AdminTotpVerifyLive` page
   (currently `/admin/verify`) gains a "Use security key" option that, on
   success, sets `admin_totp_verified_at` identically to TOTP success.

```
Browser (LiveView)                       Server
       |                                    |
       |── "begin_webauthn" event ──────────>|
       |                                    |── Auth.begin_authentication(user)
       |                                    |   • lookup credential_ids for user
       |                                    |   • generate challenge, store in ETS
       |                                    |   • build PublicKeyCredentialRequestOptions
       |<── push_event "webauthn_authenticate", options ──|
       |                                    |
       | JS hook calls                      |
       | navigator.credentials.get()        |
       | (user taps key)                    |
       |                                    |
       |── phx-trigger-action POST ─────────>|
       |   /admin-webauthn-verify           |── Auth.finish_authentication/6
       |   authenticator_data (b64)         |   • Wax.authenticate/4
       |   client_data_json (b64)           |   • verify origin, challenge, rpid
       |   signature (b64)                  |   • verify sign_count (clone detection)
       |   credential_id (b64)              |   • update sign_count in DB
       |   challenge_token                  |   • update last_used_at
       |   return_to                        |
       |                                    |
       |<── put_session admin_totp_verified_at ──────────|
       |<── redirect return_to ─────────────|
```

### Admin verify page (`AdminTotpVerifyLive`)

Add a second form alongside the TOTP form:

```heex
<button phx-click="begin_webauthn" type="button">
  <%= gettext("Use security key") %>
</button>

<form id="webauthn-verify-form" phx-trigger-action={@trigger_webauthn}
      action={~p"/admin-webauthn-verify"} method="post">
  <input type="hidden" name="_csrf_token" value={@csrf_token} />
  <input type="hidden" name="return_to" value={@return_to} />
  <input type="hidden" id="wa_authenticator_data" name="authenticator_data" />
  <input type="hidden" id="wa_client_data_json"   name="client_data_json" />
  <input type="hidden" id="wa_signature"          name="signature" />
  <input type="hidden" id="wa_credential_id"      name="credential_id" />
  <input type="hidden" id="wa_challenge_token"    name="challenge_token"
         value={@webauthn_challenge_token} />
</form>
```

```elixir
def handle_event("begin_webauthn", _params, socket) do
  user = socket.assigns.current_user
  {challenge_token, options_json} = Auth.begin_authentication(user)

  {:noreply,
   socket
   |> assign(:webauthn_challenge_token, challenge_token)
   |> assign(:trigger_webauthn, false)
   |> push_event("webauthn_authenticate", %{options: options_json})}
end

def handle_event("webauthn_credential_received", _params, socket) do
  {:noreply, assign(socket, :trigger_webauthn, true)}
end
```

### JS hook (`assets/js/hooks/webauthn.js`)

```javascript
WebAuthnAuthenticate: {
  mounted() {
    this.handleEvent("webauthn_authenticate", async ({ options }) => {
      const opts = decodeRequestOptions(options)
      const assertion = await navigator.credentials.get({ publicKey: opts })
      document.getElementById("wa_authenticator_data").value =
        encodeBase64url(assertion.response.authenticatorData)
      document.getElementById("wa_client_data_json").value =
        encodeBase64url(assertion.response.clientDataJSON)
      document.getElementById("wa_signature").value =
        encodeBase64url(assertion.response.signature)
      document.getElementById("wa_credential_id").value =
        encodeBase64url(assertion.rawId)
      this.pushEvent("webauthn_credential_received", {})
    })
  }
}
```

`webauthn_credential_received` is handled by the LiveView to flip
`trigger_webauthn: true`, which activates `phx-trigger-action` and submits the
form to the controller — the same pattern used by `AdminTotpVerifyLive` for
TOTP.

### Controller action (`SessionController.admin_webauthn_verify/2`)

Mirrors `admin_totp_verify/2` exactly in structure:

```elixir
def admin_webauthn_verify(conn, params) do
  %{
    "authenticator_data" => ad_b64,
    "client_data_json"   => cdj_b64,
    "signature"          => sig_b64,
    "credential_id"      => cid_b64,
    "challenge_token"    => token,
    "return_to"          => return_to
  } = params

  return_to = sanitize_admin_return_to(return_to)
  user      = get_authenticated_admin(conn)
  attempts  = get_session(conn, :admin_webauthn_attempts) || 0

  with true <- attempts < @max_totp_attempts,
       {:ok, challenge} <- WebAuthnChallenges.pop(token, user.id),
       {:ok, _} <- Auth.finish_authentication(
                     user, cid_b64, ad_b64, cdj_b64, sig_b64, challenge) do
    Logger.info("auth.admin_webauthn_verify_success: user_id=#{user.id} ip=#{remote_ip(conn)}")

    conn
    |> delete_session(:admin_webauthn_attempts)
    |> put_session(:admin_totp_verified_at, System.system_time(:second))
    |> redirect(to: return_to)
  else
    _ ->
      # increment attempt counter, log failure, redirect back
      ...
  end
end
```

Note: on success, the same `admin_totp_verified_at` session key is set. The
`require_admin_totp` hook in `auth_hooks.ex` requires no changes — it already
treats any fresh `admin_totp_verified_at` as valid regardless of how it was
obtained.

---

## `wax_` Configuration

Add to `config/config.exs`:

```elixir
config :wax_,
  origin: "https://baudrate.example",   # must match window.location.origin exactly
  rp_id: "baudrate.example",            # eTLD+1 of origin
  attestation: :none,                   # accept all authenticators without attestation validation
  user_presence: true,                  # require user presence (key touch)
  user_verification: :preferred         # request UV but don't require it
```

Override in `config/test.exs`:

```elixir
config :wax_,
  origin: "http://localhost:4002",
  rp_id: "localhost",
  attestation: :none
```

---

## Credential Management UI

Add to `/profile` (or `/settings`):

- **Enrolled keys list** — label, AAGUID (shown as authenticator model if
  recognised), last used date, delete button
- **"Register new key"** button — triggers `begin_registration` event
- **Label input** — shown before or after the key tap prompt
- Warn if deleting the last credential when TOTP is also disabled

---

## `totp_policy` Extension

`Auth.SecondFactor.totp_policy/1` currently gates who must have a second
factor. A parallel `webauthn_policy/1` is not needed — WebAuthn is opt-in on
top of existing 2FA policy. The login flow checks:

```
1. password verified?
2. Does user have TOTP enabled OR WebAuthn credentials?
   → yes: show second-factor step (offer both methods if both enrolled)
   → no:  authenticated (subject to role policy enforcement)
```

`Auth.webauthn_enabled?/1`:

```elixir
def webauthn_enabled?(user) do
  Repo.exists?(from c in WebAuthnCredential, where: c.user_id == ^user.id)
end
```

---

## Security Requirements

- **Origin binding** — `wax_` verifies that `clientDataJSON.origin` matches the
  configured origin exactly. Phishing sites on different origins are
  cryptographically rejected.
- **RP ID binding** — the authenticator data includes a hash of the RP ID;
  `wax_` verifies it. Keys enrolled on one domain cannot be used on another.
- **Sign count** — after every successful authentication, update
  `webauthn_credentials.sign_count` to the new value. If the received count is
  ≤ the stored count (and the stored count is non-zero), reject with a warning —
  this indicates a cloned authenticator.
- **Challenge single-use** — `WebAuthnChallenges.pop/2` deletes the challenge
  atomically on first retrieval, preventing replay.
- **Challenge TTL** — challenges expire after 60 seconds; the ETS sweeper
  removes stale entries. Expired challenges must not be accepted.
- **No `allow_credentials` disclosure** — do not return the list of enrolled
  `credential_id`s to unauthenticated users (would allow username enumeration).
  Only populate `allowCredentials` after password verification.
- **User presence** — configure `user_presence: true`; a key tap is required.
- **HTTPS only** — WebAuthn is browser-enforced to require a secure context
  (`https://` or `localhost`). Bandit already serves TLS; no extra work needed.
- **Rate limiting** — apply the same `@max_totp_attempts` (5) lockout logic
  used for TOTP to the WebAuthn controller action.
- **Audit logging** — log registration, successful authentication, failed
  authentication, and credential deletion events at the same detail level as
  TOTP events in `SessionController`.

---

## Testing

Use `Baudrate.DataCase` for context-level tests and `BaudrateWeb.ConnCase` for
controller tests. `wax_` provides test helpers for generating synthetic
authenticator data without real hardware.

Key test cases:

- `WebAuthn.finish_registration/4` — valid attestation succeeds and persists
  credential; tampered `clientDataJSON` is rejected; wrong origin is rejected
- `WebAuthn.finish_authentication/6` — valid assertion succeeds and updates
  `sign_count`; stale sign count is rejected; wrong challenge is rejected;
  expired challenge is rejected; unknown `credential_id` is rejected
- `SessionController.admin_webauthn_verify/2` — success sets
  `admin_totp_verified_at`; 5 failures trigger lockout without dropping session;
  expired challenge returns error; non-admin user is rejected
- `WebAuthnChallenges` — pop succeeds once; second pop returns error; expired
  entries are not returned

---

## File Map

| Path | Purpose |
|------|---------|
| `lib/baudrate/auth/webauthn.ex` | Context functions: begin/finish registration and authentication, CRUD |
| `lib/baudrate/auth/webauthn_credential.ex` | Ecto schema + changesets |
| `lib/baudrate/auth/webauthn_challenges.ex` | ETS-backed challenge store (GenServer) |
| `priv/repo/migrations/<ts>_create_webauthn_credentials.exs` | DB migration |
| `lib/baudrate_web/controllers/session_controller.ex` | Add `webauthn_register/2`, `admin_webauthn_verify/2` |
| `lib/baudrate_web/live/admin_totp_verify_live.ex` | Add `begin_webauthn` event + `trigger_webauthn` assign |
| `lib/baudrate_web/live/admin_totp_verify_live.html.heex` | Add security key form alongside TOTP form |
| `assets/js/hooks/webauthn.js` | `WebAuthnRegister` and `WebAuthnAuthenticate` hooks |
| `test/baudrate/auth/webauthn_test.exs` | Context-level tests |
| `test/baudrate_web/controllers/session_controller_test.exs` | Controller tests for new actions |
