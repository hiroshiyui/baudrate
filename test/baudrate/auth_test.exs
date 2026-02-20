defmodule Baudrate.AuthTest do
  use Baudrate.DataCase

  alias Baudrate.Auth
  alias Baudrate.Setup
  alias Baudrate.Setup.{Role, User}

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user(role_name, opts \\ []) do
    role = Repo.one!(from r in Role, where: r.name == ^role_name)
    username = Keyword.get(opts, :username, "user_#{System.unique_integer([:positive])}")
    password = Keyword.get(opts, :password, "Password123!x")

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

  describe "authenticate_by_password/2" do
    test "returns user with valid credentials" do
      user = create_user("admin", username: "admin_user", password: "SecurePass1!!")
      assert {:ok, authed} = Auth.authenticate_by_password("admin_user", "SecurePass1!!")
      assert authed.id == user.id
      assert authed.role.name == "admin"
    end

    test "returns error with wrong password" do
      create_user("admin", username: "admin2", password: "SecurePass1!!")
      assert {:error, :invalid_credentials} = Auth.authenticate_by_password("admin2", "WrongPass1!!")
    end

    test "returns error with nonexistent username" do
      assert {:error, :invalid_credentials} = Auth.authenticate_by_password("nobody", "WrongPass1!!")
    end
  end

  describe "totp_policy/1" do
    test "admin requires TOTP" do
      assert Auth.totp_policy("admin") == :required
    end

    test "moderator requires TOTP" do
      assert Auth.totp_policy("moderator") == :required
    end

    test "user has optional TOTP" do
      assert Auth.totp_policy("user") == :optional
    end

    test "guest has disabled TOTP" do
      assert Auth.totp_policy("guest") == :disabled
    end
  end

  describe "login_next_step/1" do
    test "returns :totp_verify when TOTP is enabled" do
      user = create_user("user")
      secret = Auth.generate_totp_secret()
      {:ok, user} = Auth.enable_totp(user, secret)
      user = Repo.preload(user, :role)
      assert Auth.login_next_step(user) == :totp_verify
    end

    test "returns :totp_setup for admin without TOTP" do
      user = create_user("admin")
      assert Auth.login_next_step(user) == :totp_setup
    end

    test "returns :totp_setup for moderator without TOTP" do
      user = create_user("moderator")
      assert Auth.login_next_step(user) == :totp_setup
    end

    test "returns :authenticated for user without TOTP" do
      user = create_user("user")
      assert Auth.login_next_step(user) == :authenticated
    end

    test "returns :authenticated for guest" do
      user = create_user("guest")
      assert Auth.login_next_step(user) == :authenticated
    end
  end

  describe "TOTP operations" do
    test "generate_totp_secret returns 20 bytes" do
      secret = Auth.generate_totp_secret()
      assert byte_size(secret) == 20
    end

    test "totp_uri generates valid otpauth URI" do
      secret = Auth.generate_totp_secret()
      uri = Auth.totp_uri(secret, "testuser")
      assert String.starts_with?(uri, "otpauth://totp/Baudrate:testuser")
      assert uri =~ "issuer=Baudrate"
    end

    test "totp_qr_svg generates SVG string" do
      secret = Auth.generate_totp_secret()
      uri = Auth.totp_uri(secret, "testuser")
      svg = Auth.totp_qr_svg(uri)
      assert svg =~ "<svg"
      assert svg =~ "</svg>"
    end

    test "valid_totp? validates correct code" do
      secret = Auth.generate_totp_secret()
      code = NimbleTOTP.verification_code(secret)
      assert Auth.valid_totp?(secret, code)
    end

    test "valid_totp? rejects incorrect code" do
      secret = Auth.generate_totp_secret()
      refute Auth.valid_totp?(secret, "000000")
    end

    test "enable_totp stores encrypted secret and enables TOTP" do
      user = create_user("user")
      secret = Auth.generate_totp_secret()
      {:ok, updated} = Auth.enable_totp(user, secret)
      assert updated.totp_enabled == true
      # Secret is stored encrypted, not plaintext
      assert updated.totp_secret != secret
      # But can be decrypted back
      assert Auth.decrypt_totp_secret(updated) == secret
    end
  end

  describe "get_user/1" do
    test "returns user with role preloaded" do
      user = create_user("admin")
      found = Auth.get_user(user.id)
      assert found.id == user.id
      assert found.role.name == "admin"
    end

    test "returns nil for nonexistent ID" do
      assert Auth.get_user(-1) == nil
    end
  end
end
