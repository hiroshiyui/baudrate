defmodule BaudrateWeb.ProfileLiveAvatarTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  test "renders Change Avatar button for active user", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/profile")
    assert html =~ "Change Avatar"
  end

  test "renders avatar upload form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/profile")
    assert html =~ "avatar-upload-form"
  end

  test "does not render Remove Avatar button when user has no avatar", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/profile")
    refute html =~ "Remove Avatar"
  end

  test "Change Avatar button dispatches avatar:open-picker event", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/profile")
    assert html =~ "avatar:open-picker"
  end

  test "crop modal is hidden by default", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/profile")
    assert html =~ "crop-modal"
    refute html =~ ~s(open="open")
  end

  test "show_crop_modal event opens the crop modal", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/profile")
    html = render_hook(lv, "show_crop_modal", %{})
    assert html =~ "Crop Avatar"
  end

  test "crop modal dialog has aria-labelledby linking to heading", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/profile")
    assert html =~ ~s(aria-labelledby="crop-modal-title")
    assert html =~ ~s(id="crop-modal-title")
  end

  test "avatar preview image has alt text", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/profile")
    assert html =~ "Avatar preview"
  end

  test "cancel_crop event closes the crop modal", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/profile")
    render_hook(lv, "show_crop_modal", %{})
    html = render_click(lv, "cancel_crop")
    refute html =~ ~s(open="open")
  end
end
