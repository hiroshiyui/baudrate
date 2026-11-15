defmodule BaudrateWeb.ShareTargetControllerTest do
  use BaudrateWeb.ConnCase

  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  describe "POST /share" do
    test "authenticated user with title+text+url redirects to /articles/new with query params",
         %{conn: conn} do
      user = setup_user("user")
      conn = log_in_user(conn, user)

      conn =
        post(conn, "/share", %{
          "title" => "Test Title",
          "text" => "Some shared text",
          "url" => "https://example.com/page"
        })

      location = redirected_to(conn)
      assert location =~ "/articles/new?"
      uri = URI.parse(location)
      query = URI.decode_query(uri.query)
      assert query["title"] == "Test Title"
      assert query["text"] == "Some shared text"
      assert query["url"] == "https://example.com/page"
    end

    test "authenticated user with only text redirects correctly", %{conn: conn} do
      user = setup_user("user")
      conn = log_in_user(conn, user)

      conn = post(conn, "/share", %{"text" => "Just some text"})

      location = redirected_to(conn)
      assert location =~ "/articles/new?"
      uri = URI.parse(location)
      query = URI.decode_query(uri.query)
      assert query["text"] == "Just some text"
      refute Map.has_key?(query, "title")
      refute Map.has_key?(query, "url")
    end

    test "authenticated user with empty params redirects to /articles/new without query string",
         %{conn: conn} do
      user = setup_user("user")
      conn = log_in_user(conn, user)

      conn = post(conn, "/share", %{})

      assert redirected_to(conn) == "/articles/new"
    end

    test "unauthenticated user stores return_to and redirects to /login", %{conn: conn} do
      conn =
        post(conn, "/share", %{
          "title" => "Shared Title",
          "text" => "Shared content"
        })

      assert redirected_to(conn) == "/login"
      return_to = get_session(conn, :return_to)
      assert return_to =~ "/articles/new?"
      assert return_to =~ "title=Shared"
    end

    # A cross-site POST arrives without the Lax session cookie; writing
    # `:return_to` answered with a fresh cookie that replaced the member's
    # session (a forced logout) and pre-filled their next composer.
    test "a cross-site post writes no session and sends the visitor home", %{conn: conn} do
      conn =
        conn
        |> put_req_header("sec-fetch-site", "cross-site")
        |> post("/share", %{"title" => "Planted", "text" => "From another site"})

      assert redirected_to(conn) == "/"
      assert get_session(conn, :return_to) == nil
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "a share from the installed app still works", %{conn: conn} do
      conn =
        conn
        |> put_req_header("sec-fetch-site", "none")
        |> post("/share", %{"title" => "Shared Title"})

      assert redirected_to(conn) == "/login"
      assert get_session(conn, :return_to) =~ "title=Shared"
    end

    test "params are truncated to limits", %{conn: conn} do
      user = setup_user("user")
      conn = log_in_user(conn, user)

      long_title = String.duplicate("a", 300)
      long_url = "https://example.com/" <> String.duplicate("x", 3000)

      conn =
        post(conn, "/share", %{
          "title" => long_title,
          "url" => long_url
        })

      location = redirected_to(conn)
      uri = URI.parse(location)
      query = URI.decode_query(uri.query)
      assert String.length(query["title"]) == 200
      assert String.length(query["url"]) == 2048
    end
  end
end
