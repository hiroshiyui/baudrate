defmodule Baudrate.Content.Articles do
  @moduledoc """
  Article CRUD, cross-posting, revisions, and pin/lock operations.

  Manages the full lifecycle of articles including creation (local and
  remote), editing, soft-deletion, cross-posting to boards, revision
  history, and pin/lock moderation actions.
  """

  import Ecto.Query
  alias Baudrate.Repo

  alias Baudrate.Content.{
    Article,
    ArticleRevision,
    Board,
    BoardArticle,
    Comment,
    Filters,
    Images,
    Permissions,
    Polls,
    ReadTracking,
    Tags
  }

  alias Baudrate.Content.LinkPreview.Worker, as: PreviewWorker

  alias Baudrate.Content.PubSub, as: ContentPubSub

  @per_page 20

  # --- Articles ---

  @doc """
  Returns articles in a board, pinned first, then by newest.
  """
  def list_articles_for_board(%Board{id: board_id}) do
    from(a in Article,
      join: ba in BoardArticle,
      on: ba.article_id == a.id,
      where: ba.board_id == ^board_id and is_nil(a.deleted_at),
      order_by: [desc: a.pinned, desc: a.inserted_at],
      preload: :user
    )
    |> Repo.all()
  end

  @doc """
  Returns a paginated list of articles for a board.

  ## Options

    * `:page` — page number (default 1)
    * `:per_page` — articles per page (default #{@per_page})
    * `:user` — current user for block/mute filtering (nil for guests)

  Returns `%{articles: [...], total: N, page: N, per_page: N, total_pages: N}`.
  """
  def paginate_articles_for_board(%Board{id: board_id} = board, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, @per_page)
    offset = (page - 1) * per_page
    current_user = Keyword.get(opts, :user)

    base_query =
      from(a in Article,
        join: ba in BoardArticle,
        on: ba.article_id == a.id,
        where: ba.board_id == ^board_id and is_nil(a.deleted_at)
      )
      |> Filters.apply_article_hidden_filters(current_user, board)

    total = Repo.one(from(q in base_query, select: count(q.id)))

    articles =
      from(q in base_query,
        order_by: [desc: q.pinned, desc: q.last_activity_at, desc: q.id],
        offset: ^offset,
        limit: ^per_page,
        preload: [:user, :remote_actor]
      )
      |> Repo.all()

    article_ids = Enum.map(articles, & &1.id)

    comment_counts =
      if article_ids != [] do
        from(c in Comment,
          where: c.article_id in ^article_ids and is_nil(c.deleted_at),
          group_by: c.article_id,
          select: {c.article_id, count(c.id)}
        )
        |> Repo.all()
        |> Map.new()
      else
        %{}
      end

    total_pages = max(ceil(total / per_page), 1)

    unread_ids = ReadTracking.unread_article_ids(current_user, article_ids, board_id)

    %{
      articles: articles,
      comment_counts: comment_counts,
      unread_article_ids: unread_ids,
      total: total,
      page: page,
      per_page: per_page,
      total_pages: total_pages
    }
  end

  @doc """
  Fetches an article by slug with boards and user preloaded,
  or raises `Ecto.NoResultsError`.
  """
  @spec get_article_by_slug!(String.t()) :: %Article{}
  def get_article_by_slug!(slug) do
    Article
    |> where([a], is_nil(a.deleted_at))
    |> Repo.get_by!(slug: slug)
    |> Repo.preload([:boards, :user, :remote_actor, :link_preview, poll: :options])
  end

  @doc """
  Creates an article and links it to the given board IDs in a transaction.

  ## Parameters

    * `attrs` — article attributes (title, body, slug, user_id, etc.)
    * `board_ids` — list of board IDs to place the article in
  """
  @spec create_article(map(), [term()], keyword()) ::
          {:ok, %{article: %Article{}, board_articles: non_neg_integer()}}
          | {:error, atom() | Ecto.Changeset.t()}
  def create_article(attrs, board_ids, opts \\ []) when is_list(board_ids) do
    image_ids = Keyword.get(opts, :image_ids, [])
    poll_attrs = Keyword.get(opts, :poll)

    result =
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
      |> Ecto.Multi.run(:article_images, fn _repo, %{article: article} ->
        if image_ids != [] do
          user_id = attrs["user_id"] || attrs[:user_id]
          Images.associate_article_images(article.id, image_ids, user_id)
        end

        {:ok, :done}
      end)
      |> Polls.maybe_insert_poll(poll_attrs)
      |> Repo.transaction()

    with {:ok, %{article: article} = multi_result} <- result do
      # Stamp canonical AP IDs so remote instances can reference these objects
      article = stamp_article_ap_id(article)
      multi_result = maybe_stamp_poll_ap_id(multi_result, article)

      Tags.sync_article_tags(article)

      for board_id <- board_ids do
        ContentPubSub.broadcast_to_board(board_id, :article_created, %{article_id: article.id})
      end

      if article.user_id do
        Baudrate.Notification.Hooks.notify_article_created(article)
      end

      schedule_federation_task(fn ->
        article = Repo.preload(article, [:boards, :user])
        Baudrate.Federation.Publisher.publish_article_created(article)
      end)

      body_html = Baudrate.Content.Markdown.to_html(article.body || "")
      PreviewWorker.schedule_preview_fetch(:article, article.id, body_html, article.user_id)

      {:ok, %{multi_result | article: article}}
    end
  end

  @doc """
  Returns an article changeset for form tracking.
  """
  def change_article(article \\ %Article{}, attrs \\ %{}) do
    Article.changeset(article, attrs)
  end

  @doc """
  Returns an article changeset for edit form tracking.
  """
  def change_article_for_edit(%Article{} = article, attrs \\ %{}) do
    Article.update_changeset(article, attrs)
  end

  @doc """
  Updates a local article's title and body.

  Creates a revision snapshot of the pre-edit state when an `editor` is
  provided (3-arity form). The 2-arity form is kept for backward
  compatibility (federation updates with no local editor).

  Publishes an `Update(Article)` activity to federation after success.
  """
  @spec update_article(%Article{}, map(), map() | nil) ::
          {:ok, %Article{}} | {:error, Ecto.Changeset.t()}
  def update_article(%Article{} = article, attrs) do
    update_article(article, attrs, nil)
  end

  def update_article(%Article{} = article, attrs, editor) do
    result =
      Ecto.Multi.new()
      |> maybe_snapshot_revision(article, editor)
      |> Ecto.Multi.update(:article, Article.update_changeset(article, attrs))
      |> Repo.transaction()

    with {:ok, %{article: updated_article}} <- result do
      Tags.sync_article_tags(updated_article)
      updated_article = Repo.preload(updated_article, :boards)

      for board <- updated_article.boards do
        ContentPubSub.broadcast_to_board(board.id, :article_updated, %{
          article_id: updated_article.id
        })
      end

      ContentPubSub.broadcast_to_article(updated_article.id, :article_updated, %{
        article_id: updated_article.id
      })

      if updated_article.user_id do
        schedule_federation_task(fn ->
          updated_article = Repo.preload(updated_article, [:user])
          Baudrate.Federation.Publisher.publish_article_updated(updated_article)
        end)
      end

      maybe_update_article_preview(article, updated_article)

      {:ok, updated_article}
    else
      {:error, :article, changeset, _} -> {:error, changeset}
      other -> other
    end
  end

  defp maybe_snapshot_revision(multi, _article, nil), do: multi

  defp maybe_snapshot_revision(multi, article, editor) do
    Ecto.Multi.insert(multi, :revision, fn _changes ->
      ArticleRevision.changeset(%ArticleRevision{}, %{
        title: article.title,
        body: article.body,
        article_id: article.id,
        editor_id: editor.id
      })
    end)
  end

  # --- Cross-post ---

  @doc """
  Links an existing article to an additional board.
  Used for cross-post deduplication when the same remote article
  arrives via multiple board inboxes.
  """
  def add_article_to_board(%Article{id: article_id}, board_id) do
    %BoardArticle{}
    |> BoardArticle.changeset(%{board_id: board_id, article_id: article_id})
    |> Repo.insert(on_conflict: :nothing)
  end

  @doc """
  Forwards an article to a board.

  Boardless articles can only be forwarded by the author or an admin.
  Articles already in boards can be cross-forwarded by any authenticated user,
  provided the article's `forwardable` flag is `true`.

  Returns `{:ok, article}` (silently) if the article is already in the target board,
  `{:error, :unauthorized}` if the user cannot forward a boardless article,
  `{:error, :not_forwardable}` if the article disallows forwarding,
  and `{:error, :cannot_post}` if the user cannot post in the target board.
  """
  def forward_article_to_board(%Article{} = article, %Board{} = board, user) do
    article = Permissions.ensure_boards_loaded(article)

    cond do
      # Already in target board -> silently succeed
      Enum.any?(article.boards, &(&1.id == board.id)) ->
        {:ok, article}

      # Boardless: existing author/admin-only logic
      article.boards == [] and not Permissions.can_forward_article?(user, article) ->
        {:error, :unauthorized}

      # Non-forwardable articles with boards
      article.boards != [] and not article.forwardable ->
        {:error, :not_forwardable}

      # Must be able to post in target board
      not Permissions.can_post_in_board?(board, user) ->
        {:error, :cannot_post}

      true ->
        case add_article_to_board(article, board.id) do
          {:ok, _} ->
            article = Repo.preload(article, :boards, force: true)

            ContentPubSub.broadcast_to_board(board.id, :article_created, %{
              article_id: article.id
            })

            Baudrate.Notification.Hooks.notify_article_forwarded(article, user.id)

            schedule_federation_task(fn ->
              Baudrate.Federation.Publisher.publish_article_forwarded(article, board)
            end)

            {:ok, article}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Removes an article from a specific board.

  Only the article author or an admin can remove. Deletes the `BoardArticle`
  join record linking the article to the board and broadcasts the removal.

  Returns `{:ok, updated_article}` with refreshed boards on success,
  `{:error, :unauthorized}` if the user cannot remove, and
  `{:error, :not_in_board}` if the article is not in the target board.
  """
  def remove_article_from_board(%Article{} = article, %Board{} = board, user) do
    article = Permissions.ensure_boards_loaded(article)

    cond do
      not Permissions.article_author_or_admin?(user, article) ->
        {:error, :unauthorized}

      not Enum.any?(article.boards, &(&1.id == board.id)) ->
        {:error, :not_in_board}

      true ->
        from(ba in BoardArticle,
          where: ba.article_id == ^article.id and ba.board_id == ^board.id
        )
        |> Repo.delete_all()

        article = Repo.preload(article, :boards, force: true)

        ContentPubSub.broadcast_to_board(board.id, :article_deleted, %{
          article_id: article.id
        })

        {:ok, article}
    end
  end

  # --- Remote Articles ---

  @doc """
  Creates a remote article and links it to the given board IDs in a transaction.
  """
  def create_remote_article(attrs, board_ids, opts \\ []) when is_list(board_ids) do
    poll_attrs = Keyword.get(opts, :poll)

    result =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:article, Article.remote_changeset(%Article{}, attrs))
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
      |> Polls.maybe_insert_poll(poll_attrs)
      |> Repo.transaction()

    with {:ok, %{article: article}} <- result do
      for board_id <- board_ids do
        ContentPubSub.broadcast_to_board(board_id, :article_created, %{article_id: article.id})
      end

      body_html = Baudrate.Content.Markdown.to_html(article.body || "")
      PreviewWorker.schedule_preview_fetch(:article, article.id, body_html)

      result
    end
  end

  @doc """
  Returns an article by ID, or nil if not found.
  """
  @spec get_article(term()) :: %Article{} | nil
  def get_article(id) do
    Repo.get(Article, id)
  end

  @doc """
  Fetches an article by its ActivityPub ID.
  """
  def get_article_by_ap_id(ap_id) when is_binary(ap_id) do
    Repo.get_by(Article, ap_id: ap_id)
  end

  @doc """
  Soft-deletes an article by setting `deleted_at`.
  """
  @spec soft_delete_article(%Article{}) :: {:ok, %Article{}} | {:error, Ecto.Changeset.t()}
  def soft_delete_article(%Article{} = article) do
    result =
      article
      |> Article.soft_delete_changeset()
      |> Repo.update()

    with {:ok, deleted_article} <- result do
      deleted_article = Repo.preload(deleted_article, :boards)

      for board <- deleted_article.boards do
        ContentPubSub.broadcast_to_board(board.id, :article_deleted, %{
          article_id: deleted_article.id
        })
      end

      ContentPubSub.broadcast_to_article(deleted_article.id, :article_deleted, %{
        article_id: deleted_article.id
      })

      # Only publish deletion for local articles (those with a user_id)
      if deleted_article.user_id do
        schedule_federation_task(fn ->
          deleted_article = Repo.preload(deleted_article, [:user])
          Baudrate.Federation.Publisher.publish_article_deleted(deleted_article)
        end)
      end

      result
    end
  end

  @doc """
  Updates a remote article's content.
  """
  def update_remote_article(%Article{} = article, attrs) do
    article
    |> Article.update_remote_changeset(attrs)
    |> Repo.update()
  end

  # --- Article Revisions ---

  @doc """
  Creates a revision snapshot of the article's current title and body.
  """
  def create_article_revision(%Article{} = article, editor) do
    %ArticleRevision{}
    |> ArticleRevision.changeset(%{
      title: article.title,
      body: article.body,
      article_id: article.id,
      editor_id: if(editor, do: editor.id)
    })
    |> Repo.insert()
  end

  @doc """
  Lists all revisions for an article, newest first, with editor preloaded.
  """
  def list_article_revisions(article_id) do
    from(r in ArticleRevision,
      where: r.article_id == ^article_id,
      order_by: [desc: r.inserted_at, desc: r.id],
      preload: :editor
    )
    |> Repo.all()
  end

  @doc """
  Fetches a single revision by ID with editor preloaded, or raises.
  """
  def get_article_revision!(id) do
    ArticleRevision
    |> Repo.get!(id)
    |> Repo.preload(:editor)
  end

  @doc """
  Returns the count of revisions for an article.
  """
  def count_article_revisions(article_id) do
    Repo.one(
      from(r in ArticleRevision,
        where: r.article_id == ^article_id,
        select: count(r.id)
      )
    ) || 0
  end

  # --- Pin / Lock ---

  @doc """
  Toggles the pinned status of an article.
  """
  def toggle_pin_article(%Article{} = article) do
    result =
      article
      |> Ecto.Changeset.change(pinned: !article.pinned)
      |> Repo.update()

    with {:ok, updated} <- result do
      updated = Repo.preload(updated, :boards)
      event = if updated.pinned, do: :article_pinned, else: :article_unpinned

      for board <- updated.boards do
        ContentPubSub.broadcast_to_board(board.id, event, %{article_id: updated.id})
      end

      result
    end
  end

  @doc """
  Toggles the locked status of an article.
  """
  def toggle_lock_article(%Article{} = article) do
    result =
      article
      |> Ecto.Changeset.change(locked: !article.locked)
      |> Repo.update()

    with {:ok, updated} <- result do
      updated = Repo.preload(updated, :boards)
      event = if updated.locked, do: :article_locked, else: :article_unlocked

      for board <- updated.boards do
        ContentPubSub.broadcast_to_board(board.id, event, %{article_id: updated.id})
      end

      result
    end
  end

  defp maybe_update_article_preview(old_article, updated_article) do
    alias Baudrate.Content.LinkPreview.UrlExtractor

    old_html = Baudrate.Content.Markdown.to_html(old_article.body || "")
    new_html = Baudrate.Content.Markdown.to_html(updated_article.body || "")

    old_url =
      case UrlExtractor.extract_first_url(old_html) do
        {:ok, url} -> url
        :none -> nil
      end

    new_url =
      case UrlExtractor.extract_first_url(new_html) do
        {:ok, url} -> url
        :none -> nil
      end

    if old_url != new_url do
      # Clear old preview association
      if old_article.link_preview_id do
        from(a in Article, where: a.id == ^updated_article.id)
        |> Repo.update_all(set: [link_preview_id: nil])
      end

      # Schedule new fetch if there's a new URL
      if new_url do
        PreviewWorker.schedule_preview_fetch(
          :article,
          updated_article.id,
          new_html,
          updated_article.user_id
        )
      end
    end
  end

  defp maybe_stamp_poll_ap_id(%{poll: %{ap_id: nil} = poll} = multi_result, article) do
    ap_id = (article.ap_id || Baudrate.Federation.actor_uri(:article, article.slug)) <> "#poll"

    poll =
      poll
      |> Ecto.Changeset.change(ap_id: ap_id)
      |> Repo.update!()

    %{multi_result | poll: poll}
  end

  defp maybe_stamp_poll_ap_id(multi_result, _article), do: multi_result

  defp stamp_article_ap_id(%Article{ap_id: nil, slug: slug} = article) when is_binary(slug) do
    ap_id = Baudrate.Federation.actor_uri(:article, slug)

    article
    |> Ecto.Changeset.change(ap_id: ap_id)
    |> Repo.update!()
  end

  defp stamp_article_ap_id(article), do: article

  defp schedule_federation_task(fun), do: Baudrate.Federation.schedule_federation_task(fun)
end
