defmodule Baudrate.Auth.BioTest do
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

  describe "update_bio/2" do
    test "sets bio on user" do
      user = create_user()
      assert is_nil(user.bio)

      {:ok, updated} = Auth.update_bio(user, "Hello, world!")
      assert updated.bio == "Hello, world!"
    end

    test "updates existing bio" do
      user = create_user()
      {:ok, user} = Auth.update_bio(user, "Old bio")
      assert user.bio == "Old bio"

      {:ok, updated} = Auth.update_bio(user, "New bio")
      assert updated.bio == "New bio"
    end

    test "clears bio when set to nil" do
      user = create_user()
      {:ok, user} = Auth.update_bio(user, "Has a bio")
      assert user.bio == "Has a bio"

      {:ok, updated} = Auth.update_bio(user, nil)
      assert is_nil(updated.bio)
    end

    test "clears bio when set to empty string" do
      user = create_user()
      {:ok, user} = Auth.update_bio(user, "Has a bio")

      {:ok, updated} = Auth.update_bio(user, "")
      assert is_nil(updated.bio) or updated.bio == ""
    end

    test "validates max length of 500 characters" do
      user = create_user()
      long_bio = String.duplicate("a", 501)

      {:error, changeset} = Auth.update_bio(user, long_bio)
      errors = errors_on(changeset)
      assert "should be at most 500 character(s)" in errors.bio
    end

    test "accepts bio exactly at max length" do
      user = create_user()
      max_bio = String.duplicate("a", 500)

      {:ok, updated} = Auth.update_bio(user, max_bio)
      assert String.length(updated.bio) == 500
    end

    test "allows multiline bio without line limit" do
      user = create_user()
      # 20 lines — unlike signature, bio has no line limit
      multiline = Enum.join(1..20, "\n")

      {:ok, updated} = Auth.update_bio(user, multiline)
      assert updated.bio == multiline
    end
  end
end
