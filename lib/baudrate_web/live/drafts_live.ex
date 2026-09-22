defmodule BaudrateWeb.DraftsLive do
  @moduledoc """
  A member's unfinished articles, at `/drafts`.

  Only ever their own. Every read goes through `Baudrate.Content.Drafts`,
  which scopes by owner in the query rather than fetching and then checking,
  so a draft id belonging to somebody else is indistinguishable here from one
  that does not exist.

  Resuming pushes the id into the composer as `/articles/new?draft=N`, and the
  composer re-checks ownership itself — the id in that URL is client-supplied
  like any other, and the page that produced it proves nothing.

  It also lists the member's posts that are waiting for a moderator, and the
  ones a moderator declined, with the text they wrote (ADR 0065). A pending
  one can be withdrawn; a declined one cannot be deleted from here, because it
  is the record of what was refused and is removed on its own after 90 days.

  The page is `noindex` and names no canonical (ADR 0057). It is behind
  `:require_auth` so a crawler is redirected to the login page long before it
  gets here, but a list of what somebody has started writing and not published
  is the last thing that should ever reach an index if that ever changes.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content
  alias Baudrate.Moderation.HeldPosts

  import BaudrateWeb.Helpers, only: [parse_id: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Drafts"))
     |> load_drafts()}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, draft_id} ->
        Content.delete_draft(socket.assigns.current_user.id, draft_id)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Draft deleted."))
         |> load_drafts()}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("withdraw_held", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, held_id} ->
        HeldPosts.withdraw(socket.assigns.current_user.id, held_id)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Withdrawn. Nobody will review it now."))
         |> load_drafts()
         |> push_event("focus", %{id: "drafts-heading"})}

      :error ->
        {:noreply, socket}
    end
  end

  # Authenticated LiveViews receive DM and notification PubSub messages via the
  # count hooks whether or not they use them.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_drafts(socket) do
    drafts = Content.list_drafts(socket.assigns.current_user.id)

    socket
    |> assign(:drafts, drafts)
    |> assign(:draft_count, length(drafts))
    |> assign(:max_drafts, Content.max_drafts())
    |> assign(:held_posts, HeldPosts.list_for_author(socket.assigns.current_user.id))
  end

  @doc """
  A draft's heading: its title, or a first line of the body, or a plain
  statement that it is empty.

  A row with no title is the common case — people write the post before they
  name it — so falling back to the body is what makes the list readable at
  all. `Untitled` on every row would be a list of identical entries.
  """
  def draft_heading(%{title: title}) when is_binary(title) and title != "", do: title

  def draft_heading(%{body: body}) when is_binary(body) and body != "" do
    body
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.slice(0, 80)
  end

  def draft_heading(_), do: gettext("Empty draft")

  @doc "A held post's heading: an article's title, or which article a comment is on."
  def held_heading(%{kind: "article", title: title}) when is_binary(title), do: title

  def held_heading(%{kind: "comment", article: %{title: title}}) when is_binary(title),
    do: gettext("Your comment on “%{title}”", title: title)

  def held_heading(_), do: gettext("Your comment")
end
