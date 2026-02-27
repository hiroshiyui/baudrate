defmodule Baudrate.Content.ArticleRead do
  @moduledoc """
  Schema tracking when a user last read an article.

  Used together with `BoardRead` to compute unread status. An article is
  considered unread when its `last_activity_at` is later than both the
  per-article `read_at` and the per-board "mark all as read" floor.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "article_reads" do
    belongs_to :user, Baudrate.Setup.User
    belongs_to :article, Baudrate.Content.Article
    field :read_at, :utc_datetime
  end

  @doc "Changeset for creating or updating an article read record."
  def changeset(article_read, attrs) do
    article_read
    |> cast(attrs, [:user_id, :article_id, :read_at])
    |> validate_required([:user_id, :article_id, :read_at])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:article_id)
    |> unique_constraint([:user_id, :article_id])
  end
end
