defmodule Baudrate.Federation.Announce do
  @moduledoc """
  Schema for tracking remote Announce (boost/share) activities.

  Records that a remote actor has boosted a target object. This is a
  federation-only concept — local boosts would use a separate mechanism.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Federation.RemoteActor

  schema "announces" do
    field :ap_id, :string
    field :target_ap_id, :string
    field :activity_id, :string

    belongs_to :remote_actor, RemoteActor

    timestamps(type: :utc_datetime)
  end

  @doc "Casts and validates fields for creating an announce record."
  def changeset(announce, attrs) do
    announce
    |> cast(attrs, [:ap_id, :target_ap_id, :activity_id, :remote_actor_id])
    |> validate_required([:ap_id, :target_ap_id, :activity_id, :remote_actor_id])
    |> foreign_key_constraint(:remote_actor_id)
    |> unique_constraint(:ap_id)
    |> unique_constraint([:target_ap_id, :remote_actor_id])
  end
end
