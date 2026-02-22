defmodule Baudrate.Auth.SignatureTest do
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

  describe "update_signature/2" do
    test "sets signature on user" do
      user = create_user()
      assert is_nil(user.signature)

      {:ok, updated} = Auth.update_signature(user, "Hello, world!")
      assert updated.signature == "Hello, world!"
    end

    test "updates existing signature" do
      user = create_user()
      {:ok, user} = Auth.update_signature(user, "Old signature")
      assert user.signature == "Old signature"

      {:ok, updated} = Auth.update_signature(user, "New signature")
      assert updated.signature == "New signature"
    end

    test "clears signature when set to nil" do
      user = create_user()
      {:ok, user} = Auth.update_signature(user, "Has a signature")
      assert user.signature == "Has a signature"

      {:ok, updated} = Auth.update_signature(user, nil)
      assert is_nil(updated.signature)
    end

    test "clears signature when set to empty string" do
      user = create_user()
      {:ok, user} = Auth.update_signature(user, "Has a signature")

      {:ok, updated} = Auth.update_signature(user, "")
      # Ecto casts empty string to nil for string fields
      assert is_nil(updated.signature) or updated.signature == ""
    end

    test "validates max length of 500 characters" do
      user = create_user()
      long_signature = String.duplicate("a", 501)

      {:error, changeset} = Auth.update_signature(user, long_signature)
      errors = errors_on(changeset)
      assert "should be at most 500 character(s)" in errors.signature
    end

    test "accepts signature exactly at max length" do
      user = create_user()
      max_signature = String.duplicate("a", 500)

      {:ok, updated} = Auth.update_signature(user, max_signature)
      assert String.length(updated.signature) == 500
    end

    test "validates max lines (8 lines)" do
      user = create_user()
      # 9 lines = 8 newlines
      nine_lines = Enum.join(1..9, "\n")

      {:error, changeset} = Auth.update_signature(user, nine_lines)
      errors = errors_on(changeset)
      assert "must not exceed 8 lines" in errors.signature
    end

    test "accepts signature with exactly 8 lines" do
      user = create_user()
      # 8 lines = 7 newlines
      eight_lines = Enum.join(1..8, "\n")

      {:ok, updated} = Auth.update_signature(user, eight_lines)
      assert updated.signature == eight_lines
    end

    test "supports Markdown content" do
      user = create_user()
      markdown_sig = "**Bold** and *italic* text\n- item 1\n- item 2"

      {:ok, updated} = Auth.update_signature(user, markdown_sig)
      assert updated.signature == markdown_sig
    end
  end
end
