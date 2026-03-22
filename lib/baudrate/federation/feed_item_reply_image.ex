defmodule Baudrate.Federation.FeedItemReplyImage do
  @moduledoc """
  Schema for images attached to feed item replies.

  Reply images are displayed as a media gallery below the reply body and
  included as `attachment` entries in federated `Create(Note)` activities
  sent to the remote actor's inbox.

  The `reply_id` is nullable to support upload-before-save: images are
  uploaded during reply composition and associated with the reply on
  submission. Orphaned images (where `reply_id` is NULL for over 24 hours)
  are cleaned up by `SessionCleaner`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Federation.FeedItemReply

  @max_images_per_reply 4

  schema "feed_item_reply_images" do
    field :filename, :string
    field :storage_path, :string
    field :width, :integer
    field :height, :integer

    belongs_to :reply, FeedItemReply
    belongs_to :user, Baudrate.Setup.User

    timestamps(type: :utc_datetime)
  end

  @doc "Casts and validates fields for creating a feed item reply image record."
  def changeset(image, attrs) do
    image
    |> cast(attrs, [:filename, :storage_path, :width, :height, :reply_id, :user_id])
    |> validate_required([:filename, :storage_path, :width, :height, :user_id])
    |> foreign_key_constraint(:reply_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc "Returns the maximum number of images allowed per reply."
  def max_images_per_reply, do: @max_images_per_reply
end
