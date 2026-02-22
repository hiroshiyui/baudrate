defmodule Baudrate.Federation.KeyStoreTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Federation.KeyStore
  alias Baudrate.Federation.KeyVault
  alias Baudrate.Setup.Setting

  describe "generate_keypair/0" do
    test "returns a tuple of {public_pem, private_pem}" do
      {public_pem, private_pem} = KeyStore.generate_keypair()

      assert is_binary(public_pem)
      assert is_binary(private_pem)
      assert public_pem =~ "BEGIN PUBLIC KEY"
      assert private_pem =~ "BEGIN RSA PRIVATE KEY"
    end

    test "generates unique keypairs" do
      {pub1, _priv1} = KeyStore.generate_keypair()
      {pub2, _priv2} = KeyStore.generate_keypair()
      refute pub1 == pub2
    end

    test "public key can be decoded" do
      {public_pem, _private_pem} = KeyStore.generate_keypair()
      [entry] = :public_key.pem_decode(public_pem)
      public_key = :public_key.pem_entry_decode(entry)
      assert {:RSAPublicKey, _, _} = public_key
    end
  end

  describe "ensure_user_keypair/1" do
    test "generates keypair for user without keys" do
      user = setup_user_with_role("user")
      assert is_nil(user.ap_public_key)

      {:ok, updated} = KeyStore.ensure_user_keypair(user)
      assert updated.ap_public_key =~ "BEGIN PUBLIC KEY"
      assert is_binary(updated.ap_private_key_encrypted)

      # Verify decryption round-trip
      {:ok, private_pem} = KeyVault.decrypt(updated.ap_private_key_encrypted)
      assert private_pem =~ "BEGIN RSA PRIVATE KEY"
    end

    test "returns existing user if keys already present" do
      user = setup_user_with_role("user")
      {:ok, with_keys} = KeyStore.ensure_user_keypair(user)
      {:ok, same} = KeyStore.ensure_user_keypair(with_keys)

      assert same.ap_public_key == with_keys.ap_public_key
      assert same.ap_private_key_encrypted == with_keys.ap_private_key_encrypted
    end
  end

  describe "ensure_board_keypair/1" do
    test "generates keypair for board without keys" do
      board = setup_board()
      assert is_nil(board.ap_public_key)

      {:ok, updated} = KeyStore.ensure_board_keypair(board)
      assert updated.ap_public_key =~ "BEGIN PUBLIC KEY"
      assert is_binary(updated.ap_private_key_encrypted)
    end

    test "returns existing board if keys already present" do
      board = setup_board()
      {:ok, with_keys} = KeyStore.ensure_board_keypair(board)
      {:ok, same} = KeyStore.ensure_board_keypair(with_keys)

      assert same.ap_public_key == with_keys.ap_public_key
    end
  end

  describe "ensure_site_keypair/0" do
    test "generates and stores site keypair in settings" do
      {:ok, %{public_pem: pem}} = KeyStore.ensure_site_keypair()
      assert pem =~ "BEGIN PUBLIC KEY"

      # Verify stored in settings
      stored = Repo.one(from s in Setting, where: s.key == "ap_site_public_key", select: s.value)
      assert stored == pem

      encrypted_b64 =
        Repo.one(
          from s in Setting, where: s.key == "ap_site_private_key_encrypted", select: s.value
        )

      assert is_binary(encrypted_b64)
      {:ok, encrypted} = Base.decode64(encrypted_b64)
      {:ok, private_pem} = KeyVault.decrypt(encrypted)
      assert private_pem =~ "BEGIN RSA PRIVATE KEY"
    end

    test "returns existing keypair if already present" do
      {:ok, %{public_pem: pem1}} = KeyStore.ensure_site_keypair()
      {:ok, %{public_pem: pem2}} = KeyStore.ensure_site_keypair()
      assert pem1 == pem2
    end
  end

  describe "decrypt_private_key/1" do
    test "decrypts user private key" do
      user = setup_user_with_role("user")
      {:ok, user} = KeyStore.ensure_user_keypair(user)
      {:ok, pem} = KeyStore.decrypt_private_key(user)
      assert pem =~ "BEGIN RSA PRIVATE KEY"
    end

    test "returns :error for user without encrypted key" do
      user = setup_user_with_role("user")
      assert :error = KeyStore.decrypt_private_key(user)
    end
  end

  describe "rotate_user_keypair/1" do
    test "replaces user keypair with new keys" do
      user = setup_user_with_role("user")
      {:ok, user} = KeyStore.ensure_user_keypair(user)
      old_public = user.ap_public_key

      {:ok, rotated} = KeyStore.rotate_user_keypair(user)
      assert rotated.ap_public_key =~ "BEGIN PUBLIC KEY"
      refute rotated.ap_public_key == old_public
      assert is_binary(rotated.ap_private_key_encrypted)

      {:ok, pem} = KeyStore.decrypt_private_key(rotated)
      assert pem =~ "BEGIN RSA PRIVATE KEY"
    end
  end

  describe "rotate_board_keypair/1" do
    test "replaces board keypair with new keys" do
      board = setup_board()
      {:ok, board} = KeyStore.ensure_board_keypair(board)
      old_public = board.ap_public_key

      {:ok, rotated} = KeyStore.rotate_board_keypair(board)
      assert rotated.ap_public_key =~ "BEGIN PUBLIC KEY"
      refute rotated.ap_public_key == old_public
    end
  end

  describe "rotate_site_keypair/0" do
    test "replaces site keypair with new keys" do
      {:ok, %{public_pem: old_pem}} = KeyStore.ensure_site_keypair()
      {:ok, %{public_pem: new_pem}} = KeyStore.rotate_site_keypair()

      assert new_pem =~ "BEGIN PUBLIC KEY"
      refute new_pem == old_pem

      {:ok, private_pem} = KeyStore.decrypt_site_private_key()
      assert private_pem =~ "BEGIN RSA PRIVATE KEY"
    end
  end

  # --- Test Helpers ---

  defp setup_user_with_role(role_name) do
    alias Baudrate.Setup
    alias Baudrate.Setup.{Role, User}

    unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    role = Repo.one!(from(r in Role, where: r.name == ^role_name))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "ks_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp setup_board do
    alias Baudrate.Content.Board

    {:ok, board} =
      %Board{}
      |> Board.changeset(%{
        name: "Test Board",
        slug: "test-#{System.unique_integer([:positive])}",
        description: "A test board"
      })
      |> Repo.insert()

    board
  end
end
