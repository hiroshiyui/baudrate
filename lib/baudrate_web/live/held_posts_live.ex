defmodule BaudrateWeb.HeldPostsLive do
  @moduledoc """
  Posts waiting for a moderator, at `/moderation/held` (Phase 5C, ADR 0065).

  One page for everyone who reviews: admins and global moderators see every
  held post, and a board moderator sees the ones they could approve — an
  article whose every board they moderate, a comment on an article in only
  boards they moderate. That is why it lives beside `/moderation` rather than
  under `/admin`: board moderators are ordinary members.

  Every decision is `Baudrate.Moderation.HeldPosts`'s. The id of a held post
  comes from the client, so approving and rejecting look it up again inside
  the reviewer's scope; this page never trusts the row it rendered.

  Approving publishes the post as its author. It can fail for reasons that
  arose after the submission — the author has been silenced, lost the right to
  post in its boards, or the article a comment answers has been locked — and
  each says which.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content
  alias Baudrate.Moderation.HeldPosts

  import BaudrateWeb.Helpers, only: [parse_id: 1, parse_page: 1]

  @statuses ~w(pending rejected)

  @impl true
  def mount(_params, _session, socket) do
    if HeldPosts.reviewer?(socket.assigns.current_user) do
      {:ok,
       assign(socket,
         status: "pending",
         page: 1,
         total_pages: 1,
         held_posts: [],
         images: %{},
         boards: %{},
         page_title: gettext("Posts waiting for review")
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not moderate any boards."))
       |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = if params["status"] in @statuses, do: params["status"], else: "pending"

    {:noreply,
     socket
     |> assign(status: status, page: parse_page(params["page"]))
     |> load()}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) when status in @statuses do
    {:noreply, push_patch(socket, to: ~p"/moderation/held?status=#{status}")}
  end

  def handle_event("approve", %{"id" => id}, socket) do
    with_held(socket, id, fn held ->
      case HeldPosts.approve(held, socket.assigns.current_user) do
        {:ok, _published} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Approved and published."))
           |> load()
           |> push_event("focus", %{id: "held-posts-heading"})}

        {:error, reason} ->
          {:noreply, socket |> put_flash(:error, approve_refusal(reason)) |> load()}
      end
    end)
  end

  def handle_event("reject", %{"held_post_id" => id} = params, socket) do
    with_held(socket, id, fn held ->
      case HeldPosts.reject(held, socket.assigns.current_user, params["note"]) do
        {:ok, _rejected} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Declined. The author has been told."))
           |> load()
           |> push_event("focus", %{id: "held-posts-heading"})}

        {:error, _} ->
          {:noreply, socket |> put_flash(:error, not_found()) |> load()}
      end
    end)
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp with_held(socket, id, fun) do
    with {:ok, held_id} <- parse_id(id),
         %{} = held <- HeldPosts.get_pending_for_reviewer(held_id, socket.assigns.current_user) do
      fun.(held)
    else
      _ -> {:noreply, socket |> put_flash(:error, not_found()) |> load()}
    end
  end

  defp load(socket) do
    %{held_posts: held_posts, page: page, total_pages: total_pages} =
      HeldPosts.paginate_for_reviewer(socket.assigns.current_user,
        status: socket.assigns.status,
        page: socket.assigns.page
      )

    board_ids = held_posts |> Enum.flat_map(& &1.board_ids) |> Enum.uniq()

    boards =
      Enum.reduce(board_ids, %{}, fn board_id, acc ->
        case Content.get_board(board_id) do
          {:ok, board} -> Map.put(acc, board.id, board)
          _ -> acc
        end
      end)

    images =
      if socket.assigns.status == "pending", do: HeldPosts.images_for(held_posts), else: %{}

    assign(socket,
      held_posts: held_posts,
      page: page,
      total_pages: total_pages,
      boards: boards,
      images: images
    )
  end

  defp not_found,
    do: gettext("That post has already been reviewed, or it is not yours to review.")

  @doc false
  def approve_refusal(:not_found), do: not_found()

  def approve_refusal(:no_boards),
    do:
      gettext(
        "The author can no longer post in any of the boards this article was for, so it cannot be published."
      )

  def approve_refusal(:article_gone),
    do: gettext("The article this comment answers has been removed.")

  def approve_refusal(:cannot_comment),
    do:
      gettext(
        "The article this comment answers is locked, or its author can no longer comment there."
      )

  def approve_refusal(reason)
      when reason in [
             :banned,
             :account_suspended,
             :account_silenced,
             :account_moved,
             :terms_not_accepted
           ],
      do:
        gettext(
          "The author's account is restricted at the moment, so the post cannot be published."
        )

  def approve_refusal(:blocked),
    do: gettext("A block now stands between the author and the person they were answering.")

  def approve_refusal(_), do: gettext("The post could not be published.")

  @doc false
  def reason_label(%{reason: "filter", content_filter: %{pattern: pattern}}),
    do: gettext("Matched the filter “%{pattern}”", pattern: pattern)

  def reason_label(%{reason: "filter"}), do: gettext("Matched a filter since deleted")

  def reason_label(%{reason: "first_posts", content_filter: %{pattern: pattern}}),
    do: gettext("One of the author's first posts; also matched “%{pattern}”", pattern: pattern)

  def reason_label(%{reason: "first_posts"}), do: gettext("One of the author's first posts")

  def reason_label(_), do: gettext("Held")
end
