defmodule Baudrate.Content.Likes do
  @moduledoc """
  Article and comment like operations.

  Manages local and remote likes, toggles, counts, and batch queries
  for rendering like state across content trees.
  """

  import Ecto.Query
  alias Baudrate.Repo

  alias Baudrate.Content.{
    Article,
    ArticleLike,
    Comment,
    CommentLike
  }

  # --- Article Likes ---

  @doc """
  Creates a remote article like received via ActivityPub.
  """
  def create_remote_article_like(attrs) do
    result =
      %ArticleLike{}
      |> ArticleLike.remote_changeset(attrs)
      |> Repo.insert()

    with {:ok, like} <- result do
      Baudrate.Notification.Hooks.notify_remote_article_liked(
        like.article_id,
        like.remote_actor_id
      )

      result
    end
  end

  @doc """
  Deletes an article like by its ActivityPub ID.
  """
  def delete_article_like_by_ap_id(ap_id) when is_binary(ap_id) do
    from(l in ArticleLike, where: l.ap_id == ^ap_id)
    |> Repo.delete_all()
  end

  @doc """
  Deletes an article like by its ActivityPub ID, scoped to the given remote actor.
  Returns `{count, nil}` — only deletes if both ap_id and remote_actor_id match.
  """
  def delete_article_like_by_ap_id(ap_id, remote_actor_id) when is_binary(ap_id) do
    from(l in ArticleLike,
      where: l.ap_id == ^ap_id and l.remote_actor_id == ^remote_actor_id
    )
    |> Repo.delete_all()
  end

  @doc """
  Returns the count of likes for an article.
  """
  def count_article_likes(%Article{id: article_id}) do
    Repo.one(from(l in ArticleLike, where: l.article_id == ^article_id, select: count(l.id))) ||
      0
  end

  @doc """
  Creates a local article like for the given user.

  Returns `{:ok, like}` or `{:error, changeset}`.
  """
  @spec like_article(term(), term()) :: {:ok, %ArticleLike{}} | {:error, Ecto.Changeset.t()}
  def like_article(user_id, article_id) do
    result =
      %ArticleLike{}
      |> ArticleLike.changeset(%{user_id: user_id, article_id: article_id})
      |> Repo.insert()

    with {:ok, like} <- result do
      {:ok, stamp_like_ap_id(like)}
    end
  end

  @doc """
  Removes a local article like for the given user.

  Returns `{count, nil}`.
  """
  @spec unlike_article(term(), term()) :: {non_neg_integer(), nil}
  def unlike_article(user_id, article_id) do
    from(l in ArticleLike, where: l.user_id == ^user_id and l.article_id == ^article_id)
    |> Repo.delete_all()
  end

  @doc """
  Returns true if the user has liked the given article.
  """
  @spec article_liked?(term(), term()) :: boolean()
  def article_liked?(user_id, article_id) do
    Repo.exists?(
      from(l in ArticleLike, where: l.user_id == ^user_id and l.article_id == ^article_id)
    )
  end

  @doc """
  Toggles an article like — creates if not exists, removes if exists.

  Returns `{:ok, like}` when created, `{:ok, :removed}` when deleted,
  `{:error, :self_like}` if the user owns the article,
  `{:error, :deleted}` if the article is soft-deleted.
  """
  @spec toggle_article_like(term(), term()) ::
          {:ok, %ArticleLike{}}
          | {:ok, :removed}
          | {:error, :self_like | :deleted | Ecto.Changeset.t()}
  def toggle_article_like(user_id, article_id) do
    article = Repo.get!(Article, article_id)

    cond do
      article.user_id == user_id ->
        {:error, :self_like}

      not is_nil(article.deleted_at) ->
        {:error, :deleted}

      true ->
        case Repo.get_by(ArticleLike, user_id: user_id, article_id: article_id) do
          nil ->
            case like_article(user_id, article_id) do
              {:ok, like} ->
                Baudrate.Notification.Hooks.notify_local_article_liked(article_id, user_id)

                schedule_federation_task(fn ->
                  Baudrate.Federation.Publisher.publish_article_liked(user_id, article)
                end)

                {:ok, like}

              {:error, %Ecto.Changeset{} = cs} ->
                if has_unique_constraint_error?(cs) do
                  unlike_article(user_id, article_id)
                  {:ok, :removed}
                else
                  {:error, cs}
                end
            end

          like ->
            like_ap_id = like.ap_id
            unlike_article(user_id, article_id)

            schedule_federation_task(fn ->
              Baudrate.Federation.Publisher.publish_article_unliked(user_id, article, like_ap_id)
            end)

            {:ok, :removed}
        end
    end
  end

  # --- Comment Likes ---

  @doc """
  Creates a local comment like for the given user.

  Returns `{:ok, like}` or `{:error, changeset}`.
  """
  @spec like_comment(term(), term()) :: {:ok, %CommentLike{}} | {:error, Ecto.Changeset.t()}
  def like_comment(user_id, comment_id) do
    %CommentLike{}
    |> CommentLike.changeset(%{user_id: user_id, comment_id: comment_id})
    |> Repo.insert()
  end

  @doc """
  Removes a local comment like for the given user.

  Returns `{count, nil}`.
  """
  @spec unlike_comment(term(), term()) :: {non_neg_integer(), nil}
  def unlike_comment(user_id, comment_id) do
    from(l in CommentLike, where: l.user_id == ^user_id and l.comment_id == ^comment_id)
    |> Repo.delete_all()
  end

  @doc """
  Returns true if the user has liked the given comment.
  """
  @spec comment_liked?(term(), term()) :: boolean()
  def comment_liked?(user_id, comment_id) do
    Repo.exists?(
      from(l in CommentLike, where: l.user_id == ^user_id and l.comment_id == ^comment_id)
    )
  end

  @doc """
  Returns the count of likes for a comment.
  """
  @spec count_comment_likes(%Comment{}) :: non_neg_integer()
  def count_comment_likes(%Comment{id: comment_id}) do
    Repo.one(from(l in CommentLike, where: l.comment_id == ^comment_id, select: count(l.id))) ||
      0
  end

  @doc """
  Toggles a comment like — creates if not exists, removes if exists.

  Returns `{:ok, like}` when created, `{:ok, :removed}` when deleted,
  `{:error, :self_like}` if the user owns the comment,
  `{:error, :deleted}` if the comment is soft-deleted.
  """
  @spec toggle_comment_like(term(), term()) ::
          {:ok, %CommentLike{}}
          | {:ok, :removed}
          | {:error, :self_like | :deleted | Ecto.Changeset.t()}
  def toggle_comment_like(user_id, comment_id) do
    comment = Repo.get!(Comment, comment_id)

    cond do
      comment.user_id == user_id ->
        {:error, :self_like}

      not is_nil(comment.deleted_at) ->
        {:error, :deleted}

      true ->
        case Repo.get_by(CommentLike, user_id: user_id, comment_id: comment_id) do
          nil ->
            case like_comment(user_id, comment_id) do
              {:ok, like} ->
                Baudrate.Notification.Hooks.notify_local_comment_liked(comment_id, user_id)
                {:ok, like}

              {:error, %Ecto.Changeset{} = cs} ->
                if has_unique_constraint_error?(cs) do
                  unlike_comment(user_id, comment_id)
                  {:ok, :removed}
                else
                  {:error, cs}
                end
            end

          _like ->
            unlike_comment(user_id, comment_id)
            {:ok, :removed}
        end
    end
  end

  @doc """
  Returns a MapSet of comment IDs that the given user has liked,
  filtered to the provided list of comment IDs.

  Useful for efficiently rendering like state across a comment tree.
  """
  @spec comment_likes_by_user(term(), [term()]) :: MapSet.t()
  def comment_likes_by_user(_user_id, []), do: MapSet.new()

  def comment_likes_by_user(user_id, comment_ids) do
    from(l in CommentLike,
      where: l.user_id == ^user_id and l.comment_id in ^comment_ids,
      select: l.comment_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Returns a map of `%{comment_id => like_count}` for the given comment IDs.

  Useful for efficiently rendering like counts across a comment tree.
  """
  @spec comment_like_counts([term()]) :: %{term() => non_neg_integer()}
  def comment_like_counts([]), do: %{}

  def comment_like_counts(comment_ids) do
    from(l in CommentLike,
      where: l.comment_id in ^comment_ids,
      group_by: l.comment_id,
      select: {l.comment_id, count(l.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Returns true if a changeset has a unique constraint error.
  """
  def has_unique_constraint_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_msg, meta}} -> Keyword.get(meta, :constraint) == :unique
      _ -> false
    end)
  end

  defp stamp_like_ap_id(%ArticleLike{ap_id: nil, user_id: user_id} = like)
       when is_integer(user_id) do
    user = Repo.get!(Baudrate.Setup.User, user_id)
    ap_id = Baudrate.Federation.actor_uri(:user, user.username) <> "#like-#{like.id}"

    like
    |> Ecto.Changeset.change(ap_id: ap_id)
    |> Repo.update!()
  end

  defp stamp_like_ap_id(like), do: like

  defp schedule_federation_task(fun), do: Baudrate.Federation.schedule_federation_task(fun)
end
