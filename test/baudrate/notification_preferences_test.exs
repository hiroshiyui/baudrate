defmodule Baudrate.NotificationPreferencesTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Auth
  alias Baudrate.Notification

  setup do
    Baudrate.Setup.seed_roles_and_permissions()

    user = create_user("pref_user")
    actor = create_user("pref_actor")

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

  describe "notification_preferences_changeset/2" do
    test "accepts valid notification types", %{user: user} do
      prefs = %{"mention" => %{"in_app" => false}, "new_follower" => %{"in_app" => true}}

      changeset =
        Baudrate.Setup.User.notification_preferences_changeset(user, %{
          notification_preferences: prefs
        })

      assert changeset.valid?
    end

    test "rejects unknown notification types", %{user: user} do
      prefs = %{"invalid_type" => %{"in_app" => false}}

      changeset =
        Baudrate.Setup.User.notification_preferences_changeset(user, %{
          notification_preferences: prefs
        })

      refute changeset.valid?
      assert errors_on(changeset).notification_preferences
    end
  end

  describe "update_notification_preferences/2" do
    test "persists preferences", %{user: user} do
      prefs = %{"mention" => %{"in_app" => false}}

      assert {:ok, updated} = Auth.update_notification_preferences(user, prefs)
      assert updated.notification_preferences == prefs
    end

    test "replaces existing preferences", %{user: user} do
      {:ok, user} =
        Auth.update_notification_preferences(user, %{
          "mention" => %{"in_app" => false}
        })

      {:ok, updated} =
        Auth.update_notification_preferences(user, %{
          "mention" => %{"in_app" => true},
          "new_follower" => %{"in_app" => false}
        })

      assert updated.notification_preferences == %{
               "mention" => %{"in_app" => true},
               "new_follower" => %{"in_app" => false}
             }
    end
  end

  describe "create_notification respects in_app preference" do
    test "skips notification when in_app is false for the type", %{user: user, actor: actor} do
      {:ok, _} =
        Auth.update_notification_preferences(user, %{
          "mention" => %{"in_app" => false}
        })

      assert {:ok, :skipped} =
               Notification.create_notification(%{
                 type: "mention",
                 user_id: user.id,
                 actor_user_id: actor.id
               })
    end

    test "creates notification when in_app is true for the type", %{user: user, actor: actor} do
      {:ok, _} =
        Auth.update_notification_preferences(user, %{
          "mention" => %{"in_app" => true}
        })

      assert {:ok, %Baudrate.Notification.Notification{}} =
               Notification.create_notification(%{
                 type: "mention",
                 user_id: user.id,
                 actor_user_id: actor.id
               })
    end

    test "creates notification when type has no preference set (default enabled)", %{
      user: user,
      actor: actor
    } do
      # No preferences set — should default to enabled
      assert {:ok, %Baudrate.Notification.Notification{}} =
               Notification.create_notification(%{
                 type: "reply_to_article",
                 user_id: user.id,
                 actor_user_id: actor.id
               })
    end

    test "only suppresses the disabled type, not others", %{user: user, actor: actor} do
      {:ok, _} =
        Auth.update_notification_preferences(user, %{
          "mention" => %{"in_app" => false}
        })

      # mention should be skipped
      assert {:ok, :skipped} =
               Notification.create_notification(%{
                 type: "mention",
                 user_id: user.id,
                 actor_user_id: actor.id
               })

      # reply_to_article should still work
      assert {:ok, %Baudrate.Notification.Notification{}} =
               Notification.create_notification(%{
                 type: "reply_to_article",
                 user_id: user.id,
                 actor_user_id: actor.id
               })
    end
  end
end
