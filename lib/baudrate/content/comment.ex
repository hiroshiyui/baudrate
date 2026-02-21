defmodule Baudrate.Content.Comment do
  @moduledoc """
  Schema for comments on articles.

  Comments support threading via `parent_id` (self-referential). A comment
  can be authored by a local user (`user_id`) or a remote actor
  (`remote_actor_id`) from the Fediverse. Soft-delete is handled via
  `deleted_at` rather than physical row removal.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.Article
  alias Baudrate.Federation.RemoteActor

  schema "comments" do
    field :body, :string
    field :body_html, :string
    field :ap_id, :string
    field :deleted_at, :utc_datetime

    belongs_to :article, Article
    belongs_to :parent, __MODULE__
    belongs_to :user, Baudrate.Setup.User
    belongs_to :remote_actor, RemoteActor

    has_many :replies, __MODULE__, foreign_key: :parent_id

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for local comments created by authenticated users."
  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body, :body_html, :article_id, :parent_id, :user_id])
    |> validate_required([:body, :article_id, :user_id])
    |> foreign_key_constraint(:article_id)
    |> foreign_key_constraint(:parent_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc "Changeset for remote comments received via ActivityPub."
  def remote_changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body, :body_html, :ap_id, :article_id, :parent_id, :remote_actor_id])
    |> validate_required([:body, :ap_id, :article_id, :remote_actor_id])
    |> foreign_key_constraint(:article_id)
    |> foreign_key_constraint(:parent_id)
    |> foreign_key_constraint(:remote_actor_id)
    |> unique_constraint(:ap_id)
  end

  @doc "Changeset for soft-deleting a comment."
  def soft_delete_changeset(comment) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    comment
    |> change(deleted_at: now, body: "[deleted]", body_html: nil)
  end
end
