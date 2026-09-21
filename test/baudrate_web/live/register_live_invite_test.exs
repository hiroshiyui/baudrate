defmodule BaudrateWeb.RegisterLiveInviteTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    Repo.insert!(%Setting{key: "registration_mode", value: "invite_only"})
    # Seed roles so register_user can find the "user" role
    Baudrate.Setup.seed_roles_and_permissions()
    # Clear shared rate limit buckets to avoid cross-test interference
    BaudrateWeb.RateLimit.reset_all()
    {:ok, conn: conn}
  end

  test "shows invite code field in invite_only mode", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/register")
    assert html =~ "Invite Code"
    assert html =~ "Registration requires an invite code"
  end

  test "pre-fills invite code from ?invite= query param", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/register?invite=abc12345")
    assert html =~ ~s(value="abc12345")
  end

  test "registration fails without invite code", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/register")

    html =
      lv
      |> form("#register-form",
        user: %{
          username: "newuser_#{System.unique_integer([:positive])}",
          password: "Password123!x",
          password_confirmation: "Password123!x",
          invite_code: ""
        }
      )
      |> render_submit()

    assert html =~ "invite code is required"
  end

  test "registration fails with invalid invite code", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/register")

    html =
      lv
      |> form("#register-form",
        user: %{
          username: "newuser_#{System.unique_integer([:positive])}",
          password: "Password123!x",
          password_confirmation: "Password123!x",
          invite_code: "invalid123"
        }
      )
      |> render_submit()

    assert html =~ "Invalid invite code"
  end

  test "registration succeeds with valid invite code and shows recovery codes", %{conn: conn} do
    admin = setup_admin()
    {:ok, invite} = Auth.generate_invite_code(admin)

    {:ok, lv, _html} = live(conn, "/register")

    html =
      lv
      |> form("#register-form",
        user: %{
          username: "invited_#{System.unique_integer([:positive])}",
          password: "Password123!x",
          password_confirmation: "Password123!x",
          invite_code: invite.code,
          terms_accepted: "true"
        }
      )
      |> render_submit()

    assert html =~ "Recovery Codes"

    # Invite mode signs in like open mode does (P4-D2), through the same
    # trigger-action POST rather than a bounce to /login.
    html = lv |> render_click("ack_codes")
    assert html =~ ~s(action="/auth/session")
    assert html =~ ~s(phx-trigger-action)
  end

  defp setup_admin do
    import Ecto.Query
    alias Baudrate.Setup
    alias Baudrate.Setup.{Role, User}

    unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    role = Repo.one!(from(r in Role, where: r.name == "admin"))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "admin_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end
end
