defmodule Baudrate.Auth.RecoveryCodeKeysTest do
  # Configures application-wide key material (ADR 0038).
  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Auth.RecoveryCode
  alias Baudrate.Crypto.Keyring
  alias Baudrate.Repo
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    original = Application.get_env(:baudrate, Keyring)
    on_exit(fn -> restore(original) end)
    {:ok, user: create_user(), original: original}
  end

  defp restore(nil), do: Application.delete_env(:baudrate, Keyring)
  defp restore(config), do: Application.put_env(:baudrate, Keyring, config)

  defp key, do: :crypto.strong_rand_bytes(32)

  defp create_user do
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "recovery_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    user
  end

  defp key_ids(user) do
    Repo.all(from(rc in RecoveryCode, where: rc.user_id == ^user.id, select: rc.key_id))
  end

  test "codes record the key that hashed them", %{user: user} do
    Application.put_env(:baudrate, Keyring, auth_keys: [%{id: "k1", key: key()}])

    [code | _] = Auth.generate_recovery_codes(user)

    assert key_ids(user) |> Enum.uniq() == ["k1"]
    assert :ok = Auth.verify_recovery_code(user, code)
  end

  test "a code issued on the fallback still verifies once a key is configured", %{user: user} do
    Application.delete_env(:baudrate, Keyring)
    [legacy_code | _] = Auth.generate_recovery_codes(user)
    assert key_ids(user) |> Enum.uniq() == ["legacy"]

    Application.put_env(:baudrate, Keyring, auth_keys: [%{id: "k1", key: key()}])

    assert :ok = Auth.verify_recovery_code(user, legacy_code)
  end

  test "a code issued under a retired key still verifies after a rotation", %{user: user} do
    retired = key()
    Application.put_env(:baudrate, Keyring, auth_keys: [%{id: "k1", key: retired}])
    [old_code, another_old | _] = Auth.generate_recovery_codes(user)

    Application.put_env(:baudrate, Keyring,
      auth_keys: [%{id: "k2", key: key()}, %{id: "k1", key: retired}]
    )

    assert :ok = Auth.verify_recovery_code(user, old_code)
    # Still one use each: verifying under a retired key consumes the row.
    assert :error = Auth.verify_recovery_code(user, old_code)
    assert :ok = Auth.verify_recovery_code(user, another_old)
  end

  test "regenerating moves a member to the current key", %{user: user} do
    retired = key()
    Application.put_env(:baudrate, Keyring, auth_keys: [%{id: "k1", key: retired}])
    Auth.generate_recovery_codes(user)

    Application.put_env(:baudrate, Keyring,
      auth_keys: [%{id: "k2", key: key()}, %{id: "k1", key: retired}]
    )

    [fresh | _] = Auth.generate_recovery_codes(user)

    assert key_ids(user) |> Enum.uniq() == ["k2"]
    assert :ok = Auth.verify_recovery_code(user, fresh)
  end

  test "dropping the key a code was hashed under fails closed", %{user: user} do
    Application.put_env(:baudrate, Keyring, auth_keys: [%{id: "k1", key: key()}])
    [code | _] = Auth.generate_recovery_codes(user)

    # The operator dropped a key rows still depend on: the code stops working,
    # and nothing else happens — no crash, and nobody is let in.
    Application.put_env(:baudrate, Keyring, auth_keys: [%{id: "k2", key: key()}])

    assert :error = Auth.verify_recovery_code(user, code)
    assert key_ids(user) |> Enum.uniq() == ["k1"]
  end

  test "a row whose label is wrong still verifies, because the label is advisory", %{user: user} do
    Application.put_env(:baudrate, Keyring, auth_keys: [%{id: "k1", key: key()}])
    [code | _] = Auth.generate_recovery_codes(user)

    Repo.update_all(from(rc in RecoveryCode, where: rc.user_id == ^user.id),
      set: [key_id: "nonsense"]
    )

    assert :ok = Auth.verify_recovery_code(user, code)
  end
end
