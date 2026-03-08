defmodule Baudrate.Content.Boosts do
  @moduledoc """
  Article and comment boost operations.

  Manages local and remote boosts, toggles, counts, and batch queries
  for rendering boost state across content.
  """

  import Ecto.Query
  alias Baudrate.Repo

  alias Baudrate.Content.{
    Article,
    ArticleBoost,
    Comment,
    CommentBoost,
    Interactions
  }

  # --- Article Boosts ---

  @doc """
  Creates a remote article boost received via ActivityPub.
  """
  def create_remote_article_boost(attrs) do
    result =
      %ArticleBoost{}
      |> ArticleBoost.remote_changeset(attrs)
      |> Repo.insert()

    with {:ok, boost} <- result do
      Baudrate.Notification.Hooks.notify_remote_article_boosted(
        boost.article_id,
        boost.remote_actor_id
      )

      result
    end
  end

  @doc """
  Deletes an article boost by its ActivityPub ID.
  """
  def delete_article_boost_by_ap_id(ap_id) when is_binary(ap_id) do
    from(b in ArticleBoost, where: b.ap_id == ^ap_id)
    |> Repo.delete_all()
  end

  @doc """
  Deletes an article boost by its ActivityPub ID, scoped to the given remote actor.
  Returns `{count, nil}` — only deletes if both ap_id and remote_actor_id match.
  """
  def delete_article_boost_by_ap_id(ap_id, remote_actor_id) when is_binary(ap_id) do
    from(b in ArticleBoost,
      where: b.ap_id == ^ap_id and b.remote_actor_id == ^remote_actor_id
    )
    |> Repo.delete_all()
  end

  @doc """
  Returns the count of boosts for an article.
  """
  def count_article_boosts(%Article{id: article_id}) do
    Repo.one(from(b in ArticleBoost, where: b.article_id == ^article_id, select: count(b.id))) ||
      0
  end

  @doc """
  Creates a local article boost for the given user.
  """
  def boost_article(user_id, article_id) do
    result =
      %ArticleBoost{}
      |> ArticleBoost.changeset(%{user_id: user_id, article_id: article_id})
      |> Repo.insert()

    with {:ok, boost} <- result do
      {:ok, Interactions.stamp_ap_id(boost, "announce")}
    end
  end

  @doc """
  Removes a local article boost for the given user.
  """
  def unboost_article(user_id, article_id) do
    from(b in ArticleBoost, where: b.user_id == ^user_id and b.article_id == ^article_id)
    |> Repo.delete_all()
  end

  @doc """
  Returns true if the user has boosted the given article.
  """
  def article_boosted?(user_id, article_id) do
    Repo.exists?(
      from(b in ArticleBoost, where: b.user_id == ^user_id and b.article_id == ^article_id)
    )
  end

  @doc """
  Toggles an article boost — creates if not exists, removes if exists.

  Returns `{:ok, boost}` when created, `{:ok, :removed}` when deleted,
  `{:error, :self_boost}` if the user owns the article,
  `{:error, :deleted}` if the article is soft-deleted.
  """
  def toggle_article_boost(user_id, article_id) do
    case Repo.get(Article, article_id) do
      nil ->
        {:error, :not_found}

      article ->
        do_toggle_article_boost(user_id, article)
    end
  end

  defp do_toggle_article_boost(user_id, article) do
    article_id = article.id

    cond do
      article.user_id == user_id ->
        {:error, :self_boost}

      not is_nil(article.deleted_at) ->
        {:error, :deleted}

      not Interactions.article_visible_to_user?(article_id, user_id) ->
        {:error, :not_found}

      true ->
        case Repo.get_by(ArticleBoost, user_id: user_id, article_id: article_id) do
          nil ->
            case boost_article(user_id, article_id) do
              {:ok, boost} ->
                Baudrate.Notification.Hooks.notify_local_article_boosted(article_id, user_id)

                Interactions.schedule_federation_task(fn ->
                  Baudrate.Federation.Publisher.publish_article_boosted(user_id, article)
                end)

                {:ok, boost}

              {:error, %Ecto.Changeset{} = cs} ->
                if Interactions.has_unique_constraint_error?(cs) do
                  unboost_article(user_id, article_id)
                  {:ok, :removed}
                else
                  {:error, cs}
                end
            end

          boost ->
            boost_ap_id = boost.ap_id
            unboost_article(user_id, article_id)

            Interactions.schedule_federation_task(fn ->
              Baudrate.Federation.Publisher.publish_article_unboosted(
                user_id,
                article,
                boost_ap_id
              )
            end)

            {:ok, :removed}
        end
    end
  end

  @doc """
  Returns a MapSet of article IDs that the given user has boosted,
  filtered to the provided list of article IDs.
  """
  def article_boosts_by_user(_user_id, []), do: MapSet.new()

  def article_boosts_by_user(user_id, article_ids) do
    from(b in ArticleBoost,
      where: b.user_id == ^user_id and b.article_id in ^article_ids,
      select: b.article_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Returns a map of `%{article_id => boost_count}` for the given article IDs.
  """
  def article_boost_counts([]), do: %{}

  def article_boost_counts(article_ids) do
    from(b in ArticleBoost,
      where: b.article_id in ^article_ids,
      group_by: b.article_id,
      select: {b.article_id, count(b.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # --- Comment Boosts ---

  @doc """
  Creates a remote comment boost received via ActivityPub.
  """
  def create_remote_comment_boost(attrs) do
    result =
      %CommentBoost{}
      |> CommentBoost.remote_changeset(attrs)
      |> Repo.insert()

    with {:ok, boost} <- result do
      Baudrate.Notification.Hooks.notify_remote_comment_boosted(
        boost.comment_id,
        boost.remote_actor_id
      )

      result
    end
  end

  @doc """
  Deletes a comment boost by its ActivityPub ID.
  """
  def delete_comment_boost_by_ap_id(ap_id) when is_binary(ap_id) do
    from(b in CommentBoost, where: b.ap_id == ^ap_id)
    |> Repo.delete_all()
  end

  @doc """
  Deletes a comment boost by its ActivityPub ID, scoped to the given remote actor.
  """
  def delete_comment_boost_by_ap_id(ap_id, remote_actor_id) when is_binary(ap_id) do
    from(b in CommentBoost,
      where: b.ap_id == ^ap_id and b.remote_actor_id == ^remote_actor_id
    )
    |> Repo.delete_all()
  end

  @doc """
  Returns the count of boosts for a comment.
  """
  def count_comment_boosts(%Comment{id: comment_id}) do
    Repo.one(from(b in CommentBoost, where: b.comment_id == ^comment_id, select: count(b.id))) ||
      0
  end

  @doc """
  Creates a local comment boost for the given user.
  """
  def boost_comment(user_id, comment_id) do
    result =
      %CommentBoost{}
      |> CommentBoost.changeset(%{user_id: user_id, comment_id: comment_id})
      |> Repo.insert()

    with {:ok, boost} <- result do
      {:ok, Interactions.stamp_ap_id(boost, "comment-announce")}
    end
  end

  @doc """
  Removes a local comment boost for the given user.
  """
  def unboost_comment(user_id, comment_id) do
    from(b in CommentBoost, where: b.user_id == ^user_id and b.comment_id == ^comment_id)
    |> Repo.delete_all()
  end

  @doc """
  Returns true if the user has boosted the given comment.
  """
  def comment_boosted?(user_id, comment_id) do
    Repo.exists?(
      from(b in CommentBoost, where: b.user_id == ^user_id and b.comment_id == ^comment_id)
    )
  end

  @doc """
  Toggles a comment boost — creates if not exists, removes if exists.

  Returns `{:ok, boost}` when created, `{:ok, :removed}` when deleted,
  `{:error, :self_boost}` if the user owns the comment,
  `{:error, :deleted}` if the comment is soft-deleted.
  """
  def toggle_comment_boost(user_id, comment_id) do
    case Repo.get(Comment, comment_id) do
      nil ->
        {:error, :not_found}

      comment ->
        do_toggle_comment_boost(user_id, comment)
    end
  end

  defp do_toggle_comment_boost(user_id, comment) do
    comment_id = comment.id

    cond do
      comment.user_id == user_id ->
        {:error, :self_boost}

      not is_nil(comment.deleted_at) ->
        {:error, :deleted}

      not Interactions.article_visible_to_user?(comment.article_id, user_id) ->
        {:error, :not_found}

      true ->
        case Repo.get_by(CommentBoost, user_id: user_id, comment_id: comment_id) do
          nil ->
            case boost_comment(user_id, comment_id) do
              {:ok, boost} ->
                Baudrate.Notification.Hooks.notify_local_comment_boosted(comment_id, user_id)

                Interactions.schedule_federation_task(fn ->
                  Baudrate.Federation.Publisher.publish_comment_boosted(user_id, comment)
                end)

                {:ok, boost}

              {:error, %Ecto.Changeset{} = cs} ->
                if Interactions.has_unique_constraint_error?(cs) do
                  unboost_comment(user_id, comment_id)
                  {:ok, :removed}
                else
                  {:error, cs}
                end
            end

          boost ->
            boost_ap_id = boost.ap_id
            unboost_comment(user_id, comment_id)

            Interactions.schedule_federation_task(fn ->
              Baudrate.Federation.Publisher.publish_comment_unboosted(
                user_id,
                comment,
                boost_ap_id
              )
            end)

            {:ok, :removed}
        end
    end
  end

  @doc """
  Returns a MapSet of comment IDs that the given user has boosted,
  filtered to the provided list of comment IDs.
  """
  def comment_boosts_by_user(_user_id, []), do: MapSet.new()

  def comment_boosts_by_user(user_id, comment_ids) do
    from(b in CommentBoost,
      where: b.user_id == ^user_id and b.comment_id in ^comment_ids,
      select: b.comment_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Returns a map of `%{comment_id => boost_count}` for the given comment IDs.
  """
  def comment_boost_counts([]), do: %{}

  def comment_boost_counts(comment_ids) do
    from(b in CommentBoost,
      where: b.comment_id in ^comment_ids,
      group_by: b.comment_id,
      select: {b.comment_id, count(b.id)}
    )
    |> Repo.all()
    |> Map.new()
  end
end
