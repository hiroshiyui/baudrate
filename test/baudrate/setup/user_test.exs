defmodule Baudrate.Setup.UserTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Setup.{Role, User}

  setup do
    role =
      Repo.insert!(%Role{
        name: "admin",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    %{role: role}
  end

  describe "registration_changeset/2" do
    test "valid changeset with proper attributes", %{role: role} do
      attrs = valid_attrs(role)
      changeset = User.registration_changeset(%User{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :hashed_password)
      refute get_change(changeset, :password)
      refute get_change(changeset, :password_confirmation)
    end

    test "requires username", %{role: role} do
      attrs = valid_attrs(role) |> Map.delete(:username)
      changeset = User.registration_changeset(%User{}, attrs)
      assert %{username: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates username minimum length", %{role: role} do
      attrs = %{valid_attrs(role) | username: "ab"}
      changeset = User.registration_changeset(%User{}, attrs)
      assert %{username: [msg]} = errors_on(changeset)
      assert msg =~ "at least"
    end

    test "validates username maximum length", %{role: role} do
      attrs = %{valid_attrs(role) | username: String.duplicate("a", 33)}
      changeset = User.registration_changeset(%User{}, attrs)
      assert %{username: [msg]} = errors_on(changeset)
      assert msg =~ "at most"
    end

    test "validates username format - only alphanumeric and underscores", %{role: role} do
      attrs = %{valid_attrs(role) | username: "bad user!"}
      changeset = User.registration_changeset(%User{}, attrs)

      assert %{username: ["only allows letters, numbers, and underscores"]} =
               errors_on(changeset)
    end

    test "accepts valid username formats", %{role: role} do
      for name <- ["admin", "Admin_123", "user_name", "ABC"] do
        attrs = %{valid_attrs(role) | username: name}
        changeset = User.registration_changeset(%User{}, attrs)
        refute Map.has_key?(errors_on(changeset), :username), "Expected #{name} to be valid"
      end
    end

    test "validates username uniqueness", %{role: role} do
      attrs = valid_attrs(role)
      {:ok, _} = Repo.insert(User.registration_changeset(%User{}, attrs))

      {:error, changeset} =
        Repo.insert(User.registration_changeset(%User{}, attrs))

      assert %{username: ["has already been taken"]} = errors_on(changeset)
    end

    test "requires password", %{role: role} do
      attrs = valid_attrs(role) |> Map.delete(:password)
      changeset = User.registration_changeset(%User{}, attrs)
      assert %{password: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates password minimum length", %{role: role} do
      attrs = %{
        valid_attrs(role)
        | password: "Short1!abc",
          password_confirmation: "Short1!abc"
      }

      changeset = User.registration_changeset(%User{}, attrs)
      assert %{password: [msg]} = errors_on(changeset)
      assert msg =~ "at least"
    end

    test "validates password requires lowercase letter", %{role: role} do
      attrs = %{
        valid_attrs(role)
        | password: "ALLUPPERCASE1!",
          password_confirmation: "ALLUPPERCASE1!"
      }

      changeset = User.registration_changeset(%User{}, attrs)
      assert "must contain a lowercase letter" in errors_on(changeset).password
    end

    test "validates password requires uppercase letter", %{role: role} do
      attrs = %{
        valid_attrs(role)
        | password: "alllowercase1!",
          password_confirmation: "alllowercase1!"
      }

      changeset = User.registration_changeset(%User{}, attrs)
      assert "must contain an uppercase letter" in errors_on(changeset).password
    end

    test "validates password requires digit", %{role: role} do
      attrs = %{
        valid_attrs(role)
        | password: "NoDigitsHere!!",
          password_confirmation: "NoDigitsHere!!"
      }

      changeset = User.registration_changeset(%User{}, attrs)
      assert "must contain a digit" in errors_on(changeset).password
    end

    test "validates password requires special character", %{role: role} do
      attrs = %{
        valid_attrs(role)
        | password: "NoSpecialChar1x",
          password_confirmation: "NoSpecialChar1x"
      }

      changeset = User.registration_changeset(%User{}, attrs)
      assert "must contain a special character" in errors_on(changeset).password
    end

    test "validates password confirmation match", %{role: role} do
      attrs = %{valid_attrs(role) | password_confirmation: "DifferentPass1!"}
      changeset = User.registration_changeset(%User{}, attrs)
      assert %{password_confirmation: ["does not match password"]} = errors_on(changeset)
    end

    test "does not hash password when changeset is invalid" do
      changeset = User.registration_changeset(%User{}, %{username: "a"})
      refute get_change(changeset, :hashed_password)
    end

    test "hashes password with bcrypt", %{role: role} do
      attrs = valid_attrs(role)
      changeset = User.registration_changeset(%User{}, attrs)
      hashed = get_change(changeset, :hashed_password)
      assert hashed
      assert Bcrypt.verify_pass("SecurePass1!xyz", hashed)
    end

    test "accepts role_id", %{role: role} do
      attrs = valid_attrs(role)
      changeset = User.registration_changeset(%User{}, attrs)
      assert get_change(changeset, :role_id) == role.id
    end

    test "validates role association constraint", %{role: _role} do
      attrs = %{
        username: "admin_user",
        password: "SecurePass1!xyz",
        password_confirmation: "SecurePass1!xyz",
        role_id: 0
      }

      changeset = User.registration_changeset(%User{}, attrs)
      {:error, changeset} = Repo.insert(changeset)
      assert %{role: ["does not exist"]} = errors_on(changeset)
    end
  end

  defp valid_attrs(role) do
    %{
      username: "admin_user",
      password: "SecurePass1!xyz",
      password_confirmation: "SecurePass1!xyz",
      role_id: role.id
    }
  end
end
