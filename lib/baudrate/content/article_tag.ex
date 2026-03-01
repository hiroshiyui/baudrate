defmodule Baudrate.Content.ArticleTag do
  @moduledoc """
  Schema for article hashtags.

  Each record links an article to a single lowercase tag string.
  Tags are extracted from article bodies on create/update and stored
  for efficient querying (e.g., the `/tags/:tag` browse page).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @tag_re ~r/\A\p{L}[\w]{0,63}\z/u

  schema "article_tags" do
    field :tag, :string

    belongs_to :article, Baudrate.Content.Article

    timestamps(updated_at: false, type: :utc_datetime)
  end

  @doc """
  Changeset for creating an article tag.

  Validates that the tag is lowercase, 1–64 characters, and starts with
  a Unicode letter followed by word characters only.
  """
  def changeset(article_tag, attrs) do
    article_tag
    |> cast(attrs, [:article_id, :tag])
    |> validate_required([:article_id, :tag])
    |> validate_length(:tag, min: 1, max: 64)
    |> validate_format(:tag, @tag_re,
      message: "must start with a letter and contain only letters, numbers, or underscores"
    )
    |> unique_constraint([:article_id, :tag])
    |> foreign_key_constraint(:article_id)
  end
end
