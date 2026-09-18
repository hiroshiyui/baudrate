defmodule Baudrate.Auth.UsernameUniquenessTest do
  @moduledoc """
  Usernames are unique without regard to case.

  `users.username` carried a plain unique index, so `Admin` could be registered
  alongside `admin`. That gave a distinct fediverse actor for impersonation —
  WebFinger and the AP actor endpoint both match exactly, and the UI renders
  `@{username}` verbatim — and it made `get_user_by_username_ci/1` return two
  rows, so `Ecto.MultipleResultsError` reached the LiveView of anyone who
  wrote `@admin` in a post. One throwaway registration broke mentions of a
  chosen account permanently.
  """

  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.{Role, User}

  setup do
    unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    :ok
  end

  defp register(username) do
    role = Repo.one!(from(r in Role, where: r.name == "user"))

    %User{}
    |> User.registration_changeset(%{
      "username" => username,
      "password" => "Password123!x",
      "password_confirmation" => "Password123!x",
      "role_id" => role.id
    })
    |> Repo.insert()
  end

  test "a name differing only in case is refused, as a validation error" do
    base = "casetest#{System.unique_integer([:positive])}"

    assert {:ok, _user} = register(base)
    assert {:error, changeset} = register(String.upcase(base))

    assert "has already been taken" in errors_on(changeset).username,
           "it must come back as a changeset error, not an Ecto.ConstraintError"
  end

  test "the case-insensitive lookup returns one row, not a crash" do
    base = "lookup#{System.unique_integer([:positive])}"
    assert {:ok, user} = register(base)

    # The DoS was here: two rows made this raise, and it runs on every mention.
    assert %User{id: id} = Auth.get_user_by_username_ci(String.upcase(base))
    assert id == user.id
  end

  test "the index makes a colliding row impossible to insert at all" do
    base = "forced#{System.unique_integer([:positive])}"
    assert {:ok, first} = register(base)

    role = Repo.one!(from(r in Role, where: r.name == "user"))
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Not even a raw insert_all, which bypasses every changeset, can create the
    # pair that used to crash every mention.
    assert_raise Postgrex.Error, fn ->
      Repo.insert_all(User, [
        %{
          username: String.upcase(base),
          hashed_password: first.hashed_password,
          role_id: role.id,
          status: "active",
          inserted_at: now,
          updated_at: now
        }
      ])
    end
  end
end
