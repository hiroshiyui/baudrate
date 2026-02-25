defmodule BaudrateWeb.Admin.SettingsLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    Repo.insert!(%Setting{key: "registration_mode", value: "approval_required"})
    {:ok, conn: conn}
  end

  test "admin can view settings page", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, _lv, html} = live(conn, "/admin/settings")
    assert html =~ "Admin Settings"
    assert html =~ "Test Site"
    assert html =~ "approval_required"
  end

  test "non-admin is redirected away", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/admin/settings")
  end

  test "admin can validate settings", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/settings")

    html =
      lv
      |> form("#settings-form", settings: %{site_name: "", registration_mode: "open"})
      |> render_change()

    assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
  end

  test "admin can save settings", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/settings")

    html =
      lv
      |> form("#settings-form", settings: %{site_name: "New Name", registration_mode: "open"})
      |> render_submit()

    assert html =~ "Settings saved successfully"
    assert Setup.get_setting("site_name") == "New Name"
    assert Setup.get_setting("registration_mode") == "open"
  end

  test "admin sees validation errors on invalid submit", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/settings")

    html =
      lv
      |> form("#settings-form", settings: %{site_name: ""})
      |> render_submit()

    refute html =~ "Settings saved successfully"
    # Original value unchanged
    assert Setup.get_setting("site_name") == "Test Site"
  end

  test "admin can save timezone setting", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_user(conn, admin)

    {:ok, lv, html} = live(conn, "/admin/settings")
    assert html =~ "Timezone"

    html =
      lv
      |> form("#settings-form",
        settings: %{site_name: "Test Site", timezone: "Asia/Taipei"}
      )
      |> render_submit()

    assert html =~ "Settings saved successfully"
    assert Setup.get_setting("timezone") == "Asia/Taipei"
  end

  describe "EUA management" do
    test "EUA textarea renders on settings page", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_user(conn, admin)

      {:ok, _lv, html} = live(conn, "/admin/settings")
      assert html =~ "End User Agreement"
      assert html =~ "eua-form"
    end

    test "admin can save EUA text", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/settings")

      html =
        lv
        |> form("#eua-form", eua_settings: %{eua: "**Custom Terms of Service**"})
        |> render_submit()

      assert html =~ "End User Agreement saved"
      assert Setup.get_eua() == "**Custom Terms of Service**"
    end

    test "admin can update existing EUA", %{conn: conn} do
      Repo.insert!(%Setting{key: "eua", value: "Old EUA text"})
      admin = setup_user("admin")
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/settings")

      html =
        lv
        |> form("#eua-form", eua_settings: %{eua: "Updated EUA text"})
        |> render_submit()

      assert html =~ "End User Agreement saved"
      assert Setup.get_eua() == "Updated EUA text"
    end
  end
end
