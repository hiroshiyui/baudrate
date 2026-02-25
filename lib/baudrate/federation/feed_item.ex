defmodule Baudrate.Federation.FeedItem do
  @moduledoc """
  Schema for storing incoming posts from followed remote actors.

  Feed items capture `Create` activities that don't land in a local board,
  article comment thread, or DM conversation. They are keyed by `ap_id`
  (one row per activity) and visibility is determined at query time by
  JOINing with `user_follows`.

  Soft-delete uses `deleted_at` timestamp, consistent with articles and comments.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Federation.RemoteActor

  @max_body_length 65_536

  schema "feed_items" do
    belongs_to :remote_actor, RemoteActor

    field :activity_type, :string, default: "Create"
    field :object_type, :string, default: "Note"
    field :ap_id, :string
    field :title, :string
    field :body, :string
    field :body_html, :string
    field :source_url, :string
    field :published_at, :utc_datetime
    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(remote_actor_id activity_type object_type ap_id published_at)a
  @optional_fields ~w(title body body_html source_url deleted_at)a

  @doc """
  Builds a changeset for a feed item.
  """
  def changeset(feed_item, attrs) do
    feed_item
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:activity_type, ~w(Create))
    |> validate_inclusion(:object_type, ~w(Note Article Page))
    |> validate_length(:body, max: @max_body_length)
    |> foreign_key_constraint(:remote_actor_id)
    |> unique_constraint(:ap_id)
  end
end
