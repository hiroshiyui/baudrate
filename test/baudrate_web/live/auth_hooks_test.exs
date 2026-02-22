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
      assert {:redirect, %{to: "/login"}} = socket.redirected
    end

    test "redirects to /login when session_token is invalid" do
      socket = %Phoenix.LiveView.Socket{}
      session = %{"session_token" => "invalid_token"}

      assert {:halt, socket} = AuthHooks.on_mount(:require_auth, %{}, session, socket)
      assert {:redirect, %{to: "/login"}} = socket.redirected
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

      assert {:redirect, %{to: "/login"}} = socket.redirected
    end

    test "redirects to /login when user_id does not exist" do
      socket = %Phoenix.LiveView.Socket{}
      session = %{"user_id" => -1}

      assert {:halt, socket} =
               AuthHooks.on_mount(:require_password_auth, %{}, session, socket)

      assert {:redirect, %{to: "/login"}} = socket.redirected
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
      {:ok, banned_user} = Baudrate.Auth.ban_user(user, admin.id, "test ban")
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
      assert {:redirect, %{to: "/login"}} = socket.redirected
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

      assert {:redirect, %{to: "/login"}} = socket.redirected
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
end
