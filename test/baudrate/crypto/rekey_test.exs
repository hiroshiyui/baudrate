defmodule Baudrate.Crypto.RekeyTest do
  @moduledoc """
  Acceptance gate for the rotation half of Phase 2G: every stored secret moves
  to the current key, a value nobody can read is left alone rather than
  crashing the run, and a secret written while the task runs survives.
  """

  # Configures application-wide key material (ADR 0038).
  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Auth.TotpVault
  alias Baudrate.Content.Board
  alias Baudrate.Crypto.{Keyring, Rekey, Vault}
  alias Baudrate.Federation.KeyStore
  alias Baudrate.Notification.{VAPID, VapidVault}
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.User

  setup do
    Setup.seed_roles_and_permissions()
    configured = Application.get_env(:baudrate, Keyring)

    on_exit(fn ->
      if configured,
        do: Application.put_env(:baudrate, Keyring, configured),
        else: Application.delete_env(:baudrate, Keyring)
    end)

    {:ok, configured: configured}
  end

  defp on_fallback(fun) do
    configured = Application.get_env(:baudrate, Keyring)
    Application.delete_env(:baudrate, Keyring)

    try do
      fun.()
    after
      if configured, do: Application.put_env(:baudrate, Keyring, configured)
    end
  end

  defp create_user do
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "rekey_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    user
  end

  defp create_board do
    {:ok, board} =
      %Board{}
      |> Board.changeset(%{
        name: "Rekey #{System.unique_integer([:positive])}",
        slug: "rekey-#{System.unique_integer([:positive])}",
        description: "for rotation tests"
      })
      |> Repo.insert()

    board
  end

  defp key_id_of(blob), do: Vault.key_id(blob)

  defp reload(%User{id: id}), do: Repo.get!(User, id)
  defp reload(%Board{id: id}), do: Repo.get!(Board, id)

  describe "run/1" do
    test "moves every secret written on the fallback to the current key" do
      secret = :crypto.strong_rand_bytes(20)

      {user, board} =
        on_fallback(fn ->
          user = create_user()
          {:ok, user} = Auth.enable_totp(user, secret)
          {:ok, user} = KeyStore.ensure_user_keypair(user)
          board = create_board()
          {:ok, board} = KeyStore.ensure_board_keypair(board)
          {:ok, _} = KeyStore.ensure_site_keypair()

          {public, encrypted} = VAPID.generate_keypair()
          {:ok, _} = Setup.set_setting("vapid_public_key", public)
          {:ok, _} = Setup.set_setting(VapidVault.setting(), Base.encode64(encrypted))
          Setup.SettingsCache.refresh()

          {user, board}
        end)

      # Everything is on the fallback, and readable there.
      assert {:ok, "legacy"} = key_id_of(reload(user).totp_secret)
      assert {:ok, "legacy"} = key_id_of(reload(user).ap_private_key_encrypted)
      assert {:ok, "legacy"} = key_id_of(reload(board).ap_private_key_encrypted)

      {:ok, site_pem_before} = KeyStore.decrypt_site_private_key()
      {:ok, user_pem_before} = KeyStore.decrypt_private_key(reload(user))

      # A dry run reports the work and writes nothing.
      before = reload(user).totp_secret
      dry = Rekey.run(dry_run: true)
      assert dry.rekeyed >= 5
      assert reload(user).totp_secret == before

      result = Rekey.run()
      assert result.rekeyed >= 5
      assert result.undecryptable == 0
      assert result.skipped_concurrent == 0

      # Now on the current keys, and still the same secrets.
      assert {:ok, "testauth"} = key_id_of(reload(user).totp_secret)
      assert {:ok, "testsign"} = key_id_of(reload(user).ap_private_key_encrypted)
      assert {:ok, "testsign"} = key_id_of(reload(board).ap_private_key_encrypted)

      assert Auth.decrypt_totp_secret(reload(user)) == secret
      assert {:ok, ^user_pem_before} = KeyStore.decrypt_private_key(reload(user))
      assert {:ok, ^site_pem_before} = KeyStore.decrypt_site_private_key()

      assert {:ok, _vapid} =
               VapidVault.decrypt(Base.decode64!(Setup.get_setting(VapidVault.setting())))

      # And the census says so.
      assert result.remaining["users.totp_secret"] == %{"testauth" => 1}
      assert result.remaining["boards.ap_private_key_encrypted"]["testsign"] >= 1
      refute Map.has_key?(result.remaining["users.ap_private_key_encrypted"], "legacy")
    end

    test "running again changes nothing" do
      secret = :crypto.strong_rand_bytes(20)

      user =
        on_fallback(fn ->
          user = create_user()
          {:ok, user} = Auth.enable_totp(user, secret)
          user
        end)

      assert %{rekeyed: 1} = Rekey.run()
      before = reload(user).totp_secret

      assert %{rekeyed: 0, undecryptable: 0} = Rekey.run()
      assert reload(user).totp_secret == before
    end

    test "leaves a value it cannot read alone, and does not stop" do
      secret = :crypto.strong_rand_bytes(20)

      {readable, unreadable} =
        on_fallback(fn ->
          readable = create_user()
          {:ok, readable} = Auth.enable_totp(readable, secret)
          unreadable = create_user()
          {readable, unreadable}
        end)

      # What the data-export canary test writes: marker bytes, not ciphertext.
      Repo.update_all(from(u in User, where: u.id == ^unreadable.id),
        set: [totp_secret: "CANARY-NOT-CIPHERTEXT"]
      )

      result = Rekey.run()

      assert result.rekeyed == 1
      assert result.undecryptable == 1
      assert reload(unreadable).totp_secret == "CANARY-NOT-CIPHERTEXT"
      assert {:ok, "testauth"} = key_id_of(reload(readable).totp_secret)
      assert result.remaining["users.totp_secret"]["unreadable"] == 1
    end

    test "a secret written while the task runs is not overwritten" do
      old_secret = :crypto.strong_rand_bytes(20)
      new_secret = :crypto.strong_rand_bytes(20)

      user =
        on_fallback(fn ->
          user = create_user()
          {:ok, user} = Auth.enable_totp(user, old_secret)
          user
        end)

      # Stands in for the member re-enrolling between the read and the write.
      interrupt = fn
        "users.totp_secret", id ->
          Repo.update_all(from(u in User, where: u.id == ^id),
            set: [totp_secret: TotpVault.encrypt(new_secret, %User{id: id})]
          )

          :ok

        _target, _id ->
          :ok
      end

      result = Rekey.run(after_read: interrupt)

      assert result.skipped_concurrent == 1
      assert result.rekeyed == 0
      # The newer secret survived, under the current key.
      assert Auth.decrypt_totp_secret(reload(user)) == new_secret
    end

    test "only: [:auth] leaves signing keys alone" do
      secret = :crypto.strong_rand_bytes(20)

      {user, _board} =
        on_fallback(fn ->
          user = create_user()
          {:ok, user} = Auth.enable_totp(user, secret)
          {:ok, user} = KeyStore.ensure_user_keypair(user)
          {user, nil}
        end)

      assert %{rekeyed: 1} = Rekey.run(only: [:auth])

      assert {:ok, "testauth"} = key_id_of(reload(user).totp_secret)
      assert {:ok, "legacy"} = key_id_of(reload(user).ap_private_key_encrypted)
    end

    test "works one row at a time" do
      secret = :crypto.strong_rand_bytes(20)

      users =
        on_fallback(fn ->
          for _ <- 1..3 do
            user = create_user()
            {:ok, user} = Auth.enable_totp(user, secret)
            user
          end
        end)

      assert %{rekeyed: 3} = Rekey.run(batch: 1)

      for user <- users do
        assert {:ok, "testauth"} = key_id_of(reload(user).totp_secret)
      end
    end
  end

  describe "usage/0 and unknown_key_ids/1" do
    test "counts what sits under each key, and names keys that are gone" do
      secret = :crypto.strong_rand_bytes(20)

      user =
        on_fallback(fn ->
          user = create_user()
          {:ok, user} = Auth.enable_totp(user, secret)
          user
        end)

      assert Rekey.usage()["users.totp_secret"] == %{"legacy" => 1}
      assert Rekey.unknown_key_ids() == []

      Rekey.run()
      assert Rekey.usage()["users.totp_secret"] == %{"testauth" => 1}

      # Drop the key that row needs: the census still says which one it is.
      Application.put_env(:baudrate, Keyring,
        auth_keys: [%{id: "other", key: :crypto.strong_rand_bytes(32)}]
      )

      assert Rekey.unknown_key_ids() == ["testauth"]
      assert Auth.decrypt_totp_secret(reload(user)) == nil
    end

    test "counts recovery codes, which cannot be re-keyed" do
      user =
        on_fallback(fn ->
          user = create_user()
          Auth.generate_recovery_codes(user)
          user
        end)

      assert Rekey.usage()["recovery_codes.code_hash"] == %{"legacy" => 10}

      Rekey.run()

      # Untouched by rotation: only the member generating new codes moves them.
      assert Rekey.usage()["recovery_codes.code_hash"] == %{"legacy" => 10}
      assert Auth.generate_recovery_codes(user)
      assert Rekey.usage()["recovery_codes.code_hash"] == %{"testauth" => 10}
    end
  end
end
