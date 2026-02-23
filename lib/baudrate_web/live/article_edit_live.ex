defmodule BaudrateWeb.ArticleEditLive do
  @moduledoc """
  LiveView for editing an existing article.

  Only the article author or an admin can access this page.
  Supports uploading up to 4 images (total with existing) per article.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content
  alias Baudrate.Content.ArticleImageStorage

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    article = Content.get_article_by_slug!(slug)
    user = socket.assigns.current_user

    if Content.can_edit_article?(user, article) do
      changeset = Content.change_article_for_edit(article)
      existing_images = Content.list_article_images(article.id)
      max_new = Baudrate.Content.ArticleImage.max_images_per_article() - length(existing_images)

      {:ok,
       socket
       |> assign(:article, article)
       |> assign(:form, to_form(changeset, as: :article))
       |> assign(:article_images, existing_images)
       |> assign(:page_title, gettext("Edit Article"))
       |> allow_upload(:article_images,
         accept: ~w(.jpg .jpeg .png .webp .gif),
         max_entries: max(max_new, 0),
         max_file_size: 5_000_000
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
  def handle_event("validate_images", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("upload_images", _params, socket) do
    article = socket.assigns.article
    user = socket.assigns.current_user
    max = Baudrate.Content.ArticleImage.max_images_per_article()
    existing_count = length(socket.assigns.article_images)

    uploaded =
      consume_uploaded_entries(socket, :article_images, fn %{path: path}, _entry ->
        if existing_count >= max do
          {:postpone, :max_reached}
        else
          case ArticleImageStorage.process_upload(path) do
            {:ok, file_info} ->
              attrs = Map.merge(file_info, %{user_id: user.id, article_id: article.id})

              case Content.create_article_image(attrs) do
                {:ok, image} -> {:ok, image}
                {:error, _} -> {:postpone, :error}
              end

            {:error, _} ->
              {:postpone, :error}
          end
        end
      end)

    new_images = Enum.reject(uploaded, &(&1 == :error || &1 == :max_reached))
    all_images = socket.assigns.article_images ++ new_images
    max_new = max(max - length(all_images), 0)

    socket =
      if Enum.any?(uploaded, &(&1 == :error)) do
        put_flash(socket, :error, gettext("Some images failed to upload."))
      else
        socket
      end

    {:noreply,
     socket
     |> assign(:article_images, all_images)
     |> allow_upload(:article_images,
       accept: ~w(.jpg .jpeg .png .webp .gif),
       max_entries: max_new,
       max_file_size: 5_000_000
     )}
  end

  @impl true
  def handle_event("remove_image", %{"id" => id}, socket) do
    image = Content.get_article_image!(id)
    Content.delete_article_image(image)

    updated = Enum.reject(socket.assigns.article_images, &(&1.id == image.id))
    max = Baudrate.Content.ArticleImage.max_images_per_article()
    max_new = max(max - length(updated), 0)

    {:noreply,
     socket
     |> assign(:article_images, updated)
     |> allow_upload(:article_images,
       accept: ~w(.jpg .jpeg .png .webp .gif),
       max_entries: max_new,
       max_file_size: 5_000_000
     )}
  end

  @impl true
  def handle_event("cancel_image_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :article_images, ref)}
  end

  @impl true
  def handle_event("submit", %{"article" => params}, socket) do
    case Content.update_article(socket.assigns.article, params, socket.assigns.current_user) do
      {:ok, updated_article} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Article updated successfully."))
         |> redirect(to: ~p"/articles/#{updated_article.slug}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :article))}
    end
  end

  defp upload_error_to_string(:too_large), do: gettext("File too large (max 5 MB)")
  defp upload_error_to_string(:too_many_files), do: gettext("Too many files (max 4)")
  defp upload_error_to_string(:not_accepted), do: gettext("File type not accepted")
  defp upload_error_to_string(_), do: gettext("Upload error")
end
