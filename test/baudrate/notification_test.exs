defmodule Baudrate.NotificationTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Auth
  alias Baudrate.Notification
  alias Baudrate.Notification.Notification, as: NotificationSchema
  alias Baudrate.Notification.PubSub
  alias Baudrate.Federation.{KeyStore, RemoteActor}

  setup do
    Baudrate.Setup.seed_roles_and_permissions()

    user = create_user("notif_recipient")
    actor = create_user("notif_actor")

    %{user: user, actor: actor}
  end

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

  describe "create_notification/1" do
    test "creates a notification and broadcasts", %{user: user, actor: actor} do
      PubSub.subscribe_user(user.id)

      assert {:ok, %NotificationSchema{} = notif} =
               Notification.create_notification(%{
                 type: "reply_to_article",
                 user_id: user.id,
                 actor_user_id: actor.id
               })

      assert notif.type == "reply_to_article"
      assert notif.user_id == user.id
      assert notif.actor_user_id == actor.id
      assert notif.read == false
      assert notif.data == %{}

      notif_id = notif.id
      assert_receive {:notification_created, %{notification_id: ^notif_id}}
    end

    test "stores custom data", %{user: user, actor: actor} do
      assert {:ok, %NotificationSchema{} = notif} =
               Notification.create_notification(%{
                 type: "mention",
                 user_id: user.id,
                 actor_user_id: actor.id,
                 data: %{"excerpt" => "Hello @user!"}
               })

      assert notif.data == %{"excerpt" => "Hello @user!"}
    end

    test "rejects self-notification", %{user: user} do
      assert {:ok, :skipped} =
               Notification.create_notification(%{
                 type: "reply_to_article",
                 user_id: user.id,
                 actor_user_id: user.id
               })
    end

    test "skips when recipient has blocked actor", %{user: user, actor: actor} do
      {:ok, _block} = Auth.block_user(user, actor)

      assert {:ok, :skipped} =
               Notification.create_notification(%{
                 type: "reply_to_article",
                 user_id: user.id,
                 actor_user_id: actor.id
               })
    end

    test "skips when recipient has muted actor", %{user: user, actor: actor} do
      {:ok, _mute} = Auth.mute_user(user, actor)

      assert {:ok, :skipped} =
               Notification.create_notification(%{
                 type: "reply_to_article",
                 user_id: user.id,
                 actor_user_id: actor.id
               })
    end

    test "returns duplicate on dedup constraint violation", %{user: user, actor: actor} do
      attrs = %{
        type: "article_liked",
        user_id: user.id,
        actor_user_id: actor.id
      }

      assert {:ok, %NotificationSchema{}} = Notification.create_notification(attrs)
      assert {:ok, :duplicate} = Notification.create_notification(attrs)
    end

    test "allows same type from different actors", %{user: user, actor: actor} do
      actor2 = create_user("notif_actor2")

      assert {:ok, %NotificationSchema{}} =
               Notification.create_notification(%{
                 type: "article_liked",
                 user_id: user.id,
                 actor_user_id: actor.id
               })

      assert {:ok, %NotificationSchema{}} =
               Notification.create_notification(%{
                 type: "article_liked",
                 user_id: user.id,
                 actor_user_id: actor2.id
               })
    end

    test "creates notification from remote actor", %{user: user} do
      remote = create_remote_actor()

      assert {:ok, %NotificationSchema{} = notif} =
               Notification.create_notification(%{
                 type: "new_follower",
                 user_id: user.id,
                 actor_remote_actor_id: remote.id
               })

      assert notif.actor_remote_actor_id == remote.id
    end

    test "skips when recipient has blocked remote actor", %{user: user} do
      remote = create_remote_actor()
      {:ok, _} = Auth.block_remote_actor(user, remote.ap_id)

      assert {:ok, :skipped} =
               Notification.create_notification(%{
                 type: "new_follower",
                 user_id: user.id,
                 actor_remote_actor_id: remote.id
               })
    end

    test "skips when recipient has muted remote actor", %{user: user} do
      remote = create_remote_actor()
      {:ok, _} = Auth.mute_remote_actor(user, remote.ap_id)

      assert {:ok, :skipped} =
               Notification.create_notification(%{
                 type: "new_follower",
                 user_id: user.id,
                 actor_remote_actor_id: remote.id
               })
    end

    test "rejects invalid type", %{user: user, actor: actor} do
      assert {:error, changeset} =
               Notification.create_notification(%{
                 type: "invalid_type",
                 user_id: user.id,
                 actor_user_id: actor.id
               })

      assert errors_on(changeset).type
    end

    test "requires type and user_id" do
      assert {:error, changeset} = Notification.create_notification(%{})

      errors = errors_on(changeset)
      assert errors.type
      assert errors.user_id
    end

    test "allows notification without actor (e.g., system)", %{user: user} do
      assert {:ok, %NotificationSchema{}} =
               Notification.create_notification(%{
                 type: "admin_announcement",
                 user_id: user.id,
                 data: %{"message" => "System maintenance"}
               })
    end
  end

  describe "unread_count/1" do
    test "returns count of unread notifications", %{user: user, actor: actor} do
      assert Notification.unread_count(user.id) == 0

      {:ok, _} =
        Notification.create_notification(%{
          type: "reply_to_article",
          user_id: user.id,
          actor_user_id: actor.id
        })

      assert Notification.unread_count(user.id) == 1
    end

    test "does not count read notifications", %{user: user, actor: actor} do
      {:ok, notif} =
        Notification.create_notification(%{
          type: "reply_to_article",
          user_id: user.id,
          actor_user_id: actor.id
        })

      Notification.mark_as_read(notif)

      assert Notification.unread_count(user.id) == 0
    end
  end

  describe "list_notifications/2" do
    test "lists notifications for a user", %{user: user, actor: actor} do
      {:ok, _} =
        Notification.create_notification(%{
          type: "reply_to_article",
          user_id: user.id,
          actor_user_id: actor.id
        })

      result = Notification.list_notifications(user.id)

      assert length(result.notifications) == 1
      assert result.page == 1
      assert result.total_pages == 1
    end

    test "orders newest first", %{user: user} do
      actor2 = create_user("notif_lister")

      {:ok, first} =
        Notification.create_notification(%{
          type: "reply_to_article",
          user_id: user.id,
          actor_user_id: actor2.id
        })

      actor3 = create_user("notif_lister2")

      {:ok, second} =
        Notification.create_notification(%{
          type: "mention",
          user_id: user.id,
          actor_user_id: actor3.id
        })

      result = Notification.list_notifications(user.id)
      ids = Enum.map(result.notifications, & &1.id)

      assert ids == [second.id, first.id]
    end

    test "paginates results", %{user: user} do
      for i <- 1..3 do
        a = create_user("pager_#{i}")

        Notification.create_notification(%{
          type: "article_liked",
          user_id: user.id,
          actor_user_id: a.id
        })
      end

      result = Notification.list_notifications(user.id, per_page: 2, page: 1)
      assert length(result.notifications) == 2
      assert result.total_pages == 2

      result2 = Notification.list_notifications(user.id, per_page: 2, page: 2)
      assert length(result2.notifications) == 1
    end

    test "caps per_page at 100", %{user: user} do
      for i <- 1..3 do
        a = create_user("cap_#{i}")

        Notification.create_notification(%{
          type: "article_liked",
          user_id: user.id,
          actor_user_id: a.id
        })
      end

      result = Notification.list_notifications(user.id, per_page: 999_999)
      assert length(result.notifications) == 3
      assert result.total_pages == 1
    end

    test "does not return other users' notifications", %{user: user, actor: actor} do
      other_user = create_user("other_recipient")

      {:ok, _} =
        Notification.create_notification(%{
          type: "mention",
          user_id: other_user.id,
          actor_user_id: actor.id
        })

      result = Notification.list_notifications(user.id)
      assert result.notifications == []
    end
  end

  describe "mark_as_read/1" do
    test "marks a notification as read and broadcasts", %{user: user, actor: actor} do
      {:ok, notif} =
        Notification.create_notification(%{
          type: "reply_to_article",
          user_id: user.id,
          actor_user_id: actor.id
        })

      PubSub.subscribe_user(user.id)

      assert {:ok, updated} = Notification.mark_as_read(notif)
      assert updated.read == true

      notif_id = notif.id
      assert_receive {:notification_read, %{notification_id: ^notif_id}}
    end
  end

  describe "mark_all_as_read/1" do
    test "marks all unread notifications as read", %{user: user} do
      for i <- 1..3 do
        a = create_user("bulk_#{i}")

        Notification.create_notification(%{
          type: "article_liked",
          user_id: user.id,
          actor_user_id: a.id
        })
      end

      assert Notification.unread_count(user.id) == 3

      PubSub.subscribe_user(user.id)

      assert {3, nil} = Notification.mark_all_as_read(user.id)
      assert Notification.unread_count(user.id) == 0

      user_id = user.id
      assert_receive {:notifications_all_read, %{user_id: ^user_id}}
    end

    test "does not broadcast when no notifications to mark", %{user: user} do
      PubSub.subscribe_user(user.id)

      assert {0, nil} = Notification.mark_all_as_read(user.id)

      refute_receive {:notifications_all_read, _}
    end
  end

  describe "cleanup_old_notifications/1" do
    test "deletes notifications older than specified days", %{user: user, actor: actor} do
      {:ok, notif} =
        Notification.create_notification(%{
          type: "reply_to_article",
          user_id: user.id,
          actor_user_id: actor.id
        })

      # Manually backdate the notification
      old_time =
        DateTime.utc_now()
        |> DateTime.add(-100, :day)
        |> DateTime.truncate(:second)

      Repo.update_all(
        from(n in NotificationSchema, where: n.id == ^notif.id),
        set: [inserted_at: old_time]
      )

      assert {1, nil} = Notification.cleanup_old_notifications(90)
      assert Notification.get_notification(notif.id) == nil
    end

    test "keeps recent notifications", %{user: user, actor: actor} do
      {:ok, notif} =
        Notification.create_notification(%{
          type: "reply_to_article",
          user_id: user.id,
          actor_user_id: actor.id
        })

      assert {0, nil} = Notification.cleanup_old_notifications(90)
      assert Notification.get_notification(notif.id) != nil
    end
  end

  describe "create_admin_announcement/2" do
    test "creates notifications for all users", %{user: user, actor: _actor} do
      admin = create_admin()

      results = Notification.create_admin_announcement(admin, "Server maintenance tonight")

      # Should create for user, actor, and admin (3 users total)
      ok_results = Enum.filter(results, &match?({:ok, %NotificationSchema{}}, &1))
      skipped = Enum.filter(results, &match?({:ok, :skipped}, &1))

      # Admin's own announcement is self-notification → skipped
      assert length(ok_results) == 2
      assert length(skipped) == 1

      # Verify user received it
      target_user_id = user.id

      user_notif_id =
        Enum.find_value(ok_results, fn
          {:ok, %NotificationSchema{user_id: ^target_user_id} = n} -> n.id
          _ -> nil
        end)

      user_notif = Notification.get_notification(user_notif_id)

      assert user_notif.type == "admin_announcement"
      assert user_notif.data == %{"message" => "Server maintenance tonight"}
    end
  end

  describe "get_notification/1 and get_notification!/1" do
    test "returns notification with preloads", %{user: user, actor: actor} do
      {:ok, notif} =
        Notification.create_notification(%{
          type: "mention",
          user_id: user.id,
          actor_user_id: actor.id
        })

      fetched = Notification.get_notification(notif.id)

      assert fetched.id == notif.id
      assert fetched.actor_user.id == actor.id
    end

    test "returns nil for missing notification" do
      assert Notification.get_notification(-1) == nil
    end

    test "raises for missing notification with bang" do
      assert_raise Ecto.NoResultsError, fn ->
        Notification.get_notification!(-1)
      end
    end
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
end
