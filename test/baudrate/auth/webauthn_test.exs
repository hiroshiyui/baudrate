defmodule Baudrate.Auth.WebAuthnTest do
  use Baudrate.DataCase, async: true

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Auth.WebAuthnChallenges
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.{Role, User}

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Setup helpers
  # ---------------------------------------------------------------------------

  defp create_user(role_name \\ "user") do
    role = Repo.one!(from r in Role, where: r.name == ^role_name)
    username = "user_#{System.unique_integer([:positive])}"
    password = "Password123!x"

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => username,
        "password" => password,
        "password_confirmation" => password,
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp build_credential_attrs do
    %{
      credential_id: :crypto.strong_rand_bytes(32),
      public_key_cbor: CBOR.encode(%{1 => 2, -2 => :crypto.strong_rand_bytes(32)}),
      sign_count: 0,
      label: "Test Key"
    }
  end

  # ---------------------------------------------------------------------------
  # webauthn_enabled?/1
  # ---------------------------------------------------------------------------

  describe "webauthn_enabled?/1" do
    test "returns false when no credentials enrolled" do
      user = create_user()
      refute Auth.webauthn_enabled?(user)
    end

    test "returns true after enrolling a credential" do
      user = create_user()
      {:ok, _} = Auth.create_webauthn_credential(user, build_credential_attrs())
      assert Auth.webauthn_enabled?(user)
    end
  end

  # ---------------------------------------------------------------------------
  # list_webauthn_credentials/1
  # ---------------------------------------------------------------------------

  describe "list_webauthn_credentials/1" do
    test "returns empty list when no credentials" do
      user = create_user()
      assert [] == Auth.list_webauthn_credentials(user)
    end

    test "returns credentials ordered by inserted_at" do
      user = create_user()

      attrs1 = %{
        build_credential_attrs()
        | credential_id: :crypto.strong_rand_bytes(32),
          label: "Key 1"
      }

      attrs2 = %{
        build_credential_attrs()
        | credential_id: :crypto.strong_rand_bytes(32),
          label: "Key 2"
      }

      {:ok, c1} = Auth.create_webauthn_credential(user, attrs1)
      {:ok, c2} = Auth.create_webauthn_credential(user, attrs2)

      ids = Auth.list_webauthn_credentials(user) |> Enum.map(& &1.id)
      assert ids == [c1.id, c2.id]
    end
  end

  # ---------------------------------------------------------------------------
  # create_webauthn_credential/2
  # ---------------------------------------------------------------------------

  describe "create_webauthn_credential/2" do
    test "creates a credential with valid attrs" do
      user = create_user()
      attrs = build_credential_attrs()
      assert {:ok, cred} = Auth.create_webauthn_credential(user, attrs)
      assert cred.user_id == user.id
      assert cred.credential_id == attrs.credential_id
      assert cred.sign_count == 0
      assert cred.label == "Test Key"
    end

    test "rejects duplicate credential_id" do
      user = create_user()
      attrs = build_credential_attrs()
      {:ok, _} = Auth.create_webauthn_credential(user, attrs)
      assert {:error, changeset} = Auth.create_webauthn_credential(user, attrs)
      assert %{credential_id: [_]} = errors_on(changeset)
    end

    test "rejects missing credential_id" do
      user = create_user()
      attrs = Map.delete(build_credential_attrs(), :credential_id)
      assert {:error, changeset} = Auth.create_webauthn_credential(user, attrs)
      assert %{credential_id: [_]} = errors_on(changeset)
    end
  end

  # ---------------------------------------------------------------------------
  # delete_webauthn_credential/2
  # ---------------------------------------------------------------------------

  describe "delete_webauthn_credential/2" do
    test "deletes own credential" do
      user = create_user()
      {:ok, cred} = Auth.create_webauthn_credential(user, build_credential_attrs())
      assert {:ok, _} = Auth.delete_webauthn_credential(user, cred.id)
      assert [] == Auth.list_webauthn_credentials(user)
    end

    test "returns error for non-existent id" do
      user = create_user()
      assert {:error, :not_found} = Auth.delete_webauthn_credential(user, 0)
    end

    test "cannot delete another user's credential" do
      user = create_user()
      other_user = create_user()
      {:ok, cred} = Auth.create_webauthn_credential(other_user, build_credential_attrs())
      assert {:error, :not_found} = Auth.delete_webauthn_credential(user, cred.id)
    end
  end

  # ---------------------------------------------------------------------------
  # begin_registration/1
  # ---------------------------------------------------------------------------

  describe "begin_registration/1" do
    test "returns a token and JSON creation options" do
      user = create_user()
      {token, json} = Auth.begin_registration(user)

      assert is_binary(token) and byte_size(token) > 0
      options = Jason.decode!(json)
      assert is_binary(options["challenge"])
      assert options["rp"]["id"] == "localhost"
      assert options["rp"]["name"] == "Baudrate"
      assert options["user"]["name"] == user.username
      assert is_list(options["pubKeyCredParams"])
      assert options["attestation"] == "none"
    end

    test "stores the Wax.Challenge in ETS under the returned token" do
      user = create_user()
      {token, _json} = Auth.begin_registration(user)

      assert {:ok, %Wax.Challenge{type: :attestation}} = WebAuthnChallenges.pop(token, user.id)
    end

    test "challenge token is single-use" do
      user = create_user()
      {token, _json} = Auth.begin_registration(user)

      assert {:ok, _} = WebAuthnChallenges.pop(token, user.id)
      assert {:error, :not_found} = WebAuthnChallenges.pop(token, user.id)
    end
  end

  # ---------------------------------------------------------------------------
  # begin_authentication/1
  # ---------------------------------------------------------------------------

  describe "begin_authentication/1" do
    test "returns a token and JSON request options" do
      user = create_user()
      {token, json} = Auth.begin_authentication(user)

      assert is_binary(token) and byte_size(token) > 0
      options = Jason.decode!(json)
      assert is_binary(options["challenge"])
      assert options["rpId"] == "localhost"
      assert is_list(options["allowCredentials"])
      assert options["userVerification"] == "preferred"
    end

    test "allowCredentials is empty when no keys enrolled" do
      user = create_user()
      {_token, json} = Auth.begin_authentication(user)

      options = Jason.decode!(json)
      assert options["allowCredentials"] == []
    end

    test "allowCredentials lists enrolled credential IDs" do
      user = create_user()
      attrs = build_credential_attrs()
      {:ok, cred} = Auth.create_webauthn_credential(user, attrs)

      {_token, json} = Auth.begin_authentication(user)
      options = Jason.decode!(json)

      credential_ids = Enum.map(options["allowCredentials"], & &1["id"])
      expected_id = Base.url_encode64(cred.credential_id, padding: false)
      assert expected_id in credential_ids
    end

    test "stores an authentication Wax.Challenge in ETS" do
      user = create_user()
      {token, _json} = Auth.begin_authentication(user)

      assert {:ok, %Wax.Challenge{type: :authentication}} = WebAuthnChallenges.pop(token, user.id)
    end
  end

  # ---------------------------------------------------------------------------
  # finish_registration/4
  # ---------------------------------------------------------------------------

  describe "finish_registration/4" do
    test "returns error for invalid base64 attestation_object" do
      user = create_user()
      challenge = Wax.new_registration_challenge(origin: "http://localhost", rp_id: "localhost")

      assert {:error, :invalid_base64} =
               Auth.finish_registration(user, "not!!valid!!base64", "dGVzdA", challenge)
    end

    test "returns error for invalid base64 client_data_json" do
      user = create_user()
      challenge = Wax.new_registration_challenge(origin: "http://localhost", rp_id: "localhost")

      assert {:error, :invalid_base64} =
               Auth.finish_registration(user, "dGVzdA", "not!!valid!!base64", challenge)
    end
  end

  # ---------------------------------------------------------------------------
  # finish_authentication/6
  # ---------------------------------------------------------------------------

  describe "finish_authentication/6" do
    test "returns :unknown_credential when credential not in DB" do
      user = create_user()
      challenge = Wax.new_authentication_challenge(origin: "http://localhost", rp_id: "localhost")

      cid_b64 = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      assert {:error, :unknown_credential} =
               Auth.finish_authentication(
                 user,
                 cid_b64,
                 Base.url_encode64("auth_data", padding: false),
                 Base.url_encode64("client_data", padding: false),
                 Base.url_encode64("signature", padding: false),
                 challenge
               )
    end

    test "returns :unknown_credential for another user's enrolled credential" do
      user = create_user()
      other_user = create_user()
      {:ok, cred} = Auth.create_webauthn_credential(other_user, build_credential_attrs())

      challenge = Wax.new_authentication_challenge(origin: "http://localhost", rp_id: "localhost")
      cid_b64 = Base.url_encode64(cred.credential_id, padding: false)

      assert {:error, :unknown_credential} =
               Auth.finish_authentication(
                 user,
                 cid_b64,
                 Base.url_encode64("auth_data", padding: false),
                 Base.url_encode64("client_data", padding: false),
                 Base.url_encode64("signature", padding: false),
                 challenge
               )
    end

    test "returns error for invalid base64 credential_id" do
      user = create_user()
      challenge = Wax.new_authentication_challenge(origin: "http://localhost", rp_id: "localhost")

      assert {:error, :invalid_base64} =
               Auth.finish_authentication(
                 user,
                 "not!!valid!!base64",
                 "dGVzdA",
                 "dGVzdA",
                 "dGVzdA",
                 challenge
               )
    end
  end

  # ---------------------------------------------------------------------------
  # WebAuthnChallenges
  # ---------------------------------------------------------------------------

  describe "WebAuthnChallenges" do
    test "pop succeeds once and returns error on second attempt" do
      user = create_user()
      challenge = %{bytes: :crypto.strong_rand_bytes(32), type: :attestation}
      token = WebAuthnChallenges.put(user.id, challenge)

      assert {:ok, ^challenge} = WebAuthnChallenges.pop(token, user.id)
      assert {:error, :not_found} = WebAuthnChallenges.pop(token, user.id)
    end

    test "pop returns error for wrong user_id" do
      user = create_user()
      challenge = %{bytes: :crypto.strong_rand_bytes(32), type: :attestation}
      token = WebAuthnChallenges.put(user.id, challenge)

      assert {:error, :not_found} = WebAuthnChallenges.pop(token, user.id + 999_999)
    end

    test "pop returns error for unknown token" do
      user = create_user()
      assert {:error, :not_found} = WebAuthnChallenges.pop("nonexistent_token_abc123", user.id)
    end

    test "expired entries are not returned" do
      user = create_user()
      # Insert an entry with a past expiry directly into ETS
      expired_at = System.system_time(:second) - 10
      token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      challenge = %{bytes: :crypto.strong_rand_bytes(32)}
      :ets.insert(:webauthn_challenges, {token, {challenge, user.id, expired_at}})

      assert {:error, :not_found} = WebAuthnChallenges.pop(token, user.id)
    end
  end
end
