defmodule Baudrate.Content.Comments do
  @moduledoc """
  Comment CRUD, listing, activity timestamp management, and discussion participant search.

  Manages comment creation (local and remote), soft-deletion, threaded
  listing with pagination, article activity timestamp updates, and
  searching remote actors who participated in article discussions.
  """

  import Ecto.Query
  alias Baudrate.Repo

  alias Baudrate.Content.{
    Article,
    Comment,
    Filters
  }

  alias Baudrate.Content.LinkPreview.Worker, as: PreviewWorker

  alias Baudrate.Content.PubSub, as: ContentPubSub

  @comments_per_page 20

  # --- Comments ---

  @doc """
  Creates a local comment on an article.

  Renders the body to HTML via `Markdown.to_html/1` and publishes a
  `Create(Note)` activity to federation.
  """
  @spec create_comment(map()) :: {:ok, %Comment{}} | {:error, Ecto.Changeset.t()}
  def create_comment(attrs) do
    body_html = Baudrate.Content.Markdown.to_html(attrs["body"] || attrs[:body] || "")

    result =
      %Comment{}
      |> Comment.changeset(Map.put(attrs, "body_html", body_html))
      |> Repo.insert()

    with {:ok, comment} <- result do
      # Stamp the local AP ID so remote replies can resolve back to this comment
      comment = stamp_local_ap_id(comment)

      touch_article_activity(comment.article_id)

      ContentPubSub.broadcast_to_article(comment.article_id, :comment_created, %{
        comment_id: comment.id
      })

      if comment.user_id do
        Baudrate.Notification.Hooks.notify_comment_created(comment)

        schedule_federation_task(fn ->
          comment = Repo.preload(comment, [:user])
          article = Repo.get!(Article, comment.article_id) |> Repo.preload([:boards, :user])
          Baudrate.Federation.Publisher.publish_comment_created(comment, article)
        end)
      end

      PreviewWorker.schedule_preview_fetch(:comment, comment.id, body_html, comment.user_id)

      {:ok, comment}
    end
  end

  @doc """
  Returns a comment changeset for form tracking.
  """
  def change_comment(comment \\ %Comment{}, attrs \\ %{}) do
    Comment.changeset(comment, attrs)
  end

  @doc """
  Creates a remote comment received via ActivityPub.
  """
  def create_remote_comment(attrs) do
    result =
      %Comment{}
      |> Comment.remote_changeset(attrs)
      |> Repo.insert()

    with {:ok, comment} <- result do
      touch_article_activity(comment.article_id)

      ContentPubSub.broadcast_to_article(comment.article_id, :comment_created, %{
        comment_id: comment.id
      })

      if comment.body_html do
        PreviewWorker.schedule_preview_fetch(:comment, comment.id, comment.body_html)
      end

      result
    end
  end

  @doc """
  Returns a comment by ID, or nil if not found.
  """
  @spec get_comment(term()) :: %Comment{} | nil
  def get_comment(id) do
    Repo.get(Comment, id)
  end

  @doc """
  Fetches a comment by its ActivityPub ID.
  """
  def get_comment_by_ap_id(ap_id) when is_binary(ap_id) do
    Repo.get_by(Comment, ap_id: ap_id)
  end

  @doc """
  Lists non-deleted comments for an article, threaded by parent.

  When `current_user` is provided, comments from blocked users and remote
  actors are filtered out.
  """
  def list_comments_for_article(article, current_user \\ nil)

  def list_comments_for_article(%Article{id: article_id}, nil) do
    from(c in Comment,
      where: c.article_id == ^article_id and is_nil(c.deleted_at),
      order_by: [asc: c.inserted_at],
      preload: [:user, :remote_actor, :link_preview]
    )
    |> Repo.all()
  end

  def list_comments_for_article(%Article{id: article_id}, current_user) do
    {hidden_uids, hidden_ap_ids} = Filters.hidden_filters(current_user)

    from(c in Comment,
      where: c.article_id == ^article_id and is_nil(c.deleted_at),
      order_by: [asc: c.inserted_at],
      preload: [:user, :remote_actor, :link_preview]
    )
    |> Filters.apply_hidden_filters(hidden_uids, hidden_ap_ids)
    |> Repo.all()
  end

  @doc """
  Returns a paginated list of comments for an article, preserving thread integrity.

  Paginates by **root comments** (those with `parent_id IS NULL`), then loads
  all descendant replies for each page of roots via iterative widening (max 5
  levels, matching the thread depth limit).

  ## Options

    * `:page` — page number (default 1)
    * `:per_page` — root comments per page (default #{@comments_per_page})

  Returns `%{comments: [...], total_roots: N, page: N, per_page: N, total_pages: N}`.
  """
  def paginate_comments_for_article(article, current_user \\ nil, opts \\ [])

  def paginate_comments_for_article(%Article{id: article_id}, current_user, opts) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, @comments_per_page)
    offset = (page - 1) * per_page

    {blocked_uids, blocked_ap_ids} = Filters.hidden_filters(current_user)

    # Count root comments
    root_count_query =
      from(c in Comment,
        where: c.article_id == ^article_id and is_nil(c.deleted_at) and is_nil(c.parent_id)
      )
      |> Filters.apply_hidden_filters(blocked_uids, blocked_ap_ids)

    total_roots = Repo.one(from(q in root_count_query, select: count(q.id)))

    # Fetch a page of root comments
    root_query =
      from(c in Comment,
        where: c.article_id == ^article_id and is_nil(c.deleted_at) and is_nil(c.parent_id),
        order_by: [asc: c.inserted_at],
        offset: ^offset,
        limit: ^per_page,
        preload: [:user, :remote_actor, :link_preview]
      )
      |> Filters.apply_hidden_filters(blocked_uids, blocked_ap_ids)

    roots = Repo.all(root_query)

    # Iteratively fetch all descendants (max 5 levels)
    descendants = fetch_descendants(article_id, roots, blocked_uids, blocked_ap_ids, 5)

    total_pages = max(ceil(total_roots / per_page), 1)

    %{
      comments: roots ++ descendants,
      total_roots: total_roots,
      page: page,
      per_page: per_page,
      total_pages: total_pages
    }
  end

  defp fetch_descendants(_article_id, [], _blocked_uids, _blocked_ap_ids, _remaining), do: []
  defp fetch_descendants(_article_id, _parents, _blocked_uids, _blocked_ap_ids, 0), do: []

  defp fetch_descendants(article_id, parents, blocked_uids, blocked_ap_ids, remaining) do
    parent_ids = Enum.map(parents, & &1.id)

    child_query =
      from(c in Comment,
        where:
          c.article_id == ^article_id and is_nil(c.deleted_at) and
            c.parent_id in ^parent_ids,
        order_by: [asc: c.inserted_at],
        preload: [:user, :remote_actor, :link_preview]
      )
      |> Filters.apply_hidden_filters(blocked_uids, blocked_ap_ids)

    children = Repo.all(child_query)

    if children == [] do
      []
    else
      children ++
        fetch_descendants(article_id, children, blocked_uids, blocked_ap_ids, remaining - 1)
    end
  end

  @doc """
  Soft-deletes a comment by setting `deleted_at` and clearing body.
  """
  @spec soft_delete_comment(%Comment{}) :: {:ok, %Comment{}} | {:error, Ecto.Changeset.t()}
  def soft_delete_comment(%Comment{} = comment) do
    result =
      comment
      |> Comment.soft_delete_changeset()
      |> Repo.update()

    with {:ok, deleted} <- result do
      recalculate_article_activity(deleted.article_id)

      ContentPubSub.broadcast_to_article(deleted.article_id, :comment_deleted, %{
        comment_id: deleted.id
      })

      # Only publish deletion for local comments (those with a user_id)
      if deleted.user_id do
        schedule_federation_task(fn ->
          deleted = Repo.preload(deleted, [:user])
          article = Repo.get!(Article, deleted.article_id) |> Repo.preload([:boards, :user])
          Baudrate.Federation.Publisher.publish_comment_deleted(deleted, article)
        end)
      end

      result
    end
  end

  @doc """
  Updates a remote comment's content.
  """
  def update_remote_comment(%Comment{} = comment, attrs) do
    comment
    |> Ecto.Changeset.cast(attrs, [:body, :body_html])
    |> Ecto.Changeset.validate_required([:body])
    |> Repo.update()
  end

  @doc """
  Returns the count of non-deleted comments for an article.
  """
  def count_comments_for_article(%Article{id: article_id}) do
    Repo.one(
      from(c in Comment,
        where: c.article_id == ^article_id and is_nil(c.deleted_at),
        select: count(c.id)
      )
    ) || 0
  end

  # --- Article Activity Timestamps ---

  @doc """
  Updates the article's `last_activity_at` to the current time.
  """
  def touch_article_activity(article_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(a in Article, where: a.id == ^article_id)
    |> Repo.update_all(set: [last_activity_at: now])
  end

  @doc """
  Recalculates the article's `last_activity_at` from the latest non-deleted comment.
  """
  def recalculate_article_activity(article_id) do
    Repo.query!(
      """
      UPDATE articles
      SET last_activity_at = COALESCE(
        (SELECT MAX(c.inserted_at) FROM comments c
         WHERE c.article_id = articles.id AND c.deleted_at IS NULL),
        articles.inserted_at
      )
      WHERE articles.id = $1
      """,
      [article_id]
    )
  end

  # Stamps a local comment with its canonical AP ID and browsable URL so that
  # remote replies (whose `inReplyTo` points here) can be resolved back to
  # this comment, and remote instances can link to the original.
  defp stamp_local_ap_id(%Comment{ap_id: nil, user_id: user_id} = comment)
       when is_integer(user_id) do
    user = Repo.get!(Baudrate.Setup.User, user_id)
    ap_id = Baudrate.Federation.actor_uri(:user, user.username) <> "#note-#{comment.id}"
    article = Repo.get!(Article, comment.article_id)
    url = "#{Baudrate.Federation.base_url()}/articles/#{article.slug}#comment-#{comment.id}"

    comment
    |> Ecto.Changeset.change(ap_id: ap_id, url: url)
    |> Repo.update!()
  end

  defp stamp_local_ap_id(comment), do: comment

  @doc """
  Searches remote actors who participated in an article's discussion thread.

  Returns remote actors who either authored the article or commented on it,
  matching the given username prefix. Excludes actors whose `actor_type` is
  not "Person". Results are deduplicated and limited.
  """
  @spec search_discussion_remote_actors(integer(), String.t(), keyword()) :: [
          Baudrate.Federation.RemoteActor.t()
        ]
  def search_discussion_remote_actors(article_id, term, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    sanitized = Repo.sanitize_like(term)

    article = Repo.get!(Article, article_id)

    # Remote actors who commented on this article
    commenter_query =
      from(ra in Baudrate.Federation.RemoteActor,
        join: c in Comment,
        on: c.remote_actor_id == ra.id,
        where:
          c.article_id == ^article_id and is_nil(c.deleted_at) and
            ra.actor_type == "Person" and
            ilike(ra.username, ^"%#{sanitized}%"),
        select: ra
      )

    # If the article itself is by a remote actor, include them
    author_query =
      if article.remote_actor_id do
        from(ra in Baudrate.Federation.RemoteActor,
          where:
            ra.id == ^article.remote_actor_id and
              ra.actor_type == "Person" and
              ilike(ra.username, ^"%#{sanitized}%"),
          select: ra
        )
      else
        nil
      end

    actors =
      if author_query do
        Repo.all(union(commenter_query, ^author_query))
      else
        Repo.all(commenter_query)
      end

    actors
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.username)
    |> Enum.take(limit)
  end

  defp schedule_federation_task(fun), do: Baudrate.Federation.schedule_federation_task(fun)
end
