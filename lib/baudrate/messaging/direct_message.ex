defmodule Baudrate.Messaging.DirectMessage do
  @moduledoc """
  Schema for direct messages within a conversation.

  Each message belongs to exactly one conversation and has exactly one sender
  (either a local user or a remote actor, enforced by a check constraint).

  ## Fields

    * `body` — plain text message content (max 64 KB)
    * `body_html` — HTML-rendered version of the body
    * `sender_user_id` — local user sender (nullable)
    * `sender_remote_actor_id` — remote actor sender (nullable)
    * `ap_id` — ActivityPub object ID (unique, for federation idempotency)
    * `ap_in_reply_to` — AP `inReplyTo` URI for threading
    * `deleted_at` — soft-delete timestamp
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Federation.RemoteActor
  alias Baudrate.Messaging.Conversation
  alias Baudrate.Setup.User

  @max_body_length 65_536

  schema "direct_messages" do
    field :body, :string
    field :body_html, :string
    field :ap_id, :string
    field :ap_in_reply_to, :string
    field :deleted_at, :utc_datetime

    belongs_to :conversation, Conversation
    belongs_to :sender_user, User
    belongs_to :sender_remote_actor, RemoteActor

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a local user message."
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body, :body_html, :conversation_id, :sender_user_id, :ap_in_reply_to])
    |> validate_required([:body, :conversation_id, :sender_user_id])
    |> validate_length(:body, max: @max_body_length)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:sender_user_id)
    |> check_constraint(:sender_user_id, name: :direct_messages_one_sender)
  end

  @doc "Changeset for creating a remote actor message (via federation)."
  def remote_changeset(message, attrs) do
    message
    |> cast(attrs, [
      :body,
      :body_html,
      :conversation_id,
      :sender_remote_actor_id,
      :ap_id,
      :ap_in_reply_to
    ])
    |> validate_required([:body, :conversation_id, :sender_remote_actor_id])
    |> validate_length(:body, max: @max_body_length)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:sender_remote_actor_id)
    |> unique_constraint(:ap_id)
    |> check_constraint(:sender_remote_actor_id, name: :direct_messages_one_sender)
  end

  @doc "Changeset for soft-deleting a message."
  def soft_delete_changeset(message) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    message
    |> change(deleted_at: now, body: "[deleted]", body_html: nil)
  end
end
