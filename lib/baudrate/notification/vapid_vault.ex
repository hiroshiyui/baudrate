defmodule Baudrate.Notification.VapidVault do
  @moduledoc """
  Encrypts and decrypts the Web Push VAPID private key with AES-256-GCM.

  The key comes from `Baudrate.Crypto.Keyring`'s `:signing` class
  (`BAUDRATE_SIGNING_KEYS`), the same class as the ActivityPub actor keys:
  both are instance signing material, whose loss breaks what remote parties
  expect (signature checks, push subscriptions) rather than a member's own
  access. While that class has no keys of its own the value is protected by
  `secret_key_base`, as before (ADR 0038).

  There is one VAPID key per instance, in the `vapid_private_key_encrypted`
  setting, so the value is bound to that settings row.
  """

  alias Baudrate.Crypto.Vault

  @purpose :vapid

  @setting "vapid_private_key_encrypted"

  @doc "Encrypts the VAPID private key."
  @spec encrypt(binary()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    Vault.encrypt(@purpose, plaintext, {:setting, @setting})
  end

  @doc """
  Decrypts the stored VAPID private key.

  Returns `{:ok, private_key}` or `:error`.
  """
  @spec decrypt(binary() | any()) :: {:ok, binary()} | :error
  def decrypt(blob), do: Vault.decrypt(@purpose, blob, {:setting, @setting})

  @doc "The settings key the VAPID private key is stored under."
  @spec setting() :: String.t()
  def setting, do: @setting
end
