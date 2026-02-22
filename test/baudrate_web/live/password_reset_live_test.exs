defmodule BaudrateWeb.PasswordResetLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Baudrate.Setup.seed_roles_and_permissions()
    Hammer.delete_buckets("password_reset:unknown")
    Hammer.delete_buckets("password_reset:127.0.0.1")
    {:ok, conn: conn}
  end

  defp create_user_with_codes(username) do
    user = setup_user("user")

    # We need a user with a known username, so update it
    user =
      user
      |> Ecto.Changeset.change(%{username: username})
      |> Repo.update!()
      |> Repo.preload(:role)

    codes = Auth.generate_recovery_codes(user)
    {user, codes}
  end

  test "renders the password reset form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/password-reset")
    assert html =~ "Reset Password"
    assert html =~ "Username"
    assert html =~ "Recovery Code"
    assert html =~ "New Password"
    assert html =~ "Confirm New Password"
  end

  test "successful password reset redirects to /login", %{conn: conn} do
    {_user, codes} = create_user_with_codes("resetlive_user")
    [code | _] = codes

    {:ok, lv, _html} = live(conn, "/password-reset")

    lv
    |> form("form",
      reset: %{
        username: "resetlive_user",
        recovery_code: code,
        new_password: "NewSecure1!!x",
        new_password_confirmation: "NewSecure1!!x"
      }
    )
    |> render_submit()

    {path, _flash} = assert_redirect(lv)
    assert path == "/login"
  end

  test "shows error for invalid credentials", %{conn: conn} do
    {_user, _codes} = create_user_with_codes("invalidcred_user")

    {:ok, lv, _html} = live(conn, "/password-reset")

    html =
      lv
      |> form("form",
        reset: %{
          username: "invalidcred_user",
          recovery_code: "wrongcode",
          new_password: "NewSecure1!!x",
          new_password_confirmation: "NewSecure1!!x"
        }
      )
      |> render_submit()

    assert html =~ "Invalid username or recovery code"
  end

  test "shows error for nonexistent username", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/password-reset")

    html =
      lv
      |> form("form",
        reset: %{
          username: "ghost_user_999",
          recovery_code: "anycode",
          new_password: "NewSecure1!!x",
          new_password_confirmation: "NewSecure1!!x"
        }
      )
      |> render_submit()

    assert html =~ "Invalid username or recovery code"
  end

  test "shows password validation errors", %{conn: conn} do
    {_user, codes} = create_user_with_codes("pwerror_user")
    [code | _] = codes

    {:ok, lv, _html} = live(conn, "/password-reset")

    html =
      lv
      |> form("form",
        reset: %{
          username: "pwerror_user",
          recovery_code: code,
          new_password: "short",
          new_password_confirmation: "short"
        }
      )
      |> render_submit()

    assert html =~ "should be at least 12 character"
  end

  test "rate limits after too many attempts", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/password-reset")

    # Exhaust the rate limit (5 attempts per hour) via submitting
    for _i <- 1..5 do
      lv
      |> form("form",
        reset: %{
          username: "anyone",
          recovery_code: "anycode",
          new_password: "NewSecure1!!x",
          new_password_confirmation: "NewSecure1!!x"
        }
      )
      |> render_submit()
    end

    # The 6th attempt should be rate limited
    html =
      lv
      |> form("form",
        reset: %{
          username: "anyone",
          recovery_code: "anycode",
          new_password: "NewSecure1!!x",
          new_password_confirmation: "NewSecure1!!x"
        }
      )
      |> render_submit()

    assert html =~ "Too many attempts"
  end

  test "authenticated users are redirected away from /password-reset", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/password-reset")
  end
end
