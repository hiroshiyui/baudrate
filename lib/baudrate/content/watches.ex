defmodule Baudrate.Content.Watches do
  @moduledoc """
  Boards and threads a member watches, and who watches what (ADR 0070).

  ## Only the member creates a watch

  A watch is the member saying "tell me". Nothing else creates one —
  writing an article, replying, bookmarking or liking all leave this table
  alone — because a notification the reader never asked for is one designed
  to pull them back (ADR 0056, question 3). `watch_test.exs` checks it.

  ## Authorization

  The toggles take a client-supplied id, so they check at the context
  boundary (ADR 0016) that the member can see the target: a watch on a board
  or thread they cannot open would announce what arrives there. Unwatching is
  always allowed, so a board whose `min_role_to_view` was raised afterwards
  does not strand the row. A sanction does not stop watching: watching is
  reading, not interacting, so `Auth.ensure_can_interact/1` is not asked.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Content.{Article, Board, Interactions, Permissions, Watch}

  @doc """
  Watches `board_id` for `user`, or stops watching it.

  Returns `{:ok, %Watch{}}` when a watch was created, `{:ok, :removed}`, or
  `{:error, :not_found}` when the board is missing or the member cannot view
  it.
  """
  def toggle_board_watch(user, board_id) do
    case Repo.get_by(Watch, user_id: user.id, board_id: board_id) do
      %Watch{} = watch ->
        remove(watch)

      nil ->
        with %Board{} = board <- Repo.get(Board, board_id),
             true <- Permissions.can_view_board?(board, user) do
          insert(%{user_id: user.id, board_id: board.id}, user_id: user.id, board_id: board.id)
        else
          _ -> {:error, :not_found}
        end
    end
  end

  @doc """
  Watches the thread `article_id` for `user`, or stops watching it.

  Returns `{:ok, %Watch{}}`, `{:ok, :removed}`, or `{:error, :not_found}`
  when the article is missing, soft-deleted or not visible to the member.
  """
  def toggle_article_watch(user, article_id) do
    case Repo.get_by(Watch, user_id: user.id, article_id: article_id) do
      %Watch{} = watch ->
        remove(watch)

      nil ->
        with %Article{deleted_at: nil} = article <- Repo.get(Article, article_id),
             true <- Interactions.article_visible_to_user?(article.id, user.id) do
          insert(%{user_id: user.id, article_id: article.id},
            user_id: user.id,
            article_id: article.id
          )
        else
          _ -> {:error, :not_found}
        end
    end
  end

  @doc "Whether `user` watches `board_id`. Always `false` for a guest."
  def board_watched?(nil, _board_id), do: false

  def board_watched?(user, board_id),
    do: Repo.exists?(from(w in Watch, where: w.user_id == ^user.id and w.board_id == ^board_id))

  @doc "Whether `user` watches the thread `article_id`. Always `false` for a guest."
  def article_watched?(nil, _article_id), do: false

  def article_watched?(user, article_id) do
    Repo.exists?(from(w in Watch, where: w.user_id == ^user.id and w.article_id == ^article_id))
  end

  @doc """
  Lists a member's watches, newest first, with the board or article
  preloaded. A thread that has since been soft-deleted is left out; its row
  stays until the article is purged.
  """
  def list_watches(user) do
    from(w in Watch,
      left_join: a in assoc(w, :article),
      where: w.user_id == ^user.id,
      where: is_nil(w.article_id) or is_nil(a.deleted_at),
      order_by: [desc: w.inserted_at, desc: w.id],
      preload: [:board, :article]
    )
    |> Repo.all()
  end

  @doc "Removes one of `user`'s watches by id. Another member's id is a miss."
  def delete_watch(user, watch_id) do
    case Repo.get_by(Watch, id: watch_id, user_id: user.id) do
      nil -> {:error, :not_found}
      watch -> remove(watch)
    end
  end

  @doc """
  The members watching any of `board_ids`, as `{user_id, board_id}` with one
  entry per member — the board with the lowest id when they watch several.
  """
  def board_watchers([]), do: []

  def board_watchers(board_ids) do
    from(w in Watch,
      where: w.board_id in ^board_ids,
      distinct: w.user_id,
      order_by: [asc: w.user_id, asc: w.board_id],
      select: {w.user_id, w.board_id}
    )
    |> Repo.all()
  end

  @doc "The ids of the members watching the thread `article_id`."
  def watcher_ids_for_article(article_id) do
    Repo.all(from(w in Watch, where: w.article_id == ^article_id, select: w.user_id))
  end

  defp insert(attrs, lookup) do
    %Watch{}
    |> Watch.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, watch} ->
        {:ok, watch}

      # Two clicks racing: the other one won, which is the state asked for.
      {:error, changeset} ->
        if unique_error?(changeset),
          do: {:ok, Repo.get_by!(Watch, lookup)},
          else: {:error, changeset}
    end
  end

  defp unique_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :unique end)
  end

  defp remove(watch) do
    case Repo.delete(watch) do
      {:ok, _} -> {:ok, :removed}
      error -> error
    end
  end
end
