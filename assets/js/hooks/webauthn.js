/**
 * WebAuthn (FIDO2) LiveView hooks.
 *
 * WebAuthnRegister — handles security key registration from the profile page.
 * WebAuthnAuthenticate — handles security key assertion for sudo-mode verification.
 *
 * Both hooks listen for a server push_event, call the WebAuthn API, encode
 * the binary response fields as base64url, populate hidden form inputs, and
 * either submit the form or push an event back to the LiveView to trigger
 * phx-trigger-action.
 */

/**
 * Decodes base64url-encoded binary fields in PublicKeyCredentialCreationOptions
 * returned from the server so the browser WebAuthn API can consume them.
 */
function decodeCreationOptions(options) {
  return {
    ...options,
    challenge: decodeBase64url(options.challenge),
    user: {
      ...options.user,
      id: decodeBase64url(options.user.id),
    },
    excludeCredentials: (options.excludeCredentials || []).map((c) => ({
      ...c,
      id: decodeBase64url(c.id),
    })),
  }
}

/**
 * Decodes base64url-encoded binary fields in PublicKeyCredentialRequestOptions.
 */
function decodeRequestOptions(options) {
  return {
    ...options,
    challenge: decodeBase64url(options.challenge),
    allowCredentials: (options.allowCredentials || []).map((c) => ({
      ...c,
      id: decodeBase64url(c.id),
    })),
  }
}

function decodeBase64url(str) {
  const padded = str + "=".repeat((4 - (str.length % 4)) % 4)
  const binary = atob(padded.replace(/-/g, "+").replace(/_/g, "/"))
  return Uint8Array.from(binary, (c) => c.charCodeAt(0)).buffer
}

function encodeBase64url(buffer) {
  const bytes = new Uint8Array(buffer)
  let binary = ""
  bytes.forEach((b) => (binary += String.fromCharCode(b)))
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "")
}

export const WebAuthnRegister = {
  mounted() {
    this.handleEvent("webauthn_register", async ({ options }) => {
      if (!window.PublicKeyCredential) {
        this.pushEvent("webauthn_error", { reason: "not_supported" })
        return
      }

      try {
        const parsed = typeof options === "string" ? JSON.parse(options) : options
        const opts = decodeCreationOptions(parsed)
        const credential = await navigator.credentials.create({ publicKey: opts })

        document.getElementById("attestation_object").value = encodeBase64url(
          credential.response.attestationObject,
        )
        document.getElementById("client_data_json").value = encodeBase64url(
          credential.response.clientDataJSON,
        )

        document.getElementById("webauthn-register-form").requestSubmit()
      } catch (err) {
        console.error("WebAuthn registration error:", err)
        this.pushEvent("webauthn_error", { reason: err.name || "unknown" })
      }
    })
  },
}

export const WebAuthnAuthenticate = {
  mounted() {
    this.handleEvent("webauthn_authenticate", async ({ options }) => {
      if (!window.PublicKeyCredential) {
        this.pushEvent("webauthn_error", { reason: "not_supported" })
        return
      }

      try {
        const parsed = typeof options === "string" ? JSON.parse(options) : options
        const opts = decodeRequestOptions(parsed)
        const assertion = await navigator.credentials.get({ publicKey: opts })

        document.getElementById("wa_authenticator_data").value = encodeBase64url(
          assertion.response.authenticatorData,
        )
        document.getElementById("wa_client_data_json").value = encodeBase64url(
          assertion.response.clientDataJSON,
        )
        document.getElementById("wa_signature").value = encodeBase64url(
          assertion.response.signature,
        )
        document.getElementById("wa_credential_id").value = encodeBase64url(assertion.rawId)

        this.pushEvent("webauthn_credential_received", {})
      } catch (err) {
        console.error("WebAuthn authentication error:", err)
        this.pushEvent("webauthn_error", { reason: err.name || "unknown" })
      }
    })
  },
}
