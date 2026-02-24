defmodule Baudrate.Messaging.ConversationReadCursorTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Messaging.ConversationReadCursor

  describe "changeset/2" do
    test "valid changeset with required fields" do
      changeset =
        ConversationReadCursor.changeset(%ConversationReadCursor{}, %{
          conversation_id: 1,
          user_id: 1,
          last_read_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = ConversationReadCursor.changeset(%ConversationReadCursor{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:conversation_id]
      assert errors[:user_id]
      assert errors[:last_read_at]
    end
  end
end
