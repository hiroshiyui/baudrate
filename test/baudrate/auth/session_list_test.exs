defmodule Baudrate.Auth.SessionListTest do
  @moduledoc """
  A member's own session list, and signing out one session from it (6E-1).
  A revocation goes through `Auth.Sessions` like every other (ADR 0008), and
  both of its refusals live in the query.
  """

  use Baudrate.DataCase, async: true

  alias Baudrate.Auth
  alias Baudrate.Auth.UserSession
  alias Baudrate.Repo

  @firefox_linux "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    %{user: user_fixture(), other: user_fixture()}
  end

  defp user_fixture do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "sess#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    user
  end

  defp session!(user, opts \\ []) do
    {:ok, token, _refresh} = Auth.create_user_session(user.id, opts)
    Auth.session_id_by_token(token)
  end

  describe "list_sessions/1" do
    test "names the browser and system, and never returns the raw header", %{user: user} do
      id = session!(user, user_agent: @firefox_linux, ip_address: "203.0.113.7")

      assert [session] = Auth.list_sessions(user.id)
      assert session.id == id
      assert session.browser == "Firefox"
      assert session.os == "Linux"
      assert session.ip_address == "203.0.113.7"
      refute Map.has_key?(session, :user_agent)
    end

    test "leaves out expired sessions and other members' sessions", %{user: user, other: other} do
      live = session!(user)
      expired = session!(user)
      _theirs = session!(other)

      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      Repo.update_all(from(s in UserSession, where: s.id == ^expired), set: [expires_at: past])

      assert Enum.map(Auth.list_sessions(user.id), & &1.id) == [live]
    end
  end

  describe "revoke_session/3" do
    test "signs out that session and closes its sockets", %{user: user} do
      current = session!(user)
      target = session!(user)
      BaudrateWeb.Endpoint.subscribe(Auth.live_socket_id(target))

      assert :ok = Auth.revoke_session(user.id, target, current)

      refute Repo.get(UserSession, target)
      assert Repo.get(UserSession, current)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "another member's session is a miss", %{user: user, other: other} do
      current = session!(user)
      theirs = session!(other)

      assert {:error, :not_found} = Auth.revoke_session(user.id, theirs, current)
      assert Repo.get(UserSession, theirs)
    end

    test "the current session can never be signed out this way", %{user: user} do
      current = session!(user)

      assert {:error, :not_found} = Auth.revoke_session(user.id, current, current)
      assert Repo.get(UserSession, current)
    end

    test "an unknown current session refuses rather than excluding nothing", %{user: user} do
      target = session!(user)

      assert {:error, :no_session} = Auth.revoke_session(user.id, target, nil)
      assert Repo.get(UserSession, target)
    end
  end
end
