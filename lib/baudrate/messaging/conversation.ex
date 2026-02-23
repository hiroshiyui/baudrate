defmodule Baudrate.Messaging.Conversation do
  @moduledoc """
  Schema for 1-on-1 conversations between two participants.

  Participants can be local users or remote actors (via ActivityPub federation).
  The canonical ordering is: the participant with the lower user ID is `user_a`,
  the other is `user_b`. For local-remote conversations, the local user is
  always `user_a` and the remote actor is `remote_actor_b`.

  ## Fields

    * `user_a_id` / `user_b_id` — local user participants (nullable)
    * `remote_actor_a_id` / `remote_actor_b_id` — remote actor participants (nullable)
    * `ap_context` — ActivityPub conversation threading URI (Mastodon compat)
    * `last_message_at` — denormalized timestamp of most recent message for sorting
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Federation.RemoteActor
  alias Baudrate.Messaging.DirectMessage
  alias Baudrate.Setup.User

  schema "conversations" do
    field :ap_context, :string
    field :last_message_at, :utc_datetime

    belongs_to :user_a, User
    belongs_to :remote_actor_a, RemoteActor
    belongs_to :user_b, User
    belongs_to :remote_actor_b, RemoteActor

    has_many :messages, DirectMessage

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a local-local conversation."
  def local_changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:user_a_id, :user_b_id, :ap_context, :last_message_at])
    |> validate_required([:user_a_id, :user_b_id])
    |> foreign_key_constraint(:user_a_id)
    |> foreign_key_constraint(:user_b_id)
    |> unique_constraint([:user_a_id, :user_b_id], name: :conversations_local_pair_index)
    |> check_constraint(:user_a_id, name: :conversations_two_participants)
  end

  @doc "Changeset for creating a local-remote conversation."
  def remote_changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:user_a_id, :remote_actor_b_id, :ap_context, :last_message_at])
    |> validate_required([:user_a_id, :remote_actor_b_id])
    |> foreign_key_constraint(:user_a_id)
    |> foreign_key_constraint(:remote_actor_b_id)
    |> unique_constraint([:user_a_id, :remote_actor_b_id],
      name: :conversations_local_remote_pair_index
    )
    |> check_constraint(:user_a_id, name: :conversations_two_participants)
  end
end
