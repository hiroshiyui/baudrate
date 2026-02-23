defmodule BaudrateWeb.ArticleHistoryLive do
  @moduledoc """
  LiveView for displaying an article's edit history.

  Shows all revisions with timestamps and editor names. Selecting a revision
  displays a diff against the previous version, computed with
  `String.myers_difference/2`.

  Accessible to both guests and authenticated users via `:optional_auth`.
  Board visibility is enforced the same way as `ArticleLive`.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    article = Content.get_article_by_slug!(slug)
    current_user = socket.assigns.current_user

    if not user_can_view_article?(article, current_user) do
      redirect_to = if current_user, do: ~p"/", else: ~p"/login"
      {:ok, redirect(socket, to: redirect_to)}
    else
      revisions = Content.list_article_revisions(article.id)

      {:ok,
       socket
       |> assign(:article, article)
       |> assign(:revisions, revisions)
       |> assign(:selected_index, nil)
       |> assign(:page_title, gettext("Edit History — %{title}", title: article.title))}
    end
  end

  @impl true
  def handle_event("select_revision", %{"index" => index_str}, socket) do
    case Integer.parse(index_str) do
      {index, ""} -> {:noreply, assign(socket, :selected_index, index)}
      _ -> {:noreply, socket}
    end
  end

  @doc """
  Computes a diff between two strings using `String.myers_difference/2`
  and returns a list of `{tag, text}` tuples where tag is `:eq`, `:ins`, or `:del`.
  """
  def compute_diff(old_text, new_text) do
    String.myers_difference(old_text || "", new_text || "")
  end

  @doc """
  Returns the previous revision (older) relative to the given index.
  Revisions are ordered newest-first, so index+1 is the previous version.
  If no previous revision exists, the article's current state is used as
  a conceptual "first" — but in practice the oldest revision *is* the
  first snapshot, and there's nothing before it.
  """
  def get_previous_revision(revisions, index) do
    Enum.at(revisions, index + 1)
  end

  defp user_can_view_article?(article, user) do
    Enum.any?(article.boards, &Content.can_view_board?(&1, user))
  end
end
