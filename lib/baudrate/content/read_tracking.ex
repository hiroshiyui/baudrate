defmodule Baudrate.Content.ReadTracking do
  @moduledoc """
  Read tracking for articles and boards.

  Tracks per-user read state for articles and boards, supporting
  unread indicators in the UI.
  """

  import Ecto.Query
  alias Baudrate.Repo

  alias Baudrate.Content.{
    Article,
    ArticleRead,
    BoardArticle,
    BoardCache,
    BoardRead
  }

  # UTC epoch used as default when no read record exists
  @epoch ~U[1970-01-01 00:00:00Z]

  @doc """
  Records that a user has read an article at the current time.

  Upserts the `article_reads` row so repeated visits update `read_at`.
  """
  def mark_article_read(user_id, article_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %ArticleRead{}
    |> ArticleRead.changeset(%{user_id: user_id, article_id: article_id, read_at: now})
    |> Repo.insert(
      on_conflict: [set: [read_at: now]],
      conflict_target: [:user_id, :article_id]
    )
  end

  @doc """
  Records that a user has marked all articles in a board as read.

  Sets the board-level floor timestamp so any article with
  `last_activity_at <= read_at` is considered read.
  """
  def mark_board_read(user_id, board_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %BoardRead{}
    |> BoardRead.changeset(%{user_id: user_id, board_id: board_id, read_at: now})
    |> Repo.insert(
      on_conflict: [set: [read_at: now]],
      conflict_target: [:user_id, :board_id]
    )
  end

  @doc """
  Returns a `MapSet` of article IDs (from the given list) that are unread
  for the user.

  An article is unread when its `last_activity_at` is strictly greater than
  `GREATEST(article_read.read_at, board_read.read_at, user.inserted_at)`.

  Returns `MapSet.new()` when the user is `nil` (guest).
  """
  def unread_article_ids(nil, _article_ids, _board_id), do: MapSet.new()
  def unread_article_ids(_user, [], _board_id), do: MapSet.new()

  def unread_article_ids(%{id: user_id, inserted_at: user_registered_at}, article_ids, board_id) do
    # Get the board-level floor (mark-all-as-read timestamp)
    board_floor =
      from(br in BoardRead,
        where: br.user_id == ^user_id and br.board_id == ^board_id,
        select: br.read_at
      )
      |> Repo.one()

    # The baseline is the latest of board_floor and user registration time
    baseline = latest_datetime(board_floor, user_registered_at)

    from(a in Article,
      left_join: ar in ArticleRead,
      on: ar.article_id == a.id and ar.user_id == ^user_id,
      where: a.id in ^article_ids,
      where:
        a.last_activity_at >
          fragment(
            "GREATEST(?, ?)",
            coalesce(ar.read_at, ^@epoch),
            ^baseline
          ),
      select: a.id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Returns a `MapSet` of board IDs (from the given list) that contain at
  least one unread article for the user.

  Returns `MapSet.new()` when the user is `nil` (guest).
  """
  def unread_board_ids(nil, _board_ids), do: MapSet.new()
  def unread_board_ids(_user, []), do: MapSet.new()

  def unread_board_ids(%{id: user_id, inserted_at: user_registered_at} = _user, board_ids) do
    # Build map of each input board -> all descendant board IDs (including itself)
    descendants = descendant_board_ids_map(board_ids)
    all_desc_ids = descendants |> Map.values() |> List.flatten() |> Enum.uniq()

    # Single batch query: find all descendant board IDs that have >=1 unread article.
    # Joins BoardRead inline so each board's floor is computed per-row, replacing
    # the previous N×M individual queries with a single query.
    unread_desc_ids =
      from(a in Article,
        join: ba in BoardArticle,
        on: ba.article_id == a.id,
        left_join: ar in ArticleRead,
        on: ar.article_id == a.id and ar.user_id == ^user_id,
        left_join: br in BoardRead,
        on: br.board_id == ba.board_id and br.user_id == ^user_id,
        where: ba.board_id in ^all_desc_ids and is_nil(a.deleted_at),
        where:
          a.last_activity_at >
            fragment(
              "GREATEST(?, ?, ?)",
              coalesce(ar.read_at, ^@epoch),
              coalesce(br.read_at, ^@epoch),
              ^user_registered_at
            ),
        distinct: true,
        select: ba.board_id
      )
      |> Repo.all()
      |> MapSet.new()

    # Map back: a root board is unread if any of its descendants is in the unread set
    board_ids
    |> Enum.filter(fn board_id ->
      desc_ids = Map.get(descendants, board_id, [board_id])
      Enum.any?(desc_ids, fn desc_id -> MapSet.member?(unread_desc_ids, desc_id) end)
    end)
    |> MapSet.new()
  end

  # Returns a map: %{board_id => [board_id | descendant_ids]}
  # When cache is enabled, reads pre-computed descendants from ETS.
  # Otherwise, uses a recursive CTE to find all descendants.
  defp descendant_board_ids_map([]), do: %{}

  defp descendant_board_ids_map(board_ids) do
    if board_cache_enabled?() do
      Map.new(board_ids, fn id -> {id, BoardCache.descendant_ids(id)} end)
    else
      result =
        Repo.query!(
          """
          WITH RECURSIVE tree AS (
            SELECT id, id AS root_id FROM boards WHERE id = ANY($1)
            UNION ALL
            SELECT b.id, t.root_id FROM boards b JOIN tree t ON b.parent_id = t.id
          )
          SELECT root_id, array_agg(id) FROM tree GROUP BY root_id
          """,
          [board_ids]
        )

      Map.new(result.rows, fn [root_id, ids] -> {root_id, ids} end)
    end
  end

  defp latest_datetime(nil, b), do: b
  defp latest_datetime(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  defp board_cache_enabled? do
    Application.get_env(:baudrate, :settings_cache_enabled, true)
  end
end
