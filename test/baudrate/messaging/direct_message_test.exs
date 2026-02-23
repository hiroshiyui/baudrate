defmodule Baudrate.Messaging.DirectMessageTest do
  use Baudrate.DataCase

  alias Baudrate.Messaging.DirectMessage

  describe "changeset/2" do
    test "valid changeset" do
      changeset =
        DirectMessage.changeset(%DirectMessage{}, %{
          body: "Hello",
          conversation_id: 1,
          sender_user_id: 1
        })

      assert changeset.valid?
    end

    test "requires body" do
      changeset =
        DirectMessage.changeset(%DirectMessage{}, %{
          conversation_id: 1,
          sender_user_id: 1
        })

      assert errors_on(changeset)[:body]
    end

    test "validates body length" do
      long_body = String.duplicate("x", 65_537)

      changeset =
        DirectMessage.changeset(%DirectMessage{}, %{
          body: long_body,
          conversation_id: 1,
          sender_user_id: 1
        })

      assert errors_on(changeset)[:body]
    end
  end

  describe "remote_changeset/2" do
    test "valid remote changeset" do
      changeset =
        DirectMessage.remote_changeset(%DirectMessage{}, %{
          body: "Hello remote",
          conversation_id: 1,
          sender_remote_actor_id: 1,
          ap_id: "https://example.com/notes/1"
        })

      assert changeset.valid?
    end

    test "requires sender_remote_actor_id" do
      changeset =
        DirectMessage.remote_changeset(%DirectMessage{}, %{
          body: "Hello",
          conversation_id: 1
        })

      assert errors_on(changeset)[:sender_remote_actor_id]
    end
  end

  describe "soft_delete_changeset/1" do
    test "sets deleted_at and replaces body" do
      msg = %DirectMessage{body: "Original", body_html: "<p>Original</p>"}
      changeset = DirectMessage.soft_delete_changeset(msg)

      changes = changeset.changes
      assert changes[:deleted_at]
      assert changes[:body] == "[deleted]"
      assert changes[:body_html] == nil
    end
  end
end
