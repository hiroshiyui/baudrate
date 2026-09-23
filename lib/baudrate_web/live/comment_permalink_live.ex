defmodule BaudrateWeb.CommentPermalinkLive do
  @moduledoc """
  A local comment's permanent address, `/comments/:id`.

  Comments are paged on their article, 20 threads to a page, so the page a
  comment is on changes as the thread grows, and a stored
  `/articles/:slug#comment-N` points at page 1 forever. This page never
  renders: it works out the page for whoever opened the link
  (`Content.comment_location/2`, with their blocks and mutes) and redirects
  there. It is the `url` a new local comment publishes, so "View original"
  on another instance lands on the comment rather than the top of the thread.

  The refusals are `CommentHistoryLive`'s, for the same reasons: a
  soft-deleted comment, a remote one (its own instance holds its address)
  and one in a thread the viewer cannot open all answer 404 — never a
  redirect, which a crawler would read as the page having moved (ADR 0057),
  and indistinguishable from an id that never existed. `/comments/` is a
  `noindex` prefix in `BaudrateWeb.Crawlers`.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content
  alias BaudrateWeb.ArticleHelpers

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    viewer = socket.assigns.current_user

    with {:ok, comment_id} <- BaudrateWeb.Helpers.parse_id(id),
         %Content.Comment{deleted_at: nil, user_id: user_id} = comment
         when not is_nil(user_id) <- Baudrate.Repo.get(Content.Comment, comment_id),
         %Content.Article{deleted_at: nil} = article <-
           Baudrate.Repo.get(Content.Article, comment.article_id),
         article = Baudrate.Repo.preload(article, :boards),
         true <- ArticleHelpers.user_can_view_article?(article, viewer) do
      {:ok, redirect(socket, to: BaudrateWeb.Helpers.comment_link(article, comment, viewer))}
    else
      _ -> raise BaudrateWeb.NotFoundError
    end
  end

  @impl true
  def render(assigns), do: ~H""
end
