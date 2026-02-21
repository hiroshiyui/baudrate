defmodule BaudrateWeb.RegisterLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    # Seed roles so register_user can find the "user" role
    Baudrate.Setup.seed_roles_and_permissions()
    {:ok, conn: conn}
  end

  test "renders registration form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/register")
    assert html =~ "Sign Up"
    assert html =~ "Username"
    assert html =~ "Password"
    assert html =~ "Confirm Password"
  end

  test "validates form on change", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/register")

    html =
      lv
      |> form("form", user: %{username: "ab", password: "short", password_confirmation: ""})
      |> render_change()

    assert html =~ "should be at least 3"
  end

  test "registers user successfully in open mode", %{conn: conn} do
    Repo.insert!(%Setting{key: "registration_mode", value: "open"})

    {:ok, lv, _html} = live(conn, "/register")

    lv
    |> form("form",
      user: %{
        username: "newuser",
        password: "SecurePass1!!",
        password_confirmation: "SecurePass1!!"
      }
    )
    |> render_submit()

    assert_redirect(lv, "/login")
  end

  test "registers user successfully in approval mode", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/register")

    lv
    |> form("form",
      user: %{
        username: "pendinguser",
        password: "SecurePass1!!",
        password_confirmation: "SecurePass1!!"
      }
    )
    |> render_submit()

    assert_redirect(lv, "/login")

    user = Repo.one!(from u in Baudrate.Setup.User, where: u.username == "pendinguser")
    assert user.status == "pending"
  end

  test "shows validation errors on invalid input", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/register")

    html =
      lv
      |> form("form",
        user: %{
          username: "",
          password: "short",
          password_confirmation: "mismatch"
        }
      )
      |> render_submit()

    assert html =~ "can&#39;t be blank" || html =~ "can't be blank"
  end

  test "redirects authenticated users away from /register", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/register")
  end

  test "shows register link on login page", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/login")
    assert html =~ "Sign Up"
    assert html =~ "/register"
  end
end
