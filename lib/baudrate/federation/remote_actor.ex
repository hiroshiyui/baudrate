defmodule Baudrate.Federation.RemoteActor do
  @moduledoc """
  Schema for cached remote ActivityPub actors.

  Stores actor profile data fetched from remote instances, including
  the public key needed for HTTP Signature verification. Actor data
  is refreshed when `fetched_at` exceeds the configured TTL.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "remote_actors" do
    field :ap_id, :string
    field :username, :string
    field :domain, :string
    field :display_name, :string
    field :avatar_url, :string
    field :public_key_pem, :string
    field :inbox, :string
    field :shared_inbox, :string
    field :actor_type, :string, default: "Person"
    field :fetched_at, :utc_datetime

    has_many :followers, Baudrate.Federation.Follower

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(ap_id username domain public_key_pem inbox actor_type fetched_at)a
  @optional_fields ~w(display_name avatar_url shared_inbox)a

  @doc "Casts and validates fields for creating or updating a remote actor cache entry."
  def changeset(remote_actor, attrs) do
    remote_actor
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:actor_type, ~w(Person Group Organization Application Service))
    |> unique_constraint(:ap_id)
    |> unique_constraint([:username, :domain])
  end
end
