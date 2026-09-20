defmodule BaudrateWeb.CrawlerSurfaceTest do
  @moduledoc """
  Everything this instance says to a crawler, and the acceptance gate for
  [ADR 0057](../../doc/adr/0057-a-sitemap-invites-only-what-a-guest-sees.md).

  Two halves:

    * **What the sitemap invites.** A slug in a sitemap is an existence signal
      that machines copy and repeat, so the exclusions are asserted one by one
      — a private board, an article that lives only in one, a soft-deleted
      article, a remote article, an unlisted article, and a tag reachable only
      from a private board.
    * **What a page says about itself** — `noindex`, canonical and the
      description.

  A new public surface belongs in `@indexable_pages` or in the exclusion
  block, not in neither.
  """
  use BaudrateWeb.ConnCase

  alias Baudrate.Content
  alias Baudrate.Content.{Article, Board, BoardArticle}
  alias Baudrate.Federation.RemoteActor
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  @base BaudrateWeb.Endpoint.url()

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Forum"})
    Repo.insert!(%Setting{key: "site_description", value: "A place to talk."})

    user = setup_user("user")
    public_board = insert_board("public-board", "guest")
    private_board = insert_board("private-board", "user")

    {:ok, %{article: article}} = insert_article(user, public_board, "hello-world")

    %{
      conn: conn,
      user: user,
      public_board: public_board,
      private_board: private_board,
      article: article
    }
  end

  # --- robots.txt ---

  describe "robots.txt" do
    test "is served by the router and names the sitemap absolutely", %{conn: conn} do
      body = conn |> get("/robots.txt") |> response(200)

      assert body =~ "Sitemap: #{@base}/sitemap.xml"
      assert body =~ "User-agent: *"
    end

    test "blocks machine endpoints only", %{conn: conn} do
      body = conn |> get("/robots.txt") |> response(200)

      assert body =~ "Disallow: /ap/"
      assert body =~ "Disallow: /api/"
      assert body =~ "Disallow: /exports/"
    end

    test "does not disallow the pages that carry noindex", %{conn: conn} do
      # A blocked page can still be indexed URL-only, and its noindex is never
      # read because the crawler never fetches it. Blocking is not the
      # directive that removes a page from an index.
      body = conn |> get("/robots.txt") |> response(200)

      refute body =~ "Disallow: /search"
      refute body =~ "Disallow: /login"
      refute body =~ "Disallow: /register"
    end

    test "is not shadowed by a file in priv/static" do
      refute File.exists?(Application.app_dir(:baudrate, "priv/static/robots.txt"))
      refute "robots.txt" in BaudrateWeb.static_paths()
    end
  end

  # --- The sitemap index ---

  describe "sitemap.xml" do
    test "lists the child documents that exist", %{conn: conn, user: user, public_board: board} do
      {:ok, _} = insert_tagged_article(user, board, "tagged-one", "elixir")

      body = conn |> get("/sitemap.xml") |> response(200)

      assert body =~ "#{@base}/sitemap/boards.xml"
      assert body =~ "#{@base}/sitemap/tags.xml"
      assert body =~ "#{@base}/sitemap/articles-1.xml"
    end

    test "omits a child with nothing in it", %{conn: conn} do
      # No article carries a tag in the base fixture.
      body = conn |> get("/sitemap.xml") |> response(200)

      refute body =~ "/sitemap/tags.xml"
    end

    test "is XML with a public cache", %{conn: conn} do
      conn = get(conn, "/sitemap.xml")

      assert response_content_type(conn, :xml) =~ "application/xml"
      assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]
    end

    test "every listed document is absolute and answers 200", %{conn: conn} do
      for loc <- locs(conn, "/sitemap.xml") do
        assert String.starts_with?(loc, @base), "#{loc} is not absolute"
        assert conn |> get(path_of(loc)) |> response(200)
      end
    end
  end

  # --- What is never invited ---

  describe "what the sitemap never invites" do
    test "a board a guest cannot open", %{conn: conn, private_board: board} do
      refute everything(conn) =~ board.slug
    end

    test "an article that lives only in a private board", %{
      conn: conn,
      user: user,
      private_board: board
    } do
      {:ok, _} = insert_article(user, board, "private-article")

      refute everything(conn) =~ "private-article"
    end

    test "a cross-posted article is invited, because one of its boards is public", %{
      conn: conn,
      user: user,
      public_board: public,
      private_board: private
    } do
      {:ok, _} =
        Content.create_article(article_attrs(user, "crossposted"), [private.id, public.id])

      assert everything(conn) =~ "crossposted"
    end

    test "a soft-deleted article", %{conn: conn, user: user, public_board: board} do
      {:ok, %{article: article}} = insert_article(user, board, "deleted-article")
      Content.soft_delete_article(article, deleted_by: article.user_id)

      refute everything(conn) =~ "deleted-article"
    end

    test "an unlisted article", %{conn: conn, user: user, public_board: board} do
      {:ok, _} = insert_unlisted_article(user, board, "unlisted-article")

      refute everything(conn) =~ "unlisted-article"
    end

    test "a remote article", %{conn: conn, public_board: board} do
      insert_remote_article(board, "remote-article")

      refute everything(conn) =~ "remote-article"
    end

    test "a tag reachable only from a private board", %{
      conn: conn,
      user: user,
      private_board: board
    } do
      {:ok, _} = insert_tagged_article(user, board, "secret-tagged", "cabal")

      refute everything(conn) =~ "cabal"
    end

    test "a member profile — public and crawlable, deliberately not enumerated", %{
      conn: conn,
      user: user
    } do
      refute everything(conn) =~ "/users/#{user.username}"
    end
  end

  # --- Child documents ---

  describe "the child documents" do
    test "a public board is listed with an absolute URL", %{conn: conn, public_board: board} do
      assert "#{@base}/boards/#{board.slug}" in locs(conn, "/sitemap/boards.xml")
    end

    test "an article page beyond the last is 404", %{conn: conn} do
      assert conn |> get("/sitemap/articles-2.xml") |> response(404)
    end

    test "a name that is not a sitemap is 404", %{conn: conn} do
      assert conn |> get("/sitemap/../secrets.xml") |> response(404)
      assert conn |> get("/sitemap/articles-.xml") |> response(404)
    end

    test "a non-ASCII tag is percent-encoded, and the encoded URL resolves", %{
      conn: conn,
      user: user,
      public_board: board
    } do
      {:ok, _} = insert_tagged_article(user, board, "cjk-tagged", "台灣")

      loc = Enum.find(locs(conn, "/sitemap/tags.xml"), &String.contains?(&1, "/tags/"))

      assert loc == "#{@base}/tags/%E5%8F%B0%E7%81%A3"
      assert conn |> get(path_of(loc)) |> html_response(200) =~ "台灣"
    end

    test "answers 304 to a conditional GET", %{conn: conn} do
      first = get(conn, "/sitemap/articles-1.xml")
      [last_modified] = get_resp_header(first, "last-modified")

      second =
        conn
        |> put_req_header("if-modified-since", last_modified)
        |> get("/sitemap/articles-1.xml")

      assert response(second, 304)
    end
  end

  # --- What a page says about itself ---

  describe "noindex" do
    test "the pages with nothing worth indexing carry it, and no canonical", %{conn: conn} do
      for path <- ~w(/search /login /register /password-reset) do
        html = conn |> get(path) |> html_response(200)

        assert html =~ ~s(<meta name="robots" content="noindex, follow">),
               "#{path} is missing noindex"

        refute html =~ ~s(rel="canonical"),
               "#{path} is noindex and canonical at once, which contradict"
      end
    end

    test "an unlisted article keeps the promise its own word makes", %{
      conn: conn,
      user: user,
      public_board: board
    } do
      {:ok, %{article: article}} = insert_unlisted_article(user, board, "quiet-article")

      html = conn |> get("/articles/#{article.slug}") |> html_response(200)

      assert html =~ ~s(<meta name="robots" content="noindex, follow">)
    end

    test "an ordinary article does not", %{conn: conn, article: article} do
      html = conn |> get("/articles/#{article.slug}") |> html_response(200)

      refute html =~ ~s(name="robots")
    end
  end

  describe "canonical" do
    test "every indexable public page names itself absolutely", %{
      conn: conn,
      user: user,
      public_board: board,
      article: article
    } do
      {:ok, _} = insert_tagged_article(user, board, "canonical-tagged", "elixir")

      pages = [
        "/",
        "/boards/#{board.slug}",
        "/articles/#{article.slug}",
        "/users/#{user.username}",
        "/tags/elixir"
      ]

      for path <- pages do
        html = conn |> get(path) |> html_response(200)

        assert html =~ ~s(<link rel="canonical" href="#{@base}#{path}">),
               "#{path} does not name itself canonically"
      end
    end

    test "a paginated page canonicalizes to itself, not to page 1", %{
      conn: conn,
      user: user,
      public_board: board
    } do
      {:ok, _} = insert_tagged_article(user, board, "paged-tagged", "elixir")

      html = conn |> get("/tags/elixir?page=2") |> html_response(200)

      assert html =~ ~s(<link rel="canonical" href="#{@base}/tags/elixir?page=2">)
    end

    test "tracking parameters are dropped", %{conn: conn, article: article} do
      html = conn |> get("/articles/#{article.slug}?utm_source=elsewhere") |> html_response(200)

      assert html =~ ~s(<link rel="canonical" href="#{@base}/articles/#{article.slug}">)
    end
  end

  describe "description" do
    test "every indexable public page describes itself in a sentence", %{
      conn: conn,
      user: user,
      public_board: board,
      article: article
    } do
      {:ok, _} = insert_tagged_article(user, board, "described-tagged", "elixir")

      pages = [
        "/",
        "/boards/#{board.slug}",
        "/articles/#{article.slug}",
        "/users/#{user.username}",
        "/tags/elixir"
      ]

      for path <- pages do
        html = conn |> get(path) |> html_response(200)

        assert html =~ ~r/<meta name="description" content="[^"]+">/,
               "#{path} has no description"
      end
    end
  end

  # --- Feed discovery ---

  describe "per-page feed discovery" do
    test "a board page advertises and links its own feeds", %{conn: conn, public_board: board} do
      html = conn |> get("/boards/#{board.slug}") |> html_response(200)

      assert html =~ ~s(href="/feeds/boards/#{board.slug}/rss")
      assert html =~ ~s(href="/feeds/boards/#{board.slug}/atom")
      assert html =~ ~s(id="board-feed-rss")
    end

    test "a private board links no feed, because it has none", %{
      conn: conn,
      private_board: board,
      user: user
    } do
      html = conn |> log_in_user(user) |> get("/boards/#{board.slug}") |> html_response(200)

      refute html =~ "board-feed-rss"
    end

    test "a profile advertises and links its own feeds", %{conn: conn, user: user} do
      html = conn |> get("/users/#{user.username}") |> html_response(200)

      assert html =~ ~s(href="/feeds/users/#{user.username}/rss")
      assert html =~ ~s(id="user-profile-feed-atom")
    end

    test "a tag page advertises and links its own feeds", %{
      conn: conn,
      user: user,
      public_board: board
    } do
      {:ok, _} = insert_tagged_article(user, board, "feedy-tagged", "elixir")

      html = conn |> get("/tags/elixir") |> html_response(200)

      assert html =~ ~s(href="/feeds/tags/elixir/rss")
      assert html =~ ~s(id="tag-feed-rss")
    end
  end

  # --- Helpers ---

  # Every sitemap document this instance serves, concatenated. A slug that
  # appears nowhere in here was never invited.
  defp everything(conn) do
    index = conn |> get("/sitemap.xml") |> response(200)

    children =
      index
      |> locs_from()
      |> Enum.map_join("\n", fn loc -> conn |> get(path_of(loc)) |> response(200) end)

    index <> "\n" <> children
  end

  defp locs(conn, path), do: conn |> get(path) |> response(200) |> locs_from()

  defp locs_from(xml) do
    Regex.scan(~r{<loc>(.*?)</loc>}s, xml) |> Enum.map(fn [_, loc] -> loc end)
  end

  defp path_of(url), do: String.replace_prefix(url, @base, "")

  defp article_attrs(user, slug) do
    %{title: "Article #{slug}", body: "Body for #{slug}.", slug: slug, user_id: user.id}
  end

  defp insert_article(user, board, slug) do
    Content.create_article(article_attrs(user, slug), [board.id])
  end

  defp insert_unlisted_article(user, board, slug) do
    Content.create_article(
      article_attrs(user, slug) |> Map.put(:visibility, "unlisted"),
      [board.id]
    )
  end

  defp insert_tagged_article(user, board, slug, tag) do
    Content.create_article(
      %{article_attrs(user, slug) | body: "Writing about ##{tag} today."},
      [board.id]
    )
  end

  defp insert_board(slug, min_role_to_view) do
    %Board{}
    |> Board.changeset(%{
      name: "Board #{slug}",
      slug: slug,
      description: "Test board for #{slug}",
      min_role_to_view: min_role_to_view,
      min_role_to_post: "user"
    })
    |> Repo.insert!()
  end

  defp insert_remote_article(board, slug) do
    actor =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/actor/#{slug}",
        username: "remote_#{slug}",
        domain: "remote.example",
        public_key_pem: "-----BEGIN PUBLIC KEY-----\nMIIBIjANBg==\n-----END PUBLIC KEY-----",
        inbox: "https://remote.example/inbox",
        shared_inbox: "https://remote.example/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    article =
      %Article{}
      |> Article.remote_changeset(%{
        title: "Remote #{slug}",
        body: "Remote body",
        slug: slug,
        ap_id: "https://remote.example/articles/#{slug}",
        remote_actor_id: actor.id
      })
      |> Repo.insert!()

    Repo.insert!(%BoardArticle{
      board_id: board.id,
      article_id: article.id,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    article
  end
end
