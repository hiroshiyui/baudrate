defmodule Baudrate.Content.ArticleImage do
  @moduledoc """
  Schema for images attached to articles.

  Article images are displayed as a media gallery at the end of the article,
  not inline in the body. Each image is processed to WebP format with metadata
  stripped and dimensions capped at 1024px.

  The `article_id` is nullable to support upload-before-save: images are
  uploaded during article composition and associated with the article on save.
  Orphaned images (where `article_id` is NULL for over 24 hours) are cleaned
  up by `SessionCleaner`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.Article

  @max_images_per_article 4

  schema "article_images" do
    field :filename, :string
    field :storage_path, :string
    field :width, :integer
    field :height, :integer

    belongs_to :article, Article
    belongs_to :user, Baudrate.Setup.User

    timestamps(type: :utc_datetime)
  end

  def changeset(image, attrs) do
    image
    |> cast(attrs, [:filename, :storage_path, :width, :height, :article_id, :user_id])
    |> validate_required([:filename, :storage_path, :width, :height, :user_id])
    |> foreign_key_constraint(:article_id)
    |> foreign_key_constraint(:user_id)
  end

  def max_images_per_article, do: @max_images_per_article
end
