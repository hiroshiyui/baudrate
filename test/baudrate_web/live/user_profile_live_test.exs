defmodule BaudrateWeb.UserProfileLiveTest do
  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  @pgp_key """
  -----BEGIN PGP PUBLIC KEY BLOCK-----

  mDMEZfakeKeyForTestingOnlyNotARealKeyAtAll0123456789abcdefghijkl
  -----END PGP PUBLIC KEY BLOCK-----\
  """

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

  # 404, not a redirect: a redirect tells a crawler the page moved, so it keeps
  # asking and `/` collects the authority of every mistyped handle (ADR 0057).
  test "a nonexistent user is 404", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, "/users/doesnotexist999") end
  end

  test "a banned user is 404, indistinguishable from one that never existed", %{conn: conn} do
    admin = setup_user("admin")
    user = setup_user("user")
    {:ok, _, _} = Auth.ban_user(user, admin, "test")

    assert_error_sent 404, fn -> get(conn, "/users/#{user.username}") end
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

  describe "blocking" do
    setup do
      BaudrateWeb.RateLimiter.Sandbox.set_global_response({:allow, 1})
      :ok
    end

    test "blocks and unblocks from the more-actions menu", %{conn: conn} do
      me = setup_user("user")
      other = setup_user("user")
      {:ok, _} = Federation.create_local_follow(me, other)
      conn = log_in_user(conn, me)

      {:ok, lv, _html} = live(conn, "/users/#{other.username}")
      assert has_element?(lv, "#user-profile-unfollow")

      lv |> element("#user-profile-block") |> render_click()

      assert Auth.blocked?(me, other)
      refute Federation.local_follows?(me.id, other.id)
      assert has_element?(lv, "#user-profile-unblock")
      refute has_element?(lv, "#user-profile-follow")
      refute has_element?(lv, "#user-profile-message")
      assert_push_event(lv, "focus", %{id: "user-profile-more-actions"})

      lv |> element("#user-profile-unblock") |> render_click()

      refute Auth.blocked?(me, other)
      assert has_element?(lv, "#user-profile-block")
      assert has_element?(lv, "#user-profile-follow")
    end

    test "block events as a guest are a no-op", %{conn: conn} do
      user = setup_user("user")
      {:ok, lv, _html} = live(conn, "/users/#{user.username}")

      assert render_hook(lv, :block_user, %{})
      assert render_hook(lv, :unblock_user, %{})
    end

    test "the block is refused when rate limited", %{conn: conn} do
      me = setup_user("user")
      other = setup_user("user")
      conn = log_in_user(conn, me)
      {:ok, lv, _html} = live(conn, "/users/#{other.username}")

      BaudrateWeb.RateLimiter.Sandbox.set_global_response({:deny, 1_000})
      assert render_hook(lv, :block_user, %{}) =~ "Too many actions"
      refute Auth.blocked?(me, other)
    end
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

  # ADR 0068: the badge states what staff checked — control of a key — and
  # never that the site verified who somebody is.
  describe "the OpenPGP badge" do
    test "is absent until an admin has confirmed a key", %{conn: conn} do
      user = setup_user("user")

      {:ok, _lv, html} = live(conn, "/users/#{user.username}")
      refute html =~ "user-profile-key-confirmed"

      # A contact the member registered is a claim nobody has checked yet.
      {:ok, _contact} =
        Auth.add_recovery_contact(user, %{
          "email" => "owner@example.com",
          "pgp_public_key" => @pgp_key
        })

      {:ok, _lv, html} = live(conn, "/users/#{user.username}")
      refute html =~ "user-profile-key-confirmed"
    end

    test "says what was checked, to anyone reading the page", %{conn: conn} do
      admin = setup_user("admin")
      user = setup_user("user")

      {:ok, contact} =
        Auth.add_recovery_contact(user, %{
          "email" => "owner@example.com",
          "pgp_public_key" => @pgp_key
        })

      {:ok, _} = Auth.issue_recovery_challenge(admin, contact.id)
      {:ok, _} = Auth.set_recovery_contact_verification(admin, contact.id, "verified")

      # A guest connection: the badge is public, which is the point of it.
      {:ok, _lv, html} = live(conn, "/users/#{user.username}")

      assert html =~ "user-profile-key-confirmed"
      assert html =~ "OpenPGP key confirmed"

      assert html =~ "controls an OpenPGP key",
             """
             The title says what an admin actually established. A bare
             "Verified" would claim an identity check nobody here performed.
             """

      refute html =~ "owner@example.com",
             "the address is encrypted at rest and belongs on no public page"
    end

    test "goes away when the member changes the key", %{conn: conn} do
      admin = setup_user("admin")
      user = setup_user("user")

      {:ok, contact} =
        Auth.add_recovery_contact(user, %{
          "email" => "owner@example.com",
          "pgp_public_key" => @pgp_key
        })

      {:ok, _} = Auth.issue_recovery_challenge(admin, contact.id)
      {:ok, _} = Auth.set_recovery_contact_verification(admin, contact.id, "verified")

      {:ok, _} =
        Auth.update_recovery_contact(user, contact.id, %{
          "pgp_public_key" => String.replace(@pgp_key, "0123456789", "9876543210")
        })

      {:ok, _lv, html} = live(conn, "/users/#{user.username}")

      refute html =~ "user-profile-key-confirmed",
             """
             Editing the key drops the anchor back to pending (ADR 0058), and
             a badge that outlived that would vouch for a key nobody checked.
             """
    end
  end
end
