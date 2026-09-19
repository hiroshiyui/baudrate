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
    Filters,
    Permissions
  }

  alias Baudrate.Content.LinkPreview.Worker, as: PreviewWorker

  alias Baudrate.Content.PubSub, as: ContentPubSub

  @comments_per_page 20

  # --- Comments ---

  @doc """
  Creates a local comment on an article.

  Renders the body to HTML via `Markdown.to_html/1` and publishes a
  `Create(Note)` activity to federation.

  ## Options

    * `:image_ids` — list of `CommentImage` IDs (integers) to associate with
      the comment after insertion. Only orphan images owned by the comment
      author are associated.

  Returns `{:error, :account_moved}` for a moved account (ADR 0025) and
  `{:error, :blocked}` when a block stands between the commenter and the
  author of the article or of the parent comment.
  """
  @spec create_comment(map(), keyword()) ::
          {:ok, %Comment{}} | {:error, Ecto.Changeset.t() | term()}
  def create_comment(attrs, opts \\ []) do
    attrs = attrs |> Map.new(fn {k, v} -> {to_string(k), v} end)

    # A moved, silenced or suspended account cannot comment (ADR 0029).
    with :ok <- Baudrate.Auth.ensure_can_interact(attrs["user_id"]),
         :ok <- ensure_not_blocked(attrs) do
      do_create_comment(attrs, opts)
    end
  end

  # A block between the commenter and the author of the article, or of the
  # comment being replied to, refuses the comment.
  defp ensure_not_blocked(%{"user_id" => user_id} = attrs) when is_integer(user_id) do
    targets = [
      attrs["article_id"] && Repo.get(Article, attrs["article_id"]),
      attrs["parent_id"] && Repo.get(Comment, attrs["parent_id"])
    ]

    if Enum.any?(targets, &(&1 && Baudrate.Auth.blocked_with_author?(user_id, &1))) do
      {:error, :blocked}
    else
      :ok
    end
  end

  defp ensure_not_blocked(_attrs), do: :ok

  defp do_create_comment(attrs, opts) do
    body_html = Baudrate.Content.Markdown.to_html(attrs["body"] || "")
    image_ids = Keyword.get(opts, :image_ids, [])

    multi_result =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(
        :comment,
        Comment.changeset(%Comment{}, Map.put(attrs, "body_html", body_html))
      )
      |> Ecto.Multi.update(:comment_with_ap_id, &comment_ap_id_changeset(&1.comment))
      # Images are attached before publishing, since the Note carries them.
      |> Ecto.Multi.run(:images, fn _repo, %{comment_with_ap_id: comment} ->
        if image_ids != [] and comment.user_id do
          Baudrate.Content.Images.associate_comment_images(comment.id, image_ids, comment.user_id)
        end

        {:ok, :done}
      end)
      # The Create(Note) jobs commit with the comment (Phase 2C).
      |> Ecto.Multi.run(:federation, fn _repo, %{comment_with_ap_id: comment} ->
        if comment.user_id do
          comment = Repo.preload(comment, [:user, :images])
          article = Repo.get!(Article, comment.article_id) |> Repo.preload([:boards, :user])
          Baudrate.Federation.Publisher.publish_comment_created(comment, article)
        end

        {:ok, :enqueued}
      end)
      |> Repo.transaction()

    with {:ok, %{comment_with_ap_id: comment}} <- multi_result |> flatten_create_comment_result() do
      touch_article_activity(comment.article_id)

      ContentPubSub.broadcast_to_article(comment.article_id, :comment_created, %{
        comment_id: comment.id
      })

      if comment.user_id do
        Baudrate.Notification.Hooks.notify_comment_created(comment)
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
      # Only servable comments bump the article. Board listings order by
      # `last_activity_at`, so a hidden remote reply moved a public article to
      # the top of a public page for no reason a viewer could see — an
      # existence signal, and attacker-controlled ordering.
      if comment.visibility in ["public", "unlisted"] do
        touch_article_activity(comment.article_id)
      end

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
      order_by: [asc: c.inserted_at, asc: c.id],
      preload: [:user, :remote_actor, :link_preview, :images]
    )
    |> exclude_unservable_remote()
    |> Repo.all()
  end

  def list_comments_for_article(%Article{id: article_id}, current_user) do
    {hidden_uids, hidden_ap_ids} = Filters.hidden_filters(current_user)

    from(c in Comment,
      where: c.article_id == ^article_id and is_nil(c.deleted_at),
      order_by: [asc: c.inserted_at, asc: c.id],
      preload: [:user, :remote_actor, :link_preview, :images]
    )
    |> exclude_unservable_remote()
    |> Filters.apply_hidden_filters(hidden_uids, hidden_ap_ids)
    |> Repo.all()
  end

  # Article pages and the AP replies collection are public surfaces. A remote
  # comment ingested as followers-only/direct (rows that predate the inbox
  # refusing them) must not be shown there. Local comments are board content
  # and are always listed.
  defp exclude_unservable_remote(query), do: Filters.exclude_unservable_remote(query)

  @doc """
  Returns a paginated list of comments for an article, preserving thread integrity.

  Paginates by **root comments** (those with `parent_id IS NULL`), then loads
  all descendant replies for each page of roots via iterative widening (max 5
  levels, matching the thread depth limit).

  A soft-deleted comment is included (with its `deleted_at` set) only when a
  visible reply sits somewhere below it, so the page can render a placeholder
  and keep that reply in its thread. Deleted comments with no visible replies
  are left out.

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
    placeholder_ids = deleted_ancestor_ids(article_id, blocked_uids, blocked_ap_ids)

    # Count root comments
    root_count_query =
      from(c in Comment,
        where: c.article_id == ^article_id and is_nil(c.parent_id),
        where: is_nil(c.deleted_at) or c.id in ^placeholder_ids
      )
      |> exclude_unservable_remote()
      |> Filters.apply_hidden_filters(blocked_uids, blocked_ap_ids)

    total_roots = Repo.one(from(q in root_count_query, select: count(q.id)))

    # Fetch a page of root comments
    root_query =
      from(c in Comment,
        where: c.article_id == ^article_id and is_nil(c.parent_id),
        where: is_nil(c.deleted_at) or c.id in ^placeholder_ids,
        order_by: [asc: c.inserted_at, asc: c.id],
        offset: ^offset,
        limit: ^per_page,
        preload: [:user, :remote_actor, :link_preview, :images]
      )
      |> exclude_unservable_remote()
      |> Filters.apply_hidden_filters(blocked_uids, blocked_ap_ids)

    roots = Repo.all(root_query)

    # Iteratively fetch all descendants (max 5 levels)
    descendants =
      fetch_descendants(article_id, roots, {blocked_uids, blocked_ap_ids, placeholder_ids}, 5)

    total_pages = max(ceil(total_roots / per_page), 1)

    %{
      comments: roots ++ descendants,
      total_roots: total_roots,
      page: page,
      per_page: per_page,
      total_pages: total_pages
    }
  end

  defp fetch_descendants(_article_id, [], _filters, _remaining), do: []
  defp fetch_descendants(_article_id, _parents, _filters, 0), do: []

  defp fetch_descendants(article_id, parents, filters, remaining) do
    {blocked_uids, blocked_ap_ids, placeholder_ids} = filters
    parent_ids = Enum.map(parents, & &1.id)

    child_query =
      from(c in Comment,
        where: c.article_id == ^article_id and c.parent_id in ^parent_ids,
        where: is_nil(c.deleted_at) or c.id in ^placeholder_ids,
        order_by: [asc: c.inserted_at, asc: c.id],
        preload: [:user, :remote_actor, :link_preview, :images]
      )
      |> exclude_unservable_remote()
      |> Filters.apply_hidden_filters(blocked_uids, blocked_ap_ids)

    children = Repo.all(child_query)

    if children == [] do
      []
    else
      children ++ fetch_descendants(article_id, children, filters, remaining - 1)
    end
  end

  # Ids of soft-deleted comments that have a visible (not deleted, not hidden
  # from this viewer) reply somewhere below them. Only ids and parent ids are
  # loaded, so this stays cheap for long threads.
  defp deleted_ancestor_ids(article_id, blocked_uids, blocked_ap_ids) do
    deleted_parents =
      from(c in Comment,
        where: c.article_id == ^article_id and not is_nil(c.deleted_at),
        select: {c.id, c.parent_id}
      )
      |> Repo.all()
      |> Map.new()

    if deleted_parents == %{} do
      []
    else
      live_parents =
        from(c in Comment,
          where: c.article_id == ^article_id and is_nil(c.deleted_at),
          select: {c.id, c.parent_id}
        )
        |> exclude_unservable_remote()
        |> Filters.apply_hidden_filters(blocked_uids, blocked_ap_ids)
        |> Repo.all()

      parents = Map.merge(deleted_parents, Map.new(live_parents))

      live_parents
      |> Enum.reduce(MapSet.new(), fn {_id, parent_id}, acc ->
        collect_deleted_ancestors(parent_id, parents, deleted_parents, acc)
      end)
      |> MapSet.to_list()
    end
  end

  defp collect_deleted_ancestors(nil, _parents, _deleted, acc), do: acc

  defp collect_deleted_ancestors(id, parents, deleted, acc) do
    cond do
      MapSet.member?(acc, id) ->
        acc

      Map.has_key?(deleted, id) ->
        collect_deleted_ancestors(Map.get(parents, id), parents, deleted, MapSet.put(acc, id))

      true ->
        collect_deleted_ancestors(Map.get(parents, id), parents, deleted, acc)
    end
  end

  @doc """
  Soft-deletes a comment by setting `deleted_at` and clearing body.

  The row is removed for good 90 days later (`Baudrate.Retention`, ADR 0040),
  or with its article, unless a report points at it.
  """
  @spec soft_delete_comment(%Comment{}) :: {:ok, %Comment{}} | {:error, Ecto.Changeset.t()}
  def soft_delete_comment(%Comment{} = comment, opts \\ []) do
    with :ok <- authorize_delete(comment, opts) do
      do_soft_delete_comment(comment, opts)
    end
  end

  # As for articles (ADR 0016): a local deletion names its actor and is
  # re-checked here against freshly loaded state; a remote one is authorized by
  # the inbox and says `remote: true`. The article is loaded because the rule
  # for a comment is the rule for the article it is on (P1-D5).
  defp authorize_delete(comment, opts) do
    if Keyword.get(opts, :remote, false) do
      :ok
    else
      case Repo.get(Article, comment.article_id) do
        nil ->
          {:error, :unauthorized}

        article ->
          Permissions.authorize_delete_comment(Keyword.get(opts, :deleted_by), comment, article)
      end
    end
  end

  defp do_soft_delete_comment(%Comment{} = comment, opts) do
    result =
      Baudrate.Federation.federate(
        fn ->
          comment
          |> Comment.soft_delete_changeset(Keyword.get(opts, :deleted_by))
          |> Repo.update()
        end,
        fn deleted ->
          # Only local comments (those with a user_id) publish their deletion.
          if deleted.user_id do
            deleted = Repo.preload(deleted, [:user])
            article = Repo.get!(Article, deleted.article_id) |> Repo.preload([:boards, :user])
            Baudrate.Federation.Publisher.publish_comment_deleted(deleted, article)
          end
        end
      )

    with {:ok, deleted} <- result do
      recalculate_article_activity(deleted.article_id)

      ContentPubSub.broadcast_to_article(deleted.article_id, :comment_deleted, %{
        comment_id: deleted.id
      })

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
    # Filtered like the listings. Both callers are public — the AP `Article`
    # object and the JSON-LD block on the article page — so counting a hidden
    # `followers_only` remote reply told a guest it existed, and let them
    # count them.
    Repo.one(
      from(c in Comment,
        where: c.article_id == ^article_id and is_nil(c.deleted_at),
        select: count(c.id)
      )
      |> Filters.exclude_unservable_remote()
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

  # Builds an Ecto changeset that stamps the comment's canonical AP ID and
  # human-readable URL inside the same transaction that inserts the comment.
  # Idempotent: returns an unchanged changeset when the ap_id is already set
  # (defensive — reserved for backfill / mirrored rows). When the author or
  # parent article cannot be loaded the comment is returned untouched, so
  # callers see the same `:ok` they did before AP-ID stamping became
  # transactional.
  defp comment_ap_id_changeset(%Comment{ap_id: ap_id} = comment)
       when is_binary(ap_id) and ap_id != "",
       do: Ecto.Changeset.change(comment)

  defp comment_ap_id_changeset(%Comment{user_id: user_id} = comment)
       when is_integer(user_id) do
    with %{} = user <- Repo.get(Baudrate.Setup.User, user_id),
         %{} = article <- Repo.get(Article, comment.article_id) do
      ap_id = Baudrate.Federation.actor_uri(:user, user.username) <> "#note-#{comment.id}"
      url = "#{Baudrate.Federation.base_url()}/articles/#{article.slug}#comment-#{comment.id}"

      Ecto.Changeset.change(comment, ap_id: ap_id, url: url)
    else
      _ -> Ecto.Changeset.change(comment)
    end
  end

  defp comment_ap_id_changeset(%Comment{} = comment), do: Ecto.Changeset.change(comment)

  # Normalises `Repo.transaction/1` output so the surrounding `with` clause
  # keeps its pre-Multi `{:ok, comment} | {:error, changeset}` shape.
  defp flatten_create_comment_result({:ok, _} = ok), do: ok

  defp flatten_create_comment_result({:error, _step, %Ecto.Changeset{} = changeset, _changes}),
    do: {:error, changeset}

  defp flatten_create_comment_result({:error, _step, reason, _changes}), do: {:error, reason}

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
end
