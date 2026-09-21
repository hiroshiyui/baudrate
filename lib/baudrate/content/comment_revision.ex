defmodule Baudrate.Content.CommentRevision do
  @moduledoc """
  Schema for comment revision snapshots.

  Each row is the comment as it stood **before** an edit — body, content
  warning and all — so the history reads as a sequence of what was replaced.
  Diffs between revisions are computed on the fly with
  `String.myers_difference/2`, exactly as `Baudrate.Content.ArticleRevision`
  does; nothing is stored pre-diffed.

  Two things this shares with the article table and one it does not.

  Shared: it is **insert-only** (no `updated_at`) — a revision that could be
  edited is not a record of anything — and `editor_id` is `nilify_all`, so
  deleting an account leaves the history standing with its author removed
  rather than rewriting the thread.

  Different: it carries `summary` and `sensitive` (ADR 0052). Removing a
  content warning re-exposes what the warning hid, which makes it the edit
  most worth recording; snapshotting only the body would lose it silently.
  Article revisions gained the same two columns in the same migration.

  A revision is written only for a **local** editor. An inbound `Update(Note)`
  from the actor who owns a remote comment rewrites it with no snapshot, which
  is what `Baudrate.Federation.InboxHandler.handle_update_note/2` has always
  done for articles: the history here records acts taken on this instance.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.Comment
  alias Baudrate.Content.ContentWarning
  alias Baudrate.Setup.User

  @max_body_length 65_536

  schema "comment_revisions" do
    field :body, :string
    field :summary, :string
    field :sensitive, :boolean, default: false

    belongs_to :comment, Comment
    belongs_to :editor, User

    timestamps(updated_at: false, type: :utc_datetime)
  end

  @doc "The longest body a revision may hold. Matches `Comment`."
  @spec max_body_length() :: pos_integer()
  def max_body_length, do: @max_body_length

  @doc "Changeset for creating a revision snapshot."
  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [:body, :comment_id, :editor_id] ++ ContentWarning.fields())
    |> ContentWarning.validate()
    |> validate_required([:body, :comment_id])
    |> validate_length(:body, max: @max_body_length)
    |> foreign_key_constraint(:comment_id)
    |> foreign_key_constraint(:editor_id)
  end
end
