defmodule BaudrateWeb.ArticleLiveTest do
  use BaudrateWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    conn = log_in_user(conn, user)

    board =
      %Board{}
      |> Board.changeset(%{name: "General", slug: "general-art"})
      |> Repo.insert!()

    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Test Article",
          body: "Article body text",
          slug: "test-article",
          user_id: user.id
        },
        [board.id]
      )

    {:ok, conn: conn, user: user, board: board, article: article}
  end

  test "renders JSON-LD with sioc:Post and DC meta", %{conn: conn, article: article} do
    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")

    assert html =~ "application/ld+json"
    assert html =~ "sioc:Post"
    assert html =~ "DC.title"
    assert html =~ "DC.creator"
  end

  test "renders article with edit/delete buttons for author", %{conn: conn, article: article} do
    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
    assert html =~ "Test Article"
    assert html =~ "Edit"
    assert html =~ "Delete"
  end

  test "does not show edit/delete for non-author", %{article: article} do
    Repo.insert!(%Setting{key: "registration_mode", value: "open"})
    other_user = setup_user("user")

    conn =
      Phoenix.ConnTest.build_conn()
      |> log_in_user(other_user)

    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
    assert html =~ "Test Article"
    refute html =~ "hero-pencil-square"
  end

  test "deletes article and redirects", %{conn: conn, article: article} do
    {:ok, lv, _html} = live(conn, "/articles/#{article.slug}")

    lv |> element("button[phx-click=delete_article]") |> render_click()

    assert_redirect(lv)
  end

  test "renders comment section", %{conn: conn, article: article} do
    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
    assert html =~ "Comments"
    assert html =~ "Write a comment"
  end

  test "posts a comment", %{conn: conn, article: article} do
    {:ok, lv, _html} = live(conn, "/articles/#{article.slug}")

    html =
      lv
      |> form("form[phx-submit=submit_comment]", comment: %{body: "Great article!"})
      |> render_submit()

    assert html =~ "Great article!"
  end

  test "updates comment list when new comment is posted via PubSub", %{
    conn: conn,
    user: user,
    article: article
  } do
    {:ok, lv, html} = live(conn, "/articles/#{article.slug}")
    refute html =~ "PubSub comment here"

    # Create a comment from another process (simulates another user)
    Content.create_comment(%{
      "body" => "PubSub comment here",
      "article_id" => article.id,
      "user_id" => user.id
    })

    # The LiveView should re-render with the new comment
    assert render(lv) =~ "PubSub comment here"
  end

  test "updates comment list when comment is deleted via PubSub", %{
    conn: conn,
    user: user,
    article: article
  } do
    {:ok, comment} =
      Content.create_comment(%{
        "body" => "Will be deleted remotely",
        "article_id" => article.id,
        "user_id" => user.id
      })

    {:ok, lv, html} = live(conn, "/articles/#{article.slug}")
    assert html =~ "Will be deleted remotely"

    # Delete the comment from another process
    Content.soft_delete_comment(comment)

    # The LiveView should re-render without the deleted comment
    refute render(lv) =~ "Will be deleted remotely"
  end

  test "displays author signature after article body", %{conn: conn, user: user, article: article} do
    {:ok, _updated_user} = Baudrate.Auth.update_signature(user, "My **awesome** signature")

    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
    assert html =~ "Signature"
    assert html =~ "awesome"
  end

  test "comment pagination controls appear when root comments exceed per_page", %{
    conn: conn,
    user: user,
    article: article
  } do
    # Create 21 root comments (exceeds default per_page of 20)
    for i <- 1..21 do
      Content.create_comment(%{
        "body" => "Root comment #{i}",
        "article_id" => article.id,
        "user_id" => user.id
      })
    end

    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
    # Pagination should render with next-page button
    assert html =~ "join-item btn btn-sm btn-active"
    assert html =~ "»"
  end

  test "renders board-less article for authenticated user", %{conn: conn, user: user} do
    {:ok, %{article: boardless}} =
      Content.create_article(
        %{title: "Boardless Post", body: "No boards", slug: "boardless-post", user_id: user.id},
        []
      )

    {:ok, _lv, html} = live(conn, "/articles/#{boardless.slug}")
    assert html =~ "Boardless Post"
  end

  test "renders board-less article for guest visitor" do
    author = setup_user("user")

    {:ok, %{article: boardless}} =
      Content.create_article(
        %{
          title: "Guest Viewable",
          body: "Public post",
          slug: "guest-viewable",
          user_id: author.id
        },
        []
      )

    conn = Phoenix.ConnTest.build_conn()
    {:ok, _lv, html} = live(conn, "/articles/#{boardless.slug}")
    assert html =~ "Guest Viewable"
  end

  describe "toggle_pin" do
    test "admin can pin and unpin an article", %{article: article} do
      admin = setup_user("admin")

      admin_conn =
        Phoenix.ConnTest.build_conn()
        |> log_in_user(admin)

      {:ok, lv, html} = live(admin_conn, "/articles/#{article.slug}")
      assert html =~ "Pin"

      # Pin the article
      lv |> element("button[phx-click=toggle_pin]") |> render_click()
      html = render(lv)
      assert html =~ "Pinned"

      # Unpin the article
      lv |> element("button[phx-click=toggle_pin]") |> render_click()
      html = render(lv)
      refute html =~ "badge-primary"
    end
  end

  describe "toggle_lock" do
    test "admin can lock and unlock an article", %{article: article} do
      admin = setup_user("admin")

      admin_conn =
        Phoenix.ConnTest.build_conn()
        |> log_in_user(admin)

      {:ok, lv, html} = live(admin_conn, "/articles/#{article.slug}")
      assert html =~ "Lock"

      # Lock the article
      lv |> element("button[phx-click=toggle_lock]") |> render_click()
      html = render(lv)
      assert html =~ "Locked"
      assert html =~ "This thread is locked"

      # Unlock the article
      lv |> element("button[phx-click=toggle_lock]") |> render_click()
      html = render(lv)
      refute html =~ "This thread is locked"
    end
  end

  describe "delete_comment" do
    test "admin can delete a comment", %{user: user, article: article} do
      {:ok, comment} =
        Content.create_comment(%{
          "body" => "Comment to delete",
          "article_id" => article.id,
          "user_id" => user.id
        })

      admin = setup_user("admin")

      admin_conn =
        Phoenix.ConnTest.build_conn()
        |> log_in_user(admin)

      {:ok, lv, html} = live(admin_conn, "/articles/#{article.slug}")
      assert html =~ "Comment to delete"

      lv
      |> element(~s|button[phx-click="delete_comment"][phx-value-id="#{comment.id}"]|)
      |> render_click()

      html = render(lv)
      refute html =~ "Comment to delete"
    end
  end

  describe "reply_to and cancel_reply" do
    test "clicking reply shows reply form and cancel hides it", %{
      conn: conn,
      user: user,
      article: article
    } do
      {:ok, comment} =
        Content.create_comment(%{
          "body" => "Parent comment",
          "article_id" => article.id,
          "user_id" => user.id
        })

      {:ok, lv, _html} = live(conn, "/articles/#{article.slug}")

      # Click reply
      lv
      |> element(~s|button[phx-click="reply_to"][phx-value-id="#{comment.id}"]|)
      |> render_click()

      html = render(lv)
      assert html =~ "cancel_reply"

      # Cancel reply
      lv |> element(~s|button[phx-click="cancel_reply"]|) |> render_click()
      html = render(lv)
      refute html =~ "cancel_reply"
    end
  end

  describe "board-less articles" do
    test "authenticated user can post comments on board-less article", %{conn: conn, user: user} do
      {:ok, %{article: boardless}} =
        Content.create_article(
          %{
            title: "Boardless Commenting",
            body: "Test body",
            slug: "boardless-commenting",
            user_id: user.id
          },
          []
        )

      {:ok, lv, html} = live(conn, "/articles/#{boardless.slug}")
      assert html =~ "Write a comment"

      html =
        lv
        |> form("form[phx-submit=submit_comment]", comment: %{body: "Comment on boardless!"})
        |> render_submit()

      assert html =~ "Comment on boardless!"
    end

    test "admin sees moderation controls on board-less article", %{user: user} do
      {:ok, %{article: boardless}} =
        Content.create_article(
          %{
            title: "Boardless Moderation",
            body: "Test body",
            slug: "boardless-moderation",
            user_id: user.id
          },
          []
        )

      admin = setup_user("admin")

      admin_conn =
        Phoenix.ConnTest.build_conn()
        |> log_in_user(admin)

      {:ok, _lv, html} = live(admin_conn, "/articles/#{boardless.slug}")
      assert html =~ "Pin"
      assert html =~ "Lock"
      assert html =~ "Delete"
    end

    test "locking then unlocking a board-less article restores comment form", %{user: user} do
      {:ok, %{article: boardless}} =
        Content.create_article(
          %{
            title: "Boardless Lock Test",
            body: "Test body",
            slug: "boardless-lock-test",
            user_id: user.id
          },
          []
        )

      admin = setup_user("admin")

      admin_conn =
        Phoenix.ConnTest.build_conn()
        |> log_in_user(admin)

      {:ok, lv, _html} = live(admin_conn, "/articles/#{boardless.slug}")

      # Lock the article
      lv |> element("button[phx-click=toggle_lock]") |> render_click()
      html = render(lv)
      assert html =~ "This thread is locked"

      # Unlock the article
      lv |> element("button[phx-click=toggle_lock]") |> render_click()
      html = render(lv)
      refute html =~ "This thread is locked"
      assert html =~ "Write a comment"
    end
  end

  describe "forward to board" do
    test "shows forward button for board-less articles owned by user", %{conn: conn, user: user} do
      {:ok, %{article: boardless}} =
        Content.create_article(
          %{
            title: "Forward Me",
            body: "No board yet",
            slug: "forward-me",
            user_id: user.id
          },
          []
        )

      {:ok, _lv, html} = live(conn, "/articles/#{boardless.slug}")
      assert html =~ "Forward to Board"
    end

    test "shows forward button for forwardable articles in boards", %{
      conn: conn,
      article: article
    } do
      {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
      assert html =~ "Forward to Board"
    end

    test "does not show forward button for non-forwardable articles in boards", %{
      conn: conn,
      user: user
    } do
      board =
        %Board{}
        |> Board.changeset(%{name: "NF Board", slug: "nf-board-live"})
        |> Repo.insert!()

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Non Forwardable",
            body: "body",
            slug: "non-fwd-live",
            user_id: user.id,
            forwardable: false
          },
          [board.id]
        )

      {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
      refute html =~ "Forward to Board"
    end

    test "does not show forward button for other user's board-less articles", %{user: user} do
      {:ok, %{article: boardless}} =
        Content.create_article(
          %{
            title: "Others Forward",
            body: "Not mine",
            slug: "others-forward",
            user_id: user.id
          },
          []
        )

      other = setup_user("user")

      other_conn =
        Phoenix.ConnTest.build_conn()
        |> log_in_user(other)

      {:ok, _lv, html} = live(other_conn, "/articles/#{boardless.slug}")
      refute html =~ "Forward to Board"
    end

    test "autocomplete search returns board results", %{conn: conn, user: user} do
      _target_board =
        %Board{}
        |> Board.changeset(%{name: "Target Board", slug: "target-fwd"})
        |> Repo.insert!()

      {:ok, %{article: boardless}} =
        Content.create_article(
          %{
            title: "Search Forward",
            body: "body",
            slug: "search-forward",
            user_id: user.id
          },
          []
        )

      {:ok, lv, _html} = live(conn, "/articles/#{boardless.slug}")

      # Open search
      lv |> element("button[phx-click=toggle_forward_search]") |> render_click()

      # Search for board
      html =
        lv
        |> form("form[phx-change=search_forward_board]", %{query: "Target"})
        |> render_change()

      assert html =~ "Target Board"
    end

    test "forward action moves article to board and shows flash", %{conn: conn, user: user} do
      target_board =
        %Board{}
        |> Board.changeset(%{name: "Destination", slug: "destination-fwd"})
        |> Repo.insert!()

      {:ok, %{article: boardless}} =
        Content.create_article(
          %{
            title: "Will Forward",
            body: "body",
            slug: "will-forward",
            user_id: user.id
          },
          []
        )

      {:ok, lv, _html} = live(conn, "/articles/#{boardless.slug}")

      # Open search and forward directly
      lv |> element("button[phx-click=toggle_forward_search]") |> render_click()

      lv
      |> form("form[phx-change=search_forward_board]", %{query: "Dest"})
      |> render_change()

      html =
        lv
        |> element(
          ~s|button[phx-click="forward_to_board"][phx-value-board-id="#{target_board.id}"]|
        )
        |> render_click()

      assert html =~ "Article forwarded to board"
    end

    test "admin can forward another user's board-less article", %{user: user} do
      admin = setup_user("admin")

      admin_conn =
        Phoenix.ConnTest.build_conn()
        |> log_in_user(admin)

      target_board =
        %Board{}
        |> Board.changeset(%{name: "Admin Dest", slug: "admin-dest-fwd"})
        |> Repo.insert!()

      {:ok, %{article: boardless}} =
        Content.create_article(
          %{
            title: "Admin Forward",
            body: "body",
            slug: "admin-forward",
            user_id: user.id
          },
          []
        )

      {:ok, lv, html} = live(admin_conn, "/articles/#{boardless.slug}")
      assert html =~ "Forward to Board"

      lv |> element("button[phx-click=toggle_forward_search]") |> render_click()

      lv
      |> form("form[phx-change=search_forward_board]", %{query: "Admin"})
      |> render_change()

      html =
        lv
        |> element(
          ~s|button[phx-click="forward_to_board"][phx-value-board-id="#{target_board.id}"]|
        )
        |> render_click()

      assert html =~ "Article forwarded to board"
    end
  end

  describe "bookmark" do
    test "toggle bookmark button", %{conn: conn, article: article} do
      {:ok, lv, html} = live(conn, "/articles/#{article.slug}")
      # Should show unbookmarked state
      assert html =~ "Bookmark"
      refute html =~ "Bookmarked"

      # Click to bookmark
      lv |> element(~s|button[phx-click="toggle_bookmark"]|) |> render_click()
      html = render(lv)
      assert html =~ "Bookmarked"

      # Click to unbookmark
      lv |> element(~s|button[phx-click="toggle_bookmark"]|) |> render_click()
      html = render(lv)
      assert html =~ "hero-star"
      refute html =~ "hero-star-solid"
    end

    test "guest does not see bookmark button", %{article: article} do
      conn = Phoenix.ConnTest.build_conn()
      {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
      refute html =~ "toggle_bookmark"
    end
  end

  test "threaded replies stay with their root when paginated", %{
    conn: conn,
    user: user,
    article: article
  } do
    # Create 21 root comments so we have 2 pages
    root_comments =
      for i <- 1..21 do
        {:ok, c} =
          Content.create_comment(%{
            "body" => "Root #{i}",
            "article_id" => article.id,
            "user_id" => user.id
          })

        c
      end

    # Add a reply to the first root comment
    first_root = List.first(root_comments)

    {:ok, _reply} =
      Content.create_comment(%{
        "body" => "Reply to first root",
        "article_id" => article.id,
        "user_id" => user.id,
        "parent_id" => first_root.id
      })

    # Page 1 should show the first root and its reply
    {:ok, _lv, html} = live(conn, "/articles/#{article.slug}")
    assert html =~ "Root 1"
    assert html =~ "Reply to first root"
  end

  test "visiting article marks it as read", %{conn: conn, user: user, article: article} do
    # No read record before visit
    read =
      Baudrate.Repo.one(
        from(ar in Baudrate.Content.ArticleRead,
          where: ar.user_id == ^user.id and ar.article_id == ^article.id
        )
      )

    assert is_nil(read)

    # Visit the article
    {:ok, _lv, _html} = live(conn, "/articles/#{article.slug}")

    # Now there should be a read record
    read =
      Baudrate.Repo.one(
        from(ar in Baudrate.Content.ArticleRead,
          where: ar.user_id == ^user.id and ar.article_id == ^article.id
        )
      )

    assert read
    assert read.read_at
  end
end
