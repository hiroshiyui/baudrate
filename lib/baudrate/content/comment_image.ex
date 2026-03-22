defmodule Baudrate.Content.CommentImage do
  @moduledoc """
  Schema for images attached to comments.

  Comment images are displayed as a media gallery below the comment body.
  Each image is processed to WebP format with metadata stripped and
  dimensions capped at 1024px.

  The `comment_id` is nullable to support upload-before-save: images are
  uploaded during comment composition and associated with the comment on
  submission. Orphaned images (where `comment_id` is NULL for over 24 hours)
  are cleaned up by `SessionCleaner`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.Comment

  @max_images_per_comment 4

  schema "comment_images" do
    field :filename, :string
    field :storage_path, :string
    field :width, :integer
    field :height, :integer

    belongs_to :comment, Comment
    belongs_to :user, Baudrate.Setup.User

    timestamps(type: :utc_datetime)
  end

  @doc "Casts and validates fields for creating a comment image record."
  def changeset(image, attrs) do
    image
    |> cast(attrs, [:filename, :storage_path, :width, :height, :comment_id, :user_id])
    |> validate_required([:filename, :storage_path, :width, :height, :user_id])
    |> foreign_key_constraint(:comment_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc "Returns the maximum number of images allowed per comment."
  def max_images_per_comment, do: @max_images_per_comment
end
