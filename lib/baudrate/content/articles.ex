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
    Interactions,
    Permissions,
    Polls,
    ReadTracking,
    Tags
  }

  alias Baudrate.Content.LinkPreview.Worker, as: PreviewWorker

  alias Baudrate.Content.PubSub, as: ContentPubSub
  alias Baudrate.Moderation.{ContentFilters, HeldPosts}

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
      order_by: [desc: a.pinned, desc: a.inserted_at, desc: a.id],
      preload: :user
    )
    |> Filters.exclude_unservable_remote()
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
      |> Filters.exclude_unservable_remote()

    total = Repo.one(from(q in base_query, select: count(q.id)))

    articles =
      from(q in base_query,
        order_by: [desc: q.pinned, desc: q.last_activity_at, desc: q.id],
        offset: ^offset,
        limit: ^per_page,
        preload: [:user, :remote_actor, :article_images]
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
          | {:error, Ecto.Multi.name(), any(), map()}
  def create_article(attrs, board_ids, opts \\ []) when is_list(board_ids) do
    author_id = attrs[:user_id] || attrs["user_id"]

    cond do
      # A comment forwarded into a board by someone else keeps its author and
      # is not new writing by that author.
      Keyword.get(opts, :forwarded_comment, false) ->
        do_create_article(attrs, board_ids, opts)

      # A held post a moderator approved (ADR 0065). It passed the filters and
      # the limits on new accounts when it was submitted, and taking another
      # place in the author's hourly bucket for a moderator's click would be
      # wrong; whether the author may act at all can have changed since.
      Keyword.has_key?(opts, :held_post) ->
        case Baudrate.Auth.ensure_can_interact(author_id) do
          :ok -> do_create_article(attrs, board_ids, opts)
          {:error, reason} -> {:error, :account, reason, %{}}
        end

      true ->
        gate_and_create_article(author_id, attrs, board_ids, opts)
    end
  end

  @doc """
  Creates an article from a composer, or holds it for a moderator
  (ADR 0065).

  The same as `create_article/3`, except that a post that is one of a new
  account's first (`hold_first_posts`), or that a `hold` filter matched, is
  not published but held, and `{:held, %HeldPost{}}` is returned. Every
  LiveView that lets a member write an article calls this, never
  `create_article/3` — `test/baudrate/content/submit_path_test.exs` fails the
  build otherwise, because a composer that forgot would publish what should
  have waited.
  """
  @spec submit_article(map(), [term()], keyword()) ::
          {:ok, %{article: %Article{}}}
          | {:held, Baudrate.Moderation.HeldPost.t()}
          | {:error, Ecto.Multi.name(), any(), map()}
  def submit_article(attrs, board_ids, opts \\ []) when is_list(board_ids) do
    author_id = attrs[:user_id] || attrs["user_id"]

    opts =
      opts
      |> Keyword.drop([:forwarded_comment, :held_post, :trusted])
      |> Keyword.put(:holdable, true)

    gate_and_create_article(author_id, attrs, board_ids, opts)
  end

  # A moved, silenced or suspended account cannot write (ADR 0029); a filter
  # may refuse, hold or flag what it wrote (ADR 0065); and a new account is
  # held to the limits on new accounts (ADR 0064) — in that order, so a post a
  # filter refuses spends no place in the hourly bucket. The error uses the
  # Multi shape every caller already handles.
  defp gate_and_create_article(author_id, attrs, board_ids, opts) do
    holdable = Keyword.get(opts, :holdable, false)

    with :ok <- Baudrate.Auth.ensure_can_interact(author_id),
         verdict = screen_article(author_id, attrs, if(holdable, do: :post, else: :publish)),
         :ok <- ContentFilters.refuse_blocked(verdict),
         :ok <- check_new_account_limits(author_id, attrs, opts) do
      ContentFilters.record(verdict)

      case hold_reason(holdable, author_id, verdict) do
        nil ->
          attrs
          |> do_create_article(board_ids, Keyword.delete(opts, :holdable))
          |> tap(fn
            {:ok, %{article: article}} ->
              ContentFilters.flag(verdict, %{article_id: article.id})

            _ ->
              :ok
          end)

        {reason, filter} ->
          case HeldPosts.hold_article(attrs, board_ids, opts, reason, filter) do
            {:ok, held} -> {:held, held}
            {:error, changeset} -> {:error, :held_post, changeset, %{}}
          end
      end
    else
      {:error, reason} -> {:error, :account, reason, %{}}
    end
  end

  defp screen_article(author_id, attrs, mode) do
    ContentFilters.screen(
      %{
        title: attrs[:title] || attrs["title"],
        summary: attrs[:summary] || attrs["summary"],
        body: attrs[:body] || attrs["body"]
      },
      mode: mode,
      target_type: "article",
      user_id: author_id
    )
  end

  # Only a composer's submission can be held. A filter's hold comes first, so
  # the queue says which filter it was.
  defp hold_reason(false, _author_id, _verdict), do: nil
  defp hold_reason(true, _author_id, %{outcome: :hold, filter: filter}), do: {"filter", filter}

  # A flag filter that matched a post held for being one of the first is
  # named on the held row, so the moderator reviewing it knows.
  defp hold_reason(true, author_id, verdict) do
    if HeldPosts.first_post?(author_id),
      do: {"first_posts", if(verdict.outcome == :flag, do: verdict.filter)}
  end

  # One link and one image for an account that has not earned trust yet. Bots
  # are exempt inside the check itself, which is why they are not skipped here.
  # The attached count is the ids asked for, deduplicated: association only
  # ever takes the caller's own orphan uploads, so this is an upper bound.
  defp check_new_account_limits(author_id, attrs, opts) do
    image_count = opts |> Keyword.get(:image_ids, []) |> Enum.uniq() |> length()
    Baudrate.Auth.check_post(author_id, attrs[:body] || attrs["body"], image_count)
  end

  defp do_create_article(attrs, board_ids, opts) do
    image_ids = Keyword.get(opts, :image_ids, [])
    poll_attrs = Keyword.get(opts, :poll)

    # Learn any remote actor the body mentions *before* the transaction: the
    # lookup is an HTTP request, and one inside a transaction holds a database
    # connection open for the length of somebody else's timeout (ADR 0034).
    # Best-effort and bounded — see `Federation.Mentions` (ADR 0051).
    maybe_warm_mentions(attrs, board_ids, opts)

    # `trusted: true` is for system callers (bots) that legitimately set
    # `url`/`published_at`; user-facing callers must never pass it.
    changeset =
      if Keyword.get(opts, :trusted, false),
        do: Article.trusted_changeset(%Article{}, attrs),
        else: Article.changeset(%Article{}, attrs)

    result =
      Ecto.Multi.new()
      |> claim_held_post(Keyword.get(opts, :held_post))
      |> Ecto.Multi.insert(:article, changeset)
      |> Ecto.Multi.update(:article_with_ap_id, &article_ap_id_changeset(&1.article))
      |> Ecto.Multi.run(:board_articles, fn repo, %{article_with_ap_id: article} ->
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
      |> Ecto.Multi.run(:article_images, fn _repo, %{article_with_ap_id: article} ->
        if image_ids != [] do
          user_id = attrs["user_id"] || attrs[:user_id]
          Images.associate_article_images(article.id, image_ids, user_id)
        end

        {:ok, :done}
      end)
      |> Polls.maybe_insert_poll(poll_attrs)
      |> stamp_poll_ap_id_step(poll_attrs)
      # The Create/Announce jobs commit with the article (Phase 2C).
      |> Ecto.Multi.run(:federation, fn _repo, %{article_with_ap_id: article} ->
        if article.user_id do
          article
          |> Repo.preload([:boards, :user])
          |> Baudrate.Federation.Publisher.publish_article_created()
        end

        {:ok, :enqueued}
      end)
      |> Repo.transaction()

    with {:ok, multi_result} <- result do
      # `article_with_ap_id` is the durably-stamped row; surface it as `:article`
      # for callers that destructure on that key.
      article = multi_result.article_with_ap_id
      multi_result = Map.put(multi_result, :article, article)
      multi_result = maybe_promote_stamped_poll(multi_result)

      Tags.sync_article_tags(article)

      for board_id <- board_ids do
        ContentPubSub.broadcast_to_board(board_id, :article_created, %{article_id: article.id})
      end

      if article.user_id do
        Baudrate.Notification.Hooks.notify_article_created(article)
      end

      body_html = Baudrate.Content.Markdown.to_html(article.body || "")
      PreviewWorker.schedule_preview_fetch(:article, article.id, body_html, article.user_id)

      {:ok, %{multi_result | article: article}}
    end
  end

  # Approving a held post deletes its row in the transaction that publishes
  # it, so a second approval rolls back instead of publishing twice.
  defp claim_held_post(multi, nil), do: multi

  defp claim_held_post(multi, held),
    do: Ecto.Multi.run(multi, :claim_held_post, fn repo, _ -> HeldPosts.claim(repo, held) end)

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
          {:ok, %Article{}} | {:error, Ecto.Changeset.t() | :account_moved}
  def update_article(%Article{} = article, attrs) do
    update_article(article, attrs, nil)
  end

  def update_article(%Article{} = article, attrs, editor) do
    # A restricted account cannot edit (ADR 0029); staff editing its articles
    # are not restricted by it. Nor can a new account edit a link or an image
    # into a post that creation would have refused (ADR 0064) — posting clean
    # and editing dirty is the second way in.
    with :ok <- Baudrate.Auth.ensure_can_interact(editor),
         verdict = screen_edit(article, attrs, editor),
         :ok <- ContentFilters.refuse_blocked(verdict),
         :ok <- check_edit_limits(article, attrs, editor) do
      ContentFilters.record(verdict)

      article
      |> do_update_article(attrs, editor)
      |> tap(fn
        {:ok, updated} -> ContentFilters.flag(verdict, %{article_id: updated.id})
        _ -> :ok
      end)
    end
  end

  # An edit is judged by what it adds (ADR 0065): a filter the stored article
  # already matched does not stop its author fixing a typo. An update from
  # federation has no local editor and is screened in the inbox instead.
  defp screen_edit(_article, _attrs, nil), do: %{outcome: :pass}

  defp screen_edit(article, attrs, editor) do
    ContentFilters.screen(
      %{
        title: attrs[:title] || attrs["title"] || article.title,
        summary: Map.get(attrs, :summary, Map.get(attrs, "summary", article.summary)),
        body: attrs[:body] || attrs["body"] || article.body
      },
      mode: :edit,
      previous: %{title: article.title, summary: article.summary, body: article.body},
      target_type: "article",
      user_id: editor.id
    )
  end

  # An update from federation has no local editor and no limits to apply.
  defp check_edit_limits(_article, _attrs, nil), do: :ok

  defp check_edit_limits(article, attrs, editor) do
    images = Images.count_article_images(article.id)
    body = attrs[:body] || attrs["body"] || article.body

    Baudrate.Auth.check_post(editor, body, images, previous: {article.body, images})
  end

  defp do_update_article(article, attrs, editor) do
    # An edit can add a mention nobody here has seen, so the same
    # before-the-transaction lookup applies (ADR 0051).
    article = Repo.preload(article, :boards)

    if Baudrate.Federation.Delivery.article_boards_federated?(article) do
      Baudrate.Federation.Mentions.warm(attrs[:body] || attrs["body"], article.user_id)
    end

    result =
      Ecto.Multi.new()
      |> maybe_snapshot_revision(article, editor)
      |> Ecto.Multi.update(:article, Article.update_changeset(article, attrs))
      |> Ecto.Multi.run(:federation, fn _repo, %{article: updated} ->
        if updated.user_id do
          Baudrate.Federation.Publisher.publish_article_updated(updated)
        end

        {:ok, :enqueued}
      end)
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

  Admins and authors can always forward. Other authenticated users can
  forward articles with `forwardable: true` and `public` or `unlisted`
  visibility.

  Returns `{:ok, article}` (silently) if the article is already in the target board,
  `{:error, :not_found}` if the article is soft-deleted,
  `{:error, :unauthorized}` if the user cannot forward the article,
  and `{:error, :cannot_post}` if the user cannot post in the target board.
  """
  def forward_article_to_board(%Article{} = article, %Board{} = board, user) do
    article = Permissions.ensure_boards_loaded(article)

    cond do
      # A soft-deleted article must not be resurrected into another board.
      not is_nil(article.deleted_at) ->
        {:error, :not_found}

      # Already in target board -> silently succeed
      Enum.any?(article.boards, &(&1.id == board.id)) ->
        {:ok, article}

      # Source-board view gate: the acting user must be able to see the board
      # the article lives in before they can republish it elsewhere. Mirrors
      # `forward_comment_to_board/3` — `article.visibility` alone does not
      # capture board-level restrictions (local articles default to "public"
      # regardless of the board's `min_role_to_view`).
      not Interactions.article_visible_to_user?(article.id, user.id) ->
        {:error, :unauthorized}

      # Permission check (covers forwardable flag + visibility)
      not Permissions.can_forward_article?(user, article) ->
        {:error, :unauthorized}

      # Forwarding is an interaction: refused across a block.
      Baudrate.Auth.blocked_with_author?(user.id, article) ->
        {:error, :unauthorized}

      # Must be able to post in target board
      not Permissions.can_post_in_board?(board, user) ->
        {:error, :cannot_post}

      true ->
        Baudrate.Federation.federate(
          fn ->
            with {:ok, _} <- add_article_to_board(article, board.id) do
              {:ok, Repo.preload(article, :boards, force: true)}
            end
          end,
          &Baudrate.Federation.Publisher.publish_article_forwarded(&1, board)
        )
        |> case do
          {:ok, article} ->
            ContentPubSub.broadcast_to_board(board.id, :article_created, %{
              article_id: article.id
            })

            Baudrate.Notification.Hooks.notify_article_forwarded(article, user.id)
            {:ok, article}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Forwards a timeline item to a board by materializing it as a remote article.

  If an article with the same `ap_id` already exists, links it to the
  target board instead of creating a duplicate. Requires the user to
  have posting permission in the target board and the timeline item to have
  `public` or `unlisted` visibility (or user is admin).

  Returns `{:ok, article}` on success, `{:error, :not_found}` if the timeline
  item is soft-deleted, or `{:error, reason}`.
  """
  def forward_timeline_item_to_board(
        %Baudrate.Federation.TimelineItem{} = timeline_item,
        %Board{} = board,
        user
      ) do
    alias Baudrate.Content.TitleDeriver

    cond do
      # A soft-deleted timeline item (e.g. withdrawn by its remote author via
      # `Delete`) must not be resurrected as a board article.
      not is_nil(timeline_item.deleted_at) ->
        {:error, :not_found}

      not Permissions.can_forward_timeline_item?(user, timeline_item) ->
        {:error, :unauthorized}

      Baudrate.Auth.blocked_with_author?(user.id, timeline_item) ->
        {:error, :unauthorized}

      not Permissions.can_post_in_board?(board, user) ->
        {:error, :cannot_post}

      true ->
        # Check if an article with the same ap_id already exists
        existing = Repo.get_by(Article, ap_id: timeline_item.ap_id)

        if existing do
          existing = Permissions.ensure_boards_loaded(existing)

          if Enum.any?(existing.boards, &(&1.id == board.id)) do
            {:ok, existing}
          else
            case add_article_to_board(existing, board.id) do
              {:ok, _} ->
                existing = Repo.preload(existing, :boards, force: true)

                ContentPubSub.broadcast_to_board(board.id, :article_created, %{
                  article_id: existing.id
                })

                {:ok, existing}

              {:error, _} = err ->
                err
            end
          end
        else
          title = TitleDeriver.derive_title_from_body(timeline_item.body)
          slug = Baudrate.Content.generate_slug(title)

          attrs = %{
            title: title,
            body: timeline_item.body || "",
            slug: slug,
            ap_id: timeline_item.ap_id,
            url: timeline_item.source_url,
            remote_actor_id: timeline_item.remote_actor_id,
            visibility: timeline_item.visibility || "public"
          }

          case create_remote_article(attrs, [board.id],
                 image_attachments: timeline_item.attachments,
                 publish: &Baudrate.Federation.Publisher.publish_article_forwarded(&1, board)
               ) do
            {:ok, %{article: article}} ->
              {:ok, article}

            {:error, :article, %Ecto.Changeset{} = changeset, _} ->
              {:error, changeset}

            {:error, _, reason, _} ->
              {:error, reason}
          end
        end
    end
  end

  @doc """
  Forwards a comment to a board by materializing it as an article.

  For remote comments, creates a remote article. For local comments,
  creates a regular article attributed to the comment author. The
  comment body becomes the article body and the title is derived from
  the first line.

  Returns `{:ok, article}` on success, `{:error, :not_found}` if the comment
  is soft-deleted, or `{:error, reason}`.
  """
  def forward_comment_to_board(%Comment{} = comment, %Board{} = board, user) do
    alias Baudrate.Content.TitleDeriver

    comment = Repo.preload(comment, [:user, :remote_actor])

    cond do
      # A soft-deleted comment must not be resurrected as a board article.
      # Callers fetch the comment by a client-supplied ID, so the moderation
      # decision has to be enforced here at the context boundary.
      not is_nil(comment.deleted_at) ->
        {:error, :not_found}

      # Source-board view gate: the acting user must be able to see the board the
      # comment lives in before they can materialize it elsewhere. Without this, a
      # user could guess a comment ID in a private board they cannot view and
      # forward its body into a public board — exfiltrating restricted content.
      # `comment.visibility` alone does not capture board-level restrictions
      # (local comments default to "public" regardless of the board's min role).
      not Interactions.article_visible_to_user?(comment.article_id, user.id) ->
        {:error, :unauthorized}

      not Permissions.can_forward_comment?(user, comment) ->
        {:error, :unauthorized}

      Baudrate.Auth.blocked_with_author?(user.id, comment) ->
        {:error, :unauthorized}

      not Permissions.can_post_in_board?(board, user) ->
        {:error, :cannot_post}

      true ->
        # Check if already materialized
        if comment.ap_id do
          existing = Repo.get_by(Article, ap_id: comment.ap_id)

          if existing do
            existing = Permissions.ensure_boards_loaded(existing)

            if Enum.any?(existing.boards, &(&1.id == board.id)) do
              {:ok, existing}
            else
              case add_article_to_board(existing, board.id) do
                {:ok, _} ->
                  existing = Repo.preload(existing, :boards, force: true)

                  ContentPubSub.broadcast_to_board(board.id, :article_created, %{
                    article_id: existing.id
                  })

                  {:ok, existing}

                {:error, _} = err ->
                  err
              end
            end
          else
            do_materialize_comment(comment, board)
          end
        else
          do_materialize_comment(comment, board)
        end
    end
  end

  defp do_materialize_comment(comment, board) do
    alias Baudrate.Content.TitleDeriver

    title = TitleDeriver.derive_title_from_body(comment.body)
    slug = Baudrate.Content.generate_slug(title)

    if comment.remote_actor_id do
      # Remote comment → remote article
      attrs = %{
        title: title,
        body: comment.body || "",
        slug: slug,
        ap_id: comment.ap_id,
        url: comment.url,
        remote_actor_id: comment.remote_actor_id,
        visibility: comment.visibility || "public"
      }

      case create_remote_article(attrs, [board.id],
             publish: &Baudrate.Federation.Publisher.publish_article_forwarded(&1, board)
           ) do
        {:ok, %{article: article}} ->
          {:ok, article}

        {:error, :article, %Ecto.Changeset{} = changeset, _} ->
          {:error, changeset}

        {:error, _, reason, _} ->
          {:error, reason}
      end
    else
      # Local comment → local article
      attrs = %{
        title: title,
        body: comment.body || "",
        slug: slug,
        user_id: comment.user_id,
        # Local articles accept only public/unlisted (D1). A legacy local
        # comment with narrower addressing, which only an admin may forward,
        # becomes unlisted rather than failing.
        visibility: if(comment.visibility == "public", do: "public", else: "unlisted")
      }

      # `create_article/3` publishes the article's Create and the board's
      # Announce itself. This used to publish them a second time as well,
      # under new activity ids, so the board's followers received both twice.
      case Baudrate.Content.create_article(attrs, [board.id], forwarded_comment: true) do
        {:ok, %{article: article}} ->
          {:ok, article}

        {:error, :article, %Ecto.Changeset{} = changeset, _} ->
          {:error, changeset}

        {:error, _, reason, _} ->
          {:error, reason}
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
      # The author, staff, or a moderator of this board (P1-D5): taking the
      # article out of one board is that board's business.
      not Permissions.can_remove_from_board?(user, article, board) ->
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

  ## Options

    * `:poll` — attributes of an attached poll
    * `:image_attachments` — remote images to fetch after the insert
    * `:publish` — a function called with the article inside the transaction,
      for a local action that federates it (a member forwarding the item into
      a board). Its delivery jobs commit with the article. Inbound activities
      never pass one, which is what keeps boosts loop-safe.
  """
  def create_remote_article(attrs, board_ids, opts \\ []) when is_list(board_ids) do
    poll_attrs = Keyword.get(opts, :poll)
    image_attachments = Keyword.get(opts, :image_attachments, [])
    publish = Keyword.get(opts, :publish)

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
      |> maybe_publish_step(publish)
      |> Repo.transaction()

    with {:ok, %{article: article}} <- result do
      for board_id <- board_ids do
        ContentPubSub.broadcast_to_board(board_id, :article_created, %{article_id: article.id})
      end

      # Fetch remote image attachments asynchronously (best-effort)
      if image_attachments != [] do
        Baudrate.Federation.schedule_federation_task(fn ->
          Images.fetch_and_store_remote_images(article.id, image_attachments)
        end)
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

  The row is removed for good 90 days later, with its revisions, images and
  the image files on disk (`Baudrate.Retention`, ADR 0040) — unless a report
  points at it.

  ## Options

    * `:deleted_by` — id of the local user performing the deletion (the author
      or a moderator). Stored as `deleted_by_id`. Omit for remote deletions.
  """
  @spec soft_delete_article(%Article{}, keyword()) ::
          {:ok, %Article{}} | {:error, Ecto.Changeset.t()}
  def soft_delete_article(%Article{} = article, opts \\ []) do
    with :ok <- authorize_delete(article, opts) do
      do_soft_delete_article(article, opts)
    end
  end

  # A local deletion names its actor and is re-checked here; a remote one is
  # authorized by the inbox (the signer owns the object) and says so with
  # `remote: true`, so neither path can reach the delete without having been
  # authorized somewhere explicit (ADR 0016).
  defp authorize_delete(article, opts) do
    if Keyword.get(opts, :remote, false) do
      :ok
    else
      Permissions.authorize_delete_article(Keyword.get(opts, :deleted_by), article)
    end
  end

  defp do_soft_delete_article(%Article{} = article, opts) do
    result =
      Baudrate.Federation.federate(
        fn ->
          article
          |> Article.soft_delete_changeset(Keyword.get(opts, :deleted_by))
          |> Repo.update()
        end,
        fn deleted ->
          # Only local articles (those with a user_id) publish their deletion.
          if deleted.user_id do
            Baudrate.Federation.Publisher.publish_article_deleted(deleted)
          end
        end
      )

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
  Whether an article has ever been edited.

  The article-side twin of `Comments.comment_edited?/1`, and it exists for the
  same reason: `updated_at` records when the row last changed, which a
  backfill or any other housekeeping write also moves. A revision is written
  only by an actual edit.
  """
  @spec article_edited?(%Article{} | integer()) :: boolean()
  def article_edited?(%Article{id: id}), do: article_edited?(id)

  def article_edited?(article_id) when is_integer(article_id) do
    Repo.exists?(from(r in ArticleRevision, where: r.article_id == ^article_id))
  end

  def article_edited?(_), do: false

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
  def toggle_pin_article(%Article{} = article, actor) do
    with :ok <- Permissions.authorize_pin(actor, article) do
      do_toggle_pin(article)
    end
  end

  defp do_toggle_pin(%Article{} = article) do
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
  def toggle_lock_article(%Article{} = article, actor) do
    with :ok <- Permissions.authorize_lock(actor, article) do
      do_toggle_lock(article)
    end
  end

  defp do_toggle_lock(%Article{} = article) do
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

  # A mention is resolved only for content that can actually leave (ADR 0051,
  # decision 3). Resolving one is itself an outbound request, so doing it for
  # an article in a private board would tell that server a member here typed
  # the handle — a smaller leak than delivering the article, and the same
  # decision governs both.
  #
  # Bots are skipped: a feed body is not the bot's writing, and an RSS item
  # that happens to contain an address would make this instance fetch from
  # whatever domain it named, on a schedule.
  defp maybe_warm_mentions(attrs, board_ids, opts) do
    author_id = attrs[:user_id] || attrs["user_id"]
    body = attrs[:body] || attrs["body"]

    if not Keyword.get(opts, :trusted, false) and boards_federated?(board_ids) do
      Baudrate.Federation.Mentions.warm(body, author_id)
    end

    :ok
  end

  defp boards_federated?([]), do: true

  defp boards_federated?(board_ids) do
    from(b in Board, where: b.id in ^board_ids)
    |> Repo.all()
    |> Enum.any?(&Board.federated?/1)
  end

  # Builds a changeset that stamps the article's canonical AP ID inside the
  # creation transaction. Idempotent: returns an unchanged changeset when the
  # article already has an `ap_id` (e.g. mirrored via `create_remote_article`
  # or backfilled by a prior run), so this step is safe to chain unconditionally.
  defp article_ap_id_changeset(%Article{ap_id: nil, slug: slug} = article)
       when is_binary(slug) do
    Ecto.Changeset.change(article, ap_id: Baudrate.Federation.actor_uri(:article, slug))
  end

  defp article_ap_id_changeset(%Article{} = article), do: Ecto.Changeset.change(article)

  # Adds a Multi step that stamps the just-inserted poll with `/ap/polls/:id`.
  # No-op when no poll was inserted, so callers can chain unconditionally.
  # Not `<article-ap-id>#poll`: a fragment never reaches the server, so the old
  # form dereferenced to the Article and a remote voter had nothing to address
  # (ADR 0050).
  defp stamp_poll_ap_id_step(multi, nil), do: multi

  defp stamp_poll_ap_id_step(multi, _poll_attrs) do
    Ecto.Multi.update(multi, :poll_with_ap_id, fn changes ->
      poll = changes.poll

      cond do
        is_nil(poll) ->
          # `maybe_insert_poll` is unconditional once `poll_attrs` is non-nil,
          # but defensively handle a nil result rather than crashing the tx.
          Ecto.Changeset.change(%Baudrate.Content.Poll{})

        is_binary(poll.ap_id) and poll.ap_id != "" ->
          Ecto.Changeset.change(poll)

        true ->
          Ecto.Changeset.change(poll, ap_id: Baudrate.Federation.actor_uri(:poll, poll.id))
      end
    end)
  end

  # When the poll-stamping step ran, surface the stamped poll under the
  # `:poll` key callers expect.
  defp maybe_promote_stamped_poll(%{poll_with_ap_id: poll} = multi_result)
       when not is_nil(poll) do
    Map.put(multi_result, :poll, poll)
  end

  defp maybe_promote_stamped_poll(multi_result), do: multi_result

  defp maybe_publish_step(multi, nil), do: multi

  defp maybe_publish_step(multi, publish) when is_function(publish, 1) do
    Ecto.Multi.run(multi, :federation, fn _repo, %{article: article} ->
      publish.(article)
      {:ok, :enqueued}
    end)
  end
end
