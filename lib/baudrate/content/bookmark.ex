defmodule Baudrate.Content.Bookmark do
  @moduledoc """
  Schema for bookmarked articles and comments.

  Users can bookmark articles or comments for later reference. Each bookmark
  targets exactly one of article or comment, enforced by a database check
  constraint and application-level validation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "bookmarks" do
    belongs_to :user, Baudrate.Setup.User
    belongs_to :article, Baudrate.Content.Article
    belongs_to :comment, Baudrate.Content.Comment
    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a bookmark."
  def changeset(bookmark, attrs) do
    bookmark
    |> cast(attrs, [:user_id, :article_id, :comment_id])
    |> validate_required([:user_id])
    |> validate_exactly_one_target()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:article_id)
    |> foreign_key_constraint(:comment_id)
    |> unique_constraint([:user_id, :article_id], name: :bookmarks_user_article_unique)
    |> unique_constraint([:user_id, :comment_id], name: :bookmarks_user_comment_unique)
  end

  defp validate_exactly_one_target(changeset) do
    article_id = get_field(changeset, :article_id)
    comment_id = get_field(changeset, :comment_id)

    cond do
      is_nil(article_id) and is_nil(comment_id) ->
        add_error(changeset, :article_id, "either article or comment must be set")

      not is_nil(article_id) and not is_nil(comment_id) ->
        add_error(changeset, :article_id, "cannot bookmark both article and comment")

      true ->
        changeset
    end
  end
end
