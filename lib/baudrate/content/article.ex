defmodule Baudrate.Content.Article do
  @moduledoc """
  Schema for forum articles (posts).

  An article belongs to an author (user) and can be cross-posted to
  multiple boards via the `board_articles` join table. Remote articles
  received via ActivityPub are tracked by `ap_id` and `remote_actor_id`;
  the `url` field stores the human-readable permalink (distinct from `ap_id`).
  Soft-delete is handled via `deleted_at`. The `forwardable` flag
  controls whether other users can cross-forward the article to
  additional boards (default: `true`). The `visibility` field records
  the ActivityPub visibility derived from `to`/`cc` addressing
  (`public`, `unlisted`, `followers_only`, or `direct`); defaults to
  `public` for local articles.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.{
    ArticleImage,
    ArticleRevision,
    ArticleLike,
    Board,
    BoardArticle,
    Comment,
    LinkPreview,
    Poll
  }

  alias Baudrate.Federation.RemoteActor

  schema "articles" do
    field :title, :string
    field :body, :string
    field :slug, :string
    field :pinned, :boolean, default: false
    field :locked, :boolean, default: false
    field :forwardable, :boolean, default: true
    field :visibility, :string, default: "public"
    field :ap_id, :string
    field :url, :string
    field :deleted_at, :utc_datetime
    field :last_activity_at, :utc_datetime
    field :published_at, :utc_datetime_usec

    belongs_to :user, Baudrate.Setup.User
    belongs_to :remote_actor, RemoteActor
    belongs_to :link_preview, LinkPreview
    has_many :board_articles, BoardArticle
    has_many :comments, Comment
    has_many :likes, ArticleLike
    has_many :boosts, Baudrate.Content.ArticleBoost
    has_many :article_images, ArticleImage
    has_many :revisions, ArticleRevision
    has_one :poll, Poll
    many_to_many :boards, Board, join_through: "board_articles"

    timestamps(type: :utc_datetime)
  end

  @max_title_length 255
  @max_body_length 65_536

  @user_fields [:title, :body, :slug, :user_id, :forwardable, :visibility]
  @trusted_fields @user_fields ++ [:ap_id, :url, :published_at]

  @doc """
  Changeset for creating a local article from user input.

  Casts only the fields a user may set. `ap_id` is stamped post-insert by
  `Articles.create_article/3`; `url` and `published_at` are reserved for
  trusted system callers (`trusted_changeset/2`). Casting them here let any
  authenticated user pre-set an `ap_id` (squatting a remote object's URI so
  the genuine post is later dropped as a duplicate and the local one is served
  in its place), plant an arbitrary "View original" link, or backdate a post.
  """
  def changeset(article, attrs), do: base_changeset(article, attrs, @user_fields)

  @doc """
  Changeset for articles created by trusted system code (RSS/Atom bots), which
  may additionally set `url` and `published_at` from the feed entry and, for
  mirrored objects, a pre-existing `ap_id`. Never expose to user input.
  """
  def trusted_changeset(article, attrs), do: base_changeset(article, attrs, @trusted_fields)

  defp base_changeset(article, attrs, fields) do
    article
    |> cast(attrs, fields)
    |> validate_required([:title, :body, :slug])
    |> validate_length(:title, max: @max_title_length)
    |> validate_length(:body, max: @max_body_length)
    |> validate_inclusion(:visibility, ~w(public unlisted followers_only direct))
    |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> assoc_constraint(:user)
    |> unique_constraint(:slug)
    |> unique_constraint(:ap_id)
  end

  @doc "Changeset for updating a local article (title and body only, slug stays fixed)."
  def update_changeset(article, attrs) do
    article
    |> cast(attrs, [:title, :body, :forwardable, :visibility])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: @max_title_length)
    |> validate_length(:body, max: @max_body_length)
    |> validate_inclusion(:visibility, ~w(public unlisted followers_only direct))
  end

  @doc "Changeset for remote articles received via ActivityPub."
  def remote_changeset(article, attrs) do
    article
    |> cast(attrs, [
      :title,
      :body,
      :slug,
      :ap_id,
      :url,
      :remote_actor_id,
      :visibility,
      :forwardable
    ])
    |> validate_required([:title, :body, :slug, :ap_id, :remote_actor_id])
    |> validate_length(:title, max: @max_title_length)
    |> validate_length(:body, max: @max_body_length)
    |> validate_inclusion(:visibility, ~w(public unlisted followers_only direct))
    |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
      message: "must be lowercase alphanumeric with hyphens"
    )
    # Backstop for the ingest-time scheme check: `url` is rendered as an href.
    |> validate_format(:url, ~r{\Ahttps://}, message: "must be an https URL")
    |> foreign_key_constraint(:remote_actor_id)
    |> unique_constraint(:slug)
    |> unique_constraint(:ap_id)
  end

  @doc "Changeset for updating remote article content."
  def update_remote_changeset(article, attrs) do
    article
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: @max_title_length)
    |> validate_length(:body, max: @max_body_length)
  end

  @doc "Changeset for soft-deleting an article."
  def soft_delete_changeset(article) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    article
    |> change(deleted_at: now)
  end
end
