defmodule Baudrate.Auth.RecoveryContactVault do
  @moduledoc """
  Encrypts and decrypts a member's recovery email address with AES-256-GCM.

  The key comes from `Baudrate.Crypto.Keyring`'s `:auth` class
  (`BAUDRATE_AUTH_KEYS`), or from `secret_key_base` while that class has no
  keys of its own (ADR 0038). `Baudrate.Crypto.Vault` holds the format and the
  cipher; this module fixes the purpose and binds each address to the member it
  belongs to, so a row copied into another member's account does not decrypt.

  **Why an address is encrypted at all** (ADR 0058): this is a pseudonymous
  forum, and the recovery contact is the one column that links an account to a
  real-world identity. A database leak must not hand that over. The OpenPGP
  public key stored beside it is published material and stays readable — it is
  the *binding* that is secret here, not the key.

  An address that cannot be read comes back as `:error`, never as an exception,
  so a key problem shows up as a contact an admin cannot verify rather than as
  a 500. `Baudrate.Health`'s `encryption_keys` check reports a key that
  configuration no longer has.
  """

  alias Baudrate.Crypto.Vault

  @purpose :recovery_contact

  @doc """
  Encrypts a recovery address for `owner` (a user struct or a user id).
  """
  @spec encrypt(binary(), map() | integer()) :: binary()
  def encrypt(plaintext, owner) when is_binary(plaintext) do
    Vault.encrypt(@purpose, plaintext, context(owner))
  end

  @doc """
  Decrypts a stored recovery address belonging to `owner`.

  Returns `{:ok, address}` or `:error`.
  """
  @spec decrypt(binary() | any(), map() | integer()) :: {:ok, binary()} | :error
  def decrypt(blob, owner), do: Vault.decrypt(@purpose, blob, context(owner))

  defp context(%{id: id}) when is_integer(id), do: {:user, id}
  defp context(id) when is_integer(id), do: {:user, id}

  # An unpersisted user has `id: nil`. `Vault` turns an unrecognised context
  # into `:error` on decrypt and a clear raise on encrypt, so hand it through
  # rather than matching here — the invariant lives in one place.
  defp context(other), do: {:invalid, other}
end
