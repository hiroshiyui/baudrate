defmodule BaudrateWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use BaudrateWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint BaudrateWeb.Endpoint

      use BaudrateWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import BaudrateWeb.ConnCase
    end
  end

  setup tags do
    Baudrate.DataCase.setup_sandbox(tags)

    # Default: pass rate limit checks through to the real Hammer backend.
    # Sandbox walks $callers chain, so LiveView processes inherit this automatically.
    BaudrateWeb.RateLimiter.Sandbox.set_global_fun(&BaudrateWeb.RateLimiter.Hammer.check_rate/3)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Seeds roles/permissions if needed and creates a user with the given role.
  Returns the user with role preloaded.
  """
  def setup_user(role_name) do
    import Ecto.Query
    alias Baudrate.Repo
    alias Baudrate.Setup
    alias Baudrate.Setup.{Role, User}

    # Seed roles if they don't exist
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

  @doc """
  Backdates a user's `inserted_at` to simulate an older account.
  Returns the user with the updated timestamp.
  """
  def backdate_user(user, days) do
    import Ecto.Query
    alias Baudrate.Repo
    alias Baudrate.Setup.User

    past =
      DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [inserted_at: past])
    %{user | inserted_at: past}
  end

  @doc """
  Creates a DB session and sets session keys for a fully authenticated user.
  """
  def log_in_user(conn, user) do
    {:ok, session_token, refresh_token} = Baudrate.Auth.create_user_session(user.id)

    conn
    |> Plug.Test.init_test_session(%{
      session_token: session_token,
      refresh_token: refresh_token,
      refreshed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end
end
