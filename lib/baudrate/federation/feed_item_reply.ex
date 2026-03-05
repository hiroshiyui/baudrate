defmodule Baudrate.Federation.FeedItemReply do
  @moduledoc """
  Schema for replies from local users to remote feed items.

  When a user replies to a post from a followed Fediverse actor, the reply
  body (Markdown source + rendered HTML) is stored here alongside the
  generated ActivityPub ID. The corresponding `Create(Note)` activity is
  delivered to the remote actor's inbox and the replying user's AP followers.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.LinkPreview
  alias Baudrate.Federation.FeedItem
  alias Baudrate.Setup.User

  schema "feed_item_replies" do
    belongs_to :feed_item, FeedItem
    belongs_to :user, User
    belongs_to :link_preview, LinkPreview

    field :body, :string
    field :body_html, :string
    field :ap_id, :string

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(body feed_item_id user_id ap_id)a
  @optional_fields ~w(body_html)a

  @doc """
  Validates a feed item reply changeset.

  Required: `:body`, `:feed_item_id`, `:user_id`, `:ap_id`.
  Body max length: 10,000 characters.
  """
  def changeset(reply, attrs) do
    reply
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:body, max: 10_000)
    |> foreign_key_constraint(:feed_item_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:ap_id)
  end
end
