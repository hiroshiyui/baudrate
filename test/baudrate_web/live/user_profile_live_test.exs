defmodule BaudrateWeb.UserProfileLiveTest do
  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    {:ok, conn: conn}
  end

  test "renders JSON-LD with foaf:Person and DC meta", %{conn: conn} do
    user = setup_user("user")

    {:ok, _lv, html} = live(conn, "/users/#{user.username}")

    assert html =~ "application/ld+json"
    assert html =~ "foaf:Person"
    assert html =~ "DC.title"
  end

  test "renders profile for valid user", %{conn: conn} do
    user = setup_user("user")

    {:ok, _lv, html} = live(conn, "/users/#{user.username}")
    assert html =~ user.username
    assert html =~ "Articles"
    assert html =~ "Comments"
  end

  test "redirects for nonexistent user", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/users/doesnotexist999")
  end

  test "redirects for banned user", %{conn: conn} do
    admin = setup_user("admin")
    user = setup_user("user")
    {:ok, _, _} = Auth.ban_user(user, admin.id, "test")

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/users/#{user.username}")
  end

  test "shows article and comment counts", %{conn: conn} do
    user = setup_user("user")

    {:ok, _lv, html} = live(conn, "/users/#{user.username}")
    assert html =~ "0"
  end

  test "mute event as guest is a no-op", %{conn: conn} do
    user = setup_user("user")

    {:ok, lv, _html} = live(conn, "/users/#{user.username}")

    # Simulate crafted websocket message — guest has no current_user
    assert render_hook(lv, :mute_user, %{})
    assert render_hook(lv, :unmute_user, %{})
  end

  test "displays bio on user profile page", %{conn: conn} do
    user = setup_user("user")
    {:ok, _updated} = Auth.update_bio(user, "This is my bio text")

    {:ok, _lv, html} = live(conn, "/users/#{user.username}")
    assert html =~ "Bio"
    assert html =~ "This is my bio text"
  end

  test "linkifies hashtags in bio display", %{conn: conn} do
    user = setup_user("user")
    {:ok, _updated} = Auth.update_bio(user, "I love #elixir")

    {:ok, _lv, html} = live(conn, "/users/#{user.username}")
    assert html =~ ~s(href="/tags/elixir")
    assert html =~ "#elixir"
  end

  test "displays signature on user profile page", %{conn: conn} do
    user = setup_user("user")
    {:ok, _updated} = Auth.update_signature(user, "My **profile** signature")

    {:ok, _lv, html} = live(conn, "/users/#{user.username}")
    assert html =~ "Signature"
    assert html =~ "profile"
  end

  describe "recent activity" do
    test "shows articles in recent activity section", %{conn: conn} do
      user = setup_user("user")

      board =
        %Board{}
        |> Board.changeset(%{
          name: "Activity Board",
          slug: "activity-board-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      {:ok, _} =
        Content.create_article(
          %{
            title: "My Recent Article",
            body: "article body content",
            slug: "recent-art-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      {:ok, _lv, html} = live(conn, "/users/#{user.username}")
      assert html =~ "Recent Articles"
      assert html =~ "My Recent Article"
    end

    test "shows comments in recent activity section", %{conn: conn} do
      user = setup_user("user")

      board =
        %Board{}
        |> Board.changeset(%{
          name: "Comment Board",
          slug: "comment-board-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Article With Comment",
            body: "body",
            slug: "comment-art-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      {:ok, _comment} =
        Content.create_comment(%{
          body: "My test comment text",
          article_id: article.id,
          user_id: user.id
        })

      {:ok, _lv, html} = live(conn, "/users/#{user.username}")
      assert html =~ "Comment"
      assert html =~ "My test comment text"
      assert html =~ "Article With Comment"
    end

    test "shows empty state when no activity", %{conn: conn} do
      user = setup_user("user")

      {:ok, _lv, html} = live(conn, "/users/#{user.username}")
      assert html =~ "No articles yet."
    end

    test "shows load more button when more than 10 items", %{conn: conn} do
      user = setup_user("user")

      board =
        %Board{}
        |> Board.changeset(%{
          name: "Load More Board",
          slug: "load-more-board-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      for i <- 1..11 do
        Content.create_article(
          %{
            title: "Load More Article #{i}",
            body: "body",
            slug: "load-more-#{i}-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )
      end

      {:ok, lv, html} = live(conn, "/users/#{user.username}")
      assert html =~ "Load more"

      # Click load more to get the remaining items
      html = lv |> element(~s(button[phx-click="load_more_activity"])) |> render_click()
      refute html =~ ~s(phx-click="load_more_activity")
    end

    test "hides load more button when 10 or fewer items", %{conn: conn} do
      user = setup_user("user")

      board =
        %Board{}
        |> Board.changeset(%{
          name: "Few Board",
          slug: "few-board-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      for i <- 1..5 do
        Content.create_article(
          %{
            title: "Few Article #{i}",
            body: "body",
            slug: "few-#{i}-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )
      end

      {:ok, _lv, html} = live(conn, "/users/#{user.username}")
      refute html =~ ~s(phx-click="load_more_activity")
    end
  end

  describe "boosted articles & comments" do
    test "shows boosted articles section on profile page", %{conn: conn} do
      user = setup_user("user")
      other_user = setup_user("user")

      board =
        %Board{}
        |> Board.changeset(%{
          name: "Test Board",
          slug: "test-boost-board-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Boosted Test Article",
            body: "body",
            slug: "boost-art-#{System.unique_integer([:positive])}",
            user_id: other_user.id
          },
          [board.id]
        )

      {:ok, _boost} = Content.boost_article(user.id, article.id)

      {:ok, _lv, html} = live(conn, "/users/#{user.username}")
      assert html =~ "Boosted Articles"
      assert html =~ "Boosted Test Article"
      assert html =~ "Boosted"
    end

    test "shows boosted comments on profile page", %{conn: conn} do
      user = setup_user("user")
      other_user = setup_user("user")

      board =
        %Board{}
        |> Board.changeset(%{
          name: "Boost Comment Board",
          slug: "boost-comment-board-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Article For Boosted Comment",
            body: "body",
            slug: "boost-comment-art-#{System.unique_integer([:positive])}",
            user_id: other_user.id
          },
          [board.id]
        )

      {:ok, comment} =
        Content.create_comment(%{
          body: "Comment to be boosted",
          article_id: article.id,
          user_id: other_user.id
        })

      {:ok, _boost} = Content.boost_comment(user.id, comment.id)

      {:ok, _lv, html} = live(conn, "/users/#{user.username}")
      assert html =~ "Boosted Articles"
      assert html =~ "Comment to be boosted"
      assert html =~ "Article For Boosted Comment"
    end

    test "does not show boosted section when no boosts", %{conn: conn} do
      user = setup_user("user")

      {:ok, _lv, html} = live(conn, "/users/#{user.username}")
      refute html =~ "Boosted Articles"
    end

    test "boosted article shows board name", %{conn: conn} do
      user = setup_user("user")
      other_user = setup_user("user")

      board =
        %Board{}
        |> Board.changeset(%{
          name: "Boost Board",
          slug: "boost-board-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Board Boost Article",
            body: "body",
            slug: "board-boost-#{System.unique_integer([:positive])}",
            user_id: other_user.id
          },
          [board.id]
        )

      {:ok, _boost} = Content.boost_article(user.id, article.id)

      {:ok, _lv, html} = live(conn, "/users/#{user.username}")
      assert html =~ "Boost Board"
    end

    test "shows load more button for boosted articles when more than 10", %{conn: conn} do
      user = setup_user("user")
      other_user = setup_user("user")

      board =
        %Board{}
        |> Board.changeset(%{
          name: "Boost Load Board",
          slug: "boost-load-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      for i <- 1..11 do
        {:ok, %{article: article}} =
          Content.create_article(
            %{
              title: "Boost Load #{i}",
              body: "body",
              slug: "boost-load-#{i}-#{System.unique_integer([:positive])}",
              user_id: other_user.id
            },
            [board.id]
          )

        Content.boost_article(user.id, article.id)
      end

      {:ok, lv, html} = live(conn, "/users/#{user.username}")
      assert html =~ ~s(phx-click="load_more_boosted")

      html = lv |> element(~s(button[phx-click="load_more_boosted"])) |> render_click()
      refute html =~ ~s(phx-click="load_more_boosted")
    end
  end

  describe "follow button" do
    test "shows follow button on other user's profile", %{conn: conn} do
      current_user = setup_user("user")
      profile_user = setup_user("user")
      conn = log_in_user(conn, current_user)

      {:ok, _lv, html} = live(conn, "/users/#{profile_user.username}")
      assert html =~ "Follow"
    end

    test "no follow button on own profile", %{conn: conn} do
      user = setup_user("user")
      conn = log_in_user(conn, user)

      {:ok, _lv, html} = live(conn, "/users/#{user.username}")
      refute html =~ "follow_user"
    end

    test "follow event creates local follow", %{conn: conn} do
      current_user = setup_user("user")
      profile_user = setup_user("user")
      conn = log_in_user(conn, current_user)

      {:ok, lv, _html} = live(conn, "/users/#{profile_user.username}")

      html = lv |> element(~s(button[phx-click="follow_user"])) |> render_click()
      assert html =~ "Followed successfully"
      assert Federation.local_follows?(current_user.id, profile_user.id)
    end

    test "unfollow event removes local follow", %{conn: conn} do
      current_user = setup_user("user")
      profile_user = setup_user("user")
      {:ok, _} = Federation.create_local_follow(current_user, profile_user)
      conn = log_in_user(conn, current_user)

      {:ok, lv, html} = live(conn, "/users/#{profile_user.username}")
      assert html =~ "Unfollow"

      html = lv |> element(~s(button[phx-click="unfollow_user"])) |> render_click()
      assert html =~ "Unfollowed successfully"
      refute Federation.local_follows?(current_user.id, profile_user.id)
    end

    test "guest users don't see follow button", %{conn: conn} do
      user = setup_user("user")

      {:ok, _lv, html} = live(conn, "/users/#{user.username}")
      refute html =~ "follow_user"
    end
  end
end
