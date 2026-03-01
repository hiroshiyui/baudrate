defmodule BaudrateWeb.FeedControllerTest do
  use BaudrateWeb.ConnCase

  alias Baudrate.Content
  alias Baudrate.Content.{Article, Board, BoardArticle}
  alias Baudrate.Federation.RemoteActor
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Forum"})
    Hammer.delete_buckets("feeds:127.0.0.1")

    user = setup_user("user")
    public_board = insert_board("public-board", min_role_to_view: "guest")
    private_board = insert_board("private-board", min_role_to_view: "user")

    {:ok, conn: conn, user: user, public_board: public_board, private_board: private_board}
  end

  # --- Site-wide RSS ---

  describe "GET /feeds/rss" do
    test "returns RSS 2.0 with correct content type", %{
      conn: conn,
      user: user,
      public_board: board
    } do
      {:ok, _} = insert_article(user, board, "rss-article")

      conn = get(conn, "/feeds/rss")

      assert response_content_type(conn, :xml) =~ "application/rss+xml"
      body = response(conn, 200)
      assert body =~ ~s(<rss version="2.0")
      assert body =~ ~s(<?xml version="1.0" encoding="UTF-8"?>)
      assert body =~ "rss-article"
      assert body =~ "Test Forum"
    end

    test "excludes articles in private boards", %{conn: conn, user: user, private_board: board} do
      {:ok, _} = insert_article(user, board, "private-rss-article")

      body = conn |> get("/feeds/rss") |> response(200)
      refute body =~ "private-rss-article"
    end

    test "excludes deleted articles", %{conn: conn, user: user, public_board: board} do
      {:ok, %{article: article}} = insert_article(user, board, "deleted-rss")
      Content.soft_delete_article(article)

      body = conn |> get("/feeds/rss") |> response(200)
      refute body =~ "deleted-rss"
    end

    test "excludes remote articles", %{conn: conn, public_board: board} do
      insert_remote_article(board, "remote-rss-article")

      body = conn |> get("/feeds/rss") |> response(200)
      refute body =~ "remote-rss-article"
    end

    test "includes Cache-Control header", %{conn: conn} do
      conn = get(conn, "/feeds/rss")
      assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
    end

    test "includes Last-Modified header when articles exist", %{
      conn: conn,
      user: user,
      public_board: board
    } do
      {:ok, _} = insert_article(user, board, "lm-rss")

      conn = get(conn, "/feeds/rss")
      assert [_] = get_resp_header(conn, "last-modified")
    end

    test "returns 304 for If-Modified-Since", %{conn: conn, user: user, public_board: board} do
      {:ok, _} = insert_article(user, board, "ims-rss")

      # First request to get Last-Modified
      first = get(conn, "/feeds/rss")
      [last_modified] = get_resp_header(first, "last-modified")

      # Second request with If-Modified-Since
      conn =
        conn
        |> put_req_header("if-modified-since", last_modified)
        |> get("/feeds/rss")

      assert response(conn, 304)
    end
  end

  # --- Site-wide Atom ---

  describe "GET /feeds/atom" do
    test "returns Atom 1.0 with correct content type", %{
      conn: conn,
      user: user,
      public_board: board
    } do
      {:ok, _} = insert_article(user, board, "atom-article")

      conn = get(conn, "/feeds/atom")

      assert response_content_type(conn, :xml) =~ "application/atom+xml"
      body = response(conn, 200)
      assert body =~ ~s(xmlns="http://www.w3.org/2005/Atom")
      assert body =~ "atom-article"
    end
  end

  # --- Board RSS ---

  describe "GET /feeds/boards/:slug/rss" do
    test "returns RSS for a public board", %{conn: conn, user: user, public_board: board} do
      {:ok, _} = insert_article(user, board, "board-rss-article")

      conn = get(conn, "/feeds/boards/#{board.slug}/rss")

      body = response(conn, 200)
      assert body =~ "board-rss-article"
      assert body =~ board.name
    end

    test "returns 404 for private boards", %{conn: conn, private_board: board} do
      conn = get(conn, "/feeds/boards/#{board.slug}/rss")
      assert response(conn, 404)
    end

    test "returns 404 for nonexistent boards", %{conn: conn} do
      conn = get(conn, "/feeds/boards/nonexistent-board/rss")
      assert response(conn, 404)
    end

    test "returns 404 for invalid slug format", %{conn: conn} do
      conn = get(conn, "/feeds/boards/INVALID/rss")
      assert response(conn, 404)
    end

    test "excludes remote articles from board feed", %{conn: conn, public_board: board} do
      insert_remote_article(board, "board-remote-rss")

      body = conn |> get("/feeds/boards/#{board.slug}/rss") |> response(200)
      refute body =~ "board-remote-rss"
    end
  end

  # --- Board Atom ---

  describe "GET /feeds/boards/:slug/atom" do
    test "returns Atom for a public board", %{conn: conn, user: user, public_board: board} do
      {:ok, _} = insert_article(user, board, "board-atom-article")

      conn = get(conn, "/feeds/boards/#{board.slug}/atom")

      body = response(conn, 200)
      assert body =~ "board-atom-article"
      assert response_content_type(conn, :xml) =~ "application/atom+xml"
    end

    test "returns 404 for private boards", %{conn: conn, private_board: board} do
      conn = get(conn, "/feeds/boards/#{board.slug}/atom")
      assert response(conn, 404)
    end
  end

  # --- User RSS ---

  describe "GET /feeds/users/:username/rss" do
    test "returns RSS for a user", %{conn: conn, user: user, public_board: board} do
      {:ok, _} = insert_article(user, board, "user-rss-article")

      conn = get(conn, "/feeds/users/#{user.username}/rss")

      body = response(conn, 200)
      assert body =~ "user-rss-article"
      assert body =~ user.username
    end

    test "excludes articles in private boards", %{conn: conn, user: user, private_board: board} do
      {:ok, _} = insert_article(user, board, "user-private-rss")

      body = conn |> get("/feeds/users/#{user.username}/rss") |> response(200)
      refute body =~ "user-private-rss"
    end

    test "returns 404 for nonexistent users", %{conn: conn} do
      conn = get(conn, "/feeds/users/nonexistent_user/rss")
      assert response(conn, 404)
    end

    test "returns 404 for banned users", %{conn: conn, public_board: board} do
      banned = setup_user("user")
      {:ok, _} = insert_article(banned, board, "banned-user-rss")

      banned
      |> Ecto.Changeset.change(
        status: "banned",
        banned_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      conn = get(conn, "/feeds/users/#{banned.username}/rss")
      assert response(conn, 404)
    end

    test "returns 404 for invalid username format", %{conn: conn} do
      conn = get(conn, "/feeds/users/inv@lid/rss")
      assert response(conn, 404)
    end
  end

  # --- User Atom ---

  describe "GET /feeds/users/:username/atom" do
    test "returns Atom for a user", %{conn: conn, user: user, public_board: board} do
      {:ok, _} = insert_article(user, board, "user-atom-article")

      conn = get(conn, "/feeds/users/#{user.username}/atom")

      body = response(conn, 200)
      assert body =~ "user-atom-article"
      assert response_content_type(conn, :xml) =~ "application/atom+xml"
    end
  end

  # --- Rate Limiting ---

  describe "rate limiting" do
    test "returns 429 after exceeding limit", %{conn: conn} do
      # Use real Hammer backend so rate limits actually trigger
      BaudrateWeb.RateLimiter.Sandbox.set_fun(&BaudrateWeb.RateLimiter.Hammer.check_rate/3)

      for _ <- 1..30 do
        get(conn, "/feeds/rss")
      end

      conn = get(conn, "/feeds/rss")
      assert response(conn, 429) =~ "Too many requests"
    end
  end

  # --- Helpers ---

  defp insert_board(slug, opts \\ []) do
    {:ok, board} =
      %Board{}
      |> Board.changeset(%{
        name: "Board #{slug}",
        slug: slug,
        description: "Test board for #{slug}",
        min_role_to_view: Keyword.get(opts, :min_role_to_view, "guest"),
        min_role_to_post: Keyword.get(opts, :min_role_to_post, "user")
      })
      |> Repo.insert()

    board
  end

  defp insert_article(user, board, slug) do
    Content.create_article(
      %{
        title: "Article #{slug}",
        body: "Body for **#{slug}**.",
        slug: slug,
        user_id: user.id
      },
      [board.id]
    )
  end

  defp insert_remote_article(board, slug) do
    {:ok, actor} =
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
      |> Repo.insert()

    {:ok, article} =
      %Article{}
      |> Article.remote_changeset(%{
        title: "Remote #{slug}",
        body: "Remote body",
        slug: slug,
        ap_id: "https://remote.example/articles/#{slug}",
        remote_actor_id: actor.id
      })
      |> Repo.insert()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%BoardArticle{
      board_id: board.id,
      article_id: article.id,
      inserted_at: now,
      updated_at: now
    })

    article
  end
end
