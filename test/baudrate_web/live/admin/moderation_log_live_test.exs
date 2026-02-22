defmodule BaudrateWeb.Admin.ModerationLogLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Moderation
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    {:ok, conn: conn}
  end

  test "admin can view moderation log", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, _lv, html} = live(conn, "/admin/moderation-log")
    assert html =~ "Moderation Log"
    assert html =~ ~s(role="toolbar")
    assert html =~ ~s(aria-label="Filter by action")
    assert html =~ ~s(aria-pressed="true")
  end

  test "non-admin is redirected away", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/admin/moderation-log")
  end

  test "displays moderation log entries", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    Moderation.log_action(admin.id, "ban_user",
      target_type: "user",
      target_id: 42,
      details: %{"username" => "baduser"}
    )

    {:ok, _lv, html} = live(conn, "/admin/moderation-log")
    assert html =~ admin.username
    assert html =~ "baduser"
  end

  test "admin can filter by action", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    Moderation.log_action(admin.id, "ban_user")
    Moderation.log_action(admin.id, "create_board")

    {:ok, lv, _html} = live(conn, "/admin/moderation-log")

    html = lv |> element("button[phx-value-action=\"ban_user\"]") |> render_click()
    assert html =~ "Ban User"
  end
end
