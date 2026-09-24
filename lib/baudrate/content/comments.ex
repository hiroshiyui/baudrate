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
    CommentRevision,
    Filters,
    Permissions
  }

  alias Baudrate.Content.LinkPreview.Worker, as: PreviewWorker

  alias Baudrate.Content.PubSub, as: ContentPubSub
  alias Baudrate.Moderation.{ContentFilters, HeldPosts}

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

  Returns the sanction gate's refusals for an account that may not act
  (ADR 0029), `{:error, :blocked}` when a block stands between the commenter
  and the author of the article or of the parent comment,
  `{:error, :content_filtered}` when a content filter refuses it (ADR 0065),
  and `Baudrate.Auth.Trust`'s refusals for a new account over its limits
  (ADR 0064). A filter set to `hold` flags the comment instead, since only
  `submit_comment/2` can hold.
  """
  @spec create_comment(map(), keyword()) ::
          {:ok, %Comment{}} | {:error, Ecto.Changeset.t() | term()}
  def create_comment(attrs, opts \\ []) do
    attrs = attrs |> Map.new(fn {k, v} -> {to_string(k), v} end)

    if Keyword.has_key?(opts, :held_post) do
      # A held comment a moderator approved (ADR 0065): it passed the filters
      # and the limits when it was submitted, but whether the author may act,
      # and whether a block now stands between them, can have changed.
      with :ok <- Baudrate.Auth.ensure_can_interact(attrs["user_id"]),
           :ok <- ensure_not_blocked(attrs) do
        do_create_comment(attrs, opts)
      end
    else
      gate_and_create_comment(attrs, opts)
    end
  end

  @doc """
  Creates a comment from the article page's composer, or holds it for a
  moderator (ADR 0065).

  The same as `create_comment/2`, except that a comment that is one of a new
  account's first (`hold_first_posts`), or that a `hold` filter matched, is
  held rather than published, and `{:held, %HeldPost{}}` is returned. A
  LiveView never calls `create_comment/2` itself —
  `test/baudrate/content/submit_path_test.exs` fails the build otherwise.
  """
  @spec submit_comment(map(), keyword()) ::
          {:ok, %Comment{}}
          | {:held, Baudrate.Moderation.HeldPost.t()}
          | {:error, Ecto.Changeset.t() | term()}
  def submit_comment(attrs, opts \\ []) do
    attrs = attrs |> Map.new(fn {k, v} -> {to_string(k), v} end)

    gate_and_create_comment(
      attrs,
      opts |> Keyword.delete(:held_post) |> Keyword.put(:holdable, true)
    )
  end

  # A moved, silenced or suspended account cannot comment (ADR 0029), a
  # filter may refuse, hold or flag what it wrote (ADR 0065), and a new
  # account is held to the limits on new accounts (ADR 0064) — the filter
  # first, so a refused comment spends no place in the hourly bucket.
  defp gate_and_create_comment(attrs, opts) do
    holdable = Keyword.get(opts, :holdable, false)
    author_id = attrs["user_id"]

    with :ok <- Baudrate.Auth.ensure_can_interact(author_id),
         :ok <- ensure_not_blocked(attrs),
         verdict = screen_comment(attrs, opts, if(holdable, do: :post, else: :publish)),
         :ok <- ContentFilters.refuse_blocked(verdict),
         :ok <- check_new_account_limits(attrs, opts) do
      ContentFilters.record(verdict)

      case hold_reason(holdable, author_id, verdict) do
        nil ->
          attrs
          |> do_create_comment(Keyword.delete(opts, :holdable))
          |> tap(fn
            {:ok, comment} -> ContentFilters.flag(verdict, %{comment_id: comment.id})
            _ -> :ok
          end)

        {reason, filter} ->
          HeldPosts.hold_comment(attrs, opts, reason, filter)
          |> case do
            {:ok, held} -> {:held, held}
            {:error, _} = error -> error
          end
      end
    end
  end

  # The uploads' descriptions are published with the comment, so they are
  # screened with it.
  defp screen_comment(attrs, opts, mode) do
    ContentFilters.screen(
      %{
        summary: attrs["summary"],
        body: attrs["body"],
        extra: fn ->
          Baudrate.Content.Images.comment_image_alts(
            Keyword.get(opts, :image_ids, []),
            attrs["user_id"]
          )
        end
      },
      mode: mode,
      target_type: "comment",
      user_id: attrs["user_id"]
    )
  end

  defp hold_reason(false, _author_id, _verdict), do: nil
  defp hold_reason(true, _author_id, %{outcome: :hold, filter: filter}), do: {"filter", filter}

  defp hold_reason(true, author_id, verdict) do
    if HeldPosts.first_post?(author_id),
      do: {"first_posts", if(verdict.outcome == :flag, do: verdict.filter)}
  end

  # Association only ever takes the commenter's own orphan uploads, so the
  # deduplicated ids asked for are an upper bound on what will be attached.
  defp check_new_account_limits(attrs, opts) do
    image_count = opts |> Keyword.get(:image_ids, []) |> Enum.uniq() |> length()
    Baudrate.Auth.check_post(attrs["user_id"], attrs["body"], image_count)
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

    # Before the transaction, and only for a thread that can leave (ADR 0051).
    # A comment inherits its article's reach, so the gate is the article's.
    warm_comment_mentions(attrs)

    multi_result =
      Ecto.Multi.new()
      |> claim_held_post(Keyword.get(opts, :held_post))
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

      # After the direct notices, so a watcher already told as the author,
      # the replied-to or a mention is not told again (ADR 0070).
      Baudrate.Notification.Hooks.notify_thread_watchers(comment)

      PreviewWorker.schedule_preview_fetch(:comment, comment.id, body_html, comment.user_id)

      {:ok, comment}
    end
  end

  # Approving a held comment deletes its row in the transaction that
  # publishes it, so a second approval rolls back instead of posting twice.
  defp claim_held_post(multi, nil), do: multi

  defp claim_held_post(multi, held),
    do: Ecto.Multi.run(multi, :claim_held_post, fn repo, _ -> HeldPosts.claim(repo, held) end)

  @doc """
  Returns a comment changeset for form tracking.
  """
  def change_comment(comment \\ %Comment{}, attrs \\ %{}) do
    Comment.changeset(comment, attrs)
  end

  @doc """
  Edits a local comment, snapshotting what it replaced and publishing an
  `Update(Note)` (ADR 0060).

  The author alone may edit — `Permissions.authorize_edit_comment/2`, checked
  **here** rather than only in the LiveView. Comments already authorize
  deletion at this boundary, and the one pre-existing comment update path
  (`update_remote_comment/2`) authorizes nothing at all because its single
  caller has already matched the signing actor; a local edit must not inherit
  that.

  Only `body` and the content warning are editable, taken by allow-list
  (ADR 0049). `visibility` is deliberately not: a comment that has already
  federated as public does not become unlisted by being relabelled here, so
  offering the control would promise something it cannot do. `article_id`,
  `parent_id` and `user_id` are not re-castable at all — an edit that could
  move a comment into another thread is not an edit.

  Returns `{:error, :unauthorized}` for anyone but the author,
  `{:error, :not_found}` for a soft-deleted comment, the sanction gate's own
  refusals (ADR 0029) for an account that may not act, and
  `Baudrate.Auth.Trust`'s for a new account adding a link or an image past its
  limit (ADR 0064).
  """
  @spec update_comment(%Comment{}, map(), map()) ::
          {:ok, %Comment{}} | {:error, Ecto.Changeset.t() | term()}
  def update_comment(%Comment{} = comment, attrs, editor) do
    with :ok <- Permissions.authorize_edit_comment(editor, comment),
         :ok <- Baudrate.Auth.ensure_can_interact(editor),
         :ok <- ensure_editable(comment),
         verdict = screen_edit(comment, attrs, editor),
         :ok <- ContentFilters.refuse_blocked(verdict),
         :ok <- check_edit_limits(comment, attrs, editor) do
      ContentFilters.record(verdict)

      comment
      |> do_update_comment(attrs, editor)
      |> tap(fn
        {:ok, updated} -> ContentFilters.flag(verdict, %{comment_id: updated.id})
        _ -> :ok
      end)
    end
  end

  # An edit is judged by what it adds (ADR 0065), as the limits on new
  # accounts judge it (ADR 0064).
  defp screen_edit(comment, attrs, editor) do
    ContentFilters.screen(
      %{
        summary: Map.get(attrs, :summary, Map.get(attrs, "summary", comment.summary)),
        body: attrs[:body] || attrs["body"] || comment.body
      },
      mode: :edit,
      previous: %{summary: comment.summary, body: comment.body},
      target_type: "comment",
      user_id: editor.id
    )
  end

  # An edit may not add a link or an image past a new account's limit
  # (ADR 0064). Images are not editable, so only the body can add one.
  defp check_edit_limits(comment, attrs, editor) do
    images = Baudrate.Content.Images.count_comment_images(comment.id)
    body = attrs[:body] || attrs["body"] || comment.body

    Baudrate.Auth.check_post(editor, body, images, previous: {comment.body, images})
  end

  # Editing a withdrawn comment would republish it: `soft_delete_changeset/2`
  # overwrites the body with a placeholder, so the edit form would offer that
  # placeholder for editing and the `Update` would resurrect the row on every
  # peer that honoured the `Delete`.
  defp ensure_editable(%Comment{deleted_at: nil}), do: :ok
  defp ensure_editable(%Comment{}), do: {:error, :not_found}

  defp do_update_comment(comment, attrs, editor) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.take(~w(body summary sensitive))

    # `body_html` is re-rendered only when a body was actually supplied.
    # Deriving it from `attrs["body"] || ""` would blank the rendered comment
    # for a caller that edits the content warning alone — the changeset would
    # still pass, because `validate_required(:body)` sees the existing value
    # on the struct.
    body = attrs["body"]

    attrs =
      case body do
        nil -> attrs
        body -> Map.put(attrs, "body_html", Baudrate.Content.Markdown.to_html(body))
      end

    # An edit can add a handle nobody here has resolved, so the same
    # before-the-transaction warming applies as on create (ADR 0051): an HTTP
    # call inside a transaction holds a DB connection for someone else's
    # timeout.
    warm_comment_mentions(%{
      "article_id" => comment.article_id,
      "body" => body,
      "user_id" => comment.user_id
    })

    result =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:revision, fn _changes ->
        CommentRevision.changeset(%CommentRevision{}, %{
          body: comment.body,
          summary: comment.summary,
          sensitive: comment.sensitive,
          comment_id: comment.id,
          editor_id: editor.id
        })
      end)
      |> Ecto.Multi.update(:comment, Comment.changeset(comment, attrs))
      # The Update(Note) jobs commit with the edit (ADR 0034).
      |> Ecto.Multi.run(:federation, fn _repo, %{comment: updated} ->
        if updated.user_id do
          updated = Repo.preload(updated, [:user, :images])
          article = Repo.get!(Article, updated.article_id) |> Repo.preload([:boards, :user])
          Baudrate.Federation.Publisher.publish_comment_updated(updated, article)
        end

        {:ok, :enqueued}
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{comment: updated}} ->
        ContentPubSub.broadcast_to_article(updated.article_id, :comment_updated, %{
          comment_id: updated.id
        })

        maybe_update_comment_preview(comment, updated)

        {:ok, updated}

      {:error, :comment, changeset, _changes} ->
        {:error, changeset}

      {:error, :revision, changeset, _changes} ->
        {:error, changeset}

      other ->
        other
    end
  end

  # The article-side twin of this lives in `Articles`; both exist because a
  # preview is fetched from the *first* URL in the body, so an edit that
  # changes which URL that is has to drop the old card rather than leave a
  # preview of a link the comment no longer contains.
  defp maybe_update_comment_preview(old_comment, updated_comment) do
    alias Baudrate.Content.LinkPreview.UrlExtractor

    first_url = fn body ->
      case body |> Baudrate.Content.Markdown.to_html() |> UrlExtractor.extract_first_url() do
        {:ok, url} -> url
        :none -> nil
      end
    end

    old_url = first_url.(old_comment.body || "")
    new_url = first_url.(updated_comment.body || "")

    if old_url != new_url do
      if old_comment.link_preview_id do
        from(c in Comment, where: c.id == ^updated_comment.id)
        |> Repo.update_all(set: [link_preview_id: nil])
      end

      if new_url do
        PreviewWorker.schedule_preview_fetch(
          :comment,
          updated_comment.id,
          Baudrate.Content.Markdown.to_html(updated_comment.body || ""),
          updated_comment.user_id
        )
      end
    end
  end

  # --- Comment Revisions ---

  @doc """
  Lists a comment's revisions, newest first, with each editor preloaded.

  Ordered `desc: inserted_at, desc: id` — the id tiebreaker matters because
  two edits inside the same second are ordinary, and without it the history
  page could show them in either order between renders.
  """
  @spec list_comment_revisions(integer()) :: [%CommentRevision{}]
  def list_comment_revisions(comment_id) do
    from(r in CommentRevision,
      where: r.comment_id == ^comment_id,
      order_by: [desc: r.inserted_at, desc: r.id],
      preload: :editor
    )
    |> Repo.all()
  end

  @doc """
  Whether a comment has ever been edited — the fact, not a proxy for it.

  `updated_at` answers "when did this row last change", which is a different
  question: any housekeeping write moves it. The v1.31.0 `ap_id` backfill did
  exactly that months after the fact, so a comment nobody had touched since
  March reported an edit in September, and the federated object said "edited"
  while the site's own history page said it had not been. A revision row is
  written by `update_comment/3` and by nothing else, so this cannot drift.
  """
  @spec comment_edited?(%Comment{} | integer()) :: boolean()
  def comment_edited?(%Comment{id: id}), do: comment_edited?(id)

  def comment_edited?(comment_id) when is_integer(comment_id) do
    Repo.exists?(from(r in CommentRevision, where: r.comment_id == ^comment_id))
  end

  def comment_edited?(_), do: false

  @doc "Counts a comment's revisions, for the 'edited' marker."
  @spec count_comment_revisions(integer()) :: non_neg_integer()
  def count_comment_revisions(comment_id) do
    Repo.one(from(r in CommentRevision, where: r.comment_id == ^comment_id, select: count(r.id))) ||
      0
  end

  @doc "Counts revisions for many comments at once, as a `%{comment_id => count}` map."
  @spec count_comment_revisions_for(list(integer())) :: %{integer() => non_neg_integer()}
  def count_comment_revisions_for([]), do: %{}

  def count_comment_revisions_for(comment_ids) when is_list(comment_ids) do
    from(r in CommentRevision,
      where: r.comment_id in ^comment_ids,
      group_by: r.comment_id,
      select: {r.comment_id, count(r.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "Fetches one revision, raising if it does not exist."
  @spec get_comment_revision!(integer()) :: %CommentRevision{}
  def get_comment_revision!(id) do
    CommentRevision |> Repo.get!(id) |> Repo.preload(:editor)
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
  Fetches a comment by its ActivityPub ID, current or previous.

  Phase 3B rewrote every local comment's `ap_id` from `<actor>#note-N` to
  `/ap/comments/:id` (ADR 0050) and kept the old value in `legacy_ap_id`. A
  remote instance that received the comment before the rewrite still knows it
  by the old URI, and ActivityPub has no way to tell it otherwise — so an
  inbound `Like`, `Announce`, `Delete` or `inReplyTo` naming the old id has to
  keep landing on the right row. This is the one lookup every inbound path
  goes through, which is why the alias lives here rather than at seven call
  sites in `InboxHandler`.

  `legacy_ap_id` is matched, never asserted: the object we serve and the
  activities we mint always carry the current `ap_id`.
  """
  def get_comment_by_ap_id(ap_id) when is_binary(ap_id) do
    Repo.one(
      from(c in Comment,
        where: c.ap_id == ^ap_id or c.legacy_ap_id == ^ap_id,
        # A current id wins over another row's legacy id, which cannot happen
        # today (both columns are unique) but must not become ambiguous if a
        # later backfill ever reuses a URI.
        order_by: [asc: fragment("? = ?", c.legacy_ap_id, ^ap_id)],
        limit: 1
      )
    )
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

  @doc """
  One page of an article's ActivityPub replies collection (Phase 8D): the
  comments `list_comments_for_article/2` shows a guest, oldest first, after
  `min_id` when given, at most `limit`. The comment id is the keyset cursor.
  `count_comments_for_article/1` applies the same filter, so the collection's
  `totalItems` agrees with its pages.
  """
  @spec list_replies_page(Article.t(), keyword()) :: [Comment.t()]
  def list_replies_page(%Article{id: article_id}, opts) do
    limit = Keyword.fetch!(opts, :limit)

    query =
      from(c in Comment,
        where: c.article_id == ^article_id and is_nil(c.deleted_at),
        order_by: [asc: c.id],
        limit: ^limit,
        preload: [:user, :remote_actor]
      )

    query =
      case Keyword.get(opts, :min_id) do
        nil -> query
        min_id -> from(c in query, where: c.id > ^min_id)
      end

    query
    |> exclude_unservable_remote()
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

    {roots_query, filters} = visible_roots_query(article_id, current_user)

    total_roots = Repo.one(from(q in roots_query, select: count(q.id)))

    # Fetch a page of root comments
    root_query =
      from(c in roots_query,
        order_by: [asc: c.inserted_at, asc: c.id],
        offset: ^offset,
        limit: ^per_page,
        preload: [:user, :remote_actor, :link_preview, :images]
      )

    roots = Repo.all(root_query)

    # Iteratively fetch all descendants (max 5 levels)
    descendants = fetch_descendants(article_id, roots, filters, 5)

    total_pages = max(ceil(total_roots / per_page), 1)

    %{
      comments: roots ++ descendants,
      total_roots: total_roots,
      page: page,
      per_page: per_page,
      total_pages: total_pages
    }
  end

  # The root comments a viewer sees on an article, in no particular order, and
  # the filters their descendants are fetched with. The paginator and
  # `comment_location/2` both start here, so they cannot disagree about what
  # page 1 holds.
  defp visible_roots_query(article_id, current_user) do
    {blocked_uids, blocked_ap_ids} = Filters.hidden_filters(current_user)
    placeholder_ids = deleted_ancestor_ids(article_id, blocked_uids, blocked_ap_ids)

    query =
      from(c in Comment,
        where: c.article_id == ^article_id and is_nil(c.parent_id),
        where: is_nil(c.deleted_at) or c.id in ^placeholder_ids
      )
      |> exclude_unservable_remote()
      |> Filters.apply_hidden_filters(blocked_uids, blocked_ap_ids)

    {query, {blocked_uids, blocked_ap_ids, placeholder_ids}}
  end

  @doc """
  Returns the page of `paginate_comments_for_article/3` a comment appears on
  for `viewer`, and its fragment, as `{page, "comment-ID"}`.

  Comments are paged by root, so the page is the one holding the comment's
  root. The position is counted over the same query the paginator uses, with
  the viewer's blocks and mutes, so a link built from this lands on the page
  that actually shows the comment. Returns `nil` when the comment's thread is
  not visible to the viewer.
  """
  def comment_location(%Comment{} = comment, viewer) do
    with %Comment{} = root <- root_of(comment, 6) do
      {roots_query, _filters} = visible_roots_query(root.article_id, viewer)

      if Repo.exists?(from(c in roots_query, where: c.id == ^root.id)) do
        before =
          Repo.one(
            from(c in roots_query,
              where:
                c.inserted_at < ^root.inserted_at or
                  (c.inserted_at == ^root.inserted_at and c.id < ^root.id),
              select: count(c.id)
            )
          )

        {div(before, @comments_per_page) + 1, "comment-#{comment.id}"}
      end
    end
  end

  defp root_of(%Comment{parent_id: nil} = comment, _remaining), do: comment
  defp root_of(_comment, 0), do: nil

  defp root_of(%Comment{parent_id: parent_id}, remaining) do
    case Repo.get(Comment, parent_id) do
      nil -> nil
      parent -> root_of(parent, remaining - 1)
    end
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
  Updates a remote comment's content, from an inbound `Update(Note)`.

  This is **not** the local edit path and must never be reused as one — it
  authorizes nothing and publishes nothing. It is safe only because its single
  caller, `Baudrate.Federation.InboxHandler.handle_update_note/2`, has already
  matched the comment's `remote_actor_id` against the verified signer. A local
  edit goes through `update_comment/3`, which authorizes, snapshots a revision
  and publishes.

  No revision is written here. A revision records an act taken on this
  instance; a remote author's edit history belongs to the instance that holds
  it, and `handle_update_article/2` has always worked the same way.
  """
  def update_remote_comment(%Comment{} = comment, attrs) do
    comment
    |> Ecto.Changeset.cast(attrs, [:body, :body_html])
    |> Ecto.Changeset.validate_required([:body])
    |> Repo.update()
  end

  @doc """
  Returns the earliest comment on `article` that `viewer` has not seen: one
  inserted after `since` (from `Content.last_read_at/2`), not written by the
  viewer, and visible to them under the same filters as the comment list.

  Returns `nil` when there is none, and always for a guest.
  """
  def first_comment_since(_article, nil, _since), do: nil
  def first_comment_since(_article, _viewer, nil), do: nil

  def first_comment_since(%Article{id: article_id}, %{id: viewer_id} = viewer, since) do
    {blocked_uids, blocked_ap_ids} = Filters.hidden_filters(viewer)

    from(c in Comment,
      where: c.article_id == ^article_id and is_nil(c.deleted_at),
      where: c.inserted_at > ^since,
      where: is_nil(c.user_id) or c.user_id != ^viewer_id,
      order_by: [asc: c.inserted_at, asc: c.id],
      limit: 1
    )
    |> exclude_unservable_remote()
    |> Filters.apply_hidden_filters(blocked_uids, blocked_ap_ids)
    |> Repo.one()
  end

  @doc """
  `count_comments_for_article/1` for many articles in one query: a map of
  article id to count, with every id present (0 when it has none). The same
  filter, so a page of AP objects says what one object would (Phase 8D).
  """
  @spec count_comments_for_articles([integer()]) :: %{integer() => non_neg_integer()}
  def count_comments_for_articles([]), do: %{}

  def count_comments_for_articles(article_ids) when is_list(article_ids) do
    counts =
      from(c in Comment,
        where: c.article_id in ^article_ids and is_nil(c.deleted_at),
        group_by: c.article_id,
        select: {c.article_id, count(c.id)}
      )
      |> Filters.exclude_unservable_remote()
      |> Repo.all()
      |> Map.new()

    Map.new(article_ids, &{&1, Map.get(counts, &1, 0)})
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

  defp warm_comment_mentions(attrs) do
    with article_id when not is_nil(article_id) <- attrs["article_id"] || attrs[:article_id],
         %{} = article <- Repo.get(Article, article_id),
         article = Repo.preload(article, :boards),
         true <- Baudrate.Federation.Delivery.article_boards_federated?(article) do
      Baudrate.Federation.Mentions.warm(
        attrs["body"] || attrs[:body],
        attrs["user_id"] || attrs[:user_id]
      )
    end

    :ok
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
    # `/ap/comments/:id`, never `<actor>#note-N` (ADR 0050). A fragment never
    # reaches the server, so the old form dereferenced to the author's Person
    # document and no remote instance could thread against it. The author is
    # still loaded, because a comment with no readable author is not stamped
    # at all — the same condition as before.
    with %{} = _user <- Repo.get(Baudrate.Setup.User, user_id),
         %{} = _article <- Repo.get(Article, comment.article_id) do
      ap_id = Baudrate.Federation.actor_uri(:comment, comment.id)
      # The permalink, not `/articles/:slug#comment-N`: comments are paged, and
      # that address only ever finds the comment while it is on page 1.
      url = "#{Baudrate.Federation.base_url()}/comments/#{comment.id}"

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
