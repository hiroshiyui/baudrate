defmodule BaudrateWeb.ArticleLive do
  @moduledoc """
  LiveView for displaying a single article with comments.

  Accessible to both guests and authenticated users via `:optional_auth`.
  Guests can only view articles that belong to at least one board they can view;
  articles exclusively in restricted boards redirect appropriately.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content
  alias Baudrate.Content.PubSub, as: ContentPubSub
  alias Baudrate.Moderation
  alias BaudrateWeb.LinkedData
  alias BaudrateWeb.OpenGraph
  alias BaudrateWeb.RateLimits
  import BaudrateWeb.Helpers, only: [parse_id: 1, parse_page: 1]

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    article = Content.get_article_by_slug!(slug)
    current_user = socket.assigns.current_user

    if not user_can_view_article?(article, current_user) do
      redirect_to = if current_user, do: ~p"/", else: ~p"/login"
      {:ok, redirect(socket, to: redirect_to)}
    else
      can_edit =
        if current_user, do: Content.can_edit_article?(current_user, article), else: false

      can_delete =
        if current_user, do: Content.can_delete_article?(current_user, article), else: false

      can_pin =
        if current_user, do: Content.can_pin_article?(current_user, article), else: false

      can_lock =
        if current_user, do: Content.can_lock_article?(current_user, article), else: false

      is_board_mod = Content.can_moderate_article?(current_user, article)
      can_comment = Content.can_comment_on_article?(current_user, article)

      comment_changeset = Content.change_comment()
      article_images = Content.list_article_images(article.id)
      revision_count = Content.count_article_revisions(article.id)

      socket =
        socket
        |> assign(:article, article)
        |> assign(:can_edit, can_edit)
        |> assign(:can_delete, can_delete)
        |> assign(:can_pin, can_pin)
        |> assign(:can_lock, can_lock)
        |> assign(:is_board_mod, is_board_mod)
        |> assign(:comment_roots, [])
        |> assign(:children_map, %{})
        |> assign(:comment_page, 1)
        |> assign(:comment_total_pages, 1)
        |> assign(:can_comment, can_comment)
        |> assign(:comment_form, to_form(comment_changeset, as: :comment))
        |> assign(:replying_to, nil)
        |> assign(:article_images, article_images)
        |> assign(:revision_count, revision_count)
        |> assign(:page_title, article.title)
        |> assign(
          :linked_data_json,
          LinkedData.article_jsonld(article) |> LinkedData.encode_jsonld()
        )
        |> assign(:dc_meta, LinkedData.dublin_core_meta(:article, article))
        |> assign(:og_meta, OpenGraph.article_tags(article, article_images))
        |> assign(:can_forward, Content.can_forward_article?(current_user, article))
        |> assign(:forward_search_open, false)
        |> assign(:forward_search_results, [])
        |> assign(:forward_search_query, "")
        |> assign(:show_report_modal, false)
        |> assign(:report_target_type, nil)
        |> assign(:report_target_id, nil)
        |> assign(:report_target_label, nil)
        |> assign(
          :liked,
          if(current_user,
            do: Content.article_liked?(current_user.id, article.id),
            else: false
          )
        )
        |> assign(:like_count, Content.count_article_likes(article))
        |> assign(:comment_liked_ids, MapSet.new())
        |> assign(:comment_like_counts, %{})
        |> assign(
          :bookmarked,
          if(current_user,
            do: Content.article_bookmarked?(current_user.id, article.id),
            else: false
          )
        )
        |> assign_poll_data(article, current_user)

      if connected?(socket) do
        ContentPubSub.subscribe_article(article.id)

        if current_user do
          Content.mark_article_read(current_user.id, article.id)
        end
      end

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    comment_page = parse_page(params["page"])

    {:noreply, load_comments(socket, comment_page)}
  end

  @impl true
  def handle_event("delete_article", _params, socket) do
    article = socket.assigns.article
    user = socket.assigns.current_user

    if socket.assigns.can_delete do
      if user.role.name != "admin" do
        case RateLimits.check_delete_content(user.id) do
          {:error, :rate_limited} ->
            {:noreply,
             put_flash(socket, :error, gettext("Too many actions. Please try again later."))}

          :ok ->
            do_delete_article(socket, article, user)
        end
      else
        do_delete_article(socket, article, user)
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  @impl true
  def handle_event("toggle_pin", _params, socket) do
    article = socket.assigns.article

    if socket.assigns.can_pin do
      case Content.toggle_pin_article(article) do
        {:ok, updated} ->
          Moderation.log_action(
            socket.assigns.current_user.id,
            if(updated.pinned, do: "pin_article", else: "unpin_article"),
            target_type: "article",
            target_id: article.id,
            details: %{"title" => article.title}
          )

          {:noreply, assign(socket, :article, updated)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to update article."))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  @impl true
  def handle_event("toggle_lock", _params, socket) do
    article = socket.assigns.article

    if socket.assigns.can_lock do
      case Content.toggle_lock_article(article) do
        {:ok, updated} ->
          Moderation.log_action(
            socket.assigns.current_user.id,
            if(updated.locked, do: "lock_article", else: "unlock_article"),
            target_type: "article",
            target_id: article.id,
            details: %{"title" => article.title}
          )

          updated = Baudrate.Repo.preload(updated, :boards)
          can_comment = Content.can_comment_on_article?(socket.assigns.current_user, updated)

          {:noreply,
           socket
           |> assign(:article, updated)
           |> assign(:can_comment, can_comment)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to update article."))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  @impl true
  def handle_event("toggle_bookmark", _params, socket) do
    user = socket.assigns.current_user
    article = socket.assigns.article

    case Content.toggle_article_bookmark(user.id, article.id) do
      {:ok, _} ->
        bookmarked = Content.article_bookmarked?(user.id, article.id)
        {:noreply, assign(socket, :bookmarked, bookmarked)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to toggle bookmark."))}
    end
  end

  @impl true
  def handle_event("toggle_like", _params, socket) do
    user = socket.assigns.current_user
    article = socket.assigns.article

    case Content.toggle_article_like(user.id, article.id) do
      {:ok, _} ->
        liked = Content.article_liked?(user.id, article.id)
        like_count = Content.count_article_likes(article)
        {:noreply, socket |> assign(:liked, liked) |> assign(:like_count, like_count)}

      {:error, :self_like} ->
        {:noreply, put_flash(socket, :error, gettext("You cannot like your own article."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to toggle like."))}
    end
  end

  @impl true
  def handle_event("toggle_comment_like", %{"id" => id}, socket) do
    case parse_id(id) do
      :error ->
        {:noreply, socket}

      {:ok, comment_id} ->
        user = socket.assigns.current_user

        case Content.toggle_comment_like(user.id, comment_id) do
          {:ok, _} ->
            liked_ids = socket.assigns.comment_liked_ids

            liked_ids =
              if MapSet.member?(liked_ids, comment_id),
                do: MapSet.delete(liked_ids, comment_id),
                else: MapSet.put(liked_ids, comment_id)

            # Update the count for this specific comment
            new_counts = Content.comment_like_counts([comment_id])
            new_count = Map.get(new_counts, comment_id, 0)

            counts =
              Map.put(socket.assigns.comment_like_counts, comment_id, new_count)

            {:noreply,
             socket
             |> assign(:comment_liked_ids, liked_ids)
             |> assign(:comment_like_counts, counts)}

          {:error, :self_like} ->
            {:noreply, put_flash(socket, :error, gettext("You cannot like your own comment."))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to toggle like."))}
        end
    end
  end

  @impl true
  def handle_event("delete_comment", %{"id" => id}, socket) do
    case parse_id(id) do
      :error ->
        {:noreply, socket}

      {:ok, comment_id} ->
        user = socket.assigns.current_user

        if user.role.name != "admin" do
          case RateLimits.check_delete_content(user.id) do
            {:error, :rate_limited} ->
              {:noreply,
               put_flash(socket, :error, gettext("Too many actions. Please try again later."))}

            :ok ->
              do_delete_comment(socket, comment_id, user)
          end
        else
          do_delete_comment(socket, comment_id, user)
        end
    end
  end

  @impl true
  def handle_event("validate_comment", %{"comment" => params}, socket) do
    changeset =
      Content.change_comment(%Baudrate.Content.Comment{}, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :comment_form, to_form(changeset, as: :comment))}
  end

  @impl true
  def handle_event("submit_comment", %{"comment" => params}, socket) do
    user = socket.assigns.current_user

    if user.role.name != "admin" do
      case RateLimits.check_create_comment(user.id) do
        {:error, :rate_limited} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("You are commenting too frequently. Please try again later.")
           )}

        :ok ->
          do_create_comment(socket, user, params)
      end
    else
      do_create_comment(socket, user, params)
    end
  end

  @impl true
  def handle_event("reply_to", %{"id" => comment_id}, socket) do
    case parse_id(comment_id) do
      {:ok, id} -> {:noreply, assign(socket, :replying_to, id)}
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_reply", _params, socket) do
    {:noreply, assign(socket, :replying_to, nil)}
  end

  @impl true
  def handle_event("toggle_forward_search", _params, socket) do
    open = !socket.assigns.forward_search_open

    {:noreply,
     socket
     |> assign(:forward_search_open, open)
     |> assign(:forward_search_results, [])
     |> assign(:forward_search_query, "")}
  end

  @impl true
  def handle_event("search_forward_board", %{"query" => query}, socket) do
    results =
      if String.length(String.trim(query)) >= 2 do
        existing_board_ids = MapSet.new(socket.assigns.article.boards, & &1.id)

        Content.search_boards(query, socket.assigns.current_user)
        |> Enum.reject(&MapSet.member?(existing_board_ids, &1.id))
      else
        []
      end

    {:noreply,
     socket
     |> assign(:forward_search_query, query)
     |> assign(:forward_search_results, results)}
  end

  @impl true
  def handle_event("forward_to_board", %{"board-id" => board_id}, socket) do
    user = socket.assigns.current_user

    with {:ok, board_id} <- parse_id(board_id),
         {:ok, board} <- Content.get_board(board_id),
         :ok <- check_forward_rate_limit(user),
         {:ok, updated_article} <-
           Content.forward_article_to_board(socket.assigns.article, board, user) do
      {:noreply,
       socket
       |> assign(:article, updated_article)
       |> assign(:can_forward, Content.can_forward_article?(user, updated_article))
       |> assign(:forward_search_open, false)
       |> assign(:forward_search_results, [])
       |> assign(:forward_search_query, "")
       |> put_flash(:info, gettext("Article forwarded to board."))}
    else
      {:error, :rate_limited} ->
        {:noreply,
         put_flash(socket, :error, gettext("Too many actions. Please try again later."))}

      {:error, :not_forwardable} ->
        {:noreply, put_flash(socket, :error, gettext("This article cannot be forwarded."))}

      {:error, :cannot_post} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You do not have permission to post in this board.")
         )}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("Not authorized."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Failed to forward article."))}
    end
  end

  @impl true
  def handle_event("cast_vote", params, socket) do
    poll = socket.assigns.poll
    user = socket.assigns.current_user

    if is_nil(user) or is_nil(poll) do
      {:noreply, put_flash(socket, :error, gettext("Cannot vote on this poll."))}
    else
      option_ids = extract_vote_option_ids(params, poll)

      case Content.cast_vote(poll, user, option_ids) do
        {:ok, updated_poll} ->
          user_votes = Content.get_user_poll_votes(updated_poll.id, user.id)

          schedule_federation_vote(user, socket.assigns.article, updated_poll, option_ids)

          {:noreply,
           socket
           |> assign(:poll, updated_poll)
           |> assign(:user_votes, user_votes)
           |> assign(:has_voted, true)
           |> put_flash(:info, gettext("Vote recorded."))}

        {:error, :poll_closed} ->
          {:noreply,
           socket
           |> assign(:poll_closed, true)
           |> put_flash(:error, gettext("This poll has closed."))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to record vote."))}
      end
    end
  end

  @impl true
  def handle_event("change_vote", _params, socket) do
    {:noreply, assign(socket, :has_voted, false)}
  end

  @impl true
  def handle_event("open_report_modal", %{"type" => type, "id" => id} = params, socket) do
    label = params["label"]

    {:noreply,
     socket
     |> assign(:show_report_modal, true)
     |> assign(:report_target_type, type)
     |> assign(:report_target_id, id)
     |> assign(:report_target_label, label)}
  end

  @impl true
  def handle_event("close_report_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_report_modal, false)
     |> assign(:report_target_type, nil)
     |> assign(:report_target_id, nil)
     |> assign(:report_target_label, nil)}
  end

  @impl true
  def handle_event("submit_report", %{"reason" => reason}, socket) do
    user = socket.assigns.current_user

    case RateLimits.check_create_report(user.id) do
      {:error, :rate_limited} ->
        {:noreply,
         socket
         |> assign(:show_report_modal, false)
         |> put_flash(:error, gettext("Too many reports. Please try again later."))}

      :ok ->
        target_attrs =
          build_report_target(socket.assigns.report_target_type, socket.assigns.report_target_id)

        cond do
          target_attrs == %{} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to submit report."))}

          Moderation.has_open_report?(user.id, target_attrs) ->
            {:noreply,
             socket
             |> assign(:show_report_modal, false)
             |> put_flash(:error, gettext("You have already reported this."))}

          true ->
            attrs = Map.merge(target_attrs, %{reason: reason, reporter_id: user.id})

            case Moderation.create_report(attrs) do
              {:ok, _report} ->
                {:noreply,
                 socket
                 |> assign(:show_report_modal, false)
                 |> put_flash(:info, gettext("Report submitted. Thank you."))}

              {:error, _changeset} ->
                {:noreply, put_flash(socket, :error, gettext("Failed to submit report."))}
            end
        end
    end
  end

  defp build_report_target("article", id) do
    case Integer.parse(id) do
      {num, ""} -> %{article_id: num}
      _ -> %{}
    end
  end

  defp build_report_target("comment", id) do
    case Integer.parse(id) do
      {num, ""} -> %{comment_id: num}
      _ -> %{}
    end
  end

  defp build_report_target(_, _), do: %{}

  @impl true
  def handle_info({event, _payload}, socket)
      when event in [:comment_created, :comment_deleted] do
    {:noreply, load_comments(socket, socket.assigns.comment_page)}
  end

  @impl true
  def handle_info({:link_preview_fetched, %{article_id: _}}, socket) do
    article = Content.get_article_by_slug!(socket.assigns.article.slug)
    {:noreply, assign(socket, :article, article)}
  end

  @impl true
  def handle_info({:link_preview_fetched, %{comment_id: _}}, socket) do
    {:noreply, load_comments(socket, socket.assigns.comment_page)}
  end

  @impl true
  def handle_info({:article_deleted, _payload}, socket) do
    board = List.first(socket.assigns.article.boards)
    redirect_path = if board, do: ~p"/boards/#{board.slug}", else: ~p"/"

    {:noreply,
     socket
     |> put_flash(:info, gettext("This article has been deleted."))
     |> redirect(to: redirect_path)}
  end

  @impl true
  def handle_info({:article_updated, _payload}, socket) do
    article = Content.get_article_by_slug!(socket.assigns.article.slug)

    {:noreply,
     socket
     |> assign(:article, article)
     |> assign(:can_forward, Content.can_forward_article?(socket.assigns.current_user, article))
     |> assign_poll_data(article, socket.assigns.current_user)}
  end

  @doc false
  attr :comment, :map, required: true
  attr :children_map, :map, required: true
  attr :depth, :integer, required: true
  attr :can_comment, :boolean, required: true
  attr :can_delete, :boolean, required: true
  attr :replying_to, :any, required: true
  attr :comment_form, :any, required: true
  attr :current_user, :any, default: nil
  attr :comment_liked_ids, :any, default: nil
  attr :comment_like_counts, :any, default: nil

  def comment_node(assigns) do
    assigns = assign(assigns, :children, Map.get(assigns.children_map, assigns.comment.id, []))

    ~H"""
    <div
      id={"comment-#{@comment.id}"}
      class={["comment border-l-2 border-base-300 pl-4", @depth > 0 && "ml-4"]}
    >
      <div class="py-2">
        <div class="flex flex-wrap items-center gap-2 text-sm text-base-content/70 mb-1">
          <.link
            :if={@comment.user}
            navigate={~p"/users/#{@comment.user.username}"}
            class="inline-flex items-center gap-1 font-semibold text-base-content link link-hover"
          >
            <.avatar user={@comment.user} size={24} />
            {display_name(@comment.user)}
          </.link>
          <a
            :if={@comment.remote_actor}
            href={remote_actor_profile_url(@comment.remote_actor)}
            target="_blank"
            rel="nofollow noopener noreferrer"
            class="font-semibold text-base-content link link-hover"
          >
            {display_name(@comment.remote_actor)}@{@comment.remote_actor.domain}
          </a>
          <span>&middot;</span>
          <time datetime={datetime_attr(@comment.inserted_at)}>
            {format_datetime(@comment.inserted_at)}
          </time>

          <button
            :if={@can_delete}
            phx-click="delete_comment"
            phx-value-id={@comment.id}
            data-confirm={gettext("Are you sure you want to delete this comment?")}
            class="btn btn-sm btn-ghost text-error ml-auto"
            aria-label={gettext("Delete comment")}
          >
            <.icon name="hero-trash" class="size-3" />
          </button>
        </div>

        <div :if={@comment.body_html} class="prose prose-sm max-w-none">
          {raw(@comment.body_html)}
        </div>
        <div :if={!@comment.body_html} class="prose prose-sm max-w-none">
          {raw(Baudrate.Content.Markdown.to_html(@comment.body))}
        </div>

        <.link_preview
          :if={@comment.link_preview && @comment.link_preview.status in ["fetched", "failed"]}
          preview={@comment.link_preview}
        />

        <div
          :if={@comment.user && @comment.user.signature && @comment.user.signature != ""}
          class="mt-1"
        >
          <div class="divider text-sm text-base-content/70 my-1"></div>
          <div class="prose prose-sm max-w-none text-base-content/70">
            {raw(Baudrate.Content.Markdown.to_html(@comment.user.signature))}
          </div>
        </div>

        <div class="flex items-center gap-3 mt-1">
          <button
            :if={@can_comment && @depth < 5 && @replying_to != @comment.id}
            phx-click="reply_to"
            phx-value-id={@comment.id}
            class="text-sm text-base-content/70 hover:text-base-content cursor-pointer"
            aria-label={
              gettext("Reply to %{author}",
                author: display_name(@comment.user || @comment.remote_actor)
              )
            }
          >
            {gettext("Reply")}
          </button>
          <%!-- Comment like button --%>
          <.comment_like_button
            comment={@comment}
            current_user={@current_user}
            comment_liked_ids={@comment_liked_ids}
            comment_like_counts={@comment_like_counts}
          />
          <%!-- Report comment menu --%>
          <div
            :if={@current_user && @comment.user_id != @current_user.id}
            class="dropdown dropdown-end"
          >
            <button
              type="button"
              tabindex="0"
              class="btn btn-ghost btn-xs btn-circle"
              aria-haspopup="true"
              aria-label={gettext("More actions")}
            >
              <.icon name="hero-ellipsis-vertical" class="size-4" />
            </button>
            <ul
              tabindex="0"
              class="dropdown-content menu bg-base-200 rounded-box z-10 w-40 p-2 shadow-sm"
            >
              <li>
                <button
                  phx-click="open_report_modal"
                  phx-value-type="comment"
                  phx-value-id={@comment.id}
                  phx-value-label={String.slice(@comment.body || "", 0..100)}
                >
                  <.icon name="hero-flag" class="size-3" />
                  {gettext("Report")}
                </button>
              </li>
            </ul>
          </div>
        </div>

        <%!-- Inline reply form --%>
        <div :if={@replying_to == @comment.id} class="mt-2">
          <.form
            for={@comment_form}
            phx-change="validate_comment"
            phx-submit="submit_comment"
            id={"reply-form-#{@comment.id}"}
            phx-hook="DraftSaveHook"
            data-draft-key={"draft:comment:#{@comment.article_id}:reply:#{@comment.id}"}
            data-draft-fields="comment[body]"
            class="space-y-2"
          >
            <.input
              field={@comment_form[:body]}
              type="textarea"
              placeholder={gettext("Write a reply...")}
              toolbar
              rows="6"
            />
            <div class="flex gap-2">
              <button
                type="submit"
                class="btn btn-sm btn-primary"
                phx-disable-with={gettext("Posting...")}
              >
                {gettext("Reply")}
              </button>
              <button type="button" phx-click="cancel_reply" class="btn btn-sm btn-ghost">
                {gettext("Cancel")}
              </button>
            </div>
          </.form>
        </div>
      </div>

      <%!-- Recursive children --%>
      <%= for child <- @children do %>
        <.comment_node
          comment={child}
          children_map={@children_map}
          depth={@depth + 1}
          can_comment={@can_comment}
          can_delete={@can_delete}
          replying_to={@replying_to}
          comment_form={@comment_form}
          current_user={@current_user}
          comment_liked_ids={@comment_liked_ids}
          comment_like_counts={@comment_like_counts}
        />
      <% end %>
    </div>
    """
  end

  attr :comment, :map, required: true
  attr :current_user, :any, default: nil
  attr :comment_liked_ids, :any, default: nil
  attr :comment_like_counts, :any, default: nil

  defp comment_like_button(assigns) do
    liked_ids = assigns.comment_liked_ids || MapSet.new()
    counts = assigns.comment_like_counts || %{}
    is_liked = MapSet.member?(liked_ids, assigns.comment.id)
    is_own = assigns.current_user && assigns.comment.user_id == assigns.current_user.id
    like_count = Map.get(counts, assigns.comment.id, 0)

    assigns =
      assigns
      |> assign(:is_liked, is_liked)
      |> assign(:is_own, is_own)
      |> assign(:like_count, like_count)

    ~H"""
    <span class="inline-flex items-center gap-1 text-sm text-base-content/70">
      <button
        :if={@current_user && !@is_own}
        type="button"
        phx-click="toggle_comment_like"
        phx-value-id={@comment.id}
        class="hover:text-error cursor-pointer"
        aria-label={if @is_liked, do: gettext("Unlike"), else: gettext("Like")}
      >
        <.icon
          name={if @is_liked, do: "hero-heart-solid", else: "hero-heart"}
          class={["size-4", @is_liked && "text-error"]}
        />
      </button>
      <.icon :if={!@current_user || @is_own} name="hero-heart" class="size-4" />
      <span :if={@like_count > 0}>{@like_count}</span>
    </span>
    """
  end

  defp do_delete_article(socket, article, user) do
    case Content.soft_delete_article(article) do
      {:ok, _} ->
        if user.id != article.user_id do
          Moderation.log_action(user.id, "delete_article",
            target_type: "article",
            target_id: article.id,
            details: %{"title" => article.title}
          )
        end

        board = List.first(article.boards)
        redirect_path = if board, do: ~p"/boards/#{board.slug}", else: ~p"/"

        {:noreply,
         socket
         |> put_flash(:info, gettext("Article deleted."))
         |> redirect(to: redirect_path)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete article."))}
    end
  end

  defp do_delete_comment(socket, comment_id, user) do
    article = socket.assigns.article

    case Content.get_comment(comment_id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Comment not found."))}

      comment ->
        if Content.can_delete_comment?(user, comment, article) do
          case Content.soft_delete_comment(comment) do
            {:ok, _} ->
              if user.id != comment.user_id do
                Moderation.log_action(user.id, "delete_comment",
                  target_type: "comment",
                  target_id: comment.id,
                  details: %{"article_title" => article.title}
                )
              end

              {:noreply,
               socket
               |> load_comments(socket.assigns.comment_page)
               |> put_flash(:info, gettext("Comment deleted."))}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, gettext("Failed to delete comment."))}
          end
        else
          {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
        end
    end
  end

  defp do_create_comment(socket, user, params) do
    article = socket.assigns.article

    attrs =
      params
      |> Map.put("article_id", article.id)
      |> Map.put("user_id", user.id)

    attrs =
      if socket.assigns.replying_to do
        Map.put(attrs, "parent_id", socket.assigns.replying_to)
      else
        attrs
      end

    case Content.create_comment(attrs) do
      {:ok, _comment} ->
        {:noreply,
         socket
         |> load_comments(socket.assigns.comment_page)
         |> assign(:comment_form, to_form(Content.change_comment(), as: :comment))
         |> assign(:replying_to, nil)
         |> put_flash(:info, gettext("Comment posted."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :comment_form, to_form(changeset, as: :comment))}
    end
  end

  defp load_comments(socket, page) do
    article = socket.assigns.article
    current_user = socket.assigns.current_user

    %{comments: comments, page: comment_page, total_pages: comment_total_pages} =
      Content.paginate_comments_for_article(article, current_user, page: page)

    {roots, children_map} = build_comment_tree(comments)

    all_comment_ids = Enum.map(comments, & &1.id)

    comment_liked_ids =
      if current_user do
        Content.comment_likes_by_user(current_user.id, all_comment_ids)
      else
        MapSet.new()
      end

    comment_like_counts = Content.comment_like_counts(all_comment_ids)

    assign(socket,
      comment_roots: roots,
      children_map: children_map,
      comment_page: comment_page,
      comment_total_pages: comment_total_pages,
      comment_liked_ids: comment_liked_ids,
      comment_like_counts: comment_like_counts
    )
  end

  defp check_forward_rate_limit(%{role: %{name: "admin"}}), do: :ok

  defp check_forward_rate_limit(user) do
    case RateLimits.check_create_article(user.id) do
      :ok -> :ok
      {:error, :rate_limited} -> {:error, :rate_limited}
    end
  end

  defp user_can_view_article?(article, _user) when article.boards == [], do: true

  defp user_can_view_article?(article, user) do
    Enum.any?(article.boards, &Content.can_view_board?(&1, user))
  end

  defp build_comment_tree(comments) do
    roots = Enum.filter(comments, &is_nil(&1.parent_id))

    children_map =
      comments
      |> Enum.filter(& &1.parent_id)
      |> Enum.group_by(& &1.parent_id)

    {roots, children_map}
  end

  # --- Poll helpers ---

  defp assign_poll_data(socket, article, current_user) do
    poll = article.poll

    if poll do
      user_votes =
        if current_user,
          do: Content.get_user_poll_votes(poll.id, current_user.id),
          else: []

      socket
      |> assign(:poll, poll)
      |> assign(:user_votes, user_votes)
      |> assign(:has_voted, user_votes != [])
      |> assign(:poll_closed, Baudrate.Content.Poll.closed?(poll))
    else
      socket
      |> assign(:poll, nil)
      |> assign(:user_votes, [])
      |> assign(:has_voted, false)
      |> assign(:poll_closed, false)
    end
  end

  defp extract_vote_option_ids(params, poll) do
    case poll.mode do
      "single" ->
        case params["vote_option"] do
          nil -> []
          id -> parse_int_list([id])
        end

      "multiple" ->
        (params["vote_options"] || [])
        |> List.wrap()
        |> parse_int_list()
    end
  end

  defp parse_int_list(strings) do
    Enum.flat_map(strings, fn s ->
      case Integer.parse(s) do
        {n, ""} -> [n]
        _ -> []
      end
    end)
  end

  defp schedule_federation_vote(user, article, poll, option_ids) do
    # Only federate votes on remote articles (those with a remote_actor)
    if article.remote_actor_id do
      poll = Content.preload_poll_options(poll)

      voted_options =
        poll.options
        |> Enum.filter(&(&1.id in option_ids))

      Content.schedule_federation_task(fn ->
        Baudrate.Federation.Publisher.publish_vote(user, article, voted_options)
      end)
    end
  end

  defp poll_percentage(_votes_count, 0), do: 0

  defp poll_percentage(votes_count, total) do
    Float.round(votes_count / total * 100, 1)
  end

  defp total_votes(poll) do
    Enum.sum(Enum.map(poll.options, & &1.votes_count))
  end
end
