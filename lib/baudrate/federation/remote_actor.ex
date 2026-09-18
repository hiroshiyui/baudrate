defmodule Baudrate.Federation.RemoteActor do
  @moduledoc """
  Schema for cached remote ActivityPub actors.

  Stores actor profile data fetched from remote instances, including
  the public key needed for HTTP Signature verification. Actor data
  is refreshed when `fetched_at` exceeds the configured TTL.

  The `summary` field stores the sanitized HTML bio/about text from
  the remote actor's ActivityPub `summary` property.

  The `url` field stores the human-readable profile URL from the actor's
  `url` property (e.g. `https://mastodon.social/@user`), distinct from
  `ap_id` which is the canonical ActivityPub identifier.

  The `profile_fields` field stores the `attachment` entries of type
  `PropertyValue` from the remote actor's AP representation. Each entry is a
  map with `"name"` and `"value"` keys. Values are sanitized HTML (run through
  `Baudrate.Federation.Sanitizer.sanitize/1` on ingest).

  The `also_known_as` field stores the actor's `alsoKnownAs` URIs (aliases).
  It is used to authorize inbound `Move` activities: a target actor must claim
  the moving actor as an alias before its local followers are migrated.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "remote_actors" do
    field :ap_id, :string
    field :username, :string
    field :domain, :string
    field :display_name, :string
    field :avatar_url, :string
    field :summary, :string
    field :public_key_pem, :string
    field :inbox, :string
    field :shared_inbox, :string
    field :url, :string
    field :actor_type, :string, default: "Person"
    field :fetched_at, :utc_datetime
    field :profile_fields, {:array, :map}, default: []
    field :also_known_as, {:array, :string}, default: []
    # Where this actor moved: its `movedTo`, or the target of the last Move
    # processed from it. `moved_at` is set only when a Move is processed and
    # bounds how often one is (ADR 0025).
    field :moved_to_ap_id, :string
    field :moved_at, :utc_datetime

    # Instance-wide suspension of this one actor (ADR 0030). Like a domain
    # block, it hides the actor's content at query time and is lifted by
    # clearing the stamp — nothing is deleted.
    field :suspended_at, :utc_datetime
    field :suspend_reason, :string
    belongs_to :suspended_by, Baudrate.Setup.User

    has_many :followers, Baudrate.Federation.Follower

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(ap_id username domain public_key_pem inbox actor_type fetched_at)a
  @optional_fields ~w(display_name avatar_url summary shared_inbox url profile_fields also_known_as moved_to_ap_id)a

  @doc """
  Casts and validates fields for creating or updating a remote actor cache entry.

  `domain` is downcased on the way in. It is written from the host of the
  actor's `ap_id`, which carries whatever case the peer used, and the domain
  block filter compares it with SQL equality — an actor stored as `Example.COM`
  would otherwise stay visible under a block on `example.com` (ADR 0030).
  """
  def changeset(remote_actor, attrs) do
    remote_actor
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> update_change(:domain, &downcase_domain/1)
    |> validate_required(@required_fields)
    |> validate_inclusion(:actor_type, ~w(Person Group Organization Application Service))
    |> validate_format(:moved_to_ap_id, ~r{\Ahttps://})
    |> validate_length(:moved_to_ap_id, max: 2048)
    |> validate_length(:inbox, max: 2048)
    |> validate_length(:shared_inbox, max: 2048)
    |> validate_length(:url, max: 2048)
    |> validate_length(:avatar_url, max: 2048)
    |> unique_constraint(:ap_id)
    |> unique_constraint([:username, :domain])
  end

  @doc """
  Suspends or lifts the suspension of this actor instance-wide (ADR 0030).

  Kept apart from `changeset/2` so an actor refresh — which rewrites every
  profile field from what the peer sends — can never clear a moderation
  decision.
  """
  def suspension_changeset(remote_actor, attrs) do
    remote_actor
    |> cast(attrs, [:suspended_at, :suspend_reason, :suspended_by_id])
    |> validate_length(:suspend_reason, max: 1000)
  end

  # `validate_required/2` is what refuses a missing domain; this only has to
  # survive being handed one.
  defp downcase_domain(domain) when is_binary(domain), do: String.downcase(domain)
  defp downcase_domain(domain), do: domain
end
