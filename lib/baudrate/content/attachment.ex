defmodule Baudrate.Content.Attachment do
  @moduledoc """
  Schema for file attachments on articles.

  Allowlisted content types: images (JPEG, PNG, WebP, GIF), PDF, plain text,
  Markdown, and ZIP archives. Maximum file size is 10 MB.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.Article

  @max_size 10 * 1024 * 1024
  @allowed_content_types ~w[
    image/jpeg image/png image/webp image/gif
    application/pdf
    text/plain text/markdown
    application/zip
  ]

  schema "attachments" do
    field :filename, :string
    field :original_filename, :string
    field :content_type, :string
    field :size, :integer
    field :storage_path, :string

    belongs_to :article, Article
    belongs_to :user, Baudrate.Setup.User

    timestamps(type: :utc_datetime)
  end

  @doc "Casts and validates fields for creating an attachment record."
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:filename, :original_filename, :content_type, :size, :storage_path, :article_id, :user_id])
    |> validate_required([:filename, :original_filename, :content_type, :size, :storage_path, :article_id])
    |> validate_inclusion(:content_type, @allowed_content_types, message: "file type not allowed")
    |> validate_number(:size, less_than_or_equal_to: @max_size, message: "file too large (max 10 MB)")
    |> foreign_key_constraint(:article_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc "Returns the maximum attachment file size in bytes (10 MB)."
  def max_size, do: @max_size

  @doc "Returns the list of allowed MIME types for attachments."
  def allowed_content_types, do: @allowed_content_types
end
