defmodule Baudrate.Federation.TimelineItemLike do
  @moduledoc """
  Schema for timeline item likes.

  Tracks local user likes on remote timeline items. Used to send AP `Like`
  activities to the remote actor's inbox.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Federation.TimelineItem

  schema "timeline_item_likes" do
    field :ap_id, :string

    belongs_to :timeline_item, TimelineItem
    belongs_to :user, Baudrate.Setup.User

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a timeline item like."
  def changeset(like, attrs) do
    like
    |> cast(attrs, [:ap_id, :timeline_item_id, :user_id])
    |> validate_required([:timeline_item_id, :user_id])
    |> foreign_key_constraint(:timeline_item_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:timeline_item_id, :user_id])
    |> unique_constraint(:ap_id)
  end
end
