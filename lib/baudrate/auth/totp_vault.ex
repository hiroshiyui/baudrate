defmodule Baudrate.Auth.TotpVault do
  @moduledoc """
  Encrypts and decrypts TOTP secrets with AES-256-GCM.

  The key comes from `Baudrate.Crypto.Keyring`'s `:auth` class
  (`BAUDRATE_AUTH_KEYS`), or from `secret_key_base` while that class has no
  keys of its own (ADR 0038). `Baudrate.Crypto.Vault` holds the format and
  the cipher; this module fixes the purpose and binds each secret to the
  member it belongs to, so a secret copied into another member's row does not
  decrypt.

  A secret that cannot be read comes back as `:error`, never as an exception:
  a member is told their code is wrong, and the rest of the site keeps
  working. `Baudrate.Health`'s `encryption_keys` check is what reports a key
  that configuration no longer has.
  """

  alias Baudrate.Crypto.Vault

  @purpose :totp

  @doc """
  Encrypts a TOTP secret for `owner` (a user struct or a user id).
  """
  @spec encrypt(binary(), map() | integer()) :: binary()
  def encrypt(plaintext, owner) when is_binary(plaintext) do
    Vault.encrypt(@purpose, plaintext, context(owner))
  end

  @doc """
  Decrypts a stored TOTP secret belonging to `owner`.

  Returns `{:ok, secret}` or `:error`.
  """
  @spec decrypt(binary() | any(), map() | integer()) :: {:ok, binary()} | :error
  def decrypt(blob, owner), do: Vault.decrypt(@purpose, blob, context(owner))

  defp context(%{id: id}) when is_integer(id), do: {:user, id}
  defp context(id) when is_integer(id), do: {:user, id}
end
