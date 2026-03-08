defmodule Baudrate.Federation.FeedItemBoost do
  @moduledoc """
  Schema for feed item boosts.

  Tracks local user boosts on remote feed items. Used to send AP `Announce`
  activities to the remote actor's inbox.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Federation.FeedItem

  schema "feed_item_boosts" do
    field :ap_id, :string

    belongs_to :feed_item, FeedItem
    belongs_to :user, Baudrate.Setup.User

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a feed item boost."
  def changeset(boost, attrs) do
    boost
    |> cast(attrs, [:ap_id, :feed_item_id, :user_id])
    |> validate_required([:feed_item_id, :user_id])
    |> foreign_key_constraint(:feed_item_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:feed_item_id, :user_id])
    |> unique_constraint(:ap_id)
  end
end
