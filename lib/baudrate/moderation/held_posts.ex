defmodule Baudrate.Moderation.HeldPosts do
  @default_first_posts 0
  @max_first_posts 10
  @rejected_days 90
  @per_page 20

  @moduledoc """
  Posts held for a moderator before they appear (Phase 5C, ADR 0065).

  ## What is held

  Only what a composer submits — `Content.submit_article/3` and
  `Content.submit_comment/2` are the one way in, and
  `test/baudrate/content/submit_path_test.exs` fails the build if a LiveView
  calls `create_article/3` or `create_comment/2` itself. A post is held when:

    * the `hold_first_posts` setting is above zero (#{@default_first_posts},
      off, unless an admin changes it; at most #{@max_first_posts}) and the
      author has fewer articles and comments still up than that — the count
      trust is earned by (`Baudrate.Auth.Trust.count_posts/2`). Admins,
      moderators and bots are never held; or
    * a content filter set to `hold` matched it
      (`Baudrate.Moderation.ContentFilters`).

  A held post has already passed everything a published one must — the
  sanction gate (ADR 0029), the limits on new accounts (ADR 0064), a
  filter's `block` — so a moderator is never asked to approve something the
  author could not have posted, and holding takes a place in a new account's
  hourly allowance like posting does.

  Bots, forwarding and federation call `create_*` and are never held: there
  is nobody to tell, or nothing to hold. A `hold` filter flags them instead.

  ## Approval is publication

  `approve/2` replays creation as the author, through the same
  `Content.create_article/3` / `create_comment/2`, with the held row's delete
  as the first step of the same transaction. So the `ap_id`, federation,
  mentions, notifications and link preview happen at approval, and two
  moderators approving at once publish once: the second transaction finds no
  row to delete and rolls back. What approval re-checks, because it can have
  changed since the submission: that the author may still act at all, still
  post in each board (a board they have lost is dropped, and approval fails
  if none is left), and that the article a comment answers is still open.

  ## Who reviews what

  Admins and global moderators review everything. A board moderator reviews
  an article only when they moderate **every** board it names, and a comment
  only when they moderate every board its article is in — the rule for
  deleting a cross-posted article (P1-D5), because approving one publishes it
  into all of them. The scope is recomputed on every action; the id comes
  from the client.

  ## What is kept

  An approved row is gone: it has become the article or comment. A rejected
  row keeps the text as the record of what was refused and is purged
  #{@rejected_days} days after review by `Baudrate.Retention`. The orphan
  image sweeps spare the uploads a **pending** row names, or a post held
  overnight would be approved with its pictures already deleted.
  """

  import Ecto.Query

  alias Baudrate.Auth.Trust
  alias Baudrate.Content
  alias Baudrate.Content.{Article, BoardArticle, BoardModerator}
  alias Baudrate.Moderation
  alias Baudrate.Moderation.HeldPost
  alias Baudrate.Notification.Hooks
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.User

  @staff_roles ~w(admin moderator)

  @doc "The largest `hold_first_posts` accepted."
  def max_first_posts, do: @max_first_posts

  @doc "How long a rejected submission is kept, in days."
  def rejected_days, do: @rejected_days

  @doc """
  The `hold_first_posts` setting: how many of an account's first posts are
  held. 0 turns it off.
  """
  @spec first_posts() :: non_neg_integer()
  def first_posts do
    case Setup.get_setting("hold_first_posts") do
      nil -> Application.get_env(:baudrate, :hold_first_posts, @default_first_posts)
      value -> parse(value)
    end
    |> max(0)
    |> min(@max_first_posts)
  end

  # A setting is a string (`Setup.get_setting/1`); `nil` is handled before.
  defp parse(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> @default_first_posts
    end
  end

  @doc """
  Whether a post by `user_id` is one of its first and should be held. Staff
  and bots never are.
  """
  @spec first_post?(integer() | nil) :: boolean()
  def first_post?(user_id) when is_integer(user_id) do
    case first_posts() do
      0 ->
        false

      n ->
        not exempt?(user_id) and Trust.count_posts(user_id, n) < n
    end
  end

  def first_post?(_), do: false

  defp exempt?(user_id) do
    Repo.exists?(
      from(u in User,
        left_join: r in assoc(u, :role),
        where: u.id == ^user_id and (u.is_bot or r.name in @staff_roles)
      )
    )
  end

  # --- Holding ---

  @doc """
  Holds an article submission. `attrs` are what the composer passed to
  `Content.submit_article/3`; `opts` its `:image_ids` and `:poll`.
  """
  @spec hold_article(map(), [integer()], keyword(), String.t(), map() | nil) ::
          {:ok, HeldPost.t()} | {:error, Ecto.Changeset.t()}
  def hold_article(attrs, board_ids, opts, reason, filter) do
    attrs = stringify(attrs)

    %{
      "kind" => "article",
      "title" => attrs["title"],
      "body" => attrs["body"],
      "summary" => attrs["summary"],
      "sensitive" => attrs["sensitive"],
      "visibility" => attrs["visibility"] || "public",
      "forwardable" => Map.get(attrs, "forwardable", true),
      "board_ids" => Enum.uniq(board_ids),
      "image_ids" => opts |> Keyword.get(:image_ids, []) |> Enum.uniq(),
      "poll" => store_poll(Keyword.get(opts, :poll))
    }
    |> insert(attrs["user_id"], reason, filter)
  end

  @doc """
  Holds a comment submission. `attrs` are what the composer passed to
  `Content.submit_comment/2`; `opts` its `:image_ids`.
  """
  @spec hold_comment(map(), keyword(), String.t(), map() | nil) ::
          {:ok, HeldPost.t()} | {:error, Ecto.Changeset.t()}
  def hold_comment(attrs, opts, reason, filter) do
    attrs = stringify(attrs)

    %{
      "kind" => "comment",
      "body" => attrs["body"],
      "summary" => attrs["summary"],
      "sensitive" => attrs["sensitive"],
      "visibility" => attrs["visibility"] || "public",
      "article_id" => attrs["article_id"],
      "parent_id" => attrs["parent_id"],
      "image_ids" => opts |> Keyword.get(:image_ids, []) |> Enum.uniq()
    }
    |> insert(attrs["user_id"], reason, filter)
  end

  defp insert(fields, user_id, reason, filter) do
    fields = Map.reject(fields, fn {_k, v} -> is_nil(v) end)

    result =
      %HeldPost{
        user_id: user_id,
        reason: reason,
        content_filter_id: filter && filter.id,
        status: "pending"
      }
      |> HeldPost.changeset(fields)
      |> Repo.insert()

    with {:ok, held} <- result do
      Hooks.notify_post_held(held)
      result
    end
  end

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  # A poll's closing time is counted from the moment it appears, so what is
  # kept is how long it was meant to stay open.
  defp store_poll(nil), do: nil

  defp store_poll(poll) do
    closes_at = poll[:closes_at] || poll["closes_at"]

    open_for =
      if closes_at,
        do: max(DateTime.diff(closes_at, DateTime.utc_now(), :second), 60),
        else: nil

    %{
      "mode" => poll[:mode] || poll["mode"] || "single",
      "options" =>
        (poll[:options] || poll["options"] || [])
        |> Enum.map(&(&1[:text] || &1["text"]))
        |> Enum.reject(&is_nil/1),
      "open_for" => open_for
    }
  end

  defp restore_poll(nil), do: []

  defp restore_poll(%{"options" => [_ | _] = options} = poll) do
    closes_at =
      case poll["open_for"] do
        seconds when is_integer(seconds) ->
          DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

        _ ->
          nil
      end

    [
      poll: %{
        mode: poll["mode"] || "single",
        closes_at: closes_at,
        options:
          options
          |> Enum.with_index()
          |> Enum.map(fn {text, position} -> %{text: text, position: position} end)
      }
    ]
  end

  defp restore_poll(_), do: []

  # --- The approval claim ---

  @doc false
  # The first step of the transaction that publishes a held post: deleting
  # the pending row. A second approval finds nothing to delete and rolls its
  # whole transaction back, so the post is published once.
  @spec claim(Ecto.Repo.t(), HeldPost.t()) :: {:ok, HeldPost.t()} | {:error, :already_reviewed}
  def claim(repo, %HeldPost{id: id} = held) do
    case repo.delete_all(from(h in HeldPost, where: h.id == ^id and h.status == "pending")) do
      {1, _} -> {:ok, held}
      _ -> {:error, :already_reviewed}
    end
  end

  # --- Reviewing ---

  @doc """
  Pending (or, with `status: "rejected"`, rejected) submissions `reviewer`
  may act on, oldest first, paginated.

  Returns `%{held_posts: [...], page: n, total_pages: n, total: n}`.
  """
  @spec paginate_for_reviewer(map(), keyword()) :: map()
  def paginate_for_reviewer(reviewer, opts \\ []) do
    status = if Keyword.get(opts, :status) == "rejected", do: "rejected", else: "pending"
    page = max(Keyword.get(opts, :page, 1), 1)

    query =
      from(h in HeldPost, where: h.status == ^status)
      |> scope(reviewer)

    total = Repo.aggregate(query, :count, :id)
    total_pages = max(ceil(total / @per_page), 1)

    order =
      if status == "pending",
        do: [asc: :inserted_at, asc: :id],
        else: [desc: :reviewed_at, desc: :id]

    held_posts =
      from(h in query,
        order_by: ^order,
        offset: ^((page - 1) * @per_page),
        limit: ^@per_page,
        preload: [:user, :content_filter, :reviewed_by, article: :boards]
      )
      |> Repo.all()

    %{held_posts: held_posts, page: page, total_pages: total_pages, total: total}
  end

  @doc "How many submissions are waiting for `reviewer`."
  @spec count_pending(map()) :: non_neg_integer()
  def count_pending(reviewer) do
    from(h in HeldPost, where: h.status == "pending")
    |> scope(reviewer)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Fetches a pending submission `reviewer` may act on, or `nil`. The id comes
  from the client, so the scope is part of the query.
  """
  @spec get_pending_for_reviewer(integer(), map()) :: HeldPost.t() | nil
  def get_pending_for_reviewer(id, reviewer) when is_integer(id) do
    from(h in HeldPost, where: h.id == ^id and h.status == "pending")
    |> scope(reviewer)
    |> Repo.one()
  end

  def get_pending_for_reviewer(_, _), do: nil

  @doc "Whether `user` reviews anything at all: staff, or a board moderator."
  @spec reviewer?(map() | nil) :: boolean()
  def reviewer?(%{role: %{name: name}}) when name in @staff_roles, do: true
  def reviewer?(%{} = user), do: Content.moderated_board_ids(user) != []
  def reviewer?(_), do: false

  defp scope(query, %{role: %{name: name}}) when name in @staff_roles, do: query

  defp scope(query, %{id: user_id}) when is_integer(user_id) do
    # Articles: every board named is one this member moderates, and there is
    # at least one. Comments: the same, for the boards the article is in.
    from(h in query,
      where:
        (h.kind == "article" and fragment("cardinality(?) > 0", h.board_ids) and
           fragment(
             "NOT EXISTS (SELECT 1 FROM unnest(?) AS b(id) WHERE b.id NOT IN (SELECT board_id FROM board_moderators WHERE user_id = ?))",
             h.board_ids,
             ^user_id
           )) or
          (h.kind == "comment" and
             fragment(
               "EXISTS (SELECT 1 FROM board_articles ba WHERE ba.article_id = ?)",
               h.article_id
             ) and
             fragment(
               "NOT EXISTS (SELECT 1 FROM board_articles ba WHERE ba.article_id = ? AND ba.board_id NOT IN (SELECT board_id FROM board_moderators WHERE user_id = ?))",
               h.article_id,
               ^user_id
             ))
    )
  end

  defp scope(query, _), do: from(h in query, where: false)

  @doc """
  Approves a held submission as `reviewer`: publishes it as its author and
  tells the author.

  Returns `{:ok, %Article{}}` or `{:ok, %Comment{}}`; `{:error, :not_found}`
  when it is not pending or not the reviewer's to approve (including a race
  another moderator won); `{:error, :no_boards}` when the author may no longer
  post in any of its boards; `{:error, :article_gone}` or
  `{:error, :cannot_comment}` for a comment whose article has been removed or
  locked; and the sanction gate's refusals when the author may no longer act.
  """
  @spec approve(HeldPost.t(), map()) :: {:ok, struct()} | {:error, atom() | Ecto.Changeset.t()}
  def approve(%HeldPost{} = held, reviewer) do
    # The author's standing first: a silenced author cannot post in any
    # board either, and "no boards left" would name the wrong reason.
    with %HeldPost{} = held <- get_pending_for_reviewer(held.id, reviewer),
         %User{} = author <- Repo.get(User, held.user_id) |> Repo.preload(:role),
         :ok <- Baudrate.Auth.ensure_can_interact(author),
         {:ok, published} <- publish(held, author) do
      Hooks.notify_post_approved(held, published)

      Moderation.log_action(reviewer.id, "approve_held_post",
        target_type: held.kind,
        target_id: published.id,
        details: %{"held_post_id" => held.id, "author_id" => held.user_id}
      )

      {:ok, published}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp publish(%HeldPost{kind: "article"} = held, author) do
    boards = permitted_boards(held.board_ids, author)

    if held.board_ids != [] and boards == [] do
      {:error, :no_boards}
    else
      attrs = %{
        "title" => held.title,
        "body" => held.body,
        "summary" => held.summary,
        "sensitive" => held.sensitive,
        "visibility" => held.visibility,
        "forwardable" => held.forwardable,
        "slug" => Content.generate_slug(held.title || ""),
        "user_id" => author.id
      }

      opts = [image_ids: held.image_ids, held_post: held] ++ restore_poll(held.poll)

      case Content.create_article(attrs, Enum.map(boards, & &1.id), opts) do
        {:ok, %{article: article}} -> {:ok, article}
        {:error, :claim_held_post, _, _} -> {:error, :not_found}
        {:error, :account, reason, _} -> {:error, reason}
        {:error, _step, %Ecto.Changeset{} = changeset, _} -> {:error, changeset}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  defp publish(%HeldPost{kind: "comment"} = held, author) do
    article = held.article_id && Repo.get(Article, held.article_id)

    cond do
      is_nil(article) or not is_nil(article.deleted_at) ->
        {:error, :article_gone}

      not Content.can_comment_on_article?(author, article) ->
        {:error, :cannot_comment}

      true ->
        attrs = %{
          "body" => held.body,
          "summary" => held.summary,
          "sensitive" => held.sensitive,
          "visibility" => held.visibility,
          "article_id" => article.id,
          "parent_id" => parent_in(held.parent_id, article.id),
          "user_id" => author.id
        }

        case Content.create_comment(attrs, image_ids: held.image_ids, held_post: held) do
          {:ok, comment} -> {:ok, comment}
          {:error, :already_reviewed} -> {:error, :not_found}
          {:error, _} = error -> error
        end
    end
  end

  # A board the author has lost the right to post in since submitting is
  # dropped rather than trusted from the row, as a resumed draft does.
  defp permitted_boards(board_ids, author) do
    Enum.flat_map(board_ids, fn board_id ->
      case Content.get_board(board_id) do
        {:ok, board} -> if Content.can_post_in_board?(board, author), do: [board], else: []
        _ -> []
      end
    end)
  end

  # The comment answered may have been hard-deleted and nilified, or never
  # have been in this article: then it becomes a reply to the article.
  defp parent_in(nil, _article_id), do: nil

  defp parent_in(parent_id, article_id) do
    case Content.get_comment(parent_id) do
      %{article_id: ^article_id} -> parent_id
      _ -> nil
    end
  end

  @doc """
  Rejects a held submission as `reviewer`, keeping it as the record of what
  was refused, and tells the author with the note.

  Returns `{:ok, %HeldPost{}}` or `{:error, :not_found}`.
  """
  @spec reject(HeldPost.t(), map(), String.t() | nil) ::
          {:ok, HeldPost.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def reject(%HeldPost{} = held, reviewer, note) do
    note = note |> to_string() |> String.trim() |> String.slice(0, 1000)
    note = if note == "", do: nil, else: note
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with %HeldPost{} = held <- get_pending_for_reviewer(held.id, reviewer),
         {1, [rejected]} <-
           Repo.update_all(
             from(h in HeldPost,
               where: h.id == ^held.id and h.status == "pending",
               select: h
             ),
             set: [
               status: "rejected",
               reviewed_by_id: reviewer.id,
               reviewed_at: now,
               review_note: note,
               updated_at: now
             ]
           ) do
      Hooks.notify_post_rejected(rejected)

      Moderation.log_action(reviewer.id, "reject_held_post",
        target_type: "held_post",
        target_id: rejected.id,
        details: %{"kind" => rejected.kind, "author_id" => rejected.user_id}
      )

      {:ok, rejected}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The uploads a held submission names that are still the author's own and
  still unattached, for the reviewer to see. `%{held_post_id => [image]}`.
  """
  @spec images_for([HeldPost.t()]) :: %{integer() => [struct()]}
  def images_for(held_posts) do
    Map.new(held_posts, fn held ->
      schema =
        if held.kind == "article",
          do: Baudrate.Content.ArticleImage,
          else: Baudrate.Content.CommentImage

      parent = if held.kind == "article", do: :article_id, else: :comment_id

      images =
        if held.image_ids == [] do
          []
        else
          from(i in schema,
            where: i.id in ^held.image_ids and i.user_id == ^held.user_id,
            where: is_nil(field(i, ^parent)),
            order_by: [asc: i.id]
          )
          |> Repo.all()
        end

      {held.id, images}
    end)
  end

  # --- The author's side ---

  @doc """
  The member's own held submissions, pending and rejected, newest first.
  """
  @spec list_for_author(integer()) :: [HeldPost.t()]
  def list_for_author(user_id) when is_integer(user_id) do
    from(h in HeldPost,
      where: h.user_id == ^user_id,
      order_by: [desc: h.inserted_at, desc: h.id],
      preload: [:article]
    )
    |> Repo.all()
  end

  @doc """
  Withdraws one of the member's own **pending** submissions. A rejected one
  stays: it is the record of what was refused, and it is not the author's to
  erase. Returns `:ok` either way.
  """
  @spec withdraw(integer(), integer()) :: :ok
  def withdraw(user_id, id) when is_integer(user_id) and is_integer(id) do
    from(h in HeldPost, where: h.id == ^id and h.user_id == ^user_id and h.status == "pending")
    |> Repo.delete_all()

    :ok
  end

  def withdraw(_, _), do: :ok

  # --- Housekeeping ---

  @doc """
  Deletes rejected submissions reviewed more than #{@rejected_days} days ago.
  Run hourly by `Baudrate.Retention`. Returns the count.
  """
  @spec purge_rejected(keyword()) :: non_neg_integer()
  def purge_rejected(opts \\ []) do
    cutoff =
      opts
      |> Keyword.get(:now, DateTime.utc_now())
      |> DateTime.add(-@rejected_days * 86_400, :second)

    query = from(h in HeldPost, where: h.status == "rejected" and h.reviewed_at < ^cutoff)

    if Keyword.get(opts, :dry_run, false) do
      Repo.aggregate(query, :count, :id)
    else
      {count, _} = Repo.delete_all(query)
      count
    end
  end

  @doc false
  # The board moderators who could approve `held`: those who moderate every
  # board it would appear in. Staff are added by the caller.
  @spec board_reviewer_ids(HeldPost.t()) :: [integer()]
  def board_reviewer_ids(%HeldPost{} = held) do
    board_ids =
      case held.kind do
        "article" ->
          held.board_ids

        "comment" ->
          Repo.all(
            from(ba in BoardArticle,
              where: ba.article_id == ^held.article_id,
              select: ba.board_id
            )
          )
      end

    case Enum.uniq(board_ids) do
      [] ->
        []

      ids ->
        needed = length(ids)

        Repo.all(
          from(bm in BoardModerator,
            where: bm.board_id in ^ids,
            group_by: bm.user_id,
            having: count(bm.board_id, :distinct) == ^needed,
            select: bm.user_id
          )
        )
    end
  end
end
