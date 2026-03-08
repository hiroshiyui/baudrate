defmodule Baudrate.Content.CommentBoost do
  @moduledoc """
  Schema for comment boosts (Announce/repost).

  Tracks boosts from both local users and remote actors. Each comment can
  only be boosted once per user or remote actor, enforced by partial unique
  indexes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.Comment
  alias Baudrate.Federation.RemoteActor

  schema "comment_boosts" do
    field :ap_id, :string

    belongs_to :comment, Comment
    belongs_to :user, Baudrate.Setup.User
    belongs_to :remote_actor, RemoteActor

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for local boosts created by authenticated users."
  def changeset(boost, attrs) do
    boost
    |> cast(attrs, [:ap_id, :comment_id, :user_id])
    |> validate_required([:comment_id, :user_id])
    |> foreign_key_constraint(:comment_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:comment_id, :user_id])
    |> unique_constraint(:ap_id)
  end

  @doc "Changeset for remote boosts received via ActivityPub."
  def remote_changeset(boost, attrs) do
    boost
    |> cast(attrs, [:ap_id, :comment_id, :remote_actor_id])
    |> validate_required([:ap_id, :comment_id, :remote_actor_id])
    |> validate_format(:ap_id, ~r/^https?:\/\//, message: "must be an HTTP(S) URL")
    |> foreign_key_constraint(:comment_id)
    |> foreign_key_constraint(:remote_actor_id)
    |> unique_constraint(:ap_id)
    |> unique_constraint([:comment_id, :remote_actor_id])
  end
end
