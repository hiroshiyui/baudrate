defmodule Baudrate.Federation.UserFollow do
  @moduledoc """
  Schema for tracking outbound follow relationships from local users
  to remote ActivityPub actors or other local users.

  Records that a local user has sent a `Follow` activity to a remote actor
  or follows a local user. The `state` field tracks the lifecycle:
  `pending` → `accepted` / `rejected`.

  Exactly one of `remote_actor_id` or `followed_user_id` must be set:
  - Remote follows: `remote_actor_id` is set, `followed_user_id` is nil
  - Local follows: `followed_user_id` is set, `remote_actor_id` is nil

  Local follows are auto-accepted immediately (state goes straight to
  `"accepted"`) with no AP delivery required.

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
    belongs_to :followed_user, User

    field :state, :string, default: "pending"
    field :ap_id, :string
    field :accepted_at, :utc_datetime
    field :rejected_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(user_id state ap_id)a
  @optional_fields ~w(remote_actor_id followed_user_id accepted_at rejected_at)a

  @doc "Casts and validates fields for creating or updating a user follow record."
  def changeset(user_follow, attrs) do
    user_follow
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:state, ~w(pending accepted rejected))
    |> validate_exactly_one_target()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:remote_actor_id)
    |> foreign_key_constraint(:followed_user_id)
    |> unique_constraint([:user_id, :remote_actor_id])
    |> unique_constraint([:user_id, :followed_user_id])
    |> unique_constraint(:ap_id)
    |> check_constraint(:remote_actor_id, name: :exactly_one_target)
  end

  defp validate_exactly_one_target(changeset) do
    remote = get_field(changeset, :remote_actor_id)
    local = get_field(changeset, :followed_user_id)

    cond do
      is_nil(remote) && is_nil(local) ->
        add_error(
          changeset,
          :remote_actor_id,
          "exactly one of remote_actor_id or followed_user_id must be set"
        )

      !is_nil(remote) && !is_nil(local) ->
        add_error(
          changeset,
          :remote_actor_id,
          "exactly one of remote_actor_id or followed_user_id must be set"
        )

      true ->
        changeset
    end
  end
end
