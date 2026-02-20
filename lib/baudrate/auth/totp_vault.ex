defmodule Baudrate.Auth.TotpVault do
  @moduledoc """
  Encrypts and decrypts TOTP secrets using AES-256-GCM.

  The encryption key is derived from the application's secret_key_base
  using HKDF, ensuring TOTP secrets are protected at rest.
  """

  @aad "Baudrate.Auth.TotpVault"

  @doc """
  Encrypts a binary TOTP secret. Returns a binary containing
  the IV, ciphertext, and authentication tag.
  """
  def encrypt(plaintext) when is_binary(plaintext) do
    key = derive_key()
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)

    iv <> tag <> ciphertext
  end

  @doc """
  Decrypts an encrypted TOTP secret. Returns `{:ok, plaintext}` or `:error`.
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

    Plug.Crypto.KeyGenerator.generate(secret_key_base, "totp_encryption_key", length: 32)
  end
end
