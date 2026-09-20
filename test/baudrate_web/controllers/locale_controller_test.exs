defmodule BaudrateWeb.LocaleControllerTest do
  @moduledoc """
  The footer language switcher's endpoint.

  Three things are worth a test here and the rest is plumbing: that a value
  nobody offered changes nothing, that `return_to` cannot bounce a reader off
  the site, and that a member's click reaches both the account **and** the
  session copy `BaudrateWeb.Plugs.SetLocale` reads — the last being the fix for
  a language change on `/profile` leaving every later dead render in the old
  language.
  """
  use BaudrateWeb.ConnCase

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting
  alias BaudrateWeb.Locale

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  defp locale_cookie(conn), do: conn.resp_cookies[Locale.cookie_name()]

  describe "choosing a language" do
    test "stores the choice in a cookie that outlives the session", %{conn: conn} do
      conn = post(conn, ~p"/locale", %{"locale" => "ja_JP", "return_to" => "/boards/sysop"})

      assert redirected_to(conn) == "/boards/sysop"

      cookie = locale_cookie(conn)
      assert cookie.value == "ja_JP"
      assert cookie.http_only
      assert cookie.same_site == "Lax"

      # A year, not the session's fourteen days: the session is dropped at
      # sign-out, and a preference that resets itself looks like a bug.
      assert cookie.max_age == 365 * 24 * 60 * 60
    end

    test "the cookie is what the next request actually renders in", %{conn: conn} do
      conn = post(conn, ~p"/locale", %{"locale" => "ja_JP"})

      conn =
        build_conn()
        |> Plug.Test.put_req_cookie(Locale.cookie_name(), locale_cookie(conn).value)
        |> get(~p"/login")

      assert html_response(conn, 200) =~ ~s(lang="ja-JP")
    end

    test "'auto' hands the decision back to the browser", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.put_req_cookie(Locale.cookie_name(), "ja_JP")
        |> post(~p"/locale", %{"locale" => Locale.auto()})

      # A deletion is an expiry, and its attributes have to match the ones the
      # cookie was written with or the browser keeps the original alongside it.
      cookie = locale_cookie(conn)
      assert cookie.max_age == 0
      refute Map.get(cookie, :value)
      assert cookie.http_only
      assert cookie.same_site == "Lax"
    end

    test "a value nobody offered changes nothing at all" do
      for bogus <- ["fr_FR", "../../etc/passwd", "", "<script>", "en; DROP"] do
        conn = post(build_conn(), ~p"/locale", %{"locale" => bogus})

        assert redirected_to(conn) == "/"

        assert locale_cookie(conn) == nil,
               "#{inspect(bogus)} was written to the locale cookie. " <>
                 "BaudrateWeb.Locale.known?/1 is the allow-list and nothing " <>
                 "may route around it."

        refute bogus != "" and conn.resp_body =~ bogus,
               "the rejected value was echoed into the response"
      end
    end

    test "a missing locale param is not an error page", %{conn: conn} do
      conn = post(conn, ~p"/locale", %{})

      assert redirected_to(conn) == "/"
      assert locale_cookie(conn) == nil
    end
  end

  describe "return_to" do
    test "refuses every shape that is not a local path" do
      hostile = [
        "//evil.example",
        "https://evil.example",
        "http://evil.example/x",
        "/x/../../y",
        "/@evil.example",
        "/x\\y",
        "/x\ny",
        "javascript:alert(1)",
        "evil.example"
      ]

      for target <- hostile do
        conn = post(build_conn(), ~p"/locale", %{"locale" => "ja_JP", "return_to" => target})

        assert redirected_to(conn) == "/",
               "#{inspect(target)} was accepted as a return path"
      end
    end

    test "keeps a genuine local path", %{conn: conn} do
      conn = post(conn, ~p"/locale", %{"locale" => "ja_JP", "return_to" => "/boards/sysop"})

      assert redirected_to(conn) == "/boards/sysop"
    end

    test "carries the query string back, so a search or a page is not lost", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "http://#{conn.host}/search?q=elixir&page=3")
        |> post(~p"/locale", %{"locale" => "ja_JP", "return_to" => "/search"})

      assert redirected_to(conn) == "/search?q=elixir&page=3"
    end

    test "takes the query only from a referer whose path the form already named", %{conn: conn} do
      # The destination stays the CSRF-protected field's; the header only ever
      # supplies a query string for that same path.
      conn =
        conn
        |> put_req_header("referer", "http://#{conn.host}/admin/users?role=admin")
        |> post(~p"/locale", %{"locale" => "ja_JP", "return_to" => "/search"})

      assert redirected_to(conn) == "/search"
    end

    test "ignores a referer on another host", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "https://evil.example/search?q=stolen")
        |> post(~p"/locale", %{"locale" => "ja_JP", "return_to" => "/search"})

      assert redirected_to(conn) == "/search"
    end

    test "survives a referer that is not a URL at all", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "::::")
        |> post(~p"/locale", %{"locale" => "ja_JP", "return_to" => "/search"})

      assert redirected_to(conn) == "/search"
    end
  end

  describe "a signed-in member" do
    setup %{conn: conn} do
      user = setup_user("user")
      {:ok, user} = Auth.update_preferred_locales(user, ["en", "zh_TW"])
      {:ok, conn: log_in_user(conn, user), user: user}
    end

    test "has the choice moved to the head of their account's list", %{conn: conn, user: user} do
      post(conn, ~p"/locale", %{"locale" => "zh_TW"})

      assert Auth.get_user(user.id).preferred_locales == ["zh_TW", "en"]
    end

    test "does not accumulate duplicates when they pick the same one twice", %{
      conn: conn,
      user: user
    } do
      post(conn, ~p"/locale", %{"locale" => "zh_TW"})
      conn |> recycle() |> post(~p"/locale", %{"locale" => "zh_TW"})

      assert Auth.get_user(user.id).preferred_locales == ["zh_TW", "en"]
    end

    test "gets the session copy refreshed, not just the database", %{conn: conn} do
      conn = post(conn, ~p"/locale", %{"locale" => "zh_TW"})

      assert get_session(conn, :preferred_locales) == ["zh_TW", "en"],
             """
             The session still describes the old list. `SetLocale` reads a
             member's language from this copy, which is otherwise written only
             at login — so a stale one renders every later dead render, and
             `<html lang>`, in the language they just moved away from.
             """
    end

    test "the refresh happens even when the locale param was ignored" do
      # `ProfileLive` posts here after a change the switcher did not make, so
      # the sync cannot be conditional on this request having chosen anything.
      user = setup_user("user")
      {:ok, _} = Auth.update_preferred_locales(user, ["ja_JP"])

      conn =
        build_conn()
        |> log_in_user(user)
        |> post(~p"/locale", %{"locale" => "nonsense"})

      assert get_session(conn, :preferred_locales) == ["ja_JP"]
    end
  end

  test "the endpoint is CSRF-protected", %{conn: conn} do
    # Not a test of Plug.CSRFProtection but of the routing decision: this must
    # sit in the `:browser` pipeline and not in a CSRF-exempt scope such as
    # `/share`, whose exemption exists for an OS share sheet.
    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
      |> post(~p"/locale", %{"locale" => "ja_JP"})
    end
  end
end
