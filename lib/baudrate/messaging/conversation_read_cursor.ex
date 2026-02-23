defmodule Baudrate.Messaging.ConversationReadCursor do
  @moduledoc """
  Schema for tracking per-user read position within a conversation.

  Each record represents the last message a user has read in a specific
  conversation. Used to compute unread message counts.

  ## Fields

    * `conversation_id` — the conversation being tracked
    * `user_id` — the user whose read position is tracked
    * `last_read_message_id` — the most recent message the user has read
    * `last_read_at` — when the read position was last updated
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Messaging.{Conversation, DirectMessage}
  alias Baudrate.Setup.User

  schema "conversation_read_cursors" do
    belongs_to :conversation, Conversation
    belongs_to :user, User
    belongs_to :last_read_message, DirectMessage

    field :last_read_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for upserting a read cursor."
  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, [:conversation_id, :user_id, :last_read_message_id, :last_read_at])
    |> validate_required([:conversation_id, :user_id, :last_read_at])
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:last_read_message_id)
    |> unique_constraint([:conversation_id, :user_id])
  end
end
