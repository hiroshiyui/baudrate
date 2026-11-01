defmodule BaudrateWeb.AuthHooksTest do
  use BaudrateWeb.ConnCase

  alias BaudrateWeb.AuthHooks

  setup do
    user = setup_user("user")
    {:ok, session_token, _refresh_token} = Baudrate.Auth.create_user_session(user.id)
    %{user: user, session_token: session_token}
  end

  describe "on_mount :require_auth" do
    test "assigns current_user when session_token is valid", %{
      user: user,
      session_token: session_token
    } do
      socket = %Phoenix.LiveView.Socket{}
      session = %{"session_token" => session_token}

      assert {:cont, socket} = AuthHooks.on_mount(:require_auth, %{}, session, socket)
      assert socket.assigns.current_user.id == user.id
    end

    test "redirects to /login when session_token is missing" do
      socket = %Phoenix.LiveView.Socket{}
      session = %{}

      assert {:halt, socket} = AuthHooks.on_mount(:require_auth, %{}, session, socket)
      assert {:redirect, %{to: "/login" <> _}} = socket.redirected
    end

    test "redirects to /login when session_token is invalid" do
      socket = %Phoenix.LiveView.Socket{}
      session = %{"session_token" => "invalid_token"}

      assert {:halt, socket} = AuthHooks.on_mount(:require_auth, %{}, session, socket)
      assert {:redirect, %{to: "/login" <> _}} = socket.redirected
    end
  end

  describe "on_mount :require_password_auth" do
    test "assigns current_user when user_id is valid", %{user: user} do
      socket = %Phoenix.LiveView.Socket{}
      session = %{"user_id" => user.id}

      assert {:cont, socket} =
               AuthHooks.on_mount(:require_password_auth, %{}, session, socket)

      assert socket.assigns.current_user.id == user.id
    end

    test "redirects to /login when user_id is missing" do
      socket = %Phoenix.LiveView.Socket{}
      session = %{}

      assert {:halt, socket} =
               AuthHooks.on_mount(:require_password_auth, %{}, session, socket)

      assert {:redirect, %{to: "/login" <> _}} = socket.redirected
    end

    test "redirects to /login when user_id does not exist" do
      socket = %Phoenix.LiveView.Socket{}
      session = %{"user_id" => -1}

      assert {:halt, socket} =
               AuthHooks.on_mount(:require_password_auth, %{}, session, socket)

      assert {:redirect, %{to: "/login" <> _}} = socket.redirected
    end
  end

  describe "on_mount :redirect_if_authenticated" do
    test "redirects to / when user has valid session", %{session_token: session_token} do
      socket = %Phoenix.LiveView.Socket{}
      session = %{"session_token" => session_token}

      assert {:halt, socket} =
               AuthHooks.on_mount(:redirect_if_authenticated, %{}, session, socket)

      assert {:redirect, %{to: "/"}} = socket.redirected
    end

    test "continues when session_token is missing" do
      socket = %Phoenix.LiveView.Socket{}
      session = %{}

      assert {:cont, ^socket} =
               AuthHooks.on_mount(:redirect_if_authenticated, %{}, session, socket)
    end

    test "continues when session_token is invalid" do
      socket = %Phoenix.LiveView.Socket{}
      session = %{"session_token" => "invalid_token"}

      assert {:cont, ^socket} =
               AuthHooks.on_mount(:redirect_if_authenticated, %{}, session, socket)
    end
  end

  describe "on_mount :optional_auth" do
    test "assigns current_user when session_token is valid", %{
      user: user,
      session_token: session_token
    } do
      socket = %Phoenix.LiveView.Socket{}
      session = %{"session_token" => session_token}

      assert {:cont, socket} = AuthHooks.on_mount(:optional_auth, %{}, session, socket)
      assert socket.assigns.current_user.id == user.id
    end

    test "assigns nil when no session" do
      socket = %Phoenix.LiveView.Socket{}
      session = %{}

      assert {:cont, socket} = AuthHooks.on_mount(:optional_auth, %{}, session, socket)
      assert socket.assigns.current_user == nil
    end

    test "assigns nil when session is invalid" do
      socket = %Phoenix.LiveView.Socket{}
      session = %{"session_token" => "invalid_token"}

      assert {:cont, socket} = AuthHooks.on_mount(:optional_auth, %{}, session, socket)
      assert socket.assigns.current_user == nil
    end
  end

  describe "on_mount :require_admin" do
    test "allows admin user" do
      admin = setup_user("admin")

      socket =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(:current_user, admin)

      assert {:cont, ^socket} = AuthHooks.on_mount(:require_admin, %{}, %{}, socket)
    end

    test "redirects non-admin user to /", %{user: user} do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, current_user: user}
      }

      assert {:halt, socket} = AuthHooks.on_mount(:require_admin, %{}, %{}, socket)
      assert {:redirect, %{to: "/"}} = socket.redirected
    end
  end

  describe "banned user handling" do
    setup %{user: user} do
      admin = setup_user("admin")
      {:ok, banned_user, _revoked} = Baudrate.Auth.ban_user(user, admin, "test ban")
      banned_user = Baudrate.Auth.get_user(banned_user.id)
      # Create a new session after banning (ban_user deletes all sessions)
      {:ok, session_token, _} = Baudrate.Auth.create_user_session(banned_user.id)
      %{banned_user: banned_user, banned_session_token: session_token}
    end

    test "require_auth redirects banned user to /login", %{
      banned_session_token: session_token
    } do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}}
      }

      session = %{"session_token" => session_token}

      assert {:halt, socket} = AuthHooks.on_mount(:require_auth, %{}, session, socket)
      assert {:redirect, %{to: "/login" <> _}} = socket.redirected
    end

    test "optional_auth assigns nil for banned user", %{
      banned_session_token: session_token
    } do
      socket = %Phoenix.LiveView.Socket{}
      session = %{"session_token" => session_token}

      assert {:cont, socket} = AuthHooks.on_mount(:optional_auth, %{}, session, socket)
      assert socket.assigns.current_user == nil
    end

    test "require_password_auth redirects banned user to /login", %{
      banned_user: banned_user
    } do
      socket = %Phoenix.LiveView.Socket{}
      session = %{"user_id" => banned_user.id}

      assert {:halt, socket} =
               AuthHooks.on_mount(:require_password_auth, %{}, session, socket)

      assert {:redirect, %{to: "/login" <> _}} = socket.redirected
    end

    test "redirect_if_authenticated allows banned user to continue", %{
      banned_session_token: session_token
    } do
      socket = %Phoenix.LiveView.Socket{}
      session = %{"session_token" => session_token}

      assert {:cont, _socket} =
               AuthHooks.on_mount(:redirect_if_authenticated, %{}, session, socket)
    end
  end

  describe "session locale propagation" do
    setup do
      previous = Gettext.get_locale()
      on_exit(fn -> Gettext.put_locale(previous) end)
      Gettext.put_locale("en")
      :ok
    end

    test "optional_auth applies session locale and assigns it for anonymous visitor" do
      socket = %Phoenix.LiveView.Socket{}
      session = %{"locale" => "ja_JP"}

      assert {:cont, socket} = AuthHooks.on_mount(:optional_auth, %{}, session, socket)
      assert socket.assigns.current_user == nil
      assert socket.assigns.locale == "ja_JP"
      assert Gettext.get_locale() == "ja_JP"
    end

    test "optional_auth keeps default locale when session has none" do
      socket = %Phoenix.LiveView.Socket{}
      session = %{}

      assert {:cont, socket} = AuthHooks.on_mount(:optional_auth, %{}, session, socket)
      assert socket.assigns.current_user == nil
      assert socket.assigns.locale == "en"
      assert Gettext.get_locale() == "en"
    end

    test "optional_auth assigns session locale when stale session_token resolves to no user" do
      socket = %Phoenix.LiveView.Socket{}
      session = %{"session_token" => "invalid_token", "locale" => "zh_TW"}

      assert {:cont, socket} = AuthHooks.on_mount(:optional_auth, %{}, session, socket)
      assert socket.assigns.current_user == nil
      assert socket.assigns.locale == "zh_TW"
      assert Gettext.get_locale() == "zh_TW"
    end

    test "redirect_if_authenticated applies session locale before rendering login page" do
      socket = %Phoenix.LiveView.Socket{}
      session = %{"locale" => "ja_JP"}

      assert {:cont, _socket} =
               AuthHooks.on_mount(:redirect_if_authenticated, %{}, session, socket)

      assert Gettext.get_locale() == "ja_JP"
    end

    test "user preferred_locales override the session locale", %{user: user} do
      {:ok, user} = Baudrate.Auth.update_preferred_locales(user, ["zh_TW"])
      {:ok, session_token, _refresh} = Baudrate.Auth.create_user_session(user.id)
      socket = %Phoenix.LiveView.Socket{}
      # Session locale was "ja_JP" (e.g. set by Accept-Language plug for an
      # earlier anonymous request) — user preference must win after login.
      session = %{"session_token" => session_token, "locale" => "ja_JP"}

      assert {:cont, socket} = AuthHooks.on_mount(:optional_auth, %{}, session, socket)
      assert socket.assigns.locale == "zh_TW"
      assert Gettext.get_locale() == "zh_TW"
    end
  end

  # Since Phoenix 1.8.16 the socket close alone reloads a revoked page only
  # after a 5-10 s delay, so the page is told and leaves by itself.
  describe "session revocation" do
    import Phoenix.LiveViewTest

    setup do
      Baudrate.Repo.insert!(%Baudrate.Setup.Setting{key: "setup_completed", value: "true"})
      :ok
    end

    defp live_socket_id(token),
      do: Baudrate.Auth.live_socket_id(Baudrate.Auth.session_id_by_token(token))

    test "a signed-in page leaves for sign-in, remembering where it was", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)
      token = get_session(conn, :session_token)
      {:ok, view, _html} = live(conn, "/bookmarks")

      :ok = Baudrate.Auth.delete_session_by_token(token)

      assert_redirect(view, "/login?" <> URI.encode_query(%{"return_to" => "/bookmarks"}))
    end

    test "a public page browsed while signed in leaves too", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      token = get_session(conn, :session_token)
      {:ok, view, _html} = live(conn, "/")

      :ok = Baudrate.Auth.delete_session_by_token(token)

      assert_redirect(view, "/login?" <> URI.encode_query(%{"return_to" => "/"}))
    end

    test "a page whose session still stands stays put", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      token = get_session(conn, :session_token)
      {:ok, view, _html} = live(conn, "/bookmarks")

      send(view.pid, {:session_revoked, live_socket_id(token)})

      assert render(view) =~ "bookmarks-heading"
    end
  end
end
