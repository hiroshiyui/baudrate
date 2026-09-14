defmodule Baudrate.Auth.WebAuthnChallenges do
  @moduledoc """
  ETS-backed challenge store for WebAuthn registration and authentication.

  WebAuthn challenges are short-lived (60 seconds) and single-use. This
  GenServer maintains a named ETS table mapping random tokens to challenge
  structs. Challenges are keyed by a random token returned to the LiveView,
  which passes it through a hidden form field to the controller.

  A sweeper task runs every 30 seconds to remove expired entries.

  ## Security

  - `pop/3` atomically removes the entry on first retrieval (single-use).
  - Expired entries are never returned, even if the sweeper hasn't run yet.
  - The token is a 16-byte cryptographically random value (base64url encoded).
  - User ID is checked on pop to prevent cross-user challenge reuse.
  - The challenge's purpose (`:attestation` for registration, `:authentication`
    for assertions) is checked on pop. `Wax.register/3` validates the
    *client-supplied* `clientData.type`, but not the stored challenge's type.
    Without this check, an authentication challenge (which `/admin/verify`
    hands to any admin session) could be spent on registering a new key,
    bypassing the re-authentication gate on registration.
  """

  use GenServer

  @table :webauthn_challenges
  @ttl_seconds 60
  @sweep_interval_ms 30_000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores a `Wax.Challenge` struct for the given user and returns a random token.

  The token is used to correlate the browser response back to the stored
  challenge in the controller.
  """
  @spec put(integer(), Wax.Challenge.t()) :: String.t()
  def put(user_id, challenge) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    expires_at = System.system_time(:second) + @ttl_seconds
    :ets.insert(@table, {token, {challenge, user_id, expires_at}})
    token
  end

  @doc """
  Retrieves and atomically removes a challenge by token.

  Returns `{:ok, challenge}` if the token exists, belongs to `user_id`, was
  issued for `type` (`:attestation` or `:authentication`), and has not expired.
  Returns `{:error, :not_found}` otherwise. The entry is consumed even when the
  type does not match, so a token can never be retried for another purpose.
  """
  @spec pop(String.t(), integer(), :attestation | :authentication) ::
          {:ok, Wax.Challenge.t()} | {:error, :not_found}
  def pop(token, user_id, type)
      when is_binary(token) and type in [:attestation, :authentication] do
    case :ets.take(@table, token) do
      [{^token, {%{type: ^type} = challenge, ^user_id, expires_at}}] ->
        if System.system_time(:second) <= expires_at do
          {:ok, challenge}
        else
          {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  def pop(_, _, _), do: {:error, :not_found}

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:second)

    # Erlang match spec uses :"=<" for the less-than-or-equal guard operator
    :ets.select_delete(@table, [
      {{:_, {:_, :_, :"$1"}}, [{:"=<", :"$1", now}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
