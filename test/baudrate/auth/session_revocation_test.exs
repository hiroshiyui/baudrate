defmodule Baudrate.Auth.SessionRevocationTest do
  @moduledoc """
  Revoking a session must also close that session's open LiveView sockets,
  otherwise an already-open page keeps acting on a deleted session until it
  happens to reconnect. Covers sign out everywhere, password change, bans,
  logout and eviction (ADR 0023 prerequisites).
  """

  use Baudrate.DataCase, async: true

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Auth.UserSession
  alias Baudrate.Notification.Notification, as: NotificationSchema
  alias Baudrate.Repo
  alias Phoenix.Socket.Broadcast

  @password "Password123!x"

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    %{user: create_user()}
  end

  defp create_user do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "revoke_#{System.unique_integer([:positive])}",
        "password" => @password,
        "password_confirmation" => @password,
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  # Creates a session and subscribes this test process to its socket topic.
  defp session(user) do
    {:ok, token, _refresh} = Auth.create_user_session(user.id)
    id = Auth.session_id_by_token(token)
    BaudrateWeb.Endpoint.subscribe(Auth.live_socket_id(id))
    {token, id}
  end

  defp session_ids(user),
    do: Repo.all(from(s in UserSession, where: s.user_id == ^user.id, select: s.id))

  defp assert_disconnected(id) do
    topic = Auth.live_socket_id(id)
    assert_receive %Broadcast{topic: ^topic, event: "disconnect"}
  end

  defp refute_disconnected(id) do
    topic = Auth.live_socket_id(id)
    refute_receive %Broadcast{topic: ^topic, event: "disconnect"}, 50
  end

  test "live_socket_id/1 and session_id_by_token/1", %{user: user} do
    {token, id} = session(user)

    assert Auth.live_socket_id(id) == "user_session:#{id}"
    assert Auth.session_id_by_token(token) == id
    assert Auth.session_id_by_token("nope") == nil
    assert Auth.session_id_by_token(nil) == nil
  end

  test "the session id survives token rotation", %{user: user} do
    {:ok, token, refresh} = Auth.create_user_session(user.id)
    id = Auth.session_id_by_token(token)

    {:ok, new_token, _} = Auth.refresh_user_session(refresh)
    assert Auth.session_id_by_token(new_token) == id
  end

  describe "delete_other_sessions_for_user/2" do
    test "revokes and disconnects every other session and keeps the given one",
         %{user: user} do
      {_t1, keep} = session(user)
      {_t2, other_a} = session(user)
      {_t3, other_b} = session(user)

      assert Auth.delete_other_sessions_for_user(user.id, keep) == 2

      assert session_ids(user) == [keep]
      assert_disconnected(other_a)
      assert_disconnected(other_b)
      refute_disconnected(keep)
    end

    test "does not touch another user's sessions", %{user: user} do
      other_user = create_user()
      {_t, keep} = session(user)
      {_t, theirs} = session(other_user)

      assert Auth.delete_other_sessions_for_user(user.id, keep) == 0
      assert session_ids(other_user) == [theirs]
      refute_disconnected(theirs)
    end
  end

  test "delete_all_sessions_for_user/1 disconnects every session (used by bans)", %{user: user} do
    {_t1, a} = session(user)
    {_t2, b} = session(user)

    assert {2, nil} = Auth.delete_all_sessions_for_user(user.id)
    assert_disconnected(a)
    assert_disconnected(b)
  end

  test "delete_session_by_token/1 disconnects that session only (logout)", %{user: user} do
    {token, a} = session(user)
    {_t2, b} = session(user)

    assert :ok = Auth.delete_session_by_token(token)
    assert_disconnected(a)
    refute_disconnected(b)
  end

  test "evicting the oldest session over the per-user limit disconnects it", %{user: user} do
    {_t1, oldest} = session(user)

    Repo.update_all(from(s in UserSession, where: s.id == ^oldest),
      set: [refreshed_at: ~U[2020-01-01 00:00:00Z]]
    )

    {_t2, _} = session(user)
    {_t3, _} = session(user)
    # A fourth session evicts the oldest (max 3 per user).
    {_t4, _} = session(user)

    refute oldest in session_ids(user)
    assert_disconnected(oldest)
  end

  test "expired sessions are disconnected when purged or found expired", %{user: user} do
    {token, looked_up} = session(user)
    {_t, purged} = session(user)
    past = ~U[2020-01-01 00:00:00Z]

    Repo.update_all(from(s in UserSession, where: s.user_id == ^user.id),
      set: [expires_at: past]
    )

    assert {:error, :expired} = Auth.get_user_by_session_token(token)
    assert_disconnected(looked_up)

    assert {1, nil} = Auth.purge_expired_sessions()
    assert_disconnected(purged)
  end

  describe "sign_out_other_sessions/2" do
    test "revokes others and sends the always-delivered notice", %{user: user} do
      {_t1, keep} = session(user)
      {_t2, other} = session(user)

      assert {:ok, 1} = Auth.sign_out_other_sessions(user, keep)
      assert_disconnected(other)

      assert [%{type: "signed_out_everywhere", data: %{"count" => 1}}] =
               Repo.all(from(n in NotificationSchema, where: n.user_id == ^user.id))
    end
  end

  describe "change_password/3" do
    @new "N3w-Passw0rd!x"

    test "stores the new password, revokes other sessions, keeps this one, notifies",
         %{user: user} do
      {_t1, keep} = session(user)
      {_t2, other} = session(user)

      assert {:ok, updated, 1} =
               Auth.change_password(
                 user,
                 %{"password" => @new, "password_confirmation" => @new},
                 keep
               )

      assert Auth.verify_password(updated, @new)
      refute Auth.verify_password(updated, @password)
      assert session_ids(user) == [keep]
      assert_disconnected(other)
      refute_disconnected(keep)

      assert [%{type: "password_changed"}] =
               Repo.all(from(n in NotificationSchema, where: n.user_id == ^user.id))
    end

    test "rejects reusing the current password without touching sessions", %{user: user} do
      {_t1, keep} = session(user)
      {_t2, other} = session(user)

      assert {:error, changeset} =
               Auth.change_password(
                 user,
                 %{"password" => @password, "password_confirmation" => @password},
                 keep
               )

      assert "must be different from your current password" in errors_on(changeset).password
      assert Enum.sort(session_ids(user)) == Enum.sort([keep, other])
      refute_disconnected(other)
    end

    test "rejects a password that fails the policy or its confirmation", %{user: user} do
      {_t, keep} = session(user)

      assert {:error, weak} =
               Auth.change_password(
                 user,
                 %{"password" => "short", "password_confirmation" => "short"},
                 keep
               )

      assert errors_on(weak).password != []

      assert {:error, mismatch} =
               Auth.change_password(
                 user,
                 %{"password" => @new, "password_confirmation" => @new <> "x"},
                 keep
               )

      assert errors_on(mismatch).password_confirmation != []
      assert Auth.verify_password(Repo.reload!(user), @password)
    end

    test "password_change_changeset/2 validates without hashing or saving", %{user: user} do
      changeset =
        Auth.password_change_changeset(user, %{
          "password" => @new,
          "password_confirmation" => @new
        })

      assert changeset.valid?
      assert changeset.action == :validate
      refute Ecto.Changeset.get_change(changeset, :hashed_password)
    end
  end

  describe "totp_enabled_at" do
    test "is set on enable, cleared on disable, and gates totp_enabled_for_at_least?/2",
         %{user: user} do
      refute Auth.totp_enabled_for_at_least?(user, 0)

      {:ok, enabled} = Auth.enable_totp(user, Auth.generate_totp_secret())
      assert %DateTime{} = enabled.totp_enabled_at
      assert Auth.totp_enabled_for_at_least?(enabled, 0)
      refute Auth.totp_enabled_for_at_least?(enabled, 7)

      eight_days_ago = DateTime.add(DateTime.utc_now(), -8 * 86_400) |> DateTime.truncate(:second)

      Repo.update_all(from(u in Baudrate.Setup.User, where: u.id == ^user.id),
        set: [totp_enabled_at: eight_days_ago]
      )

      assert Auth.totp_enabled_for_at_least?(Repo.reload!(enabled), 7)

      {:ok, disabled} = Auth.disable_totp(Repo.reload!(enabled))
      assert is_nil(disabled.totp_enabled_at)
      refute Auth.totp_enabled_for_at_least?(disabled, 0)
    end

    test "fails closed when TOTP is on but the timestamp is missing", %{user: user} do
      {:ok, enabled} = Auth.enable_totp(user, Auth.generate_totp_secret())
      refute Auth.totp_enabled_for_at_least?(%{enabled | totp_enabled_at: nil}, 0)
    end
  end
end
