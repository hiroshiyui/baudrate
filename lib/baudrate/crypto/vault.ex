defmodule Baudrate.Crypto.Vault do
  @moduledoc """
  AES-256-GCM for the secrets Baudrate stores (ADR 0038).

  One implementation, used through the three named vaults
  (`Baudrate.Auth.TotpVault`, `Baudrate.Federation.KeyVault`,
  `Baudrate.Notification.VapidVault`) so call sites keep reading as what they
  protect.

  ## Two formats

  With explicit keys configured (`Baudrate.Crypto.Keyring`), a value is
  written self-describing:

      "BK1" | id_len(1) | key_id | iv(12) | tag(16) | ciphertext

  The key id says which key to read it with, so a rotation can leave old and
  new values side by side, and the header is authenticated along with the
  purpose and the row the value belongs to.

  While the keyring is on the `secret_key_base` fallback, values are written
  in the old format instead —

      iv(12) | tag(16) | ciphertext

  — with the constant AAD Baudrate has always used. An upgrade therefore
  changes nothing on disk, and a rollback can still read what was written in
  between. Decryption accepts both formats forever: `"BK1"` is parsed first,
  and anything else, or a `"BK1"` header that fails to authenticate, is read
  as the old format.

  ## Bound to its row

  A value written in the new format is authenticated against its owner
  (`{:user, id}`, `{:board, id}`, `{:setting, key}`), so a ciphertext copied
  into another row no longer decrypts. Old-format values are bound only to
  their vault, as before, which is one more reason to rotate.
  """

  alias Baudrate.Crypto.Keyring

  @magic "BK1"
  @iv_bytes 12
  @tag_bytes 16

  @type context :: {:user, integer()} | {:board, integer()} | {:setting, String.t()}

  @doc """
  Encrypts `plaintext` for `purpose`, bound to `context`.

  Returns the stored binary. Raises only if `plaintext` is not a binary.
  """
  @spec encrypt(Keyring.purpose(), binary(), context()) :: binary()
  def encrypt(purpose, plaintext, context) when is_binary(plaintext) do
    {id, key} = Keyring.current(purpose)
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    if id == Keyring.legacy_id() do
      {ciphertext, tag} = seal(key, iv, plaintext, Keyring.legacy_aad(purpose))
      iv <> tag <> ciphertext
    else
      header = @magic <> <<byte_size(id)::8>> <> id
      {ciphertext, tag} = seal(key, iv, plaintext, aad(header, purpose, context))
      header <> iv <> tag <> ciphertext
    end
  end

  @doc """
  Decrypts a value written by `encrypt/3`.

  Returns `{:ok, plaintext}`, or `:error` for a value that fails
  authentication, was written under a key this instance does not have, or is
  not a ciphertext at all.
  """
  @spec decrypt(Keyring.purpose(), binary(), context()) :: {:ok, binary()} | :error
  def decrypt(purpose, blob, context) when is_binary(blob) do
    case decrypt_current(purpose, blob, context) do
      {:ok, plaintext} -> {:ok, plaintext}
      :error -> decrypt_legacy(purpose, blob)
    end
  end

  def decrypt(_purpose, _blob, _context), do: :error

  @doc """
  The id of the key a stored value was written with.

  `{:ok, "legacy"}` for an old-format value, so a census can count what is
  still protected by the `secret_key_base` fallback.
  """
  @spec key_id(binary()) :: {:ok, Keyring.id()} | :error
  def key_id(<<@magic, id_len::8, rest::binary>>) when id_len > 0 do
    case rest do
      <<id::binary-size(id_len), body::binary>> when byte_size(body) >= @iv_bytes + @tag_bytes ->
        {:ok, id}

      _ ->
        :error
    end
  end

  def key_id(blob) when is_binary(blob) and byte_size(blob) > @iv_bytes + @tag_bytes,
    do: {:ok, Keyring.legacy_id()}

  def key_id(_), do: :error

  # --- internals ---

  defp decrypt_current(purpose, <<@magic, id_len::8, rest::binary>>, context)
       when id_len > 0 do
    with <<id::binary-size(id_len), iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes),
           ciphertext::binary>> <- rest,
         {:ok, key} <- Keyring.fetch(purpose, id) do
      header = @magic <> <<id_len::8>> <> id
      open(key, iv, ciphertext, aad(header, purpose, context), tag)
    else
      _ -> :error
    end
  end

  defp decrypt_current(_purpose, _blob, _context), do: :error

  defp decrypt_legacy(
         purpose,
         <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>
       ) do
    {:ok, key} = Keyring.fetch(purpose, Keyring.legacy_id())
    open(key, iv, ciphertext, Keyring.legacy_aad(purpose), tag)
  end

  defp decrypt_legacy(_purpose, _blob), do: :error

  defp seal(key, iv, plaintext, aad) do
    :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, true)
  end

  defp open(key, iv, ciphertext, aad, tag) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end

  defp aad(header, purpose, context) do
    header <> "|" <> Atom.to_string(purpose) <> "|" <> owner(context)
  end

  defp owner({:user, id}) when is_integer(id), do: "user:#{id}"
  defp owner({:board, id}) when is_integer(id), do: "board:#{id}"
  defp owner({:setting, key}) when is_binary(key), do: "setting:#{key}"
end
