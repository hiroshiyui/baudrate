defmodule BaudrateWeb.Plugs.RefreshSessionTest do
  use BaudrateWeb.ConnCase

  alias BaudrateWeb.Plugs.RefreshSession

  setup do
    user = setup_user("user")
    {:ok, session_token, refresh_token} = Baudrate.Auth.create_user_session(user.id)
    %{user: user, session_token: session_token, refresh_token: refresh_token}
  end

  describe "live_socket_id backfill" do
    test "adds live_socket_id for a valid session that lacks it", %{
      conn: conn,
      session_token: session_token,
      refresh_token: refresh_token
    } do
      conn =
        conn
        |> Plug.Test.init_test_session(%{
          session_token: session_token,
          refresh_token: refresh_token,
          refreshed_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })
        |> RefreshSession.call([])

      id = Baudrate.Auth.session_id_by_token(session_token)
      assert get_session(conn, :live_socket_id) == "user_session:#{id}"
    end

    test "keeps an existing live_socket_id and ignores unknown tokens", %{conn: conn} do
      kept =
        conn
        |> Plug.Test.init_test_session(%{
          session_token: "whatever",
          live_socket_id: "user_session:1"
        })
        |> RefreshSession.call([])

      assert get_session(kept, :live_socket_id) == "user_session:1"

      unknown =
        conn
        |> Plug.Test.init_test_session(%{session_token: "not-a-session"})
        |> RefreshSession.call([])

      refute get_session(unknown, :live_socket_id)
    end
  end

  describe "call/2" do
    test "passes through when no session tokens are present", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> RefreshSession.call([])

      # conn should pass through unchanged (no drop, no new tokens)
      refute get_session(conn, :session_token)
    end

    test "passes through when refreshed_at is recent", %{
      conn: conn,
      session_token: session_token,
      refresh_token: refresh_token
    } do
      recent = DateTime.utc_now() |> DateTime.to_iso8601()

      conn =
        conn
        |> Plug.Test.init_test_session(%{
          session_token: session_token,
          refresh_token: refresh_token,
          refreshed_at: recent
        })
        |> RefreshSession.call([])

      # Tokens should remain unchanged since refresh is not needed
      assert get_session(conn, :session_token) == session_token
      assert get_session(conn, :refresh_token) == refresh_token
    end

    test "rotates tokens when refreshed_at is stale", %{
      conn: conn,
      session_token: session_token,
      refresh_token: refresh_token
    } do
      # Set refreshed_at to 2 days ago to trigger rotation
      stale =
        DateTime.utc_now()
        |> DateTime.add(-2 * 86_400, :second)
        |> DateTime.to_iso8601()

      conn =
        conn
        |> Plug.Test.init_test_session(%{
          session_token: session_token,
          refresh_token: refresh_token,
          refreshed_at: stale
        })
        |> RefreshSession.call([])

      new_session_token = get_session(conn, :session_token)
      new_refresh_token = get_session(conn, :refresh_token)

      # Tokens should have been rotated
      refute new_session_token == session_token
      refute new_refresh_token == refresh_token
      assert is_binary(new_session_token)
      assert is_binary(new_refresh_token)
    end

    test "drops session when refresh token is invalid", %{
      conn: conn,
      session_token: session_token
    } do
      stale =
        DateTime.utc_now()
        |> DateTime.add(-2 * 86_400, :second)
        |> DateTime.to_iso8601()

      conn =
        conn
        |> Plug.Test.init_test_session(%{
          session_token: session_token,
          refresh_token: "invalid_refresh_token",
          refreshed_at: stale
        })
        |> RefreshSession.call([])

      # Session should be dropped (configure_session drop: true)
      assert conn.private[:plug_session_info] == :drop
    end

    test "passes through when refreshed_at is not a valid ISO8601 string", %{
      conn: conn,
      session_token: session_token,
      refresh_token: refresh_token
    } do
      conn =
        conn
        |> Plug.Test.init_test_session(%{
          session_token: session_token,
          refresh_token: refresh_token,
          refreshed_at: "not-a-date"
        })
        |> RefreshSession.call([])

      # Should pass through without action
      assert get_session(conn, :session_token) == session_token
    end

    test "passes through when tokens are present but refreshed_at is missing", %{
      conn: conn,
      session_token: session_token,
      refresh_token: refresh_token
    } do
      conn =
        conn
        |> Plug.Test.init_test_session(%{
          session_token: session_token,
          refresh_token: refresh_token
        })
        |> RefreshSession.call([])

      # Should pass through without action
      assert get_session(conn, :session_token) == session_token
    end
  end
end
