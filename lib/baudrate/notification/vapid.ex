defmodule Baudrate.Notification.VAPID do
  @moduledoc """
  VAPID (Voluntary Application Server Identification) key management and
  ES256 JWT signing for Web Push notifications.

  Generates ECDSA P-256 keypairs and produces ES256 JWTs for the VAPID
  authentication scheme (RFC 8292). Private keys are encrypted at rest
  using `Baudrate.Notification.VapidVault`.

  ## Key Format

  - **Public key**: 65-byte uncompressed EC point, base64url-encoded (no padding)
  - **Private key**: 32-byte raw scalar, encrypted with VapidVault

  ## JWT Format

  Standard JWT with:
  - Header: `{"typ":"JWT","alg":"ES256"}`
  - Claims: `aud` (push service origin), `exp` (now + 12h), `sub` (mailto:contact)
  - Signature: ES256 (ECDSA P-256 + SHA-256), raw r||s format (64 bytes)
  """

  alias Baudrate.Notification.VapidVault

  @jwt_lifetime 12 * 3600

  @doc """
  Generates a new ECDSA P-256 keypair for VAPID.

  Returns `{public_key_base64url, encrypted_private_key_binary}` where:
  - `public_key_base64url` is the 65-byte uncompressed public point, base64url-encoded
  - `encrypted_private_key_binary` is the 32-byte private scalar encrypted with VapidVault
  """
  def generate_keypair do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    public_key_b64 = Base.url_encode64(public_key, padding: false)
    encrypted_private_key = VapidVault.encrypt(private_key)

    {public_key_b64, encrypted_private_key}
  end

  @doc """
  Signs a JWT with ES256 for VAPID authentication.

  ## Parameters

  - `audience` — the push service origin (e.g., `"https://fcm.googleapis.com"`)
  - `private_key` — the raw 32-byte ECDSA private key (already decrypted)

  Returns the JWT string in `header.claims.signature` format.
  """
  def sign_jwt(audience, private_key) when is_binary(audience) and is_binary(private_key) do
    header = Base.url_encode64(Jason.encode!(%{"typ" => "JWT", "alg" => "ES256"}), padding: false)

    claims =
      Base.url_encode64(
        Jason.encode!(%{
          "aud" => audience,
          "exp" => System.system_time(:second) + @jwt_lifetime,
          "sub" => vapid_contact()
        }),
        padding: false
      )

    signing_input = header <> "." <> claims

    der_signature = :crypto.sign(:ecdsa, :sha256, signing_input, [private_key, :prime256v1])
    raw_signature = der_to_raw_p256(der_signature)

    signature = Base.url_encode64(raw_signature, padding: false)

    signing_input <> "." <> signature
  end

  @doc """
  Builds the VAPID authorization headers for a Web Push request.

  ## Parameters

  - `endpoint` — the full push service endpoint URL
  - `public_key_b64` — base64url-encoded public key
  - `private_key` — raw 32-byte ECDSA private key (decrypted)

  Returns a keyword list of headers.
  """
  def authorization_headers(endpoint, public_key_b64, private_key) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(endpoint)

    audience =
      case {scheme, port} do
        {"https", 443} -> "#{scheme}://#{host}"
        {"https", nil} -> "#{scheme}://#{host}"
        {"http", 80} -> "#{scheme}://#{host}"
        {"http", nil} -> "#{scheme}://#{host}"
        _ -> "#{scheme}://#{host}:#{port}"
      end

    jwt = sign_jwt(audience, private_key)

    [
      {"authorization", "vapid t=#{jwt}, k=#{public_key_b64}"},
      {"ttl", "86400"}
    ]
  end

  # Converts a DER-encoded ECDSA signature to raw r||s format (64 bytes).
  # DER format: 0x30 <len> 0x02 <r_len> <r_bytes> 0x02 <s_len> <s_bytes>
  # Each of r and s must be exactly 32 bytes (left-padded or trimmed).
  defp der_to_raw_p256(der) do
    <<0x30, _total_len, 0x02, r_len, r_bytes::binary-size(r_len), 0x02, s_len,
      s_bytes::binary-size(s_len)>> = der

    r = pad_or_trim_to_32(r_bytes)
    s = pad_or_trim_to_32(s_bytes)

    r <> s
  end

  # Pads with leading zeros or trims leading zero byte to ensure exactly 32 bytes.
  defp pad_or_trim_to_32(bytes) when byte_size(bytes) == 32, do: bytes

  defp pad_or_trim_to_32(bytes) when byte_size(bytes) < 32 do
    :binary.copy(<<0>>, 32 - byte_size(bytes)) <> bytes
  end

  defp pad_or_trim_to_32(<<0, rest::binary>>) when byte_size(rest) == 32, do: rest

  defp pad_or_trim_to_32(bytes) when byte_size(bytes) > 32 do
    # Trim leading zeros until 32 bytes
    trim_leading_zeros(bytes, byte_size(bytes) - 32)
  end

  defp trim_leading_zeros(<<0, rest::binary>>, n) when n > 0, do: trim_leading_zeros(rest, n - 1)
  defp trim_leading_zeros(bytes, _), do: bytes

  defp vapid_contact do
    "mailto:" <> Application.get_env(:baudrate, :vapid_contact, "admin@localhost")
  end
end
