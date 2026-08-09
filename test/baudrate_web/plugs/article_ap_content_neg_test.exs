defmodule BaudrateWeb.Plugs.ArticleApContentNegTest do
  @moduledoc """
  The plug decides whether a *public browser URL* serves HTML or AS2 JSON, so
  both directions matter: an AP client must be able to discover an article from
  its human URL, and the sibling routes under `/articles/` must never be
  intercepted — `/articles/new` and `/articles/:slug/edit` are authenticated
  LiveViews, and handing them to `ActivityPubController.article/2` would answer
  a 404 for a literal slug of "new" instead of rendering the editor.
  """
  use BaudrateWeb.ConnCase

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting
  alias BaudrateWeb.Plugs.ArticleApContentNeg

  setup do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")

    board =
      %Board{}
      |> Board.changeset(%{
        name: "Neg Board",
        slug: "neg-board-#{System.unique_integer([:positive])}",
        ap_enabled: true,
        min_role_to_view: "guest"
      })
      |> Repo.insert!()

    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Negotiated Article",
          body: "body text",
          slug: "negotiated-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )

    {:ok, user: user, board: board, article: article}
  end

  defp call_plug(conn), do: ArticleApContentNeg.call(conn, ArticleApContentNeg.init([]))

  describe "AP Accept headers" do
    for type <- ["application/activity+json", "application/ld+json", "application/json"] do
      test "#{type} is served the AS2 object", %{conn: conn, article: article} do
        conn =
          conn
          |> put_req_header("accept", unquote(type))
          |> get("/articles/#{article.slug}")

        assert conn.halted
        body = json_response(conn, 200)
        assert body["type"] == "Article"
        assert body["id"] =~ "/ap/articles/#{article.slug}"
      end
    end

    test "the profile-qualified Accept Mastodon actually sends is matched", %{
      conn: conn,
      article: article
    } do
      conn =
        conn
        |> put_req_header(
          "accept",
          ~s(application/ld+json; profile="https://www.w3.org/ns/activitystreams")
        )
        |> get("/articles/#{article.slug}")

      assert conn.halted
      assert json_response(conn, 200)["type"] == "Article"
    end

    test "the response is marked Vary: Accept so caches do not mix the two forms", %{
      conn: conn,
      article: article
    } do
      conn =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get("/articles/#{article.slug}")

      assert "Accept" in get_resp_header(conn, "vary")
    end
  end

  describe "requests that must fall through" do
    test "a browser Accept renders the LiveView", %{conn: conn, article: article} do
      conn =
        conn
        |> put_req_header("accept", "text/html,application/xhtml+xml")
        |> get("/articles/#{article.slug}")

      refute conn.halted
      assert html_response(conn, 200) =~ "Negotiated Article"
    end

    test "a missing Accept header renders the LiveView", %{conn: conn, article: article} do
      conn = conn |> delete_req_header("accept") |> get("/articles/#{article.slug}")
      refute conn.halted
      assert html_response(conn, 200) =~ "Negotiated Article"
    end
  end

  describe "path guard" do
    test "only the exact two-segment article path is considered" do
      # Driven through the plug directly: the sibling paths are real routes, and
      # what is under test is that the plug declines them before routing.
      for path <- [
            ["articles"],
            ["articles", "new"],
            ["articles", "some-slug", "edit"],
            ["articles", "some-slug", "history"],
            ["ap", "articles", "some-slug"],
            ["boards", "some-slug"]
          ] do
        conn =
          :get
          |> Phoenix.ConnTest.build_conn("/" <> Enum.join(path, "/"))
          |> Map.put(:path_info, path)
          |> put_req_header("accept", "application/activity+json")
          |> call_plug()

        refute conn.halted, "expected #{inspect(path)} not to be intercepted"
      end
    end

    test "/articles/new is declined by the plug itself, not just by scope order", %{
      article: article
    } do
      # `["articles", "new"]` is two segments, so the segment count does not
      # exclude it — only `@reserved_slugs` does. In the assembled router the
      # request never gets here (the :authenticated scope is declared first),
      # but that is a coupling to a declaration order in another file, and this
      # asserts the plug holds the line on its own.
      conn =
        :get
        |> Phoenix.ConnTest.build_conn("/articles/new")
        |> Map.put(:path_info, ["articles", "new"])
        |> put_req_header("accept", "application/activity+json")
        |> call_plug()

      refute conn.halted

      # ...while a real slug in the same shape still negotiates.
      negotiated =
        :get
        |> Phoenix.ConnTest.build_conn("/articles/#{article.slug}")
        |> Map.put(:path_info, ["articles", article.slug])
        |> put_req_header("accept", "application/activity+json")
        |> call_plug()

      assert negotiated.halted
    end

    test "the authenticated editor refuses a JSON Accept rather than serving AS2", %{
      conn: conn,
      user: user
    } do
      # /articles/new lives in the :authenticated scope, whose :browser
      # pipeline accepts only "html" — so an AP Accept is a 406, never an
      # article lookup for the literal slug "new".
      assert_raise Phoenix.NotAcceptableError, fn ->
        conn
        |> log_in_user(user)
        |> put_req_header("accept", "application/activity+json")
        |> get("/articles/new")
      end
    end

    test "non-GET methods are never intercepted", %{article: article} do
      for method <- [:post, :put, :delete] do
        conn =
          method
          |> Phoenix.ConnTest.build_conn("/articles/#{article.slug}")
          |> Map.put(:path_info, ["articles", article.slug])
          |> put_req_header("accept", "application/activity+json")
          |> call_plug()

        refute conn.halted, "expected #{method} not to be intercepted"
      end
    end
  end
end
