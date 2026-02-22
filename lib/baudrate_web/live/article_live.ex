defmodule BaudrateWeb.ArticleLive do
  @moduledoc """
  LiveView for displaying a single article with comments.

  Accessible to both guests and authenticated users via `:optional_auth`.
  Guests can only view articles that belong to at least one public board;
  articles exclusively in private boards redirect to `/login`.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Content

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    article = Content.get_article_by_slug!(slug)
    current_user = socket.assigns.current_user

    if is_nil(current_user) and not has_public_board?(article) do
      {:ok, redirect(socket, to: "/login")}
    else
      can_manage =
        if current_user, do: Content.can_manage_article?(current_user, article), else: false

      comments = Content.list_comments_for_article(article)
      {roots, children_map} = build_comment_tree(comments)

      can_comment =
        if current_user, do: Auth.can_create_content?(current_user), else: false

      comment_changeset = Content.change_comment()
      attachments = Content.list_attachments_for_article(article)

      socket =
        socket
        |> assign(:article, article)
        |> assign(:can_manage, can_manage)
        |> assign(:comment_roots, roots)
        |> assign(:children_map, children_map)
        |> assign(:can_comment, can_comment)
        |> assign(:comment_form, to_form(comment_changeset, as: :comment))
        |> assign(:replying_to, nil)
        |> assign(:attachments, attachments)

      socket =
        if can_manage do
          allow_upload(socket, :attachments,
            accept: ~w(.jpg .jpeg .png .webp .gif .pdf .txt .md .zip),
            max_entries: 5,
            max_file_size: 10_000_000
          )
        else
          socket
        end

      {:ok, socket}
    end
  end

  @impl true
  def handle_event("delete_article", _params, socket) do
    article = socket.assigns.article

    if socket.assigns.can_manage do
      case Content.soft_delete_article(article) do
        {:ok, _} ->
          board = List.first(article.boards)
          redirect_path = if board, do: ~p"/boards/#{board.slug}", else: ~p"/"

          {:noreply,
           socket
           |> put_flash(:info, gettext("Article deleted."))
           |> redirect(to: redirect_path)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to delete article."))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
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
        comments = Content.list_comments_for_article(article)
        {roots, children_map} = build_comment_tree(comments)

        {:noreply,
         socket
         |> assign(:comment_roots, roots)
         |> assign(:children_map, children_map)
         |> assign(:comment_form, to_form(Content.change_comment(), as: :comment))
         |> assign(:replying_to, nil)
         |> put_flash(:info, gettext("Comment posted."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :comment_form, to_form(changeset, as: :comment))}
    end
  end

  @impl true
  def handle_event("reply_to", %{"id" => comment_id}, socket) do
    {:noreply, assign(socket, :replying_to, String.to_integer(comment_id))}
  end

  @impl true
  def handle_event("cancel_reply", _params, socket) do
    {:noreply, assign(socket, :replying_to, nil)}
  end

  @impl true
  def handle_event("validate_attachments", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("upload_attachments", _params, socket) do
    article = socket.assigns.article
    user = socket.assigns.current_user

    uploaded_files =
      consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
        case Baudrate.AttachmentStorage.process_upload(path, entry.client_name, entry.client_type) do
          {:ok, file_info} ->
            attrs =
              Map.merge(file_info, %{
                original_filename: entry.client_name,
                article_id: article.id,
                user_id: user.id
              })

            case Content.create_attachment(attrs) do
              {:ok, attachment} -> {:ok, attachment}
              {:error, _} -> {:postpone, :error}
            end

          {:error, _reason} ->
            {:postpone, :error}
        end
      end)

    if Enum.any?(uploaded_files, &(&1 == :error)) do
      {:noreply, put_flash(socket, :error, gettext("Some files failed to upload."))}
    else
      attachments = Content.list_attachments_for_article(article)
      {:noreply, assign(socket, :attachments, attachments)}
    end
  end

  @impl true
  def handle_event("delete_attachment", %{"id" => id}, socket) do
    if socket.assigns.can_manage do
      attachment = Content.get_attachment!(id)

      case Content.delete_attachment(attachment) do
        {:ok, _} ->
          attachments = Content.list_attachments_for_article(socket.assigns.article)
          {:noreply, assign(socket, :attachments, attachments)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to delete attachment."))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  @doc false
  attr :comment, :map, required: true
  attr :children_map, :map, required: true
  attr :depth, :integer, required: true
  attr :can_comment, :boolean, required: true
  attr :replying_to, :any, required: true
  attr :comment_form, :any, required: true

  def comment_node(assigns) do
    assigns = assign(assigns, :children, Map.get(assigns.children_map, assigns.comment.id, []))

    ~H"""
    <div class={["border-l-2 border-base-300 pl-4", @depth > 0 && "ml-4"]}>
      <div class="py-2">
        <div class="flex items-center gap-2 text-sm text-base-content/70 mb-1">
          <.link :if={@comment.user} navigate={~p"/users/#{@comment.user.username}"} class="font-semibold text-base-content link link-hover">
            {@comment.user.username}
          </.link>
          <span :if={@comment.remote_actor} class="font-semibold text-base-content">
            {@comment.remote_actor.username}@{@comment.remote_actor.domain}
          </span>
          <span>&middot;</span>
          <span>{Calendar.strftime(@comment.inserted_at, "%Y-%m-%d %H:%M")}</span>
        </div>

        <div :if={@comment.body_html} class="prose prose-sm max-w-none">
          {raw(@comment.body_html)}
        </div>
        <div :if={!@comment.body_html} class="prose prose-sm max-w-none">
          {raw(Baudrate.Content.Markdown.to_html(@comment.body))}
        </div>

        <div :if={@comment.user && @comment.user.signature && @comment.user.signature != ""} class="mt-1">
          <div class="divider text-xs text-base-content/50 my-1"></div>
          <div class="prose prose-xs max-w-none text-base-content/50">
            {raw(Baudrate.Content.Markdown.to_html(@comment.user.signature))}
          </div>
        </div>

        <div :if={@can_comment && @depth < 5} class="mt-1">
          <button
            :if={@replying_to != @comment.id}
            phx-click="reply_to"
            phx-value-id={@comment.id}
            class="text-xs text-base-content/50 hover:text-base-content cursor-pointer"
          >
            {gettext("Reply")}
          </button>
        </div>

        <%!-- Inline reply form --%>
        <div :if={@replying_to == @comment.id} class="mt-2">
          <.form for={@comment_form} phx-change="validate_comment" phx-submit="submit_comment" class="space-y-2">
            <.input
              field={@comment_form[:body]}
              type="textarea"
              placeholder={gettext("Write a reply...")}
              rows="2"
            />
            <div class="flex gap-2">
              <button type="submit" class="btn btn-xs btn-primary">
                {gettext("Reply")}
              </button>
              <button type="button" phx-click="cancel_reply" class="btn btn-xs btn-ghost">
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
          replying_to={@replying_to}
          comment_form={@comment_form}
        />
      <% end %>
    </div>
    """
  end

  defp has_public_board?(article) do
    Enum.any?(article.boards, &(&1.visibility == "public"))
  end

  defp format_file_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_file_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_file_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp upload_error_to_string(:too_large), do: gettext("File too large (max 10 MB)")
  defp upload_error_to_string(:too_many_files), do: gettext("Too many files (max 5)")
  defp upload_error_to_string(:not_accepted), do: gettext("File type not accepted")
  defp upload_error_to_string(_), do: gettext("Upload error")

  defp build_comment_tree(comments) do
    roots = Enum.filter(comments, &is_nil(&1.parent_id))

    children_map =
      comments
      |> Enum.filter(& &1.parent_id)
      |> Enum.group_by(& &1.parent_id)

    {roots, children_map}
  end
end
