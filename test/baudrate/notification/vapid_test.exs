defmodule Baudrate.Notification.VAPIDTest do
  use ExUnit.Case, async: true

  alias Baudrate.Notification.VAPID
  alias Baudrate.Notification.VapidVault

  describe "generate_keypair/0" do
    test "returns a base64url-encoded public key that decodes to 65 bytes" do
      {public_key_b64, _encrypted_private} = VAPID.generate_keypair()

      public_key = Base.url_decode64!(public_key_b64, padding: false)
      assert byte_size(public_key) == 65
      # Uncompressed EC point starts with 0x04
      assert <<0x04, _::binary-64>> = public_key
    end

    test "returns an encrypted private key binary" do
      {_public_key_b64, encrypted_private} = VAPID.generate_keypair()

      assert is_binary(encrypted_private)
      # Encrypted format: 12 (IV) + 16 (tag) + 32 (ciphertext) = 60 bytes
      assert byte_size(encrypted_private) == 60

      # Can be decrypted
      assert {:ok, private_key} = VapidVault.decrypt(encrypted_private)
      assert byte_size(private_key) == 32
    end

    test "generates unique keypairs" do
      {pub1, _priv1} = VAPID.generate_keypair()
      {pub2, _priv2} = VAPID.generate_keypair()
      refute pub1 == pub2
    end
  end

  describe "sign_jwt/2" do
    setup do
      {_public_key_b64, encrypted_private} = VAPID.generate_keypair()
      {:ok, private_key} = VapidVault.decrypt(encrypted_private)
      %{private_key: private_key}
    end

    test "returns a JWT with three base64url segments", %{private_key: private_key} do
      jwt = VAPID.sign_jwt("https://push.example.com", private_key)

      parts = String.split(jwt, ".")
      assert length(parts) == 3

      [header_b64, claims_b64, _sig_b64] = parts
      assert {:ok, _} = Base.url_decode64(header_b64, padding: false)
      assert {:ok, _} = Base.url_decode64(claims_b64, padding: false)
    end

    test "header has alg ES256 and typ JWT", %{private_key: private_key} do
      jwt = VAPID.sign_jwt("https://push.example.com", private_key)

      [header_b64, _, _] = String.split(jwt, ".")
      header = header_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert header["alg"] == "ES256"
      assert header["typ"] == "JWT"
    end

    test "claims have aud, exp, and sub", %{private_key: private_key} do
      jwt = VAPID.sign_jwt("https://push.example.com", private_key)

      [_, claims_b64, _] = String.split(jwt, ".")
      claims = claims_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert claims["aud"] == "https://push.example.com"
      assert is_integer(claims["exp"])
      assert claims["exp"] > System.system_time(:second)
      assert String.starts_with?(claims["sub"], "mailto:")
    end

    test "signature is verifiable with the corresponding public key", %{private_key: _private_key} do
      {public_key_b64, encrypted_private} = VAPID.generate_keypair()
      {:ok, priv} = VapidVault.decrypt(encrypted_private)
      public_key = Base.url_decode64!(public_key_b64, padding: false)

      jwt = VAPID.sign_jwt("https://push.example.com", priv)

      [header_b64, claims_b64, sig_b64] = String.split(jwt, ".")
      signing_input = header_b64 <> "." <> claims_b64
      raw_signature = Base.url_decode64!(sig_b64, padding: false)

      assert byte_size(raw_signature) == 64

      # Convert raw r||s back to DER for verification
      <<r::binary-32, s::binary-32>> = raw_signature
      der_sig = der_encode_p256(r, s)

      assert :crypto.verify(:ecdsa, :sha256, signing_input, der_sig, [public_key, :prime256v1])
    end
  end

  describe "authorization_headers/3" do
    test "returns VAPID authorization and TTL headers" do
      {public_key_b64, encrypted_private} = VAPID.generate_keypair()
      {:ok, private_key} = VapidVault.decrypt(encrypted_private)

      headers =
        VAPID.authorization_headers(
          "https://push.example.com/send/abc123",
          public_key_b64,
          private_key
        )

      assert [{"authorization", auth_value}, {"ttl", "86400"}] = headers
      assert String.starts_with?(auth_value, "vapid t=")
      assert String.contains?(auth_value, ", k=")
    end

    test "extracts correct audience from endpoint URL" do
      {public_key_b64, encrypted_private} = VAPID.generate_keypair()
      {:ok, private_key} = VapidVault.decrypt(encrypted_private)

      headers =
        VAPID.authorization_headers(
          "https://fcm.googleapis.com/fcm/send/abc123",
          public_key_b64,
          private_key
        )

      [{"authorization", auth_value}, _] = headers

      # Extract JWT from header and verify audience
      [_, jwt_and_key] = String.split(auth_value, "vapid t=")
      [jwt, _] = String.split(jwt_and_key, ", k=")
      [_, claims_b64, _] = String.split(jwt, ".")
      claims = claims_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert claims["aud"] == "https://fcm.googleapis.com"
    end
  end

  # Helper to DER-encode r and s for verification
  defp der_encode_p256(r, s) do
    r_int = der_encode_integer(r)
    s_int = der_encode_integer(s)
    content = r_int <> s_int
    <<0x30, byte_size(content)>> <> content
  end

  defp der_encode_integer(bytes) do
    # Strip leading zeros but keep at least one byte
    stripped = strip_leading_zeros(bytes)

    # Add leading zero if high bit is set (to keep positive)
    padded = if :binary.first(stripped) >= 128, do: <<0>> <> stripped, else: stripped

    <<0x02, byte_size(padded)>> <> padded
  end

  defp strip_leading_zeros(<<0, rest::binary>>) when byte_size(rest) > 0,
    do: strip_leading_zeros(rest)

  defp strip_leading_zeros(bytes), do: bytes
end
