defmodule BaudrateWeb.Plugs.ForgetRevokedSessionTest do
  use BaudrateWeb.ConnCase

  alias BaudrateWeb.Plugs.ForgetRevokedSession

  @auth_keys [:session_token, :refresh_token, :refreshed_at, :live_socket_id]

  setup do
    user = setup_user("user")
    {:ok, session_token, refresh_token} = Baudrate.Auth.create_user_session(user.id)
    id = Baudrate.Auth.session_id_by_token(session_token)

    session = %{
      session_token: session_token,
      refresh_token: refresh_token,
      refreshed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      live_socket_id: Baudrate.Auth.live_socket_id(id),
      locale: "ja_JP"
    }

    %{session: session}
  end

  test "drops a revoked session's auth keys and keeps the rest", %{conn: conn, session: session} do
    :ok = Baudrate.Auth.delete_session_by_token(session.session_token)

    conn = conn |> Plug.Test.init_test_session(session) |> ForgetRevokedSession.call([])

    for key <- @auth_keys, do: assert(get_session(conn, key) == nil)
    assert get_session(conn, :locale) == "ja_JP"
  end

  test "leaves a live session alone", %{conn: conn, session: session} do
    conn = conn |> Plug.Test.init_test_session(session) |> ForgetRevokedSession.call([])

    for key <- @auth_keys, do: assert(get_session(conn, key) == Map.fetch!(session, key))
  end

  test "leaves a cookie without a token alone", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{locale: "ja_JP"})
      |> ForgetRevokedSession.call([])

    assert get_session(conn, :locale) == "ja_JP"
  end

  test "the sign-in page forgets a revoked session's socket id", %{conn: conn, session: session} do
    Baudrate.Repo.insert!(%Baudrate.Setup.Setting{key: "setup_completed", value: "true"})
    :ok = Baudrate.Auth.delete_session_by_token(session.session_token)

    conn = conn |> Plug.Test.init_test_session(session) |> get("/login")

    assert html_response(conn, 200)
    assert get_session(conn, :live_socket_id) == nil
  end
end
