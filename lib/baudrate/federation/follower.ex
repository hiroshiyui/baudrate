defmodule Baudrate.Federation.Follower do
  @moduledoc """
  Schema for tracking follow relationships from remote actors.

  Records that a remote actor (`follower_uri`) follows a local actor
  (`actor_uri`). The `activity_id` stores the original Follow activity's
  AP ID for Undo(Follow) matching.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Federation.RemoteActor

  schema "followers" do
    field :actor_uri, :string
    field :follower_uri, :string
    field :accepted_at, :utc_datetime
    field :activity_id, :string

    belongs_to :remote_actor, RemoteActor

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(actor_uri follower_uri remote_actor_id activity_id)a
  @optional_fields ~w(accepted_at)a

  @doc "Casts and validates fields for creating a follower record."
  def changeset(follower, attrs) do
    follower
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:remote_actor_id)
    |> unique_constraint([:actor_uri, :follower_uri])
  end
end
