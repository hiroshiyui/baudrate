defmodule Baudrate.Federation.UserFollow do
  @moduledoc """
  Schema for tracking outbound follow relationships from local users
  to remote ActivityPub actors.

  Records that a local user has sent a `Follow` activity to a remote actor.
  The `state` field tracks the lifecycle: `pending` → `accepted` / `rejected`.

  The `ap_id` stores the outgoing Follow activity's AP ID, used for matching
  incoming `Accept(Follow)` and `Reject(Follow)` responses, and for building
  `Undo(Follow)` activities.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Federation.RemoteActor
  alias Baudrate.Setup.User

  schema "user_follows" do
    belongs_to :user, User
    belongs_to :remote_actor, RemoteActor

    field :state, :string, default: "pending"
    field :ap_id, :string
    field :accepted_at, :utc_datetime
    field :rejected_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(user_id remote_actor_id state ap_id)a
  @optional_fields ~w(accepted_at rejected_at)a

  @doc "Casts and validates fields for creating or updating a user follow record."
  def changeset(user_follow, attrs) do
    user_follow
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:state, ~w(pending accepted rejected))
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:remote_actor_id)
    |> unique_constraint([:user_id, :remote_actor_id])
    |> unique_constraint(:ap_id)
  end
end
