defmodule Baudrate.Content.FiltersTest do
  @moduledoc false

  use Baudrate.DataCase, async: true

  alias Baudrate.Content.Filters

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
        "username" => "test_#{role_name}_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  describe "hidden_filters/1" do
    test "returns empty lists for nil (guest)" do
      assert {[], []} = Filters.hidden_filters(nil)
    end

    test "returns hidden IDs for user with blocks/mutes" do
      user = setup_user_with_role("user")
      target = setup_user_with_role("user")

      Baudrate.Auth.block_user(user, target)
      {uids, _ap_ids} = Filters.hidden_filters(user)
      assert target.id in uids
    end
  end

  describe "apply_hidden_filters/3" do
    test "passes through query when both lists are empty" do
      query = from(c in "comments")
      assert Filters.apply_hidden_filters(query, [], []) == query
    end
  end

  describe "allowed_view_roles/1" do
    test "returns only guest for nil (guest user)" do
      assert Filters.allowed_view_roles(nil) == ["guest"]
    end

    test "returns roles at or below the user's role" do
      user = setup_user_with_role("user")
      roles = Filters.allowed_view_roles(user)
      assert "guest" in roles
      assert "user" in roles
      refute "admin" in roles
    end

    test "admin can view all roles" do
      admin = setup_user_with_role("admin")
      roles = Filters.allowed_view_roles(admin)
      assert "guest" in roles
      assert "user" in roles
      assert "moderator" in roles
      assert "admin" in roles
    end
  end

  describe "sanitize_like/1" do
    test "escapes percent signs" do
      assert Filters.sanitize_like("100%") == "100\\%"
    end

    test "escapes underscores" do
      assert Filters.sanitize_like("foo_bar") == "foo\\_bar"
    end

    test "escapes backslashes" do
      assert Filters.sanitize_like("C:\\path") == "C:\\\\path"
    end

    test "passes plain text through unchanged" do
      assert Filters.sanitize_like("hello world") == "hello world"
    end
  end

  describe "contains_cjk?/1" do
    test "returns true for Chinese characters" do
      assert Filters.contains_cjk?("你好")
    end

    test "returns true for Japanese characters" do
      assert Filters.contains_cjk?("こんにちは")
      assert Filters.contains_cjk?("カタカナ")
    end

    test "returns true for Korean characters" do
      assert Filters.contains_cjk?("한국어")
    end

    test "returns false for ASCII text" do
      refute Filters.contains_cjk?("hello world")
    end

    test "returns true for mixed content" do
      assert Filters.contains_cjk?("hello 世界")
    end
  end
end
