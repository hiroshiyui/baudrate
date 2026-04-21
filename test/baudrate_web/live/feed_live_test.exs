defmodule BaudrateWeb.FeedLiveTest do
  use BaudrateWeb.ConnCase, async: false

  import Ecto.Query
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
      assert html =~ "remote.example/notes/original"
      assert html =~ "hero-link"
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

    test "resets form after successful submission and article appears in feed", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/feed")

      lv
      |> form("form", article: %{title: "Quick Post", body: "Body text"})
      |> render_submit()

      # Form inputs should be cleared (value should not remain in the input)
      html = render(lv)
      refute html =~ ~s(value="Quick Post")

      # But the article should appear in the feed
      assert html =~ "Quick Post"
    end

    test "rate-limited users see error flash", %{conn: conn, user: user} do
      # Use real Hammer backend so rate limits actually trigger
      BaudrateWeb.RateLimiter.Sandbox.set_fun(&BaudrateWeb.RateLimiter.Hammer.check_rate/3)

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

  describe "quick-post board search" do
    defp create_search_board(attrs) do
      defaults = %{
        name: "Board-#{System.unique_integer([:positive])}",
        slug: "board-#{System.unique_integer([:positive])}"
      }

      %Baudrate.Content.Board{}
      |> Baudrate.Content.Board.changeset(Map.merge(defaults, attrs))
      |> Repo.insert!()
    end

    test "short query does not show result list", %{conn: conn} do
      _board = create_search_board(%{name: "FeedSearch"})
      {:ok, lv, _html} = live(conn, "/feed")

      html =
        lv
        |> element(~s|#quick-post-boards input[name="post_board_search_query"]|)
        |> render_keyup(%{"value" => "F"})

      refute html =~ ~s(id="post-board-search-results")
    end

    test "matching boards show up as clickable results", %{conn: conn} do
      board = create_search_board(%{name: "FeedSearchMatch-#{System.unique_integer([:positive])}"})
      {:ok, lv, _html} = live(conn, "/feed")

      html =
        lv
        |> element(~s|#quick-post-boards input[name="post_board_search_query"]|)
        |> render_keyup(%{"value" => "FeedSearchMatch"})

      assert html =~ ~s(id="post-board-search-results")
      assert html =~ board.name
    end

    test "selecting a board adds a chip and clears results", %{conn: conn} do
      board = create_search_board(%{name: "SelectMe-#{System.unique_integer([:positive])}"})
      {:ok, lv, _html} = live(conn, "/feed")

      lv
      |> element(~s|#quick-post-boards input[name="post_board_search_query"]|)
      |> render_keyup(%{"value" => "SelectMe"})

      html =
        lv
        |> element(~s|#post-board-search-results button|, board.name)
        |> render_click()

      assert html =~ ~s(id="selected-post-boards")
      assert html =~ board.name
      refute html =~ ~s(id="post-board-search-results")
    end

    test "removing a selected board removes the chip", %{conn: conn} do
      board = create_search_board(%{name: "DropMe-#{System.unique_integer([:positive])}"})
      {:ok, lv, _html} = live(conn, "/feed")

      lv
      |> element(~s|#quick-post-boards input[name="post_board_search_query"]|)
      |> render_keyup(%{"value" => "DropMe"})

      lv |> element(~s|#post-board-search-results button|, board.name) |> render_click()

      html =
        lv
        |> element(~s|button[phx-click="remove_post_board"][phx-value-board-id="#{board.id}"]|)
        |> render_click()

      refute html =~ ~s(id="selected-post-boards")
    end

    test "submitting with a selected board creates article attached to that board", %{conn: conn} do
      board = create_search_board(%{name: "PostHere-#{System.unique_integer([:positive])}"})
      {:ok, lv, _html} = live(conn, "/feed")

      lv
      |> element(~s|#quick-post-boards input[name="post_board_search_query"]|)
      |> render_keyup(%{"value" => "PostHere"})

      lv |> element(~s|#post-board-search-results button|, board.name) |> render_click()

      lv
      |> form("form[phx-submit='submit_post']",
        article: %{title: "Board Scoped Post", body: "Body"}
      )
      |> render_submit()

      article =
        Repo.one!(
          from(a in Baudrate.Content.Article,
            where: a.title == "Board Scoped Post",
            preload: :boards
          )
        )

      assert Enum.any?(article.boards, &(&1.id == board.id))
    end

    test "search excludes boards the user cannot post in", %{conn: conn} do
      hidden_board =
        create_search_board(%{
          name: "ModOnly-#{System.unique_integer([:positive])}",
          slug: "mod-only-feed-#{System.unique_integer([:positive])}",
          min_role_to_post: "moderator"
        })

      {:ok, lv, _html} = live(conn, "/feed")

      html =
        lv
        |> element(~s|#quick-post-boards input[name="post_board_search_query"]|)
        |> render_keyup(%{"value" => "ModOnly"})

      refute html =~ hidden_board.name
    end

    test "add_post_board rejects a board the user cannot post in even if sent directly",
         %{conn: conn} do
      # A client could skip the search and send add_post_board directly with
      # an arbitrary board id. The server must refuse via can_post_in_board?.
      hidden_board =
        create_search_board(%{
          name: "CraftedAdd-#{System.unique_integer([:positive])}",
          slug: "crafted-add-#{System.unique_integer([:positive])}",
          min_role_to_post: "moderator"
        })

      {:ok, lv, _html} = live(conn, "/feed")

      html = render_hook(lv, "add_post_board", %{"board-id" => "#{hidden_board.id}"})

      refute html =~ hidden_board.name
      refute html =~ ~s(id="selected-post-boards")
    end
  end

  describe "feed item replies" do
    test "reply button appears on remote feed items", %{conn: conn, user: user} do
      actor = create_remote_actor()
      create_accepted_follow(user, actor)
      create_feed_item(actor)

      {:ok, _lv, html} = live(conn, "/feed")
      assert html =~ "Reply"
      assert html =~ "hero-chat-bubble-left"
    end

    test "toggle_reply shows and hides the reply form", %{conn: conn, user: user} do
      actor = create_remote_actor()
      create_accepted_follow(user, actor)
      item = create_feed_item(actor)

      {:ok, lv, html} = live(conn, "/feed")
      refute html =~ "Write a reply..."

      # Click Reply to show form
      html =
        lv
        |> element("button[phx-click='toggle_reply'][phx-value-id='#{item.id}']")
        |> render_click()

      assert html =~ "Write a reply..."
      assert html =~ "Cancel"

      # Click Cancel to hide form
      html = lv |> element("button[phx-click='cancel_reply']") |> render_click()
      refute html =~ "Write a reply..."
    end

    test "submitting a reply creates a record and shows success flash", %{
      conn: conn,
      user: user
    } do
      actor = create_remote_actor()
      create_accepted_follow(user, actor)
      item = create_feed_item(actor)

      # Ensure user has a keypair for federation delivery
      Baudrate.Federation.KeyStore.ensure_user_keypair(user)

      {:ok, lv, _html} = live(conn, "/feed")

      # Open reply form
      lv
      |> element("button[phx-click='toggle_reply'][phx-value-id='#{item.id}']")
      |> render_click()

      # Submit reply
      html =
        lv
        |> form("form[phx-submit='submit_reply']",
          reply: %{body: "Hello from test!"},
          feed_item_id: item.id
        )
        |> render_submit()

      assert html =~ "Reply sent!"

      # Verify record was created
      replies = Baudrate.Federation.list_feed_item_replies(item.id)
      assert length(replies) == 1
      assert hd(replies).body == "Hello from test!"
    end

    test "reply count badge shows after submitting", %{conn: conn, user: user} do
      actor = create_remote_actor()
      create_accepted_follow(user, actor)
      item = create_feed_item(actor)

      Baudrate.Federation.KeyStore.ensure_user_keypair(user)

      {:ok, lv, _html} = live(conn, "/feed")

      lv
      |> element("button[phx-click='toggle_reply'][phx-value-id='#{item.id}']")
      |> render_click()

      lv
      |> form("form[phx-submit='submit_reply']",
        reply: %{body: "Counting reply"},
        feed_item_id: item.id
      )
      |> render_submit()

      html = render(lv)
      assert html =~ "badge badge-xs"
    end

    test "rate-limited reply shows error flash", %{conn: conn, user: user} do
      actor = create_remote_actor()
      create_accepted_follow(user, actor)
      item = create_feed_item(actor)

      # Use real Hammer backend
      BaudrateWeb.RateLimiter.Sandbox.set_fun(&BaudrateWeb.RateLimiter.Hammer.check_rate/3)

      # Exhaust the rate limit (20 per 5 min)
      for _ <- 1..20 do
        BaudrateWeb.RateLimits.check_feed_reply(user.id)
      end

      {:ok, lv, _html} = live(conn, "/feed")

      lv
      |> element("button[phx-click='toggle_reply'][phx-value-id='#{item.id}']")
      |> render_click()

      html =
        lv
        |> form("form[phx-submit='submit_reply']",
          reply: %{body: "Should be rate limited"},
          feed_item_id: item.id
        )
        |> render_submit()

      assert html =~ "replying too frequently"
    end
  end

  describe "quick-post markdown toolbar" do
    test "composer textarea has markdown toolbar", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/feed")
      assert html =~ "MarkdownToolbarHook"
    end
  end

  describe "quick-post poll" do
    test "poll toggle button renders", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/feed")
      assert html =~ "Add Poll"
    end

    test "toggling poll shows poll options", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/feed")

      html =
        lv
        |> element("button[phx-click='toggle_poll']")
        |> render_click()

      assert html =~ "Option 1"
      assert html =~ "Option 2"
      assert html =~ "Single choice"
      assert html =~ "Multiple choice"
      assert html =~ "Remove Poll"
    end

    test "can add and remove poll options", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/feed")

      lv
      |> element("button[phx-click='toggle_poll']")
      |> render_click()

      # Add a third option
      html =
        lv
        |> element("button[phx-click='add_poll_option']")
        |> render_click()

      assert html =~ "Option 3"

      # Remove the third option
      html =
        lv
        |> element("button[phx-click='remove_poll_option'][phx-value-index='2']")
        |> render_click()

      refute html =~ "Option 3"
    end

    test "creates article with poll", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/feed")

      # Enable poll
      lv
      |> element("button[phx-click='toggle_poll']")
      |> render_click()

      # Submit with poll options
      html =
        lv
        |> form("form[phx-submit='submit_post']",
          article: %{title: "Poll Post", body: "Vote on this!"},
          poll_options: %{"0" => "Yes", "1" => "No"},
          poll_mode: "single",
          poll_expires: ""
        )
        |> render_submit()

      assert html =~ "Article posted!"

      article = Baudrate.Repo.get_by(Baudrate.Content.Article, title: "Poll Post")
      assert article
      poll = Baudrate.Content.Polls.get_poll_for_article(article.id)
      assert poll
      assert poll.mode == "single"
      assert length(poll.options) == 2
    end
  end

  describe "mention autocomplete" do
    test "mention_suggest returns matching users", %{conn: conn, user: _user} do
      other = setup_user("user")
      {:ok, lv, _html} = live(conn, "/feed")

      render_hook(lv, "mention_suggest", %{"prefix" => String.slice(other.username, 0, 4)})

      assert_push_event(lv, "mention_suggestions", %{users: users})
      usernames = Enum.map(users, & &1.username)
      assert other.username in usernames
    end

    test "mention_suggest excludes current user", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/feed")

      render_hook(lv, "mention_suggest", %{"prefix" => String.slice(user.username, 0, 4)})

      assert_push_event(lv, "mention_suggestions", %{users: users})
      usernames = Enum.map(users, & &1.username)
      refute user.username in usernames
    end
  end

  describe "quick-post image upload" do
    test "image upload input renders", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/feed")
      assert html =~ "feed-images-section"
    end
  end

  describe "requires authentication" do
    test "redirects unauthenticated user to login" do
      conn = build_conn()
      {:error, {:redirect, %{to: to}}} = live(conn, "/feed")
      assert to =~ "/login"
    end
  end

  describe "comments in feed" do
    test "shows comments on own articles from other users", %{conn: conn, user: user} do
      board = create_board()
      {:ok, %{article: article}} = create_article_raw(user, board, %{title: "My Own Article"})
      other_user = setup_user("user")

      {:ok, _comment} =
        Baudrate.Content.create_comment(%{
          "body" => "Great article!",
          "article_id" => article.id,
          "user_id" => other_user.id
        })

      {:ok, _lv, html} = live(conn, "/feed")
      assert html =~ "Great article!"
      assert html =~ "commented on"
      assert html =~ "My Own Article"
    end

    test "shows comments on articles user has commented on", %{conn: conn, user: user} do
      other_author = setup_user("user")
      {:ok, _} = Federation.create_local_follow(user, other_author)
      board = create_board()

      {:ok, %{article: article}} =
        create_article_raw(other_author, board, %{title: "Interesting Discussion"})

      # User comments on the article first
      {:ok, _} =
        Baudrate.Content.create_comment(%{
          "body" => "My initial thought",
          "article_id" => article.id,
          "user_id" => user.id
        })

      # Third user comments on the same article
      third_user = setup_user("user")

      {:ok, _} =
        Baudrate.Content.create_comment(%{
          "body" => "Another perspective here",
          "article_id" => article.id,
          "user_id" => third_user.id
        })

      {:ok, _lv, html} = live(conn, "/feed")
      assert html =~ "Another perspective here"
      assert html =~ "commented on"
      assert html =~ "Interesting Discussion"
    end

    test "shows own comments in feed", %{conn: conn, user: user} do
      board = create_board()
      {:ok, %{article: article}} = create_article_raw(user, board, %{title: "Self Comment Test"})

      {:ok, _} =
        Baudrate.Content.create_comment(%{
          "body" => "My own comment on my article",
          "article_id" => article.id,
          "user_id" => user.id
        })

      {:ok, _lv, html} = live(conn, "/feed")
      assert html =~ "My own comment on my article"
      assert html =~ "Self Comment Test"
    end

    test "shows remote actor comments without crashing", %{conn: conn, user: user} do
      board = create_board()
      {:ok, %{article: article}} = create_article_raw(user, board, %{title: "Federated Replies"})

      actor =
        create_remote_actor(%{
          username: "fediuser",
          domain: "fedi.example",
          display_name: "Fedi User"
        })

      {:ok, _comment} =
        Baudrate.Content.create_remote_comment(%{
          body: "Hello from the fediverse!",
          body_html: "<p>Hello from the fediverse!</p>",
          ap_id: "https://fedi.example/comments/#{System.unique_integer([:positive])}",
          article_id: article.id,
          remote_actor_id: actor.id
        })

      {:ok, _lv, html} = live(conn, "/feed")
      assert html =~ "Hello from the fediverse!"
      assert html =~ "commented on"
      assert html =~ "Federated Replies"
      assert html =~ "Fedi User"
      assert html =~ "fediuser"
      assert html =~ "fedi.example"
      assert html =~ "Fediverse"
    end

    test "shows remote actor comment with fallback icon when no avatar", %{conn: conn, user: user} do
      board = create_board()
      {:ok, %{article: article}} = create_article_raw(user, board, %{title: "No Avatar Article"})

      actor =
        create_remote_actor(%{
          username: "noavatar",
          domain: "other.example",
          display_name: "No Avatar Actor",
          avatar_url: nil
        })

      {:ok, _comment} =
        Baudrate.Content.create_remote_comment(%{
          body: "Comment without avatar",
          body_html: "<p>Comment without avatar</p>",
          ap_id: "https://other.example/comments/#{System.unique_integer([:positive])}",
          article_id: article.id,
          remote_actor_id: actor.id
        })

      {:ok, _lv, html} = live(conn, "/feed")
      assert html =~ "Comment without avatar"
      assert html =~ "No Avatar Actor"
      assert html =~ "hero-user-circle"
    end

    test "does not show comments from blocked users", %{conn: conn, user: user} do
      board = create_board()
      {:ok, %{article: article}} = create_article_raw(user, board, %{title: "Blocked Test"})
      blocked_user = setup_user("user")

      {:ok, _} =
        Baudrate.Content.create_comment(%{
          "body" => "Comment from blocked person",
          "article_id" => article.id,
          "user_id" => blocked_user.id
        })

      {:ok, _} = Baudrate.Auth.block_user(user, blocked_user)

      {:ok, _lv, html} = live(conn, "/feed")
      refute html =~ "Comment from blocked person"
    end
  end

  describe "feed item like/boost buttons" do
    test "like button appears on remote feed items", %{conn: conn, user: user} do
      actor = create_remote_actor()
      create_accepted_follow(user, actor)
      item = create_feed_item(actor)

      {:ok, _lv, html} = live(conn, "/feed")

      assert html =~
               ~s(phx-click="toggle_feed_item_like" phx-value-id="#{item.id}")

      assert html =~ "hero-heart"
    end

    test "boost button appears on remote feed items", %{conn: conn, user: user} do
      actor = create_remote_actor()
      create_accepted_follow(user, actor)
      item = create_feed_item(actor)

      {:ok, _lv, html} = live(conn, "/feed")

      assert html =~
               ~s(phx-click="toggle_feed_item_boost" phx-value-id="#{item.id}")

      assert html =~ "hero-arrow-path-rounded-square"
    end

    test "clicking like toggles feed item like", %{conn: conn, user: user} do
      actor = create_remote_actor()
      create_accepted_follow(user, actor)
      item = create_feed_item(actor)

      Baudrate.Federation.KeyStore.ensure_user_keypair(user)

      {:ok, lv, html} = live(conn, "/feed")

      # Initially shows "Like" aria-label (not liked)
      assert html =~ ~s(aria-label="Like")
      refute html =~ "hero-heart-solid"

      # Click like button
      html =
        lv
        |> element(~s(button[phx-click="toggle_feed_item_like"][phx-value-id="#{item.id}"]))
        |> render_click()

      # After clicking, should show solid heart with text-error class
      assert html =~ "hero-heart-solid"
      assert html =~ "text-error"
      assert html =~ ~s(aria-label="Unlike")
    end

    test "clicking boost toggles feed item boost", %{conn: conn, user: user} do
      actor = create_remote_actor()
      create_accepted_follow(user, actor)
      item = create_feed_item(actor)

      Baudrate.Federation.KeyStore.ensure_user_keypair(user)

      {:ok, lv, html} = live(conn, "/feed")

      # Initially shows "Boost" aria-label (not boosted)
      assert html =~ ~s(aria-label="Boost")
      refute html =~ "hero-arrow-path-rounded-square-solid"

      # Click boost button
      html =
        lv
        |> element(~s(button[phx-click="toggle_feed_item_boost"][phx-value-id="#{item.id}"]))
        |> render_click()

      # After clicking, should show solid icon with text-success class
      assert html =~ "hero-arrow-path-rounded-square-solid"
      assert html =~ "text-success"
      assert html =~ ~s(aria-label="Unboost")
    end

    test "like/boost buttons appear on local articles from followed users", %{
      conn: conn,
      user: user
    } do
      followed_user = setup_user("user")
      {:ok, _} = Federation.create_local_follow(user, followed_user)

      board = create_board()
      create_article(followed_user, board, %{title: "Followed User Article"})

      {:ok, _lv, html} = live(conn, "/feed")

      assert html =~ "Followed User Article"
      assert html =~ ~s(phx-click="toggle_article_like")
      assert html =~ ~s(phx-click="toggle_article_boost")
    end

    test "like/boost buttons do not appear on own articles", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/feed")

      # Create own article via the quick-post composer so it appears in the feed
      lv
      |> form("form", article: %{title: "My Own Article For Buttons", body: "Own body"})
      |> render_submit()

      html = render(lv)

      # Own article should be visible in the feed
      assert html =~ "My Own Article For Buttons"

      # But like/boost buttons should NOT appear for own content
      # (the template uses :if={item.article.user_id != @current_user.id})
      refute html =~ ~s(phx-click="toggle_article_like")
      refute html =~ ~s(phx-click="toggle_article_boost")
    end
  end

  defp create_article_raw(user, board, attrs) do
    uid = System.unique_integer([:positive])

    Baudrate.Content.create_article(
      %{
        title: attrs[:title] || "Article #{uid}",
        body: attrs[:body] || "Body for article #{uid}",
        slug: "test-article-#{uid}",
        user_id: user.id
      },
      [board.id]
    )
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
