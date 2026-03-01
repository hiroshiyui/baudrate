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
  alias BaudrateWeb.RateLimits
  import BaudrateWeb.Helpers, only: [parse_id: 1]

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
       |> assign(:page_title, gettext("Create Article"))
       |> assign(:poll_enabled, false)
       |> assign(:poll_options, ["", ""])
       |> assign(:poll_mode, "single")
       |> assign(:poll_expires, "")
       |> allow_upload(:article_images,
         accept: ~w(.jpg .jpeg .png .webp .gif),
         max_entries: 4,
         max_file_size: 5_000_000,
         auto_upload: true,
         progress: &handle_progress/3
       )}
    end
  end

  @impl true
  def handle_event("hashtag_suggest", %{"prefix" => prefix}, socket) do
    tags = Content.search_tags(prefix, limit: 10)
    {:noreply, push_event(socket, "hashtag_suggestions", %{tags: tags})}
  end

  @impl true
  def handle_event("validate", %{"article" => params}, socket) do
    changeset =
      Content.change_article(%Baudrate.Content.Article{}, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :article))}
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
  def handle_event("toggle_poll", _params, socket) do
    {:noreply, assign(socket, :poll_enabled, !socket.assigns.poll_enabled)}
  end

  @impl true
  def handle_event("add_poll_option", _params, socket) do
    options = socket.assigns.poll_options

    if length(options) < 4 do
      {:noreply, assign(socket, :poll_options, options ++ [""])}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_poll_option", %{"index" => index}, socket) do
    options = socket.assigns.poll_options

    idx =
      case Integer.parse(index) do
        {n, ""} -> n
        _ -> -1
      end

    if length(options) > 2 do
      {:noreply, assign(socket, :poll_options, List.delete_at(options, idx))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "validate_poll",
        %{"poll_options" => poll_options, "poll_mode" => mode, "poll_expires" => expires},
        socket
      ) do
    options = Map.values(poll_options) |> Enum.sort_by(fn _ -> 0 end)

    {:noreply,
     socket
     |> assign(:poll_options, options)
     |> assign(:poll_mode, mode)
     |> assign(:poll_expires, expires)}
  end

  def handle_event("validate_poll", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "submit",
        %{"article" => params, "board_ids" => board_ids} = all_params,
        socket
      ) do
    do_create(socket, params, board_ids, all_params)
  end

  def handle_event("submit", %{"article" => params} = all_params, socket) do
    do_create(socket, params, [], all_params)
  end

  defp do_create(socket, params, board_ids, all_params) do
    parsed_ids =
      board_ids
      |> List.wrap()
      |> Enum.reduce_while([], fn id, acc ->
        case parse_id(id) do
          {:ok, n} -> {:cont, [n | acc]}
          :error -> {:halt, :error}
        end
      end)

    case parsed_ids do
      :error -> {:noreply, socket}
      ids -> do_create_with_boards(socket, params, Enum.reverse(ids), all_params)
    end
  end

  defp do_create_with_boards(socket, params, board_ids, all_params) do
    if board_ids == [] do
      {:noreply, put_flash(socket, :error, gettext("Please select at least one board."))}
    else
      user = socket.assigns.current_user

      if user.role.name == "admin" do
        do_create_article(socket, user, params, board_ids, all_params)
      else
        case RateLimits.check_create_article(user.id) do
          {:error, :rate_limited} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("You are posting too frequently. Please try again later.")
             )}

          :ok ->
            do_create_article(socket, user, params, board_ids, all_params)
        end
      end
    end
  end

  defp do_create_article(socket, user, params, board_ids, all_params) do
    slug = Content.generate_slug(params["title"] || "")

    attrs =
      params
      |> Map.put("slug", slug)
      |> Map.put("user_id", user.id)

    image_ids = Enum.map(socket.assigns.uploaded_images, & &1.id)
    poll_opts = build_poll_opts(socket, all_params)

    case Content.create_article(attrs, board_ids, [image_ids: image_ids] ++ poll_opts) do
      {:ok, %{article: article}} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Article created successfully."))
         |> redirect(to: ~p"/articles/#{article.slug}")}

      {:error, :article, changeset, _} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :article))}

      {:error, :poll, changeset, _} ->
        {:noreply,
         socket
         |> assign(
           :form,
           to_form(Content.change_article(%Baudrate.Content.Article{}, params), as: :article)
         )
         |> put_flash(:error, format_poll_errors(changeset))}

      {:error, _, _, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to create article."))}
    end
  end

  defp build_poll_opts(socket, all_params) do
    if socket.assigns.poll_enabled do
      poll_options = all_params["poll_options"] || %{}
      poll_mode = all_params["poll_mode"] || "single"
      poll_expires = all_params["poll_expires"] || ""

      option_texts =
        poll_options
        |> Enum.sort_by(fn {k, _v} ->
          case Integer.parse(k) do
            {n, ""} -> n
            _ -> 0
          end
        end)
        |> Enum.map(fn {_k, v} -> v end)
        |> Enum.reject(&(String.trim(&1) == ""))

      if option_texts == [] do
        []
      else
        options =
          option_texts
          |> Enum.with_index()
          |> Enum.map(fn {text, idx} -> %{text: text, position: idx} end)

        closes_at = parse_poll_expires(poll_expires)

        poll_attrs = %{mode: poll_mode, closes_at: closes_at, options: options}
        [poll: poll_attrs]
      end
    else
      []
    end
  end

  defp parse_poll_expires(""), do: nil

  defp parse_poll_expires(duration) do
    seconds =
      case duration do
        "1h" -> 3600
        "6h" -> 6 * 3600
        "1d" -> 24 * 3600
        "3d" -> 3 * 24 * 3600
        "7d" -> 7 * 24 * 3600
        _ -> nil
      end

    if seconds do
      DateTime.utc_now()
      |> DateTime.add(seconds, :second)
      |> DateTime.truncate(:second)
    end
  end

  defp format_poll_errors(%Ecto.Changeset{} = changeset) do
    errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

    cond do
      errors[:options] ->
        gettext("Poll: %{error}", error: List.first(List.flatten(List.wrap(errors[:options]))))

      errors[:mode] ->
        gettext("Poll: %{error}", error: List.first(errors[:mode]))

      true ->
        gettext("Failed to create poll.")
    end
  end

  defp handle_progress(:article_images, entry, socket) do
    if entry.done? do
      user = socket.assigns.current_user
      max = Baudrate.Content.ArticleImage.max_images_per_article()
      existing_count = length(socket.assigns.uploaded_images)

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

      new_images = Enum.reject(uploaded, &(&1 == :error || &1 == :max_reached))
      all_images = socket.assigns.uploaded_images ++ new_images

      socket =
        if Enum.any?(uploaded, &(&1 == :error)) do
          put_flash(socket, :error, gettext("Some images failed to upload."))
        else
          socket
        end

      {:noreply, assign(socket, :uploaded_images, all_images)}
    else
      {:noreply, socket}
    end
  end

  defp upload_error_to_string(err),
    do: BaudrateWeb.Helpers.upload_error_to_string(err, max_size: "5 MB", max_files: 4)
end
