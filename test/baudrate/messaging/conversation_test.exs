defmodule Baudrate.Messaging.ConversationTest do
  use Baudrate.DataCase

  alias Baudrate.Messaging.Conversation

  describe "local_changeset/2" do
    test "valid changeset with two users" do
      changeset =
        Conversation.local_changeset(%Conversation{}, %{
          user_a_id: 1,
          user_b_id: 2
        })

      assert changeset.valid?
    end

    test "requires user_a_id" do
      changeset =
        Conversation.local_changeset(%Conversation{}, %{
          user_b_id: 2
        })

      assert errors_on(changeset)[:user_a_id]
    end

    test "requires user_b_id" do
      changeset =
        Conversation.local_changeset(%Conversation{}, %{
          user_a_id: 1
        })

      assert errors_on(changeset)[:user_b_id]
    end
  end

  describe "remote_changeset/2" do
    test "valid changeset with local user and remote actor" do
      changeset =
        Conversation.remote_changeset(%Conversation{}, %{
          user_a_id: 1,
          remote_actor_b_id: 1
        })

      assert changeset.valid?
    end

    test "requires remote_actor_b_id" do
      changeset =
        Conversation.remote_changeset(%Conversation{}, %{
          user_a_id: 1
        })

      assert errors_on(changeset)[:remote_actor_b_id]
    end
  end
end
