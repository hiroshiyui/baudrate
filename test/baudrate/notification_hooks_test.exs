defmodule Baudrate.Notification.HooksTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Notification.Hooks
  alias Baudrate.Notification.Notification, as: NotificationSchema
  alias Baudrate.Content.{Article, Board, BoardArticle, Comment}
  alias Baudrate.Federation.{KeyStore, RemoteActor}

  setup do
    Baudrate.Setup.seed_roles_and_permissions()

    user = create_user("hooks_user")
    actor = create_user("hooks_actor")
    board = create_board("hooks-board")
    article = create_article(board, user, "Test article body")

    %{user: user, actor: actor, board: board, article: article}
  end

  describe "notify_comment_created/1" do
    test "sends reply_to_article to article author", %{article: article, actor: actor} do
      comment = create_comment(article, actor, "A reply")

      Hooks.notify_comment_created(comment)

      assert [notif] = list_notifications_for(article.user_id, "reply_to_article")
      assert notif.actor_user_id == actor.id
      assert notif.article_id == article.id
      assert notif.comment_id == comment.id
    end

    test "sends reply_to_comment to parent comment author", %{
      article: article,
      user: user,
      actor: actor
    } do
      parent = create_comment(article, user, "Parent comment")
      reply = create_comment(article, actor, "Reply to parent", parent.id)

      Hooks.notify_comment_created(reply)

      assert [notif] = list_notifications_for(user.id, "reply_to_comment")
      assert notif.actor_user_id == actor.id
      assert notif.comment_id == reply.id
    end

    test "sends mention notifications to @mentioned users", %{article: article, actor: actor} do
      mentioned = create_user("mentioned_user")
      comment = create_comment(article, actor, "Hey @#{mentioned.username} check this")

      Hooks.notify_comment_created(comment)

      assert [notif] = list_notifications_for(mentioned.id, "mention")
      assert notif.actor_user_id == actor.id
      assert notif.article_id == article.id
    end

    test "skips self-notification for article author commenting on own article", %{
      article: article,
      user: user
    } do
      comment = create_comment(article, user, "My own comment")

      Hooks.notify_comment_created(comment)

      assert [] == list_notifications_for(user.id, "reply_to_article")
    end
  end

  describe "notify_article_created/1" do
    test "sends mention notifications for @mentioned users", %{board: board, actor: actor} do
      mentioned = create_user("article_mentioned")
      article = create_article(board, actor, "Hello @#{mentioned.username}")

      Hooks.notify_article_created(article)

      assert [notif] = list_notifications_for(mentioned.id, "mention")
      assert notif.actor_user_id == actor.id
      assert notif.article_id == article.id
    end

    test "no notification when no mentions", %{board: board, actor: actor} do
      article = create_article(board, actor, "No mentions here")

      Hooks.notify_article_created(article)

      assert [] ==
               Repo.all(
                 from(n in NotificationSchema,
                   where: n.type == "mention"
                 )
               )
    end
  end

  describe "notify_local_article_liked/2" do
    test "sends article_liked to article author", %{article: article, actor: actor} do
      Hooks.notify_local_article_liked(article.id, actor.id)

      assert [notif] = list_notifications_for(article.user_id, "article_liked")
      assert notif.actor_user_id == actor.id
      assert notif.article_id == article.id
    end

    test "skips self-like (no notification when liker is author)", %{article: article, user: user} do
      Hooks.notify_local_article_liked(article.id, user.id)

      assert [] == list_notifications_for(user.id, "article_liked")
    end
  end

  describe "notify_local_comment_liked/2" do
    test "sends comment_liked to comment author", %{article: article, actor: actor, user: user} do
      comment = create_comment(article, user, "A comment to like")

      Hooks.notify_local_comment_liked(comment.id, actor.id)

      assert [notif] = list_notifications_for(user.id, "comment_liked")
      assert notif.actor_user_id == actor.id
      assert notif.comment_id == comment.id
      assert notif.article_id == article.id
    end

    test "skips self-like (no notification when liker is author)", %{article: article, user: user} do
      comment = create_comment(article, user, "My own comment")

      Hooks.notify_local_comment_liked(comment.id, user.id)

      assert [] == list_notifications_for(user.id, "comment_liked")
    end
  end

  describe "notify_remote_article_liked/2" do
    test "sends article_liked to article author", %{article: article} do
      remote = create_remote_actor()

      Hooks.notify_remote_article_liked(article.id, remote.id)

      assert [notif] = list_notifications_for(article.user_id, "article_liked")
      assert notif.actor_remote_actor_id == remote.id
      assert notif.article_id == article.id
    end
  end

  describe "notify_article_forwarded/2" do
    test "sends article_forwarded to article author", %{article: article, actor: actor} do
      Hooks.notify_article_forwarded(article, actor.id)

      assert [notif] = list_notifications_for(article.user_id, "article_forwarded")
      assert notif.actor_user_id == actor.id
      assert notif.article_id == article.id
    end
  end

  describe "notify_local_follow/2" do
    test "sends new_follower notification", %{user: user, actor: actor} do
      Hooks.notify_local_follow(actor.id, user.id)

      assert [notif] = list_notifications_for(user.id, "new_follower")
      assert notif.actor_user_id == actor.id
    end
  end

  describe "notify_remote_follow/2" do
    test "sends new_follower with remote actor", %{user: user} do
      remote = create_remote_actor()

      Hooks.notify_remote_follow(user.id, remote.id)

      assert [notif] = list_notifications_for(user.id, "new_follower")
      assert notif.actor_remote_actor_id == remote.id
    end
  end

  describe "notify_remote_comment_created/3" do
    test "sends reply_to_article to article author", %{article: article} do
      remote = create_remote_actor()

      Hooks.notify_remote_comment_created(article.id, nil, remote.id)

      assert [notif] = list_notifications_for(article.user_id, "reply_to_article")
      assert notif.actor_remote_actor_id == remote.id
      assert notif.article_id == article.id
    end

    test "sends reply_to_comment to parent author when parent_id given", %{
      article: article,
      user: user
    } do
      remote = create_remote_actor()
      parent = create_comment(article, user, "Parent")

      Hooks.notify_remote_comment_created(article.id, parent.id, remote.id)

      assert [notif] = list_notifications_for(user.id, "reply_to_comment")
      assert notif.actor_remote_actor_id == remote.id
    end
  end

  describe "notify_report_created/1" do
    test "sends moderation_report to all admins" do
      admin = create_admin()
      admin2 = create_admin()

      Hooks.notify_report_created(999)

      assert [_] = list_notifications_for(admin.id, "moderation_report")
      assert [_] = list_notifications_for(admin2.id, "moderation_report")
    end

    test "includes report_id in data" do
      admin = create_admin()

      Hooks.notify_report_created(42)

      [notif] = list_notifications_for(admin.id, "moderation_report")
      assert notif.data == %{"report_id" => 42}
    end
  end

  # --- Test helpers ---

  defp create_user(prefix) do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))
    uid = System.unique_integer([:positive])

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "#{prefix}_#{uid}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    user
  end

  defp create_admin do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "admin"))
    uid = System.unique_integer([:positive])

    {:ok, admin} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "admin_#{uid}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    admin
  end

  defp create_remote_actor do
    uid = System.unique_integer([:positive])

    {:ok, actor} =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/actor-#{uid}",
        username: "actor_#{uid}",
        domain: "remote.example",
        public_key_pem: elem(KeyStore.generate_keypair(), 0),
        inbox: "https://remote.example/users/actor-#{uid}/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    actor
  end

  defp create_board(slug) do
    {:ok, board} =
      %Board{}
      |> Board.changeset(%{
        name: "Test Board #{slug}",
        slug: slug,
        description: "A test board",
        position: 0,
        ap_enabled: false
      })
      |> Repo.insert()

    board
  end

  defp create_article(board, user, body) do
    uid = System.unique_integer([:positive])

    {:ok, article} =
      %Article{}
      |> Article.changeset(%{
        title: "Test Article #{uid}",
        body: body,
        slug: "test-article-#{uid}",
        user_id: user.id
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

  defp create_comment(article, user, body, parent_id \\ nil) do
    body_html = Baudrate.Content.Markdown.to_html(body)

    {:ok, comment} =
      %Comment{}
      |> Comment.changeset(%{
        "body" => body,
        "body_html" => body_html,
        "article_id" => article.id,
        "user_id" => user.id,
        "parent_id" => parent_id
      })
      |> Repo.insert()

    comment
  end

  defp list_notifications_for(user_id, type) do
    Repo.all(
      from(n in NotificationSchema,
        where: n.user_id == ^user_id and n.type == ^type,
        order_by: [desc: n.inserted_at]
      )
    )
  end
end
