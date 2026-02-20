defmodule Baudrate.Content do
  @moduledoc """
  The Content context manages boards and articles.

  Boards are organized hierarchically via `parent_id`. Articles can be
  cross-posted to multiple boards through the `board_articles` join table.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Content.{Article, Board, BoardArticle, BoardModerator}

  # --- Boards ---

  @doc """
  Returns top-level boards (no parent), ordered by position.
  """
  def list_top_boards do
    from(b in Board, where: is_nil(b.parent_id), order_by: b.position)
    |> Repo.all()
  end

  @doc """
  Returns child boards of the given board, ordered by position.
  """
  def list_sub_boards(%Board{id: board_id}) do
    from(b in Board, where: b.parent_id == ^board_id, order_by: b.position)
    |> Repo.all()
  end

  @doc """
  Fetches a board by slug or raises `Ecto.NoResultsError`.
  """
  def get_board_by_slug!(slug) do
    Repo.get_by!(Board, slug: slug)
  end

  # --- Articles ---

  @doc """
  Returns articles in a board, pinned first, then by newest.
  """
  def list_articles_for_board(%Board{id: board_id}) do
    from(a in Article,
      join: ba in BoardArticle,
      on: ba.article_id == a.id,
      where: ba.board_id == ^board_id,
      order_by: [desc: a.pinned, desc: a.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Fetches an article by slug with boards and user preloaded,
  or raises `Ecto.NoResultsError`.
  """
  def get_article_by_slug!(slug) do
    Article
    |> Repo.get_by!(slug: slug)
    |> Repo.preload([:boards, :user])
  end

  @doc """
  Creates an article and links it to the given board IDs in a transaction.

  ## Parameters

    * `attrs` — article attributes (title, body, slug, user_id, etc.)
    * `board_ids` — list of board IDs to place the article in
  """
  def create_article(attrs, board_ids) when is_list(board_ids) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:article, Article.changeset(%Article{}, attrs))
    |> Ecto.Multi.run(:board_articles, fn repo, %{article: article} ->
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      entries =
        Enum.map(board_ids, fn board_id ->
          %{board_id: board_id, article_id: article.id, inserted_at: now, updated_at: now}
        end)

      {count, _} = repo.insert_all(BoardArticle, entries)

      if count == length(board_ids) do
        {:ok, count}
      else
        {:error, :board_articles_insert_mismatch}
      end
    end)
    |> Repo.transaction()
  end

  @doc """
  Returns an article changeset for form tracking.
  """
  def change_article(article \\ %Article{}, attrs \\ %{}) do
    Article.changeset(article, attrs)
  end

  # --- SysOp Board ---

  @doc """
  Creates the predefined SysOp board and assigns the given user as its moderator.

  Returns `{:ok, board}` on success.
  """
  def seed_sysop_board(%{id: user_id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    board_changeset =
      Board.changeset(%Board{}, %{
        name: "SysOp",
        slug: "sysop",
        description: "System Operations",
        position: 0
      })

    with {:ok, board} <- Repo.insert(board_changeset) do
      Repo.insert!(%BoardModerator{
        board_id: board.id,
        user_id: user_id,
        inserted_at: now,
        updated_at: now
      })

      {:ok, board}
    end
  end
end
