defmodule BaudrateWeb.Admin.IpBansLiveTest do
  @moduledoc """
  The admin page for IP bans. The rules are `Baudrate.Auth.IpBans`' and are
  gated in `Baudrate.Auth.IpBanTest`; this checks the page renders the
  context's answers and that its form keeps what was typed.
  """
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    admin = setup_user("admin")
    {:ok, conn: log_in_admin(conn, admin), admin: admin}
  end

  test "bans a range through the form and lists it", %{conn: conn} do
    {:ok, lv, _} = live(conn, "/admin/ip-bans")

    html =
      lv
      |> form("#ip-bans-form", ban: %{address: "8.8.8.0/24", reason: "signup wave"})
      |> render_submit()

    assert html =~ "8.8.8.0/24 is banned"
    assert html =~ ~s(id="ip-bans-table")
    assert Auth.ip_banned?("8.8.8.8")
  end

  test "says how many addresses a range covers before it is submitted", %{conn: conn} do
    {:ok, lv, _} = live(conn, "/admin/ip-bans")

    html = lv |> form("#ip-bans-form", ban: %{address: "8.8.0.0/16"}) |> render_change()

    assert html =~ "covers 65536 addresses"
    # /16 is the widest range that needs no second tick.
    refute html =~ ~s(id="ip-bans-confirm-broad")

    html = lv |> form("#ip-bans-form", ban: %{address: "8.8.0.0/15"}) |> render_change()

    assert html =~ "covers 131072 addresses"
    # Anything broader asks for it before the submit, not after.
    assert html =~ ~s(id="ip-bans-confirm-broad")
  end

  test "shows the context's refusal in words, and keeps what was typed", %{conn: conn} do
    {:ok, lv, _} = live(conn, "/admin/ip-bans")

    html =
      lv
      |> form("#ip-bans-form", ban: %{address: "192.168.1.0/24", reason: "kept"})
      |> render_submit()

    assert html =~ "private or loopback range"
    assert html =~ ~s(value="192.168.1.0/24")
    assert html =~ ~s(value="kept")
    refute Auth.ip_banned?("192.168.1.5")
  end

  test "lifts a ban", %{conn: conn, admin: admin} do
    {:ok, ban} = Auth.ban_ip("8.8.8.0/24", %{}, admin, actor_ip: "1.1.1.1")

    {:ok, lv, _} = live(conn, "/admin/ip-bans")
    lv |> element("#ip-ban-delete-#{ban.id}") |> render_click()

    refute Auth.ip_banned?("8.8.8.8")
  end

  test "arrives filled in from the login-attempt log", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/admin/ip-bans?address=8.8.8.8")

    assert html =~ ~s(value="8.8.8.8")
    # Nothing is banned until the form is submitted.
    refute Auth.ip_banned?("8.8.8.8")
  end

  test "is admin-only" do
    moderator = setup_user("moderator")
    conn = log_in_user(build_conn(), moderator)

    assert {:error, {:redirect, _}} = live(conn, "/admin/ip-bans")
  end
end
