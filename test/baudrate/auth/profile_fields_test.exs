defmodule Baudrate.Auth.ProfileFieldsTest do
  use Baudrate.DataCase

  alias Baudrate.Auth
  alias Baudrate.Setup
  alias Baudrate.Setup.{Role, User}

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user(opts \\ []) do
    role = Repo.one!(from r in Role, where: r.name == "user")
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

  describe "update_profile_fields/2" do
    test "sets profile fields on user" do
      user = create_user()
      assert user.profile_fields == []

      fields = [%{"name" => "Website", "value" => "https://example.com"}]
      {:ok, updated} = Auth.update_profile_fields(user, fields)
      assert updated.profile_fields == fields
    end

    test "updates existing profile fields" do
      user = create_user()
      {:ok, user} = Auth.update_profile_fields(user, [%{"name" => "Old", "value" => "value"}])

      new_fields = [%{"name" => "New", "value" => "new value"}]
      {:ok, updated} = Auth.update_profile_fields(user, new_fields)
      assert updated.profile_fields == new_fields
    end

    test "clears profile fields when set to empty list" do
      user = create_user()
      {:ok, user} = Auth.update_profile_fields(user, [%{"name" => "Key", "value" => "Val"}])
      assert length(user.profile_fields) == 1

      {:ok, updated} = Auth.update_profile_fields(user, [])
      assert updated.profile_fields == []
    end

    test "accepts up to 4 fields" do
      user = create_user()

      fields =
        Enum.map(1..4, fn i -> %{"name" => "Field #{i}", "value" => "Value #{i}"} end)

      {:ok, updated} = Auth.update_profile_fields(user, fields)
      assert length(updated.profile_fields) == 4
    end

    test "rejects more than 4 fields" do
      user = create_user()

      fields =
        Enum.map(1..5, fn i -> %{"name" => "Field #{i}", "value" => "Value #{i}"} end)

      {:error, changeset} = Auth.update_profile_fields(user, fields)
      assert errors_on(changeset).profile_fields != []
    end

    test "rejects field name exceeding 255 characters" do
      user = create_user()
      long_name = String.duplicate("x", 256)

      {:error, changeset} =
        Auth.update_profile_fields(user, [%{"name" => long_name, "value" => "val"}])

      assert errors_on(changeset).profile_fields != []
    end

    test "rejects field value exceeding 2048 characters" do
      user = create_user()
      long_value = String.duplicate("x", 2049)

      {:error, changeset} =
        Auth.update_profile_fields(user, [%{"name" => "key", "value" => long_value}])

      assert errors_on(changeset).profile_fields != []
    end

    test "accepts field name at exactly 255 characters" do
      user = create_user()
      max_name = String.duplicate("a", 255)

      {:ok, updated} = Auth.update_profile_fields(user, [%{"name" => max_name, "value" => "v"}])
      assert hd(updated.profile_fields)["name"] == max_name
    end

    test "accepts field value at exactly 2048 characters" do
      user = create_user()
      max_value = String.duplicate("a", 2048)

      {:ok, updated} =
        Auth.update_profile_fields(user, [%{"name" => "key", "value" => max_value}])

      assert hd(updated.profile_fields)["value"] == max_value
    end

    test "rejects entries with non-string name" do
      user = create_user()

      {:error, changeset} =
        Auth.update_profile_fields(user, [%{"name" => 123, "value" => "val"}])

      assert errors_on(changeset).profile_fields != []
    end

    test "rejects entries missing required keys" do
      user = create_user()

      {:error, changeset} = Auth.update_profile_fields(user, [%{"name" => "only name"}])
      assert errors_on(changeset).profile_fields != []
    end
  end

  describe "profile_fields_changeset/2" do
    test "validates structure of each field entry" do
      user = create_user()

      valid_fields = [
        %{"name" => "Website", "value" => "https://example.com"},
        %{"name" => "Location", "value" => "Tokyo"}
      ]

      changeset = User.profile_fields_changeset(user, %{profile_fields: valid_fields})
      assert changeset.valid?
    end

    test "invalid when entry has non-string value" do
      user = create_user()

      changeset =
        User.profile_fields_changeset(user, %{
          profile_fields: [%{"name" => "key", "value" => 42}]
        })

      refute changeset.valid?
    end
  end
end
