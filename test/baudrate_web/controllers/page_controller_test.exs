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
end
