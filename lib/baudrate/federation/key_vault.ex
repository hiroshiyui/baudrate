defmodule Baudrate.Federation.KeyVault do
  @moduledoc """
  Encrypts and decrypts ActivityPub actor private keys with AES-256-GCM.

  The key comes from `Baudrate.Crypto.Keyring`'s `:signing` class
  (`BAUDRATE_SIGNING_KEYS`), or from `secret_key_base` while that class has no
  keys of its own (ADR 0038). `Baudrate.Crypto.Vault` holds the format and
  the cipher; this module fixes the purpose and binds each key to its actor —
  a user, a board, or the site's settings row — so an actor's private key
  cannot be moved onto another actor.

  `Baudrate.Federation.KeyStore` is the only caller: it is where keypairs are
  generated, stored and read back.
  """

  alias Baudrate.Crypto.Vault

  @purpose :federation

  @site_setting "ap_site_private_key_encrypted"

  @doc """
  Encrypts a private key PEM for `owner`: a user or board struct, or `:site`.
  """
  @spec encrypt(binary(), map() | :site) :: binary()
  def encrypt(plaintext, owner) when is_binary(plaintext) do
    Vault.encrypt(@purpose, plaintext, context(owner))
  end

  @doc """
  Decrypts a stored private key PEM belonging to `owner`.

  Returns `{:ok, private_pem}` or `:error`.
  """
  @spec decrypt(binary() | any(), map() | :site) :: {:ok, binary()} | :error
  def decrypt(blob, owner), do: Vault.decrypt(@purpose, blob, context(owner))

  @doc "The settings key the site actor's private key is stored under."
  @spec site_setting() :: String.t()
  def site_setting, do: @site_setting

  defp context(:site), do: {:setting, @site_setting}
  defp context(%Baudrate.Setup.User{id: id}), do: {:user, id}
  defp context(%Baudrate.Content.Board{id: id}), do: {:board, id}
end
