defmodule Baudrate.Auth.WebAuthn do
  @moduledoc """
  WebAuthn (FIDO2) credential management, registration, and authentication.

  Wraps the `wax_` library for all relying-party operations. All public
  functions are delegated through `Baudrate.Auth`.

  ## Registration flow

  1. `begin_registration/1` — generates a `Wax.Challenge`, stores it in ETS,
     and returns `{token, creation_options_json}` for the browser.
  2. Browser calls `navigator.credentials.create(options)` and POSTs the result.
  3. `finish_registration/4` — verifies attestation via `Wax.register/3` and
     returns the extracted credential attributes.
  4. `create_webauthn_credential/2` — persists the credential to the DB.

  ## Authentication flow

  1. `begin_authentication/1` — generates a challenge with `allowCredentials`
     populated from the user's enrolled keys.
  2. Browser calls `navigator.credentials.get(options)` and POSTs the result.
  3. `finish_authentication/6` — verifies the assertion via `Wax.authenticate/6`,
     checks the sign count, and updates `sign_count` + `last_used_at`.
  """

  import Ecto.Query
  require Logger

  alias Baudrate.Repo
  alias Baudrate.Auth.{WebAuthnCredential, WebAuthnChallenges}
  alias Baudrate.Setup.User

  # ---------------------------------------------------------------------------
  # CRUD
  # ---------------------------------------------------------------------------

  @doc "Lists all enrolled WebAuthn credentials for a user, ordered by enrolment date."
  @spec list_webauthn_credentials(User.t()) :: [WebAuthnCredential.t()]
  def list_webauthn_credentials(%User{} = user) do
    Repo.all(
      from c in WebAuthnCredential,
        where: c.user_id == ^user.id,
        order_by: [asc: :inserted_at]
    )
  end

  @doc "Returns true if the user has at least one WebAuthn credential enrolled."
  @spec webauthn_enabled?(User.t()) :: boolean()
  def webauthn_enabled?(%User{} = user) do
    Repo.exists?(from c in WebAuthnCredential, where: c.user_id == ^user.id)
  end

  @doc "Persists a new WebAuthn credential for a user."
  @spec create_webauthn_credential(User.t(), map()) ::
          {:ok, WebAuthnCredential.t()} | {:error, Ecto.Changeset.t()}
  def create_webauthn_credential(%User{} = user, attrs) do
    %WebAuthnCredential{user_id: user.id}
    |> WebAuthnCredential.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Deletes a WebAuthn credential by ID, scoped to the owning user.

  Returns `{:ok, credential}` on success or `{:error, :not_found}` if the
  credential does not exist or does not belong to the user.
  """
  @spec delete_webauthn_credential(User.t(), integer()) ::
          {:ok, WebAuthnCredential.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def delete_webauthn_credential(%User{} = user, id) do
    case Repo.get_by(WebAuthnCredential, id: id, user_id: user.id) do
      nil -> {:error, :not_found}
      credential -> Repo.delete(credential)
    end
  end

  # ---------------------------------------------------------------------------
  # Registration
  # ---------------------------------------------------------------------------

  @doc """
  Begins WebAuthn registration for an authenticated user.

  Generates a `Wax.Challenge`, stores it in ETS, and returns
  `{challenge_token, creation_options_json}`. The token is stored in a hidden
  form field and sent back to the controller with the attestation response.
  """
  @spec begin_registration(User.t()) :: {String.t(), String.t()}
  def begin_registration(%User{} = user) do
    challenge =
      Wax.new_registration_challenge(
        origin: origin(),
        rp_id: rp_id()
      )

    token = WebAuthnChallenges.put(user.id, challenge)

    options = %{
      challenge: Base.url_encode64(challenge.bytes, padding: false),
      rp: %{name: "Baudrate", id: rp_id()},
      user: %{
        id: Base.url_encode64(Integer.to_string(user.id), padding: false),
        name: user.username,
        displayName: user.username
      },
      pubKeyCredParams: [
        %{type: "public-key", alg: -7},
        %{type: "public-key", alg: -257}
      ],
      timeout: 60_000,
      attestation: "none",
      authenticatorSelection: %{
        userVerification: "preferred"
      }
    }

    {token, Jason.encode!(options)}
  end

  @doc """
  Verifies a WebAuthn attestation response and extracts credential attributes.

  Called from the controller after the browser POSTs the attestation response.
  Returns `{:ok, attrs}` where `attrs` can be passed to `create_webauthn_credential/2`.
  """
  @spec finish_registration(User.t(), String.t(), String.t(), Wax.Challenge.t()) ::
          {:ok, map()} | {:error, any()}
  def finish_registration(_user, att_obj_b64, cdj_b64, challenge) do
    with {:ok, attestation_object} <- url_decode64(att_obj_b64),
         {:ok, client_data_json} <- url_decode64(cdj_b64) do
      case Wax.register(attestation_object, client_data_json, challenge) do
        {:ok, {authenticator_data, _result}} ->
          {:ok,
           %{
             credential_id: authenticator_data.attested_credential_data.credential_id,
             public_key_cbor:
               CBOR.encode(authenticator_data.attested_credential_data.credential_public_key),
             aaguid: authenticator_data.attested_credential_data.aaguid,
             sign_count: authenticator_data.sign_count
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Authentication
  # ---------------------------------------------------------------------------

  @doc """
  Begins WebAuthn authentication for a user.

  Looks up enrolled credentials, generates a challenge, and returns
  `{challenge_token, request_options_json}`.
  """
  @spec begin_authentication(User.t()) :: {String.t(), String.t()}
  def begin_authentication(%User{} = user) do
    credentials = list_webauthn_credentials(user)

    challenge =
      Wax.new_authentication_challenge(
        origin: origin(),
        rp_id: rp_id()
      )

    token = WebAuthnChallenges.put(user.id, challenge)

    options = %{
      challenge: Base.url_encode64(challenge.bytes, padding: false),
      rpId: rp_id(),
      allowCredentials:
        Enum.map(credentials, fn c ->
          %{type: "public-key", id: Base.url_encode64(c.credential_id, padding: false)}
        end),
      timeout: 60_000,
      userVerification: "preferred"
    }

    {token, Jason.encode!(options)}
  end

  @doc """
  Verifies a WebAuthn assertion response and updates the sign count.

  Returns `{:ok, credential}` on success. Rejects cloned authenticators
  (sign count not advancing), unknown credentials, and invalid signatures.
  """
  @spec finish_authentication(
          User.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          Wax.Challenge.t()
        ) ::
          {:ok, WebAuthnCredential.t()} | {:error, any()}
  def finish_authentication(%User{} = user, cid_b64, ad_b64, cdj_b64, sig_b64, challenge) do
    with {:ok, credential_id} <- url_decode64(cid_b64),
         {:ok, authenticator_data} <- url_decode64(ad_b64),
         {:ok, client_data_json} <- url_decode64(cdj_b64),
         {:ok, signature} <- url_decode64(sig_b64) do
      case Repo.get_by(WebAuthnCredential, credential_id: credential_id, user_id: user.id) do
        nil ->
          {:error, :unknown_credential}

        credential ->
          cred_map = %{credential_id => {decode_public_key(credential.public_key_cbor), credential.sign_count}}

          case Wax.authenticate(
                 credential_id,
                 authenticator_data,
                 signature,
                 client_data_json,
                 cred_map,
                 challenge
               ) do
            {:ok, new_sign_count} ->
              now = DateTime.utc_now() |> DateTime.truncate(:second)

              credential
              |> WebAuthnCredential.update_changeset(%{
                sign_count: new_sign_count,
                last_used_at: now
              })
              |> Repo.update()

            {:error, _} = err ->
              Logger.warning(
                "auth.webauthn_authenticate_failed: user_id=#{user.id} credential_id=#{Base.url_encode64(credential_id, padding: false)}"
              )

              err
          end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp rp_id, do: Application.get_env(:wax_, :rp_id, "localhost")
  defp origin, do: Application.get_env(:wax_, :origin, "https://localhost:4001")

  # Decodes a CBOR-encoded public key back to a Wax.CoseKey.t() map.
  # CBOR byte strings decode to %CBOR.Tag{tag: :bytes, value: <<...>>}; we
  # unwrap those to plain binaries so the map matches the format Wax expects.
  defp decode_public_key(cbor) do
    {:ok, decoded, _rest} = CBOR.decode(cbor)
    reduce_cbor_binaries(decoded)
  end

  defp reduce_cbor_binaries(%CBOR.Tag{tag: :bytes, value: bytes}), do: bytes

  defp reduce_cbor_binaries(%{} = map) do
    Map.new(map, fn {k, v} -> {k, reduce_cbor_binaries(v)} end)
  end

  defp reduce_cbor_binaries([_ | _] = list), do: Enum.map(list, &reduce_cbor_binaries/1)
  defp reduce_cbor_binaries(v), do: v

  defp url_decode64(b64) when is_binary(b64) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :invalid_base64}
    end
  end
end
