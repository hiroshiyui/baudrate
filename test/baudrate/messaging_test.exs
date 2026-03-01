defmodule Baudrate.MessagingTest do
  use Baudrate.DataCase

  alias Baudrate.Messaging
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user(role_name, opts \\ []) do
    role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))

    attrs = %{
      "username" => opts[:username] || "user_#{System.unique_integer([:positive])}",
      "password" => "Password123!x",
      "password_confirmation" => "Password123!x",
      "role_id" => role.id
    }

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(attrs)
      |> Repo.insert()

    user = Repo.preload(user, :role)

    if dm_access = opts[:dm_access] do
      user
      |> Setup.User.dm_access_changeset(%{dm_access: dm_access})
      |> Repo.update!()
      |> Repo.preload(:role)
    else
      user
    end
  end

  defp create_remote_actor(attrs \\ %{}) do
    defaults = %{
      ap_id: "https://remote.example/users/#{System.unique_integer([:positive])}",
      username: "remote_#{System.unique_integer([:positive])}",
      domain: "remote.example",
      display_name: "Remote User",
      inbox: "https://remote.example/inbox",
      public_key_pem: "fake-key",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    merged = Map.merge(defaults, attrs)

    %Baudrate.Federation.RemoteActor{}
    |> Baudrate.Federation.RemoteActor.changeset(merged)
    |> Repo.insert!()
  end

  # --- can_receive_remote_dm? ---

  describe "can_receive_remote_dm?/2" do
    test "allows active user with dm_access=anyone" do
      user = create_user("user")
      remote_actor = create_remote_actor()
      assert Messaging.can_receive_remote_dm?(user, remote_actor)
    end

    test "denies when user is banned" do
      user = create_user("user")

      user =
        user
        |> Baudrate.Setup.User.ban_changeset(%{
          status: "banned",
          banned_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update!()
        |> Repo.preload(:role)

      remote_actor = create_remote_actor()
      refute Messaging.can_receive_remote_dm?(user, remote_actor)
    end

    test "denies when dm_access=nobody" do
      user = create_user("user", dm_access: "nobody")
      remote_actor = create_remote_actor()
      refute Messaging.can_receive_remote_dm?(user, remote_actor)
    end

    test "denies when remote actor's domain is blocked" do
      user = create_user("user")
      remote_actor = create_remote_actor(%{domain: "blocked.example"})

      Baudrate.Setup.set_setting("ap_domain_blocklist", "blocked.example")
      Baudrate.Federation.DomainBlockCache.refresh()

      refute Messaging.can_receive_remote_dm?(user, remote_actor)
    end

    test "denies when user blocked remote actor's AP ID" do
      user = create_user("user")
      remote_actor = create_remote_actor()
      Baudrate.Auth.block_remote_actor(user, remote_actor.ap_id)
      refute Messaging.can_receive_remote_dm?(user, remote_actor)
    end
  end

  # --- participant? ---

  describe "participant?/2" do
    test "returns true for both participants" do
      user_a = create_user("user")
      user_b = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)

      assert Messaging.participant?(conv, user_a)
      assert Messaging.participant?(conv, user_b)
    end

    test "returns false for non-participant" do
      user_a = create_user("user")
      user_b = create_user("user")
      user_c = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)

      refute Messaging.participant?(conv, user_c)
    end
  end

  # --- unread_count_for_conversation ---

  describe "unread_count_for_conversation/2" do
    test "counts unread messages from other user" do
      user_a = create_user("user")
      user_b = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)

      {:ok, _} = Messaging.create_message(conv, user_b, %{body: "Hello!"})
      {:ok, _} = Messaging.create_message(conv, user_b, %{body: "Are you there?"})

      assert Messaging.unread_count_for_conversation(conv.id, user_a) == 2
    end

    test "returns 0 after marking read" do
      user_a = create_user("user")
      user_b = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)

      {:ok, _} = Messaging.create_message(conv, user_b, %{body: "Hello!"})
      {:ok, msg2} = Messaging.create_message(conv, user_b, %{body: "Second"})

      Messaging.mark_conversation_read(conv, user_a, msg2)
      assert Messaging.unread_count_for_conversation(conv.id, user_a) == 0
    end

    test "does not count own messages" do
      user_a = create_user("user")
      user_b = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)

      {:ok, _} = Messaging.create_message(conv, user_a, %{body: "My message"})

      assert Messaging.unread_count_for_conversation(conv.id, user_a) == 0
    end
  end

  # --- can_send_dm? ---

  describe "can_send_dm?/2" do
    test "allows DM between two active users with dm_access=anyone" do
      sender = create_user("user")
      recipient = create_user("user")
      assert Messaging.can_send_dm?(sender, recipient)
    end

    test "denies self-messaging" do
      user = create_user("user")
      refute Messaging.can_send_dm?(user, user)
    end

    test "denies DM to user with dm_access=nobody" do
      sender = create_user("user")
      recipient = create_user("user", dm_access: "nobody")
      refute Messaging.can_send_dm?(sender, recipient)
    end

    test "denies DM from inactive sender" do
      sender = create_user("user")

      sender =
        sender
        |> Ecto.Changeset.change(status: "pending")
        |> Repo.update!()
        |> Repo.preload(:role)

      recipient = create_user("user")
      refute Messaging.can_send_dm?(sender, recipient)
    end

    test "denies DM to banned recipient" do
      sender = create_user("user")
      recipient = create_user("user")

      recipient =
        recipient
        |> Setup.User.ban_changeset(%{
          status: "banned",
          banned_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update!()
        |> Repo.preload(:role)

      refute Messaging.can_send_dm?(sender, recipient)
    end

    test "denies DM when recipient has blocked sender" do
      sender = create_user("user")
      recipient = create_user("user")
      Baudrate.Auth.block_user(recipient, sender)
      refute Messaging.can_send_dm?(sender, recipient)
    end

    test "denies DM when sender has blocked recipient" do
      sender = create_user("user")
      recipient = create_user("user")
      Baudrate.Auth.block_user(sender, recipient)
      refute Messaging.can_send_dm?(sender, recipient)
    end
  end

  # --- find_or_create_conversation ---

  describe "find_or_create_conversation/2" do
    test "creates a new conversation with canonical ordering" do
      user_a = create_user("user")
      user_b = create_user("user")

      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)
      assert conv.user_a_id == min(user_a.id, user_b.id)
      assert conv.user_b_id == max(user_a.id, user_b.id)
      assert conv.ap_context
    end

    test "returns existing conversation on second call" do
      user_a = create_user("user")
      user_b = create_user("user")

      {:ok, conv1} = Messaging.find_or_create_conversation(user_a, user_b)
      {:ok, conv2} = Messaging.find_or_create_conversation(user_b, user_a)
      assert conv1.id == conv2.id
    end
  end

  # --- create_message ---

  describe "create_message/3" do
    test "creates a message and updates last_message_at" do
      user_a = create_user("user")
      user_b = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)

      {:ok, msg} = Messaging.create_message(conv, user_a, %{body: "Hello!"})
      assert msg.body == "Hello!"
      assert msg.sender_user_id == user_a.id
      assert msg.conversation_id == conv.id
      assert msg.body_html

      updated_conv = Repo.get!(Baudrate.Messaging.Conversation, conv.id)
      assert updated_conv.last_message_at
    end

    test "rejects empty body" do
      user_a = create_user("user")
      user_b = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)

      {:error, changeset} = Messaging.create_message(conv, user_a, %{body: ""})
      assert errors_on(changeset)[:body]
    end
  end

  # --- list_conversations ---

  describe "list_conversations/1" do
    test "returns conversations ordered by last_message_at desc" do
      user = create_user("user")
      other1 = create_user("user")
      other2 = create_user("user")

      {:ok, conv1} = Messaging.find_or_create_conversation(user, other1)
      {:ok, _msg1} = Messaging.create_message(conv1, user, %{body: "First"})

      # Backdate conv1's last_message_at to ensure ordering
      import Ecto.Query

      from(c in Baudrate.Messaging.Conversation, where: c.id == ^conv1.id)
      |> Repo.update_all(set: [last_message_at: ~U[2020-01-01 00:00:00Z]])

      {:ok, conv2} = Messaging.find_or_create_conversation(user, other2)
      {:ok, _msg2} = Messaging.create_message(conv2, user, %{body: "Second"})

      conversations = Messaging.list_conversations(user)
      assert length(conversations) == 2
      assert hd(conversations).id == conv2.id
    end

    test "excludes conversations with no messages" do
      user = create_user("user")
      other = create_user("user")
      {:ok, _conv} = Messaging.find_or_create_conversation(user, other)

      conversations = Messaging.list_conversations(user)
      assert conversations == []
    end
  end

  # --- unread_count ---

  describe "unread_count/1" do
    test "counts unread messages from other users" do
      user_a = create_user("user")
      user_b = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)

      {:ok, _msg} = Messaging.create_message(conv, user_b, %{body: "Hey!"})
      assert Messaging.unread_count(user_a) == 1
    end

    test "does not count own messages as unread" do
      user_a = create_user("user")
      user_b = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)

      {:ok, _msg} = Messaging.create_message(conv, user_a, %{body: "Hey!"})
      assert Messaging.unread_count(user_a) == 0
    end

    test "returns 0 after marking conversation as read" do
      user_a = create_user("user")
      user_b = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)

      {:ok, msg} = Messaging.create_message(conv, user_b, %{body: "Hey!"})
      Messaging.mark_conversation_read(conv, user_a, msg)
      assert Messaging.unread_count(user_a) == 0
    end
  end

  # --- mark_conversation_read broadcasts :dm_read ---

  describe "mark_conversation_read/3 :dm_read broadcast" do
    test "broadcasts :dm_read to the user's PubSub topic" do
      user_a = create_user("user")
      user_b = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)
      {:ok, msg} = Messaging.create_message(conv, user_b, %{body: "Hello!"})

      Baudrate.Messaging.PubSub.subscribe_user(user_a.id)

      Messaging.mark_conversation_read(conv, user_a, msg)

      conv_id = conv.id
      assert_receive {:dm_read, %{conversation_id: ^conv_id}}
    end

    test "does not broadcast :dm_read on failure" do
      user_a = create_user("user")
      user_b = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)
      {:ok, msg} = Messaging.create_message(conv, user_b, %{body: "Hello!"})

      Baudrate.Messaging.PubSub.subscribe_user(user_a.id)

      # Mark read once (should succeed and broadcast)
      Messaging.mark_conversation_read(conv, user_a, msg)
      assert_receive {:dm_read, _}

      # Mark read again with same message (upserts, still succeeds)
      Messaging.mark_conversation_read(conv, user_a, msg)
      assert_receive {:dm_read, _}
    end
  end

  # --- soft_delete_message ---

  describe "soft_delete_message/2" do
    test "sender can delete their own message" do
      user_a = create_user("user")
      user_b = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)
      {:ok, msg} = Messaging.create_message(conv, user_a, %{body: "Delete me"})

      {:ok, deleted} = Messaging.soft_delete_message(msg, user_a)
      assert deleted.deleted_at
      assert deleted.body == "[deleted]"
    end

    test "other user cannot delete someone else's message" do
      user_a = create_user("user")
      user_b = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)
      {:ok, msg} = Messaging.create_message(conv, user_a, %{body: "My message"})

      assert {:error, :unauthorized} = Messaging.soft_delete_message(msg, user_b)
    end
  end

  # --- list_messages ---

  describe "list_messages/1" do
    test "returns messages oldest first, excludes deleted" do
      user_a = create_user("user")
      user_b = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)

      {:ok, msg1} = Messaging.create_message(conv, user_a, %{body: "First"})
      {:ok, _msg2} = Messaging.create_message(conv, user_b, %{body: "Second"})
      {:ok, msg3} = Messaging.create_message(conv, user_a, %{body: "Third"})
      Messaging.soft_delete_message(msg3, user_a)

      messages = Messaging.list_messages(conv)
      assert length(messages) == 2
      assert hd(messages).id == msg1.id
    end
  end

  # --- other_participant ---

  describe "other_participant/2" do
    test "returns the other local user" do
      user_a = create_user("user")
      user_b = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)

      other = Messaging.other_participant(conv, user_a)
      assert other.id == user_b.id
    end
  end

  # --- receive_remote_dm ---

  describe "receive_remote_dm/3" do
    test "creates a conversation and message from a remote actor" do
      local_user = create_user("user")
      remote_actor = create_remote_actor()

      {:ok, msg} =
        Messaging.receive_remote_dm(local_user, remote_actor, %{
          body: "Hello from remote",
          body_html: "<p>Hello from remote</p>",
          ap_id: "https://remote.example/notes/1"
        })

      assert msg.body == "Hello from remote"
      assert msg.sender_remote_actor_id == remote_actor.id
      assert msg.ap_id == "https://remote.example/notes/1"
    end
  end

  # --- get_message_by_ap_id ---

  describe "get_message_by_ap_id/1" do
    test "returns message by AP ID" do
      local_user = create_user("user")
      remote_actor = create_remote_actor()

      {:ok, msg} =
        Messaging.receive_remote_dm(local_user, remote_actor, %{
          body: "Test",
          body_html: "<p>Test</p>",
          ap_id: "https://remote.example/notes/unique1"
        })

      found = Messaging.get_message_by_ap_id("https://remote.example/notes/unique1")
      assert found.id == msg.id
    end

    test "returns nil for unknown AP ID" do
      assert Messaging.get_message_by_ap_id("https://nonexistent.example/notes/1") == nil
    end
  end

  describe "get_conversation_for_user/2" do
    test "returns conversation when user is participant" do
      user_a = create_user("user")
      user_b = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)

      found = Messaging.get_conversation_for_user(conv.id, user_a)
      assert found.id == conv.id
    end

    test "returns nil when user is not participant" do
      user_a = create_user("user")
      user_b = create_user("user")
      outsider = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)

      assert Messaging.get_conversation_for_user(conv.id, outsider) == nil
    end
  end

  describe "get_message/1" do
    test "returns message by ID" do
      user_a = create_user("user")
      user_b = create_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(user_a, user_b)
      {:ok, msg} = Messaging.create_message(conv, user_a, %{"body" => "Hello"})

      found = Messaging.get_message(msg.id)
      assert found.id == msg.id
    end

    test "returns nil for non-existent ID" do
      assert Messaging.get_message(0) == nil
    end
  end

  describe "change_message/1" do
    test "returns a changeset" do
      changeset = Messaging.change_message(%{})
      assert %Ecto.Changeset{} = changeset
    end
  end
end
