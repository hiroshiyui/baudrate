defmodule Baudrate.Content.Comment do
  @moduledoc """
  Schema for comments on articles.

  Comments support threading via `parent_id` (self-referential). A comment
  can be authored by a local user (`user_id`) or a remote actor
  (`remote_actor_id`) from the Fediverse. Remote comments store a `url`
  field with the human-readable permalink (distinct from `ap_id`).
  Soft-delete is handled via `deleted_at` rather than physical row removal.
  The `visibility` field records the ActivityPub visibility derived from
  `to`/`cc` addressing (`public`, `unlisted`, `followers_only`, or `direct`);
  defaults to `public` for local comments.

  Comments may have up to 4 attached images (see `CommentImage`). Images are
  displayed as a gallery below the comment body and included as `attachment`
  entries in federated `Create(Note)` activities.

  An author may edit their own comment; each edit snapshots the previous state
  into `CommentRevision` and publishes an `Update(Note)` (ADR 0060). The body
  is bounded at 64 KB on **both** changesets: inbound is already capped by
  `Baudrate.Federation.Validator.validate_content_size/1`, but the local
  composer had no bound at all, so a member could store a body no reader could
  load and every edit would copy it again into a revision.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  alias Baudrate.Content.{Article, CommentImage, CommentRevision, LinkPreview}
  alias Baudrate.Federation.RemoteActor

  # Matches `Article`'s bound and the 64 KB content ceiling inbound federation
  # is held to.
  @max_body_length 65_536

  schema "comments" do
    field :body, :string
    field :body_html, :string
    field :ap_id, :string
    # The `#note-N` URI this comment carried before Phase 3B rewrote it
    # (ADR 0050). Never cast from params, never asserted outbound as the
    # object's own id; it exists so a peer that knows only the old URI still
    # resolves, and so a withdrawal can name what that peer knows.
    field :legacy_ap_id, :string
    field :url, :string
    field :visibility, :string, default: "public"
    # Content warning (ADR 0052) — see `Baudrate.Content.ContentWarning`.
    field :summary, :string
    field :sensitive, :boolean, default: false
    field :deleted_at, :utc_datetime
    # Who deleted it: the author, or the moderator who removed it (1B).
    field :deleted_by_id, :id

    belongs_to :article, Article
    belongs_to :parent, __MODULE__
    belongs_to :user, Baudrate.Setup.User
    belongs_to :remote_actor, RemoteActor
    belongs_to :link_preview, LinkPreview

    has_many :replies, __MODULE__, foreign_key: :parent_id
    has_many :likes, Baudrate.Content.CommentLike
    has_many :boosts, Baudrate.Content.CommentBoost
    has_many :images, CommentImage
    has_many :revisions, CommentRevision

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for local comments created by authenticated users.

  `ap_id` is deliberately not cast — it is stamped post-insert by
  `Comments.create_comment/2`. Casting it let a user pre-squat a remote
  Note's URI.
  """
  def changeset(comment, attrs) do
    comment
    |> cast(
      attrs,
      [:body, :body_html, :article_id, :parent_id, :user_id, :visibility] ++
        Baudrate.Content.ContentWarning.fields()
    )
    |> Baudrate.Content.ContentWarning.validate()
    |> validate_required([:body, :article_id, :user_id])
    |> validate_length(:body, max: @max_body_length)
    # Local comments are public on the article page, so only public/unlisted
    # addressing is offered (D1 in doc/TODOs.md).
    |> validate_inclusion(:visibility, ~w(public unlisted))
    |> foreign_key_constraint(:article_id)
    |> foreign_key_constraint(:parent_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:ap_id)
  end

  @doc "Changeset for remote comments received via ActivityPub."
  def remote_changeset(comment, attrs) do
    comment
    |> cast(attrs, [
      :body,
      :body_html,
      :ap_id,
      :url,
      :article_id,
      :parent_id,
      :remote_actor_id,
      :visibility,
      :summary,
      :sensitive
    ])
    |> Baudrate.Content.ContentWarning.validate()
    |> validate_required([:body, :ap_id, :article_id, :remote_actor_id])
    |> validate_length(:body, max: @max_body_length)
    |> validate_inclusion(:visibility, ~w(public unlisted followers_only direct))
    # Backstop for the ingest-time scheme check: `url` is rendered as an href.
    |> validate_format(:url, ~r{\Ahttps://}, message: "must be an https URL")
    |> foreign_key_constraint(:article_id)
    |> foreign_key_constraint(:parent_id)
    |> foreign_key_constraint(:remote_actor_id)
    |> unique_constraint(:ap_id)
  end

  @doc "Changeset for soft-deleting a comment."
  def soft_delete_changeset(comment, deleted_by_id \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    comment
    |> change(deleted_at: now, deleted_by_id: deleted_by_id, body: "[deleted]", body_html: nil)
  end
end
