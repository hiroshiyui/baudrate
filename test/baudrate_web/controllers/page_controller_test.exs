defmodule BaudrateWeb.PageControllerTest do
  use BaudrateWeb.ConnCase

  test "GET / redirects to /setup when setup is not completed", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/setup"
  end

  test "GET / renders home page when setup is completed", %{conn: conn} do
    Baudrate.Repo.insert!(%Baudrate.Setup.Setting{key: "setup_completed", value: "true"})
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end
end
