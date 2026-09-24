defmodule BaudrateWeb.Admin.AnnouncementsLiveTest do
  use BaudrateWeb.ConnCase

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Baudrate.Announcements
  alias Baudrate.Announcements.Announcement
  alias Baudrate.Moderation.Log
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    admin = setup_user("admin")
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    %{conn: conn, admin: admin}
  end

  defp logged(action), do: Repo.all(from(l in Log, where: l.action == ^action))

  describe "/admin/announcements" do
    test "posts one, which every page then shows, and ends it", %{conn: conn, admin: admin} do
      conn = log_in_admin(conn, admin)
      {:ok, lv, _html} = live(conn, "/admin/announcements")

      lv
      |> form("#admin-announcements-form",
        announcement: %{body: "Maintenance tonight", duration: "3"}
      )
      |> render_submit()

      assert [%Announcement{id: id, ends_at: %DateTime{}}] = Repo.all(Announcement)
      assert has_element?(lv, "#admin-announcement-#{id} .admin-announcement-status", "Showing")
      assert [%{details: %{"notified" => false}}] = logged("create_announcement")

      {:ok, _home, html} = live(conn, "/")
      assert html =~ "Maintenance tonight"

      lv |> element("#admin-announcement-end-#{id}") |> render_click()
      assert has_element?(lv, "#admin-announcement-#{id} .admin-announcement-status", "Ended")
      assert [_] = logged("end_announcement")

      {:ok, _home, html} = live(conn, "/")
      refute html =~ "Maintenance tonight"
    end

    test "a refused announcement marks the text box invalid, not only the flash", %{
      conn: conn,
      admin: admin
    } do
      {:ok, lv, _html} = live(log_in_admin(conn, admin), "/admin/announcements")

      lv
      |> form("#admin-announcements-form", announcement: %{body: "   "})
      |> render_submit()

      assert has_element?(
               lv,
               ~s(#admin-announcements-body[aria-invalid="true"][aria-describedby="admin-announcements-body-error"])
             )

      assert has_element?(lv, "#admin-announcements-body-error")
    end

    test "a moderator is turned away" do
      moderator = setup_user("moderator")

      assert {:error, {:redirect, %{to: "/"}}} =
               live(log_in_user(build_conn(), moderator), "/admin/announcements")
    end
  end

  describe "the notice on every page" do
    setup %{admin: admin} do
      {:ok, a} = Announcements.create_announcement(admin, %{"body" => "Read <me>"})
      %{announcement: a}
    end

    test "a member dismisses it once, for good", %{conn: conn, announcement: a} do
      member = setup_user("user")
      conn = log_in_user(conn, member)

      {:ok, lv, html} = live(conn, "/")
      # Plain text, escaped.
      assert html =~ "Read &lt;me&gt;"
      assert has_element?(lv, ~s(#announcement-notice-#{a.id}[data-guest="false"]))

      # The accessible name contains the visible word (WCAG 2.5.3).
      assert has_element?(
               lv,
               ~s(#announcement-notice-dismiss-#{a.id}[aria-label="Close this announcement"]),
               "Close"
             )

      lv |> element("#announcement-notice-dismiss-#{a.id}") |> render_click()
      refute has_element?(lv, "#announcement-notice-#{a.id}")
      assert_push_event(lv, "focus", %{id: "main-content"})

      {:ok, _lv, html} = live(conn, "/search")
      refute html =~ "Read &lt;me&gt;"
    end

    test "a guest sees it, with a button their browser handles", %{conn: conn, announcement: a} do
      {:ok, lv, _html} = live(conn, "/")

      assert has_element?(lv, ~s(#announcement-notice-#{a.id}[data-guest="true"]))
      assert has_element?(lv, "#announcement-notice-dismiss-#{a.id}[data-announcement-dismiss]")
      refute has_element?(lv, ~s(#announcement-notice-dismiss-#{a.id}[phx-click]))
    end

    test "a crafted dismiss from a guest records nothing", %{conn: conn, announcement: a} do
      {:ok, lv, _html} = live(conn, "/")
      render_click(lv, "dismiss_announcement", %{"id" => to_string(a.id)})

      refute Repo.exists?(Baudrate.Announcements.Dismissal)
    end
  end

  describe "the contact setting" do
    test "is saved from settings and shown in the footer and on the policy pages", %{
      conn: conn,
      admin: admin
    } do
      Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
      conn = log_in_admin(conn, admin)
      {:ok, lv, _html} = live(conn, "/admin/settings")

      lv
      |> form("#settings-form", settings: %{site_contact: "admin@example.org"})
      |> render_submit()

      assert Baudrate.Setup.site_contact() == "admin@example.org"

      html = build_conn() |> get("/rules") |> html_response(200)
      assert html =~ ~s(id="site-footer-contact")
      assert html =~ ~s(id="policy-contact")
      assert html =~ "admin@example.org"
    end

    test "is one line" do
      cs = Baudrate.Setup.change_settings(%{"site_contact" => "a\nb"})
      refute cs.valid?
    end

    test "unset shows nothing", %{conn: conn} do
      html = conn |> get("/rules") |> html_response(200)
      refute html =~ ~s(id="site-footer-contact")
      refute html =~ ~s(id="policy-contact")
    end
  end
end
