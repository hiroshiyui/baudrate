defmodule BaudrateWeb.FeedLiveTest do
  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Federation
  alias Baudrate.Federation.RemoteActor
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    user = Repo.preload(user, :role)
    conn = log_in_user(conn, user)

    {:ok, conn: conn, user: user}
  end

  defp create_remote_actor(attrs \\ %{}) do
    uid = System.unique_integer([:positive])

    default = %{
      ap_id: "https://remote.example/users/actor-#{uid}",
      username: "actor_#{uid}",
      domain: "remote.example",
      display_name: "Remote Actor #{uid}",
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
      inbox: "https://remote.example/users/actor-#{uid}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    {:ok, actor} =
      %RemoteActor{}
      |> RemoteActor.changeset(Map.merge(default, attrs))
      |> Repo.insert()

    actor
  end

  defp create_accepted_follow(user, actor) do
    {:ok, follow} = Federation.create_user_follow(user, actor)
    {:ok, _follow} = Federation.accept_user_follow(follow.ap_id)
  end

  defp create_feed_item(actor, extra \\ %{}) do
    uid = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          remote_actor_id: actor.id,
          activity_type: "Create",
          object_type: "Note",
          ap_id: "https://remote.example/notes/#{uid}",
          body: "Hello from #{actor.username}",
          body_html: "<p>Hello from #{actor.username}</p>",
          source_url: "https://remote.example/notes/#{uid}",
          published_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        extra
      )

    {:ok, item} = Federation.create_feed_item(attrs)
    item
  end

  describe "page loads" do
    test "authenticated user sees feed page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/feed")
      assert html =~ "Feed"
    end

    test "shows personal info sidebar with user details", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, "/feed")
      assert html =~ user.username
      assert html =~ "Member since"
      assert html =~ "Articles"
      assert html =~ "Comments"
      assert html =~ "/profile"
    end

    test "shows empty state when no items", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/feed")
      assert html =~ "feed is empty"
      assert html =~ "/search"
    end

    test "shows feed items from followed actors", %{conn: conn, user: user} do
      actor =
        create_remote_actor(%{username: "alice", domain: "example.org", display_name: "Alice"})

      create_accepted_follow(user, actor)
      create_feed_item(actor, %{body_html: "<p>Test post content</p>"})

      {:ok, _lv, html} = live(conn, "/feed")
      assert html =~ "Alice"
      assert html =~ "alice"
      assert html =~ "example.org"
      assert html =~ "Test post content"
    end

    test "shows article titles", %{conn: conn, user: user} do
      actor = create_remote_actor()
      create_accepted_follow(user, actor)
      create_feed_item(actor, %{object_type: "Article", title: "My Great Article"})

      {:ok, _lv, html} = live(conn, "/feed")
      assert html =~ "My Great Article"
      assert html =~ "Article"
    end

    test "shows View original link", %{conn: conn, user: user} do
      actor = create_remote_actor()
      create_accepted_follow(user, actor)
      create_feed_item(actor, %{source_url: "https://remote.example/notes/original"})

      {:ok, _lv, html} = live(conn, "/feed")
      assert html =~ "View original"
      assert html =~ "remote.example/notes/original"
    end
  end

  describe "pagination" do
    test "pagination works", %{conn: conn, user: user} do
      actor = create_remote_actor()
      create_accepted_follow(user, actor)

      for _ <- 1..25 do
        create_feed_item(actor)
      end

      {:ok, _lv, html} = live(conn, "/feed")
      # Should show pagination when more than 20 items
      assert html =~ "Pagination"

      {:ok, _lv, html2} = live(conn, "/feed?page=2")
      assert html2 =~ "Feed"
    end
  end

  describe "local follows in feed" do
    test "feed includes articles from locally-followed users", %{conn: conn, user: user} do
      # Create a followed user and their article
      followed_user = setup_user("user")
      {:ok, _} = Federation.create_local_follow(user, followed_user)

      board = create_board()
      create_article(followed_user, board, %{title: "Local Followed Article"})

      {:ok, _lv, html} = live(conn, "/feed")
      assert html =~ "Local Followed Article"
      assert html =~ followed_user.username
      assert html =~ "Local"
    end

    test "feed does not show articles from unfollowed users", %{conn: conn} do
      unfollowed_user = setup_user("user")
      board = create_board()
      create_article(unfollowed_user, board, %{title: "Unfollowed Article"})

      {:ok, _lv, html} = live(conn, "/feed")
      refute html =~ "Unfollowed Article"
    end
  end

  describe "quick-post composer" do
    test "composer card renders for authenticated users", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/feed")
      assert html =~ "Oh! I just had a thought!"
      assert html =~ "Post"
    end

    test "validates form fields", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/feed")

      html =
        lv
        |> form("form", article: %{title: "", body: ""})
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    test "successfully creates an article with no boards", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/feed")

      html =
        lv
        |> form("form", article: %{title: "My Quick Post", body: "Hello from the feed!"})
        |> render_submit()

      assert html =~ "Article posted!"

      # Article exists in database
      assert Baudrate.Repo.get_by(Baudrate.Content.Article, title: "My Quick Post")
    end

    test "resets form after successful submission", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/feed")

      lv
      |> form("form", article: %{title: "Quick Post", body: "Body text"})
      |> render_submit()

      # Form should be reset — fields should not contain old values
      html = render(lv)
      refute html =~ "Quick Post"
    end

    test "rate-limited users see error flash", %{conn: conn, user: user} do
      # Exhaust the rate limit (10 per 15 minutes for non-admin)
      for _ <- 1..10 do
        BaudrateWeb.RateLimits.check_create_article(user.id)
      end

      {:ok, lv, _html} = live(conn, "/feed")

      html =
        lv
        |> form("form", article: %{title: "Rate Limited Post", body: "Should fail"})
        |> render_submit()

      assert html =~ "posting too frequently"
    end

    test "composer does not render for guests" do
      conn = build_conn()
      {:error, {:redirect, %{to: to}}} = live(conn, "/feed")
      assert to =~ "/login"
    end
  end

  describe "requires authentication" do
    test "redirects unauthenticated user to login" do
      conn = build_conn()
      {:error, {:redirect, %{to: to}}} = live(conn, "/feed")
      assert to =~ "/login"
    end
  end

  defp create_board do
    alias Baudrate.Content.Board

    uid = System.unique_integer([:positive])

    {:ok, board} =
      %Board{}
      |> Board.changeset(%{
        name: "Board #{uid}",
        slug: "board-#{uid}",
        description: "Test board",
        min_role_to_view: "guest",
        min_role_to_post: "user"
      })
      |> Repo.insert()

    board
  end

  defp create_article(user, board, attrs) do
    alias Baudrate.Content

    uid = System.unique_integer([:positive])

    {:ok, article} =
      Content.create_article(
        %{
          title: attrs[:title] || "Article #{uid}",
          body: attrs[:body] || "Body for article #{uid}",
          slug: "test-article-#{uid}",
          user_id: user.id
        },
        [board.id]
      )

    article
  end
end
