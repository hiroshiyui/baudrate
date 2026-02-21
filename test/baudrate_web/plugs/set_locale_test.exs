defmodule BaudrateWeb.Plugs.SetLocaleTest do
  use BaudrateWeb.ConnCase, async: true

  alias BaudrateWeb.Plugs.SetLocale

  defp call_plug(conn) do
    SetLocale.call(conn, SetLocale.init([]))
  end

  defp with_session(conn, session_data \\ %{}) do
    Plug.Test.init_test_session(conn, session_data)
  end

  test "defaults to 'en' when no Accept-Language header is present", %{conn: conn} do
    conn = conn |> with_session() |> call_plug()

    assert conn.assigns[:locale] == "en"
    assert Gettext.get_locale() == "en"
  end

  test "detects zh_TW from Accept-Language header", %{conn: conn} do
    conn =
      conn
      |> with_session()
      |> put_req_header("accept-language", "zh-TW,zh;q=0.9,en;q=0.8")
      |> call_plug()

    assert conn.assigns[:locale] == "zh_TW"
    assert Gettext.get_locale() == "zh_TW"
  end

  test "falls back to 'en' for unsupported locale", %{conn: conn} do
    conn =
      conn
      |> with_session()
      |> put_req_header("accept-language", "fr-FR,fr;q=0.9")
      |> call_plug()

    assert conn.assigns[:locale] == "en"
    assert Gettext.get_locale() == "en"
  end

  test "picks highest-q supported locale", %{conn: conn} do
    conn =
      conn
      |> with_session()
      |> put_req_header("accept-language", "fr;q=0.9,zh-TW;q=0.8,en;q=0.7")
      |> call_plug()

    assert conn.assigns[:locale] == "zh_TW"
  end

  test "bare 'zh' matches zh_TW via prefix fallback", %{conn: conn} do
    conn =
      conn
      |> with_session()
      |> put_req_header("accept-language", "zh")
      |> call_plug()

    assert conn.assigns[:locale] == "zh_TW"
    assert Gettext.get_locale() == "zh_TW"
  end

  test "session preferred_locales takes priority over Accept-Language", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{preferred_locales: ["zh_TW"]})
      |> put_req_header("accept-language", "en")
      |> call_plug()

    assert conn.assigns[:locale] == "zh_TW"
    assert Gettext.get_locale() == "zh_TW"
  end

  test "falls back to Accept-Language when session preferred_locales is empty", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{preferred_locales: []})
      |> put_req_header("accept-language", "zh-TW")
      |> call_plug()

    assert conn.assigns[:locale] == "zh_TW"
  end

  test "falls back to Accept-Language when session has no preferred_locales", %{conn: conn} do
    conn =
      conn
      |> with_session()
      |> put_req_header("accept-language", "zh-TW")
      |> call_plug()

    assert conn.assigns[:locale] == "zh_TW"
  end
end
