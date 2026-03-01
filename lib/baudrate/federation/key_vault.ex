defmodule Baudrate.Federation.KeyVault do
  @moduledoc """
  Encrypts and decrypts federation actor private keys using AES-256-GCM.

  The encryption key is derived from the application's `secret_key_base`
  via `Plug.Crypto.KeyGenerator` (PBKDF2) with the salt
  `"federation_key_encryption"`, producing a 32-byte AES-256 key.

  ## Storage Format

  The encrypted blob is a single binary:

      <<iv::12-bytes, tag::16-bytes, ciphertext::rest>>

    * **IV** — 12-byte random nonce, generated fresh for each encryption
    * **Tag** — 16-byte GCM authentication tag
    * **Ciphertext** — the encrypted PEM-encoded private key

  ## Additional Authenticated Data (AAD)

  The string `"Baudrate.Federation.KeyVault"` is used as AAD. This binds the
  ciphertext to this specific module, preventing ciphertext from being valid
  if decrypted by a different context using the same key.

  ## SECRET_KEY_BASE Dependency

  Changing `SECRET_KEY_BASE` invalidates **all** stored federation private
  keys — federation will break until keys are rotated via the admin panel.
  See the "SECRET_KEY_BASE — critical warning" section in `doc/sysop.md`.
  """

  @aad "Baudrate.Federation.KeyVault"

  @doc """
  Encrypts a binary private key PEM using AES-256-GCM.

  Returns a single binary in the format `<<iv::12, tag::16, ciphertext::rest>>`.
  A fresh 12-byte IV is generated for each call.
  """
  def encrypt(plaintext) when is_binary(plaintext) do
    key = derive_key()
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)

    iv <> tag <> ciphertext
  end

  @doc """
  Decrypts an encrypted private key previously produced by `encrypt/1`.

  Pattern-matches the `<<iv::12, tag::16, ciphertext::rest>>` format and
  verifies the AAD. Returns `{:ok, plaintext}` on success or `:error` if
  decryption or authentication fails (e.g., wrong key, tampered data).
  """
  def decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>) do
    key = derive_key()

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end

  def decrypt(_), do: :error

  defp derive_key do
    secret_key_base =
      Application.get_env(:baudrate, BaudrateWeb.Endpoint)[:secret_key_base]

    Plug.Crypto.KeyGenerator.generate(secret_key_base, "federation_key_encryption", length: 32)
  end
end
