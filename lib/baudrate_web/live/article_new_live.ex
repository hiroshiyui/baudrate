defmodule BaudrateWeb.ArticleNewLive do
  @moduledoc """
  LiveView for creating new articles.

  Accessible from both board pages (pre-selects that board via `board_slug`
  param) and as a standalone route at `/articles/new` where the user picks
  boards from a multi-select.

  Supports uploading up to 4 images (max 5 MB each) that are displayed as a
  media gallery at the end of the article. Images are processed to WebP,
  downscaled to max 1024px, and stripped of metadata.

  Requires the user to be active and have `user.create_content` permission.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Content
  alias Baudrate.Content.ArticleImageStorage

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user

    unless Auth.can_create_content?(user) do
      {:ok,
       socket
       |> put_flash(:error, gettext("Your account is pending approval."))
       |> redirect(to: ~p"/")}
    else
      boards = Content.list_top_boards() |> Enum.filter(&Content.can_post_in_board?(&1, user))

      selected_board_ids =
        case params do
          %{"slug" => slug} ->
            board = Content.get_board_by_slug!(slug)
            [board.id]

          _ ->
            []
        end

      changeset = Content.change_article()

      {:ok,
       socket
       |> assign(:form, to_form(changeset, as: :article))
       |> assign(:boards, boards)
       |> assign(:selected_board_ids, selected_board_ids)
       |> assign(:board_slug, params["slug"])
       |> assign(:uploaded_images, [])
       |> allow_upload(:article_images,
         accept: ~w(.jpg .jpeg .png .webp .gif),
         max_entries: 4,
         max_file_size: 5_000_000
       )}
    end
  end

  @impl true
  def handle_event("validate", %{"article" => params}, socket) do
    changeset =
      Content.change_article(%Baudrate.Content.Article{}, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :article))}
  end

  @impl true
  def handle_event("validate_images", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("upload_images", _params, socket) do
    user = socket.assigns.current_user
    existing_count = length(socket.assigns.uploaded_images)
    max = Baudrate.Content.ArticleImage.max_images_per_article()

    uploaded =
      consume_uploaded_entries(socket, :article_images, fn %{path: path}, _entry ->
        if existing_count >= max do
          {:postpone, :max_reached}
        else
          case ArticleImageStorage.process_upload(path) do
            {:ok, file_info} ->
              attrs = Map.merge(file_info, %{user_id: user.id})

              case Content.create_article_image(attrs) do
                {:ok, image} -> {:ok, image}
                {:error, _} -> {:postpone, :error}
              end

            {:error, _} ->
              {:postpone, :error}
          end
        end
      end)

    new_images =
      uploaded
      |> Enum.reject(&(&1 == :error || &1 == :max_reached))

    all_images = socket.assigns.uploaded_images ++ new_images

    socket =
      if Enum.any?(uploaded, &(&1 == :error)) do
        put_flash(socket, :error, gettext("Some images failed to upload."))
      else
        socket
      end

    {:noreply, assign(socket, :uploaded_images, all_images)}
  end

  @impl true
  def handle_event("remove_image", %{"id" => id}, socket) do
    image = Content.get_article_image!(id)
    Content.delete_article_image(image)

    updated = Enum.reject(socket.assigns.uploaded_images, &(&1.id == image.id))
    {:noreply, assign(socket, :uploaded_images, updated)}
  end

  @impl true
  def handle_event("cancel_image_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :article_images, ref)}
  end

  @impl true
  def handle_event("submit", %{"article" => params, "board_ids" => board_ids}, socket) do
    do_create(socket, params, board_ids)
  end

  def handle_event("submit", %{"article" => params}, socket) do
    do_create(socket, params, [])
  end

  defp do_create(socket, params, board_ids) do
    board_ids = Enum.map(List.wrap(board_ids), &String.to_integer/1)

    if board_ids == [] do
      {:noreply, put_flash(socket, :error, gettext("Please select at least one board."))}
    else
      user = socket.assigns.current_user
      slug = Content.generate_slug(params["title"] || "")

      attrs =
        params
        |> Map.put("slug", slug)
        |> Map.put("user_id", user.id)

      image_ids = Enum.map(socket.assigns.uploaded_images, & &1.id)

      case Content.create_article(attrs, board_ids, image_ids: image_ids) do
        {:ok, %{article: article}} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Article created successfully."))
           |> redirect(to: ~p"/articles/#{article.slug}")}

        {:error, :article, changeset, _} ->
          {:noreply, assign(socket, :form, to_form(changeset, as: :article))}

        {:error, _, _, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to create article."))}
      end
    end
  end

  defp upload_error_to_string(:too_large), do: gettext("File too large (max 5 MB)")
  defp upload_error_to_string(:too_many_files), do: gettext("Too many files (max 4)")
  defp upload_error_to_string(:not_accepted), do: gettext("File type not accepted")
  defp upload_error_to_string(_), do: gettext("Upload error")
end
