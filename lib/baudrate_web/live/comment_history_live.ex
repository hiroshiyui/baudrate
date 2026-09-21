defmodule BaudrateWeb.CommentHistoryLive do
  @moduledoc """
  A comment's edit history (ADR 0060).

  The comment-side twin of `BaudrateWeb.ArticleHistoryLive`, and it answers the
  same question the same way: every revision with its editor and timestamp, and
  a diff against the version before it, computed on the fly with
  `String.myers_difference/2`.

  ## Who may read it

  Anyone who may read the thread. The gate is
  `ArticleHelpers.user_can_view_article?/2` on the **parent article** — the
  comment has no audience of its own, so borrowing the article's is the only
  answer that cannot disagree with the page the comment is rendered on. A
  guest sees exactly what a guest sees there.

  Making the history public is the decision, not an oversight. An edit
  rewrites what other people have already replied to; a history only the
  author can read tells the person who was replied to nothing, which is
  precisely who needs it.

  ## Two refusals

  A **soft-deleted comment answers 404**, even to its author.
  `Comment.soft_delete_changeset/2` replaces the body with a placeholder, so
  the row no longer carries what was withdrawn — but the revisions still do,
  and serving them would make deletion a way of *publishing* every earlier
  draft of the thing you just withdrew.

  A **remote comment answers 404** too. Its edits happen on the instance that
  minted it and are applied here by `Update(Note)` without a snapshot, so this
  page would be an empty frame implying a history we do not hold.

  Both are `NotFoundError`, not a redirect: a redirect tells a crawler the page
  moved (ADR 0057), and the two refusals must stay indistinguishable from a
  comment id that never existed.

  ## Why the current text is a version here and is not on the article page

  `@versions` is the live comment followed by its revisions, newest first.
  Revisions store the state **before** each edit, so a list of revisions alone
  can never show what the most recent edit changed — `ArticleHistoryLive` has
  that gap and this does not. Position 0 is the comment as it stands now.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content
  alias BaudrateWeb.ArticleHelpers

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    comment = fetch_comment!(id)

    article =
      Baudrate.Repo.get!(Content.Article, comment.article_id) |> Baudrate.Repo.preload(:boards)

    if not ArticleHelpers.user_can_view_article?(article, socket.assigns.current_user) do
      raise BaudrateWeb.NotFoundError
    end

    revisions = Content.list_comment_revisions(comment.id)

    {:ok,
     socket
     |> assign(:comment, comment)
     |> assign(:article, article)
     |> assign(:versions, [current_version(comment) | revisions])
     |> assign(:selected_index, nil)
     |> assign(:noindex, true)
     |> assign(:page_title, gettext("Edit History — comment on %{title}", title: article.title))}
  end

  # A client-supplied id, so it is parsed rather than trusted, and every
  # refusal answers alike.
  defp fetch_comment!(id) do
    with {:ok, comment_id} <- BaudrateWeb.Helpers.parse_id(id),
         %Content.Comment{deleted_at: nil, user_id: user_id} = comment
         when not is_nil(user_id) <- Baudrate.Repo.get(Content.Comment, comment_id) do
      Baudrate.Repo.preload(comment, :user)
    else
      _ -> raise BaudrateWeb.NotFoundError
    end
  end

  # The comment as it stands, shaped like a revision so the list and the diff
  # do not need a special case. `id: :current` never collides with a row id.
  defp current_version(comment) do
    %{
      id: :current,
      body: comment.body,
      summary: comment.summary,
      sensitive: comment.sensitive,
      editor: comment.user,
      inserted_at: comment.updated_at,
      current?: true
    }
  end

  @impl true
  def handle_event("select_version", %{"index" => index_str}, socket) do
    case Integer.parse(index_str) do
      {index, ""} when index >= 0 -> {:noreply, assign(socket, :selected_index, index)}
      _ -> {:noreply, socket}
    end
  end

  @doc """
  Computes a diff between two strings, as `{tag, text}` tuples where `tag` is
  `:eq`, `:ins` or `:del`.
  """
  def compute_diff(old_text, new_text) do
    String.myers_difference(old_text || "", new_text || "")
  end

  @doc """
  The version immediately older than the one at `index`.

  The list is newest-first, so that is `index + 1`; `nil` for the oldest
  revision, which has nothing before it to compare against.
  """
  def previous_version(versions, index), do: Enum.at(versions, index + 1)

  @doc "Whether a version entry is the live comment rather than a stored revision."
  def current?(%{current?: true}), do: true
  def current?(_), do: false
end
