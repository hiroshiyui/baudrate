defmodule BaudrateWeb.NotificationsLiveTest do
  use BaudrateWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.Notification
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    user = setup_user("user")
    %{user: user}
  end

  describe "authenticated access" do
    test "redirects to login when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login" <> _}}} = live(conn, "/notifications")
    end

    test "renders empty state when no notifications", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, _lv, html} = live(conn, "/notifications")

      assert html =~ "No notifications yet."
      assert html =~ "hero-bell"
    end
  end

  describe "notification list" do
    setup %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, conn: conn}
    end

    # ADR 0065: each says what happened in a full sentence, names no
    # moderator, and leads somewhere the member can act.
    test "renders the three held-post notices", %{conn: conn, user: user} do
      {:ok, _} =
        Notification.create_notification(%{
          type: "held_post",
          user_id: user.id,
          data: %{"held_post_id" => 1, "kind" => "article"}
        })

      {:ok, _} =
        Notification.create_notification(%{
          type: "post_rejected",
          user_id: user.id,
          data: %{"kind" => "comment"}
        })

      {:ok, _lv, html} = live(conn, "/notifications")

      assert html =~ "A post is waiting for review."
      assert html =~ ~s(href="/moderation/held")
      assert html =~ "A moderator declined to publish your post."
      assert html =~ ~s(href="/drafts")
    end

    test "renders notification with actor name and type text", %{
      conn: conn,
      user: user
    } do
      other = setup_user("user")

      {:ok, _notif} =
        Notification.create_notification(%{
          type: "reply_to_article",
          user_id: user.id,
          actor_user_id: other.id
        })

      {:ok, _lv, html} = live(conn, "/notifications")

      assert html =~ other.username
      assert html =~ "replied to your article"
    end

    test "renders an account security notice with a link to the profile and a warning",
         %{conn: conn, user: user} do
      {:ok, _cred} =
        Baudrate.Auth.create_webauthn_credential(user, %{
          credential_id: :crypto.strong_rand_bytes(32),
          public_key_cbor: CBOR.encode(%{1 => 2, -2 => :crypto.strong_rand_bytes(32)}),
          sign_count: 0,
          label: "Office Key"
        })

      [notice] =
        Repo.all(from(n in Baudrate.Notification.Notification, where: n.user_id == ^user.id))

      {:ok, lv, _html} = live(conn, "/notifications")

      assert has_element?(lv, "#notification-#{notice.id}", "A security key was added")
      assert has_element?(lv, "#notification-target-#{notice.id}[href='/profile']", "Office Key")
      assert has_element?(lv, "#notification-security-hint-#{notice.id}")
      # No actor is rendered for a security notice.
      refute has_element?(lv, "#notification-actor-#{notice.id}")
    end

    test "a failed-code notice links to the password change page with its own warning",
         %{conn: conn, user: user} do
      {:ok, notice} =
        Baudrate.Notification.Hooks.notify_account_security(user.id, "totp_login_failed")

      {:ok, lv, _html} = live(conn, "/notifications")

      assert has_element?(lv, "#notification-#{notice.id}", "failed the two-factor code")

      assert has_element?(
               lv,
               "#notification-target-#{notice.id}[href='/profile/password']",
               "Change your password"
             )

      assert has_element?(
               lv,
               "#notification-security-hint-#{notice.id}",
               "your password is known to someone else"
             )
    end

    test "an actor_moved notice names the new account", %{conn: conn, user: user} do
      mover = setup_user("user")

      {:ok, notice} =
        Baudrate.Notification.Hooks.notify_actor_moved(user.id, %{actor_user_id: mover.id}, %{
          "label" => "@mover@new.example",
          "url" => "https://new.example/@mover"
        })

      {:ok, lv, _html} = live(conn, "/notifications")

      assert has_element?(lv, "#notification-#{notice.id}", "moved to a new account")
      assert has_element?(lv, "#notification-#{notice.id}", "New account: @mover@new.example")
      refute has_element?(lv, "#notification-security-hint-#{notice.id}")
    end

    test "unread notifications carry a visible Unread label", %{conn: conn, user: user} do
      other = setup_user("user")

      {:ok, notif} =
        Notification.create_notification(%{
          type: "mention",
          user_id: user.id,
          actor_user_id: other.id
        })

      {:ok, lv, _html} = live(conn, "/notifications")

      assert has_element?(lv, "#notification-unread-label-#{notif.id}", "Unread")
    end

    test "announces newly created notifications via a status region", %{
      conn: conn,
      user: user
    } do
      other = setup_user("user")
      {:ok, lv, _html} = live(conn, "/notifications")

      assert has_element?(lv, "#notifications-live-status[role='status']")

      {:ok, notif} =
        Notification.create_notification(%{
          type: "mention",
          user_id: user.id,
          actor_user_id: other.id
        })

      send(lv.pid, {:notification_created, %{notification_id: notif.id}})

      assert has_element?(lv, "#notifications-live-status", "1 unread notification")
    end

    test "renders multiple notification types with correct icons", %{
      conn: conn,
      user: user
    } do
      other = setup_user("user")

      for type <- ["mention", "new_follower", "article_liked"] do
        {:ok, _} =
          Notification.create_notification(%{
            type: type,
            user_id: user.id,
            actor_user_id: other.id
          })
      end

      {:ok, _lv, html} = live(conn, "/notifications")

      assert html =~ "mentioned you"
      assert html =~ "followed you"
      assert html =~ "liked your article"
      assert html =~ "hero-at-symbol"
      assert html =~ "hero-user-plus"
      assert html =~ "hero-heart"
    end

    test "shows article title as target link", %{conn: conn, user: user} do
      other = setup_user("user")
      board = create_board("test-board")

      {:ok, %{article: article}} =
        Baudrate.Content.create_article(
          %{
            "title" => "My Test Article",
            "body" => "Content here",
            "slug" => "my-test-article-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      {:ok, _notif} =
        Notification.create_notification(%{
          type: "reply_to_article",
          user_id: user.id,
          actor_user_id: other.id,
          article_id: article.id
        })

      {:ok, _lv, html} = live(conn, "/notifications")

      assert html =~ "My Test Article"
      assert html =~ ~s(/articles/#{article.slug})
    end

    test "unread notifications have primary border styling", %{conn: conn, user: user} do
      other = setup_user("user")

      {:ok, _notif} =
        Notification.create_notification(%{
          type: "mention",
          user_id: user.id,
          actor_user_id: other.id
        })

      {:ok, _lv, html} = live(conn, "/notifications")

      assert html =~ "border-primary"
    end

    test "read notifications have reduced opacity", %{conn: conn, user: user} do
      other = setup_user("user")

      {:ok, notif} =
        Notification.create_notification(%{
          type: "mention",
          user_id: user.id,
          actor_user_id: other.id
        })

      Notification.mark_as_read(notif)

      {:ok, _lv, html} = live(conn, "/notifications")

      assert html =~ "opacity-75"
      refute html =~ "border-primary"
    end
  end

  describe "mark as read" do
    setup %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, conn: conn}
    end

    test "mark_read event marks a single notification as read", %{conn: conn, user: user} do
      other = setup_user("user")

      {:ok, notif} =
        Notification.create_notification(%{
          type: "mention",
          user_id: user.id,
          actor_user_id: other.id
        })

      {:ok, lv, html} = live(conn, "/notifications")
      assert html =~ "border-primary"

      lv |> element(~s(button[phx-value-id="#{notif.id}"])) |> render_click()

      html = render(lv)
      assert html =~ "opacity-75"
    end

    test "mark_all_read event marks all notifications as read", %{conn: conn, user: user} do
      other = setup_user("user")

      for type <- ["mention", "new_follower"] do
        {:ok, _} =
          Notification.create_notification(%{
            type: type,
            user_id: user.id,
            actor_user_id: other.id
          })
      end

      {:ok, lv, html} = live(conn, "/notifications")
      assert html =~ "Mark all as read"

      lv |> element(~s(button[phx-click="mark_all_read"])) |> render_click()

      html = render(lv)
      refute html =~ "border-primary"
      refute html =~ "Mark all as read"
    end
  end

  describe "real-time updates" do
    setup %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, conn: conn}
    end

    test "new notification appears in real time", %{conn: conn, user: user} do
      other = setup_user("user")
      {:ok, lv, html} = live(conn, "/notifications")
      assert html =~ "No notifications yet."

      {:ok, _notif} =
        Notification.create_notification(%{
          type: "new_follower",
          user_id: user.id,
          actor_user_id: other.id
        })

      html = render(lv)
      assert html =~ "followed you"
      refute html =~ "No notifications yet."
    end

    test "mark_all_read broadcast updates the page", %{conn: conn, user: user} do
      other = setup_user("user")

      {:ok, _notif} =
        Notification.create_notification(%{
          type: "mention",
          user_id: user.id,
          actor_user_id: other.id
        })

      {:ok, lv, html} = live(conn, "/notifications")
      assert html =~ "border-primary"

      # Simulate external mark_all_read (e.g. from another tab)
      Notification.mark_all_as_read(user.id)

      html = render(lv)
      refute html =~ "border-primary"
    end
  end

  describe "grouping, filtering and comment links (6B)" do
    setup %{conn: conn, user: user} do
      board = create_board("grouping-#{System.unique_integer([:positive])}")

      {:ok, %{article: article}} =
        Baudrate.Content.create_article(
          %{
            "title" => "Grouped Article",
            "body" => "Content here",
            "slug" => "grouped-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      {:ok, conn: log_in_user(conn, user), article: article}
    end

    test "likes of one article are one entry naming two people and the rest", %{
      conn: conn,
      user: user,
      article: article
    } do
      for _ <- 1..4 do
        {:ok, _} =
          Notification.create_notification(%{
            type: "article_liked",
            user_id: user.id,
            actor_user_id: setup_user("user").id,
            article_id: article.id
          })
      end

      {:ok, lv, _html} = live(conn, "/notifications")

      assert [_] = Regex.scan(~r/id="notification-\d+"/, render(lv))
      assert has_element?(lv, ".notification-group")
      assert has_element?(lv, ".notification-others", "and 2 others")
      assert has_element?(lv, ".notification-text", "liked your article")
    end

    test "two people are named with \"and\"", %{conn: conn, user: user, article: article} do
      for _ <- 1..2 do
        Notification.create_notification(%{
          type: "article_liked",
          user_id: user.id,
          actor_user_id: setup_user("user").id,
          article_id: article.id
        })
      end

      {:ok, lv, _html} = live(conn, "/notifications")
      assert has_element?(lv, ".notification-actor-separator", "and")
      refute has_element?(lv, ".notification-others")
    end

    test "marking a group read marks all of it", %{conn: conn, user: user, article: article} do
      for _ <- 1..3 do
        Notification.create_notification(%{
          type: "article_liked",
          user_id: user.id,
          actor_user_id: setup_user("user").id,
          article_id: article.id
        })
      end

      {:ok, lv, _html} = live(conn, "/notifications")
      lv |> element(".notification-mark-read") |> render_click()

      assert Notification.unread_count(user.id) == 0
    end

    test "the filter shows one category and keeps it across pages", %{
      conn: conn,
      user: user,
      article: article
    } do
      other = setup_user("user")

      Notification.create_notification(%{
        type: "mention",
        user_id: user.id,
        actor_user_id: other.id,
        article_id: article.id
      })

      Notification.create_notification(%{
        type: "new_follower",
        user_id: user.id,
        actor_user_id: other.id
      })

      {:ok, lv, _html} = live(conn, "/notifications?filter=follows")

      assert has_element?(lv, ".notification-text", "followed you")
      refute has_element?(lv, ".notification-text", "mentioned you")
      assert has_element?(lv, ~s|#notifications-filter-follows a[aria-current="page"]|)

      {:ok, lv, _html} = live(conn, "/notifications?filter=bogus")
      assert has_element?(lv, ".notification-text", "followed you")
      assert has_element?(lv, ".notification-text", "mentioned you")
      assert has_element?(lv, ~s|#notifications-filter-all a[aria-current="page"]|)
    end

    test "a reply on a later page links to that page and the comment", %{
      conn: conn,
      user: user,
      article: article
    } do
      other = setup_user("user")

      comments =
        for i <- 1..21 do
          {:ok, comment} =
            Baudrate.Content.create_comment(%{
              "body" => "reply #{i}",
              "article_id" => article.id,
              "user_id" => other.id
            })

          Repo.update_all(
            from(c in Baudrate.Content.Comment, where: c.id == ^comment.id),
            set: [inserted_at: DateTime.add(~U[2026-01-01 00:00:00Z], i, :second)]
          )

          comment
        end

      last = List.last(comments)

      Repo.delete_all(from(n in Baudrate.Notification.Notification, where: n.user_id == ^user.id))

      {:ok, _} =
        Notification.create_notification(%{
          type: "reply_to_article",
          user_id: user.id,
          actor_user_id: other.id,
          article_id: article.id,
          comment_id: last.id
        })

      {:ok, lv, _html} = live(conn, "/notifications")

      assert has_element?(
               lv,
               ~s|.notification-target[href="/articles/#{article.slug}?page=2#comment-#{last.id}"]|
             )
    end
  end

  describe "admin announcement" do
    test "shows announcement message in notification", %{conn: conn, user: user} do
      admin = setup_user("admin")
      conn = log_in_user(conn, user)

      Notification.create_admin_announcement(admin, "System maintenance tonight")

      {:ok, _lv, html} = live(conn, "/notifications")

      assert html =~ "posted an announcement"
      assert html =~ "System maintenance tonight"
    end
  end

  defp create_board(slug) do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "guest"))

    {:ok, board} =
      Baudrate.Content.create_board(%{
        name: slug,
        slug: slug,
        description: "Test board",
        min_role_to_view_id: role.id,
        min_role_to_post_id: role.id
      })

    board
  end
end
