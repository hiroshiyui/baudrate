defmodule BaudrateWeb.ProfileLiveSignatureTest do
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

  test "renders signature form on profile page", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/profile")
    assert html =~ "Signature"
    assert html =~ "Save Signature"
  end

  test "saves signature successfully", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/profile")

    html =
      lv
      |> form("form[phx-submit=save_signature]", signature: %{signature: "My cool signature"})
      |> render_submit()

    assert html =~ "Signature updated"
  end

  test "shows preview when entering signature", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/profile")

    html =
      lv
      |> form("form[phx-change=validate_signature]",
        signature: %{signature: "**Bold preview**"}
      )
      |> render_change()

    assert html =~ "Preview:"
    assert html =~ "Bold preview"
  end

  test "rejects signature over max length", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/profile")
    long_signature = String.duplicate("a", 501)

    html =
      lv
      |> form("form[phx-change=validate_signature]",
        signature: %{signature: long_signature}
      )
      |> render_change()

    assert html =~ "should be at most 500 character"
  end

  test "rejects signature with too many lines", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/profile")
    nine_lines = Enum.join(1..9, "\n")

    html =
      lv
      |> form("form[phx-change=validate_signature]",
        signature: %{signature: nine_lines}
      )
      |> render_change()

    assert html =~ "must not exceed 8 lines"
  end
end
