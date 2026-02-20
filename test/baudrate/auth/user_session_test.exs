defmodule Baudrate.Auth.UserSessionTest do
  use Baudrate.DataCase

  alias Baudrate.Auth
  alias Baudrate.Auth.UserSession
  alias Baudrate.Repo

  setup do
    user = setup_user("user")
    {:ok, user: user}
  end

  defp setup_user(role_name) do
    import Ecto.Query
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

  describe "create_user_session/2" do
    test "creates a session and returns tokens", %{user: user} do
      assert {:ok, session_token, refresh_token} = Auth.create_user_session(user.id)
      assert is_binary(session_token)
      assert is_binary(refresh_token)

      session = Repo.one!(from s in UserSession, where: s.user_id == ^user.id)
      assert session.token_hash == Auth.hash_token(session_token)
      assert session.refresh_token_hash == Auth.hash_token(refresh_token)
      assert DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt
    end

    test "stores ip_address and user_agent", %{user: user} do
      opts = [ip_address: "192.168.1.1", user_agent: "TestBrowser/1.0"]
      {:ok, _st, _rt} = Auth.create_user_session(user.id, opts)

      session = Repo.one!(from s in UserSession, where: s.user_id == ^user.id)
      assert session.ip_address == "192.168.1.1"
      assert session.user_agent == "TestBrowser/1.0"
    end

    test "evicts oldest session when max is exceeded", %{user: user} do
      # Create 3 sessions
      {:ok, st1, _} = Auth.create_user_session(user.id)
      {:ok, _st2, _} = Auth.create_user_session(user.id)
      {:ok, _st3, _} = Auth.create_user_session(user.id)

      assert session_count(user.id) == 3

      # Creating a 4th should evict the oldest
      {:ok, _st4, _} = Auth.create_user_session(user.id)

      assert session_count(user.id) == 3

      # The first session token should no longer be valid
      assert {:error, :not_found} = Auth.get_user_by_session_token(st1)
    end
  end

  describe "get_user_by_session_token/1" do
    test "returns user for valid token", %{user: user} do
      {:ok, session_token, _refresh_token} = Auth.create_user_session(user.id)

      assert {:ok, found_user} = Auth.get_user_by_session_token(session_token)
      assert found_user.id == user.id
      assert found_user.role != nil
    end

    test "returns error for invalid token" do
      assert {:error, :not_found} = Auth.get_user_by_session_token("invalid_token")
    end

    test "returns error and deletes expired session", %{user: user} do
      {:ok, session_token, _refresh_token} = Auth.create_user_session(user.id)

      # Expire the session manually
      session = Repo.one!(from s in UserSession, where: s.user_id == ^user.id)

      session
      |> Ecto.Changeset.change(%{
        expires_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-1, :second)
      })
      |> Repo.update!()

      assert {:error, :expired} = Auth.get_user_by_session_token(session_token)
      assert session_count(user.id) == 0
    end
  end

  describe "refresh_user_session/1" do
    test "rotates tokens and extends expiry", %{user: user} do
      {:ok, old_session_token, old_refresh_token} = Auth.create_user_session(user.id)

      assert {:ok, new_session_token, new_refresh_token} =
               Auth.refresh_user_session(old_refresh_token)

      assert new_session_token != old_session_token
      assert new_refresh_token != old_refresh_token

      # Old tokens should be invalid
      assert {:error, :not_found} = Auth.get_user_by_session_token(old_session_token)

      # New token should work
      assert {:ok, found_user} = Auth.get_user_by_session_token(new_session_token)
      assert found_user.id == user.id
    end

    test "returns error for invalid refresh token" do
      assert {:error, :not_found} = Auth.refresh_user_session("invalid_token")
    end

    test "returns error for expired session", %{user: user} do
      {:ok, _session_token, refresh_token} = Auth.create_user_session(user.id)

      session = Repo.one!(from s in UserSession, where: s.user_id == ^user.id)

      session
      |> Ecto.Changeset.change(%{
        expires_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-1, :second)
      })
      |> Repo.update!()

      assert {:error, :expired} = Auth.refresh_user_session(refresh_token)
      assert session_count(user.id) == 0
    end
  end

  describe "delete_session_by_token/1" do
    test "deletes the session", %{user: user} do
      {:ok, session_token, _refresh_token} = Auth.create_user_session(user.id)
      assert session_count(user.id) == 1

      assert :ok = Auth.delete_session_by_token(session_token)
      assert session_count(user.id) == 0
    end

    test "is no-op for nonexistent token" do
      assert :ok = Auth.delete_session_by_token("nonexistent")
    end
  end

  describe "purge_expired_sessions/0" do
    test "deletes expired sessions", %{user: user} do
      {:ok, _st, _rt} = Auth.create_user_session(user.id)

      # Expire the session
      session = Repo.one!(from s in UserSession, where: s.user_id == ^user.id)

      session
      |> Ecto.Changeset.change(%{
        expires_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-1, :second)
      })
      |> Repo.update!()

      assert {1, nil} = Auth.purge_expired_sessions()
      assert session_count(user.id) == 0
    end

    test "does not delete active sessions", %{user: user} do
      {:ok, _st, _rt} = Auth.create_user_session(user.id)

      assert {0, nil} = Auth.purge_expired_sessions()
      assert session_count(user.id) == 1
    end
  end

  defp session_count(user_id) do
    import Ecto.Query
    Repo.aggregate(from(s in UserSession, where: s.user_id == ^user_id), :count)
  end
end
