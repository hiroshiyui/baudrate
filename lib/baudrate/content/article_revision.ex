defmodule Baudrate.Content.ArticleRevision do
  @moduledoc """
  Schema for article revision snapshots.

  Each revision stores a full snapshot of the article's title, body and
  content warning at the time of an edit. Diffs between revisions are computed
  on-the-fly using `String.myers_difference/2`.

  `summary` and `sensitive` (ADR 0052) were added after the table existed,
  because removing a content warning re-exposes what it hid and left no trace
  in the history. Rows written before that keep NULL / `false`: the value is
  unknown, not known to have been absent, and backfilling a guess would be
  worse than saying so.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.Article
  alias Baudrate.Content.ContentWarning
  alias Baudrate.Setup.User

  @max_body_length 65_536

  schema "article_revisions" do
    field :title, :string
    field :body, :string
    field :summary, :string
    field :sensitive, :boolean, default: false

    belongs_to :article, Article
    belongs_to :editor, User

    timestamps(updated_at: false, type: :utc_datetime)
  end

  @doc "Changeset for creating a revision snapshot."
  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [:title, :body, :article_id, :editor_id] ++ ContentWarning.fields())
    |> ContentWarning.validate()
    |> validate_required([:title, :body, :article_id])
    |> validate_length(:body, max: @max_body_length)
    |> foreign_key_constraint(:article_id)
    |> foreign_key_constraint(:editor_id)
  end
end
