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
    CommentBoost
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
      {:ok, stamp_boost_ap_id(boost)}
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

      not article_visible_to_user?(article_id, user_id) ->
        {:error, :not_found}

      true ->
        case Repo.get_by(ArticleBoost, user_id: user_id, article_id: article_id) do
          nil ->
            case boost_article(user_id, article_id) do
              {:ok, boost} ->
                Baudrate.Notification.Hooks.notify_local_article_boosted(article_id, user_id)

                schedule_federation_task(fn ->
                  Baudrate.Federation.Publisher.publish_article_boosted(user_id, article)
                end)

                {:ok, boost}

              {:error, %Ecto.Changeset{} = cs} ->
                if has_unique_constraint_error?(cs) do
                  unboost_article(user_id, article_id)
                  {:ok, :removed}
                else
                  {:error, cs}
                end
            end

          boost ->
            boost_ap_id = boost.ap_id
            unboost_article(user_id, article_id)

            schedule_federation_task(fn ->
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
      {:ok, stamp_comment_boost_ap_id(boost)}
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

      not article_visible_to_user?(comment.article_id, user_id) ->
        {:error, :not_found}

      true ->
        case Repo.get_by(CommentBoost, user_id: user_id, comment_id: comment_id) do
          nil ->
            case boost_comment(user_id, comment_id) do
              {:ok, boost} ->
                Baudrate.Notification.Hooks.notify_local_comment_boosted(comment_id, user_id)

                schedule_federation_task(fn ->
                  Baudrate.Federation.Publisher.publish_comment_boosted(user_id, comment)
                end)

                {:ok, boost}

              {:error, %Ecto.Changeset{} = cs} ->
                if has_unique_constraint_error?(cs) do
                  unboost_comment(user_id, comment_id)
                  {:ok, :removed}
                else
                  {:error, cs}
                end
            end

          boost ->
            boost_ap_id = boost.ap_id
            unboost_comment(user_id, comment_id)

            schedule_federation_task(fn ->
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

  # --- Private helpers ---

  defp stamp_boost_ap_id(%ArticleBoost{ap_id: nil, user_id: user_id} = boost)
       when is_integer(user_id) do
    user = Repo.get!(Baudrate.Setup.User, user_id)
    ap_id = Baudrate.Federation.actor_uri(:user, user.username) <> "#announce-#{boost.id}"

    boost
    |> Ecto.Changeset.change(ap_id: ap_id)
    |> Repo.update!()
  end

  defp stamp_boost_ap_id(boost), do: boost

  defp stamp_comment_boost_ap_id(%CommentBoost{ap_id: nil, user_id: user_id} = boost)
       when is_integer(user_id) do
    user = Repo.get!(Baudrate.Setup.User, user_id)
    ap_id = Baudrate.Federation.actor_uri(:user, user.username) <> "#comment-announce-#{boost.id}"

    boost
    |> Ecto.Changeset.change(ap_id: ap_id)
    |> Repo.update!()
  end

  defp stamp_comment_boost_ap_id(boost), do: boost

  defp has_unique_constraint_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_msg, meta}} -> Keyword.get(meta, :constraint) == :unique
      _ -> false
    end)
  end

  defp schedule_federation_task(fun), do: Baudrate.Federation.schedule_federation_task(fun)

  # Returns true if the article is in at least one board the user can view.
  # Articles with no board associations (board-less quick posts) are always visible.
  defp article_visible_to_user?(article_id, user_id) do
    user = Repo.get(Baudrate.Setup.User, user_id)
    user = user && Repo.preload(user, :role)

    board_count =
      from(ba in Baudrate.Content.BoardArticle,
        where: ba.article_id == ^article_id,
        select: count()
      )
      |> Repo.one()

    # Board-less articles (quick posts) are visible to all authenticated users
    if board_count == 0 do
      true
    else
      role_name = if user, do: user.role.name, else: "guest"

      Repo.exists?(
        from(ba in Baudrate.Content.BoardArticle,
          join: b in Baudrate.Content.Board,
          on: b.id == ba.board_id,
          where:
            ba.article_id == ^article_id and
              b.min_role_to_view in ^accessible_roles(role_name)
        )
      )
    end
  end

  defp accessible_roles("admin"), do: ~w(guest user moderator admin)
  defp accessible_roles("moderator"), do: ~w(guest user moderator)
  defp accessible_roles("user"), do: ~w(guest user)
  defp accessible_roles(_), do: ~w(guest)
end
