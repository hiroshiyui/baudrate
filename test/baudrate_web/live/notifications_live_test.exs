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
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/notifications")
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
