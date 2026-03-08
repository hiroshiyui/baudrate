defmodule Baudrate.Federation.FeedItemLike do
  @moduledoc """
  Schema for feed item likes.

  Tracks local user likes on remote feed items. Used to send AP `Like`
  activities to the remote actor's inbox.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Federation.FeedItem

  schema "feed_item_likes" do
    field :ap_id, :string

    belongs_to :feed_item, FeedItem
    belongs_to :user, Baudrate.Setup.User

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a feed item like."
  def changeset(like, attrs) do
    like
    |> cast(attrs, [:ap_id, :feed_item_id, :user_id])
    |> validate_required([:feed_item_id, :user_id])
    |> foreign_key_constraint(:feed_item_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:feed_item_id, :user_id])
    |> unique_constraint(:ap_id)
  end
end
