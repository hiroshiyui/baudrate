defmodule Baudrate.Setup.InstallationKey do
  @moduledoc """
  Reads and enforces the `INSTALLATION_KEY` that gates the first-run wizard.

  Between the moment an instance is deployed and the moment setup completes,
  `/setup` will hand admin rights to whoever reaches it first. `INSTALLATION_KEY`
  is the only thing standing in that window, so in production it is **required
  until setup completes**.

  ## Where enforcement happens

  Enforcement deliberately lives at the wizard, not in `config/runtime.exs`.
  `runtime.exs` runs as a `Config.Provider` *before* the Repo starts, so it
  cannot ask whether setup has completed without opening a throwaway database
  connection — and a `raise` there means the node never boots, so a transient
  database outage during a restart would permanently brick the instance. That is
  strictly worse than the hole being closed.

  Instead:

    * `BaudrateWeb.Plugs.EnsureSetup` answers **503** on every browser route
      while setup is incomplete and no key is configured.
    * `BaudrateWeb.SetupLive.mount/3` refuses independently, because the plug
      pipeline does not run for the LiveView websocket.
    * `log_boot_status/0` logs a startup banner. It never raises.

  Once setup is complete, `enforced?/0` no longer matters — an operator may
  remove the key, which `doc/sysop.md` has always told them to do.

  ## Configuration

    * `:installation_key` — the key itself, from `INSTALLATION_KEY`
      (`config/runtime.exs`). An empty string is normalized to `nil`.
    * `:installation_key_enforced?` — `true` in `config/prod.exs`, unset (and so
      `false`) in dev and test, where the wizard is intentionally ungated.
  """

  require Logger

  @doc """
  Returns the configured installation key, or `nil` when unset or blank.

  An empty string is treated as absent — a hand-edited env file containing
  `INSTALLATION_KEY=` must not be read as "the key is the empty string".
  """
  @spec configured_key() :: String.t() | nil
  def configured_key do
    case Application.get_env(:baudrate, :installation_key) do
      key when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  @doc "Returns true when a missing key should block the setup wizard."
  @spec enforced?() :: boolean()
  def enforced? do
    Application.get_env(:baudrate, :installation_key_enforced?, false) == true
  end

  @doc """
  Returns `:ok`, or `{:error, :missing}` when enforcement is on and no key is
  configured.
  """
  @spec status() :: :ok | {:error, :missing}
  def status do
    if enforced?() and is_nil(configured_key()) do
      {:error, :missing}
    else
      :ok
    end
  end

  @doc """
  Constant-time comparison of a submitted key against the configured one.

  Total by design: returns `false` for a non-binary submission and for the case
  where no key is configured. `Plug.Crypto.secure_compare/2` is guarded on two
  binaries, so calling it with a `nil` configured key raises — reachable by
  pushing the `verify_key` event directly over the LiveView socket.
  """
  @spec verify(String.t() | any()) :: boolean()
  def verify(submitted) when is_binary(submitted) do
    case configured_key() do
      nil -> false
      key -> Plug.Crypto.secure_compare(submitted, key)
    end
  end

  def verify(_), do: false

  @doc """
  Logs a startup banner when the wizard is locked by a missing key.

  Never raises: a database error while checking `setup_completed?/0` is logged
  at debug level and ignored, because failing to boot would be worse than the
  missing banner.
  """
  @spec log_boot_status() :: :ok
  def log_boot_status do
    if status() == {:error, :missing} and not Baudrate.Setup.setup_completed?() do
      Logger.error("""
      INSTALLATION_KEY is not set and initial setup has not completed.

      The setup wizard is locked and every browser route will answer 503 until
      a key is configured. Generate one with:

          openssl rand -base64 24

      then set INSTALLATION_KEY in the environment and restart.
      See doc/sysop.md#installation-key.
      """)
    end

    :ok
  rescue
    error ->
      Logger.debug("installation_key.boot_check_skipped: #{Exception.message(error)}")
      :ok
  end
end
