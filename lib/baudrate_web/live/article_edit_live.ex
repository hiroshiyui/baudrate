defmodule BaudrateWeb.ArticleEditLive do
  @moduledoc """
  LiveView for editing an existing article.

  Only the article author or an admin can access this page.
  Supports uploading up to 4 images (total with existing) per article.
  Image removal verifies ownership (image must belong to the article being edited).
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content
  alias Baudrate.Content.ArticleImageStorage
  alias BaudrateWeb.RateLimits

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    article = Content.get_article_by_slug!(slug)
    user = socket.assigns.current_user

    if Content.can_edit_article?(user, article) do
      changeset = Content.change_article_for_edit(article)
      existing_images = Content.list_article_images(article.id)

      {:ok,
       socket
       |> assign(:article, article)
       |> assign(:form, to_form(changeset, as: :article))
       |> assign(:article_images, existing_images)
       |> assign(:page_title, gettext("Edit Article"))
       |> allow_upload(:article_images,
         accept: ~w(.jpg .jpeg .png .webp .gif),
         max_entries: 4,
         max_file_size: 8_000_000,
         auto_upload: true,
         progress: &handle_progress/3
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorized to edit this article."))
       |> redirect(to: ~p"/articles/#{article.slug}")}
    end
  end

  @impl true
  def handle_event("validate", %{"article" => params}, socket) do
    changeset =
      Content.change_article_for_edit(socket.assigns.article, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :article))}
  end

  @impl true
  def handle_event("save_image_alt", %{"id" => image_id} = params, socket) do
    # The description saves itself against a row that already exists, so it
    # never rides along with the post and cannot be lost by a failed submit.
    case Content.update_article_image_alt(
           image_id,
           socket.assigns.current_user.id,
           params["value"]
         ) do
      {:ok, image} ->
        {:noreply, replace_image(socket, :article_images, image)}

      {:error, reason} when is_atom(reason) and reason != :not_found ->
        # Refused by the sanction gate or a filter (ADR 0029, ADR 0065): the
        # description is published text once its image is.
        {:noreply,
         put_flash(
           socket,
           :error,
           refusal(socket, reason, gettext("The image description could not be saved."))
         )}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_image", %{"id" => id}, socket) do
    article = socket.assigns.article

    case Content.get_article_image(id) do
      %{article_id: aid} = image when aid == article.id ->
        Content.delete_article_image(image)
        updated = Enum.reject(socket.assigns.article_images, &(&1.id == image.id))
        {:noreply, assign(socket, :article_images, updated)}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Image not found."))}
    end
  end

  @impl true
  def handle_event("cancel_image_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :article_images, ref)}
  end

  @impl true
  def handle_event("remove_board", %{"board-id" => board_id}, socket) do
    import BaudrateWeb.Helpers, only: [parse_id: 1]

    with {:ok, board_id} <- parse_id(board_id),
         board <- Content.get_board!(board_id),
         {:ok, updated_article} <-
           Content.remove_article_from_board(
             socket.assigns.article,
             board,
             socket.assigns.current_user
           ) do
      {:noreply,
       socket
       |> assign(:article, updated_article)
       |> put_flash(:info, gettext("Article removed from board."))}
    else
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("Not authorized."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Failed to remove from board."))}
    end
  end

  @impl true
  def handle_event("submit", %{"article" => params}, socket) do
    user = socket.assigns.current_user

    if user.role.name == "admin" do
      do_update_article(socket, params)
    else
      case RateLimits.check_update_article(user.id) do
        :ok ->
          do_update_article(socket, params)

        {:error, :rate_limited} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("You are editing too frequently. Please try again later.")
           )}
      end
    end
  end

  defp do_update_article(socket, params) do
    editor = socket.assigns.current_user
    article = socket.assigns.article

    case Content.update_article(article, params, editor) do
      {:ok, updated_article} ->
        if article.user_id != editor.id do
          Baudrate.Moderation.log_action(editor.id, "edit_article",
            target_type: "article",
            target_id: article.id,
            details: %{"title" => updated_article.title, "author_id" => article.user_id}
          )
        end

        {:noreply,
         socket
         |> put_flash(:info, gettext("Article updated successfully."))
         |> redirect(to: ~p"/articles/#{updated_article.slug}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :article))}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, refusal(socket, reason, gettext("Failed to update article.")))}
    end
  end

  # An upload here is attached to the published article as it lands, so the
  # context decides whether it may be before the file is even processed
  # (`Content.authorize_article_image/2`), and checks again as it attaches.
  defp handle_progress(:article_images, entry, socket) do
    max = Baudrate.Content.ArticleImage.max_images_per_article()
    total = length(socket.assigns.article_images)

    if entry.done? and total < max do
      article = socket.assigns.article
      user = socket.assigns.current_user

      case Content.authorize_article_image(article, user) do
        :ok -> attach_upload(socket, entry, article, user)
        {:error, reason} -> {:noreply, refuse_upload(socket, entry, reason)}
      end
    else
      {:noreply, socket}
    end
  end

  defp attach_upload(socket, entry, article, user) do
    result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        case ArticleImageStorage.process_upload(path) do
          {:ok, file_info} -> {:ok, Content.add_article_image(article, file_info, user)}
          {:error, _} -> {:ok, {:error, :processing_failed}}
        end
      end)

    case result do
      {:ok, image} ->
        {:noreply, assign(socket, :article_images, socket.assigns.article_images ++ [image])}

      {:error, reason} when is_atom(reason) ->
        {:noreply, put_flash(socket, :error, image_refusal(socket, reason))}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  defp refuse_upload(socket, entry, reason) do
    socket
    |> cancel_upload(:article_images, entry.ref)
    |> put_flash(:error, image_refusal(socket, reason))
  end

  defp image_refusal(socket, reason),
    do: refusal(socket, reason, gettext("The image could not be added."))

  defp upload_error_to_string(err),
    do: BaudrateWeb.Helpers.upload_error_to_string(err, max_size: "8 MB", max_files: 4)

  # A member refused by the interaction gate is told which restriction stands
  # and until when; anything else keeps the caller's own message (ADR 0029).
  defp refusal(socket, reason, fallback) do
    BaudrateWeb.Helpers.refusal_message(reason, socket.assigns[:current_user], fallback)
  end

  # Swap the saved row back into the list the composer renders, so the
  # thumbnail's own alt text matches what was just typed. The input itself is
  # `phx-update="ignore"` and is not patched by this.
  defp replace_image(socket, key, image) do
    updated = Enum.map(socket.assigns[key], fn i -> if i.id == image.id, do: image, else: i end)
    assign(socket, key, updated)
  end
end
