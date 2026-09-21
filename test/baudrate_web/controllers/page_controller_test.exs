defmodule BaudrateWeb.PageControllerTest do
  use BaudrateWeb.ConnCase

  test "GET / redirects to /setup when setup is not completed", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/setup"
  end

  test "GET / renders home page when setup is completed but not authenticated", %{conn: conn} do
    Baudrate.Repo.insert!(%Baudrate.Setup.Setting{key: "setup_completed", value: "true"})
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Welcome to Baudrate"
  end

  test "GET / renders home page when setup is completed and authenticated", %{conn: conn} do
    Baudrate.Repo.insert!(%Baudrate.Setup.Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    conn = conn |> log_in_user(user) |> get(~p"/")
    assert html_response(conn, 200) =~ "Welcome"
  end

  # The personal stream moved to /timeline (ADR 0039) and members bookmark it,
  # so the old path has to keep working — including the pager's `?page`, which
  # is the link most likely to have been saved.
  describe "GET /feed" do
    setup do
      Baudrate.Repo.insert!(%Baudrate.Setup.Setting{key: "setup_completed", value: "true"})
      :ok
    end

    test "redirects permanently to /timeline", %{conn: conn} do
      conn = get(conn, "/feed")

      assert conn.status == 301
      assert redirected_to(conn, 301) == "/timeline"
    end

    test "carries the query string over", %{conn: conn} do
      conn = get(conn, "/feed?page=3")

      assert redirected_to(conn, 301) == "/timeline?page=3"
    end

    test "redirects a guest too, rather than 404ing before the login check", %{conn: conn} do
      conn = get(conn, "/feed")

      assert redirected_to(conn, 301) == "/timeline"
    end
  end

  # The service worker's offline fallback (ADR 0059). It is precached, so it
  # has to answer without a session and without the network having worked for
  # anything else on the page.
  describe "GET /offline" do
    setup do
      Baudrate.Repo.insert!(%Baudrate.Setup.Setting{key: "setup_completed", value: "true"})
      :ok
    end

    test "renders for a guest", %{conn: conn} do
      html = conn |> get(~p"/offline") |> html_response(200)

      assert html =~ ~s(id="offline-section")
      assert html =~ ~s(id="offline-retry-link")
    end

    test "carries noindex and no canonical", %{conn: conn} do
      html = conn |> get(~p"/offline") |> html_response(200)

      assert html =~ ~s(<meta name="robots" content="noindex, follow">)
      refute html =~ ~s(rel="canonical")
    end
  end
end
