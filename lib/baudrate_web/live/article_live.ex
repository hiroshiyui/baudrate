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

      is_board_mod =
        if current_user do
          Enum.any?(article.boards, &Content.board_moderator?(&1, current_user))
        else
          false
        end

      can_comment =
        if current_user && not article.locked do
          Enum.any?(article.boards, &Content.can_post_in_board?(&1, current_user))
        else
          false
        end

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

      if connected?(socket), do: ContentPubSub.subscribe_article(article.id)

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

          can_comment =
            if socket.assigns.current_user && not updated.locked do
              boards =
                if Ecto.assoc_loaded?(updated.boards), do: updated.boards, else: article.boards

              Enum.any?(boards, &Content.can_post_in_board?(&1, socket.assigns.current_user))
            else
              false
            end

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
  def handle_info({event, _payload}, socket)
      when event in [:comment_created, :comment_deleted] do
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
    {:noreply, assign(socket, :article, article)}
  end

  @doc false
  attr :comment, :map, required: true
  attr :children_map, :map, required: true
  attr :depth, :integer, required: true
  attr :can_comment, :boolean, required: true
  attr :can_delete, :boolean, required: true
  attr :replying_to, :any, required: true
  attr :comment_form, :any, required: true

  def comment_node(assigns) do
    assigns = assign(assigns, :children, Map.get(assigns.children_map, assigns.comment.id, []))

    ~H"""
    <div class={["border-l-2 border-base-300 pl-4", @depth > 0 && "ml-4"]}>
      <div class="py-2">
        <div class="flex items-center gap-2 text-sm text-base-content/70 mb-1">
          <.link
            :if={@comment.user}
            navigate={~p"/users/#{@comment.user.username}"}
            class="inline-flex items-center gap-1 font-semibold text-base-content link link-hover"
          >
            <.avatar user={@comment.user} size={24} />
            {display_name(@comment.user)}
          </.link>
          <span :if={@comment.remote_actor} class="font-semibold text-base-content">
            {display_name(@comment.remote_actor)}@{@comment.remote_actor.domain}
          </span>
          <span>&middot;</span>
          <time datetime={Calendar.strftime(@comment.inserted_at, "%Y-%m-%dT%H:%M:%S")}>
            {Calendar.strftime(@comment.inserted_at, "%Y-%m-%d %H:%M")}
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

        <div
          :if={@comment.user && @comment.user.signature && @comment.user.signature != ""}
          class="mt-1"
        >
          <div class="divider text-sm text-base-content/50 my-1"></div>
          <div class="prose prose-sm max-w-none text-base-content/50">
            {raw(Baudrate.Content.Markdown.to_html(@comment.user.signature))}
          </div>
        </div>

        <div :if={@can_comment && @depth < 5} class="mt-1">
          <button
            :if={@replying_to != @comment.id}
            phx-click="reply_to"
            phx-value-id={@comment.id}
            class="text-sm text-base-content/50 hover:text-base-content cursor-pointer"
            aria-expanded="false"
          >
            {gettext("Reply")}
          </button>
        </div>

        <%!-- Inline reply form --%>
        <div :if={@replying_to == @comment.id} class="mt-2">
          <.form
            for={@comment_form}
            phx-change="validate_comment"
            phx-submit="submit_comment"
            class="space-y-2"
          >
            <.input
              field={@comment_form[:body]}
              type="textarea"
              placeholder={gettext("Write a reply...")}
              toolbar
              rows="2"
            />
            <div class="flex gap-2">
              <button type="submit" class="btn btn-sm btn-primary">
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
        />
      <% end %>
    </div>
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
    comment = Baudrate.Repo.get!(Baudrate.Content.Comment, comment_id)

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

    assign(socket,
      comment_roots: roots,
      children_map: children_map,
      comment_page: comment_page,
      comment_total_pages: comment_total_pages
    )
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
end
