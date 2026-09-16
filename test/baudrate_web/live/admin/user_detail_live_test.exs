defmodule BaudrateWeb.Admin.UserDetailLiveTest do
  @moduledoc """
  The user detail page: the record staff read before deciding about a person,
  and the actions they take on that decision (ADR 0029).
  """

  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  describe "the record" do
    test "an admin sees role, status and an empty sanction history", %{conn: conn} do
      admin = setup_user("admin")
      member = setup_user("user")
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin/users/#{member.id}")

      assert html =~ member.username
      assert html =~ "No restriction is in force"
      assert html =~ "Nothing has ever been issued against this account"
    end

    test "an unknown user redirects back to the list", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)

      assert {:error, {:redirect, %{to: "/admin/users"}}} = live(conn, ~p"/admin/users/999999")
    end

    test "an ordinary member cannot reach it at all", %{conn: conn} do
      member = setup_user("user")
      other = setup_user("user")
      conn = log_in_user(conn, member)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/users/#{other.id}")
    end
  end

  describe "IP addresses are admin-only" do
    test "an admin sees the sign-in attempts section", %{conn: conn} do
      admin = setup_user("admin")
      member = setup_user("user")
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin/users/#{member.id}")

      assert html =~ "Recent sign-in attempts"
    end

    test "a moderator does not, and the addresses never reach the page", %{conn: conn} do
      moderator = setup_user("moderator")
      member = setup_user("user")
      Auth.record_login_attempt(member.username, "203.0.113.42", false)

      conn = log_in_user(conn, moderator)
      {:ok, _lv, html} = live(conn, ~p"/admin/users/#{member.id}")

      refute html =~ "Recent sign-in attempts"
      refute html =~ "203.0.113.42"
    end
  end

  describe "issuing a sanction" do
    test "a moderator can silence a member, with a reason and an end", %{conn: conn} do
      moderator = setup_user("moderator")
      member = setup_user("user")
      conn = log_in_user(conn, moderator)

      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member.id}")

      lv |> element("#admin-user-detail-silence") |> render_click()

      html =
        lv
        |> form("#admin-user-detail-sanction-form", %{
          "reason" => "Repeated abuse",
          "days" => "7"
        })
        |> render_submit()

      assert html =~ "The account was silenced"
      assert html =~ "Repeated abuse"

      assert Auth.silenced?(member)
      assert Auth.ensure_can_interact(member) == {:error, :account_silenced}
    end

    test "the typed reason survives a re-render", %{conn: conn} do
      admin = setup_user("admin")
      member = setup_user("user")
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member.id}")
      lv |> element("#admin-user-detail-silence") |> render_click()

      html =
        lv
        |> form("#admin-user-detail-sanction-form", %{"reason" => "Half typed", "days" => "7"})
        |> render_change()

      assert html =~ "Half typed"
    end

    test "a moderator is refused an end beyond the cap", %{conn: conn} do
      moderator = setup_user("moderator")
      member = setup_user("user")
      conn = log_in_user(conn, moderator)

      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member.id}")
      lv |> element("#admin-user-detail-silence") |> render_click()

      html =
        lv
        |> form("#admin-user-detail-sanction-form", %{"reason" => "Too long", "days" => "365"})
        |> render_submit()

      assert html =~ "Choose an end within 30 days"
      refute Auth.silenced?(member)
    end

    test "a moderator gets no actions against another moderator", %{conn: conn} do
      moderator = setup_user("moderator")
      peer = setup_user("moderator")
      conn = log_in_user(conn, moderator)

      {:ok, lv, html} = live(conn, ~p"/admin/users/#{peer.id}")

      refute has_element?(lv, "#admin-user-detail-silence")
      assert html =~ "You cannot take action on this account"
    end

    test "nobody gets actions against their own account", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{admin.id}")

      refute has_element?(lv, "#admin-user-detail-silence")
    end
  end

  describe "lifting" do
    test "an admin can lift a silence, and the record keeps the row", %{conn: conn} do
      admin = setup_user("admin")
      member = setup_user("user")
      {:ok, _} = Auth.issue_sanction(admin, member, "silence", reason: "Cooling off")

      conn = log_in_admin(conn, admin)
      {:ok, lv, html} = live(conn, ~p"/admin/users/#{member.id}")

      assert html =~ "Cooling off"

      html = lv |> element("#admin-user-detail-lift-silence") |> render_click()

      assert html =~ "The restriction was lifted"
      assert html =~ "No restriction is in force"
      # Lifted, not deleted.
      assert html =~ "Cooling off"
      refute Auth.silenced?(member)
    end
  end

  test "the users list links each username to its record", %{conn: conn} do
    admin = setup_user("admin")
    member = setup_user("user")
    conn = log_in_admin(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    assert has_element?(lv, "#admin-users-detail-link-#{member.id}")
  end
end
