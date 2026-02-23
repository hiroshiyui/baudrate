defmodule Baudrate.Content.ArticleRevision do
  @moduledoc """
  Schema for article revision snapshots.

  Each revision stores a full snapshot of the article's title and body
  at the time of an edit. Diffs between revisions are computed on-the-fly
  using `String.myers_difference/2`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.Article
  alias Baudrate.Setup.User

  @max_body_length 65_536

  schema "article_revisions" do
    field :title, :string
    field :body, :string

    belongs_to :article, Article
    belongs_to :editor, User

    timestamps(updated_at: false, type: :utc_datetime)
  end

  @doc "Changeset for creating a revision snapshot."
  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [:title, :body, :article_id, :editor_id])
    |> validate_required([:title, :body, :article_id])
    |> validate_length(:body, max: @max_body_length)
    |> foreign_key_constraint(:article_id)
    |> foreign_key_constraint(:editor_id)
  end
end
