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

  test "every action the log accepts has a label" do
    untranslated =
      Enum.filter(
        Baudrate.Moderation.Log.valid_actions(),
        &(BaudrateWeb.Admin.ModerationLogLive.translate_action(&1) == &1)
      )

    assert untranslated == [],
           "shown as a bare identifier in the log: #{inspect(untranslated)}"
  end

  test "every target kind a caller logs has a label" do
    kinds =
      Path.wildcard("lib/**/*.ex")
      |> Enum.flat_map(
        &Regex.scan(~r/target_type: "([a-z_]+)"/, File.read!(&1), capture: :all_but_first)
      )
      |> List.flatten()
      |> Enum.uniq()

    assert kinds != []

    untranslated =
      Enum.filter(kinds, &(BaudrateWeb.Admin.ModerationLogLive.translate_target_type(&1) == &1))

    assert untranslated == [], "shown as a bare identifier in the log: #{inspect(untranslated)}"
  end

  test "admin can view moderation log", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

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
    conn = log_in_admin(conn, admin)

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
    conn = log_in_admin(conn, admin)

    Moderation.log_action(admin.id, "ban_user")
    Moderation.log_action(admin.id, "create_board")

    {:ok, lv, _html} = live(conn, "/admin/moderation-log")

    html = lv |> element("button[phx-value-action=\"ban_user\"]") |> render_click()
    assert html =~ "Ban User"
  end

  test "log table body is not a live region", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    Moderation.log_action(admin.id, "ban_user")

    {:ok, lv, _html} = live(conn, "/admin/moderation-log")

    assert has_element?(lv, "#admin-moderation-log-table tbody")
    refute has_element?(lv, "#admin-moderation-log-table tbody[aria-live]")
  end
end
