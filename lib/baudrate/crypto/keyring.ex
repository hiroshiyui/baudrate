defmodule Baudrate.Crypto.Keyring do
  @moduledoc """
  The keys that protect secrets at rest, and which one is current (ADR 0038).

  Two classes of key material, configured independently so either can be
  rotated without touching the other:

  | Class | Protects | Environment variable |
  |-------|----------|----------------------|
  | `:auth` | TOTP secrets, recovery-code hashes | `BAUDRATE_AUTH_KEYS` |
  | `:signing` | actor private keys, the Web Push VAPID key | `BAUDRATE_SIGNING_KEYS` |

  Each class holds a list of `%{id: id, key: key}`, **current first**, so a
  rotation adds a key at the front and keeps the old one for reading until
  `Baudrate.Release.rotate_keys/1` reports nothing left on it.

  ## Purposes

  A class's key is never used directly. Each purpose derives its own subkey
  from it, so the value that encrypts TOTP secrets is not the value that keys
  the recovery-code HMAC, even though one key configures both:

      subkey = HMAC-SHA256(class key, "baudrate:<purpose>:v1")

  The class key is 32 random bytes, so one HMAC is enough here — this is a
  key-expansion step, not a password hash.

  ## The fallback, and why it writes the old format

  With nothing configured, `current/1` returns the id `"legacy"` and the key
  Baudrate has always used: PBKDF2 over `secret_key_base` with that purpose's
  salt. An instance therefore keeps working across an upgrade with no
  configuration change, and `Baudrate.Crypto.Vault` keeps writing the old
  ciphertext format while the fallback is in use, so a rollback to a release
  without this module can still read everything written meanwhile.

  Explicit keys change that: from then on new values carry their key id and
  are bound to their row, and a release older than ADR 0038 can no longer
  read them. That is the point at which a rollback needs the rotation task
  run backwards, and it is a step the operator takes deliberately.
  """

  require Logger

  @type class :: :auth | :signing
  @type purpose :: :totp | :recovery_code | :federation | :vapid
  @type id :: String.t()

  @legacy_id "legacy"

  # Each purpose's class, the salt its legacy key is derived with, and the
  # constant AAD legacy values were written with. The salts and AAD strings
  # must never change: they are what makes existing rows readable.
  @purposes %{
    totp: %{
      class: :auth,
      legacy_salt: "totp_encryption_key",
      legacy_aad: "Baudrate.Auth.TotpVault"
    },
    recovery_code: %{
      class: :auth,
      legacy_salt: "recovery_code_hmac_key",
      legacy_aad: nil
    },
    federation: %{
      class: :signing,
      legacy_salt: "federation_key_encryption",
      legacy_aad: "Baudrate.Federation.KeyVault"
    },
    vapid: %{
      class: :signing,
      legacy_salt: "vapid_key_encryption",
      legacy_aad: "Baudrate.Notification.VapidVault"
    }
  }

  @doc "The purposes this keyring serves, and the class each belongs to."
  @spec purposes() :: %{purpose() => class()}
  def purposes, do: Map.new(@purposes, fn {purpose, %{class: class}} -> {purpose, class} end)

  @doc "The classes, in a stable order."
  @spec classes() :: [class()]
  def classes, do: [:auth, :signing]

  @doc "The id used for values protected by the `secret_key_base` fallback."
  @spec legacy_id() :: id()
  def legacy_id, do: @legacy_id

  @doc """
  The key a value should be written with now: `{id, key}`.

  Returns `{"legacy", key}` while the purpose's class has no configured keys.
  """
  @spec current(purpose()) :: {id(), binary()}
  def current(purpose) do
    case configured(class_of(purpose)) do
      [%{id: id} = entry | _] -> {id, subkey(entry, purpose)}
      [] -> {@legacy_id, legacy_key(purpose)}
    end
  end

  @doc """
  The key a value written under `id` should be read with.

  Returns `:error` for an id this instance has no key for — the value cannot
  be read, and saying so is better than silently trying the wrong key.
  """
  @spec fetch(purpose(), id()) :: {:ok, binary()} | :error
  def fetch(purpose, id) when is_binary(id) do
    # Configured keys are searched before the `"legacy"` fallback, not after.
    # `runtime.exs` rejects `"legacy"` as a configured id, so the two cannot
    # normally collide — but if the reservation is ever relaxed, an id
    # matching the fallback first would hand back the `secret_key_base`
    # derivation for a value sealed with the configured key, and nothing in
    # the census or the health report would notice: the row's label would
    # equal `current_id`, so rotation would skip it and `unknown?/2` would
    # call it known. Ordering it this way makes that state round-trip
    # instead of silently unreadable.
    case Enum.find(configured(class_of(purpose)), &(&1.id == id)) do
      %{} = entry -> {:ok, subkey(entry, purpose)}
      nil -> fetch_legacy(purpose, id)
    end
  end

  def fetch(_purpose, _id), do: :error

  defp fetch_legacy(purpose, @legacy_id), do: {:ok, legacy_key(purpose)}
  defp fetch_legacy(_purpose, _id), do: :error

  @doc """
  Every key a stored value for this purpose might have been made with:
  the current key, the retired ones, then the `secret_key_base` fallback.

  For the recovery-code HMAC, which cannot be re-keyed without the code
  itself: a code is verified by hashing it under each of these, so codes
  issued under a retired key keep working. Work is the same whatever the
  input, so there is nothing to time.
  """
  @spec candidates(purpose()) :: [binary()]
  def candidates(purpose) do
    configured = Enum.map(configured(class_of(purpose)), &subkey(&1, purpose))

    Enum.uniq(configured ++ [legacy_key(purpose)])
  end

  @doc """
  The ids configured for a class, current first, or `[]` for the fallback.
  """
  @spec configured_ids(class()) :: [id()]
  def configured_ids(class), do: Enum.map(configured(class), & &1.id)

  @doc "Whether a class has keys of its own rather than the fallback."
  @spec separated?(class()) :: boolean()
  def separated?(class), do: configured(class) != []

  @doc "The class a purpose's key material belongs to."
  @spec class_of(purpose()) :: class()
  def class_of(purpose), do: purpose_config(purpose).class

  @doc """
  The AAD legacy values were written with, or `""` for a purpose that has no
  AAD (the recovery-code HMAC covers the code itself).
  """
  @spec legacy_aad(purpose()) :: String.t()
  # `""`, never `nil`: the value goes straight to
  # `:crypto.crypto_one_time_aead/6,7`, which rejects a non-binary AAD with
  # `:badarg`. The recovery-code purpose has no AAD (the HMAC covers the code
  # itself), so routing it through the vault used to raise rather than return
  # `:error` — and the vaults are documented never to raise.
  def legacy_aad(purpose), do: purpose_config(purpose).legacy_aad || ""

  @doc """
  Logs once per class that it is still on the `secret_key_base` fallback.

  Called from `Baudrate.Application.start/2`; the detailed health report says
  the same thing (`Baudrate.Health`), for an operator who is not reading logs.
  """
  @spec warn_unseparated() :: :ok
  def warn_unseparated do
    for class <- classes(), not separated?(class) do
      Logger.warning(
        "crypto.keys_not_separated: the #{class} keys are still derived from SECRET_KEY_BASE, " <>
          "so it cannot be rotated. See doc/sysop.md, \"Rotating an encryption key\"."
      )
    end

    :ok
  end

  # --- key material ---

  defp configured(class) do
    Application.get_env(:baudrate, __MODULE__, [])
    |> Keyword.get(key_option(class), [])
  end

  defp key_option(:auth), do: :auth_keys
  defp key_option(:signing), do: :signing_keys

  defp purpose_config(purpose) do
    case Map.fetch(@purposes, purpose) do
      {:ok, config} -> config
      :error -> raise ArgumentError, "unknown key purpose: #{inspect(purpose)}"
    end
  end

  # Key expansion, cached: the class key is already 32 random bytes.
  defp subkey(%{id: id, key: key}, purpose) do
    cached({:subkey, purpose, id, :erlang.phash2(key)}, fn ->
      :crypto.mac(:hmac, :sha256, key, "baudrate:#{purpose}:v1")
    end)
  end

  # The fallback key, cached: PBKDF2 over secret_key_base, 1000 iterations,
  # which every vault call used to redo.
  defp legacy_key(purpose) do
    salt = purpose_config(purpose).legacy_salt
    secret_key_base = Application.get_env(:baudrate, BaudrateWeb.Endpoint)[:secret_key_base]

    cached({:legacy, purpose, :erlang.phash2(secret_key_base)}, fn ->
      Plug.Crypto.KeyGenerator.generate(secret_key_base, salt, length: 32)
    end)
  end

  defp cached(key, compute) do
    case :persistent_term.get({__MODULE__, key}, nil) do
      nil ->
        value = compute.()
        :persistent_term.put({__MODULE__, key}, value)
        value

      value ->
        value
    end
  end
end
