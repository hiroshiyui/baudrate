defmodule Baudrate.Content.Article do
  @moduledoc """
  Schema for forum articles (posts).

  An article belongs to an author (user) and can be cross-posted to
  multiple boards via the `board_articles` join table. Remote articles
  received via ActivityPub are tracked by `ap_id` and `remote_actor_id`.
  Soft-delete is handled via `deleted_at`. The `forwardable` flag
  controls whether other users can cross-forward the article to
  additional boards (default: `true`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.{ArticleRevision, ArticleLike, Board, BoardArticle, Comment}
  alias Baudrate.Federation.RemoteActor

  schema "articles" do
    field :title, :string
    field :body, :string
    field :slug, :string
    field :pinned, :boolean, default: false
    field :locked, :boolean, default: false
    field :forwardable, :boolean, default: true
    field :ap_id, :string
    field :deleted_at, :utc_datetime
    field :last_activity_at, :utc_datetime

    belongs_to :user, Baudrate.Setup.User
    belongs_to :remote_actor, RemoteActor
    has_many :board_articles, BoardArticle
    has_many :comments, Comment
    has_many :likes, ArticleLike
    has_many :revisions, ArticleRevision
    many_to_many :boards, Board, join_through: "board_articles"

    timestamps(type: :utc_datetime)
  end

  @max_body_length 65_536

  @doc "Changeset for creating a local article with title, body, slug, and author."
  def changeset(article, attrs) do
    article
    |> cast(attrs, [:title, :body, :slug, :user_id, :forwardable])
    |> validate_required([:title, :body, :slug])
    |> validate_length(:body, max: @max_body_length)
    |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> assoc_constraint(:user)
    |> unique_constraint(:slug)
  end

  @doc "Changeset for updating a local article (title and body only, slug stays fixed)."
  def update_changeset(article, attrs) do
    article
    |> cast(attrs, [:title, :body, :forwardable])
    |> validate_required([:title, :body])
    |> validate_length(:body, max: @max_body_length)
  end

  @doc "Changeset for remote articles received via ActivityPub."
  def remote_changeset(article, attrs) do
    article
    |> cast(attrs, [:title, :body, :slug, :ap_id, :remote_actor_id])
    |> validate_required([:title, :body, :slug, :ap_id, :remote_actor_id])
    |> validate_length(:body, max: @max_body_length)
    |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> foreign_key_constraint(:remote_actor_id)
    |> unique_constraint(:slug)
    |> unique_constraint(:ap_id)
  end

  @doc "Changeset for updating remote article content."
  def update_remote_changeset(article, attrs) do
    article
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:body, max: @max_body_length)
  end

  @doc "Changeset for soft-deleting an article."
  def soft_delete_changeset(article) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    article
    |> change(deleted_at: now)
  end
end
