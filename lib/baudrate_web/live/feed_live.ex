defmodule BaudrateWeb.FeedLive do
  @moduledoc """
  LiveView for the personal feed page.

  Displays incoming posts from remote actors the user follows, local articles
  from followed users, and comments (both local and from remote actors) on
  articles the user authored or previously commented on. Includes a personal
  info sidebar, a full-featured post composer (markdown toolbar, image uploads
  up to 4 images, and optional polls) for creating board-less articles, and
  inline reply forms for responding to remote feed items via ActivityPub.
  Subscribes to `Federation.PubSub` for real-time updates.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Content
  alias Baudrate.Content.Article
  alias Baudrate.Content.ArticleImageStorage
  alias Baudrate.Federation
  alias Baudrate.Federation.FeedItemReply
  alias Baudrate.Federation.PubSub, as: FederationPubSub
  alias BaudrateWeb.RateLimits
  alias BaudrateWeb.InteractionHelpers
  import BaudrateWeb.Helpers, only: [parse_page: 1, parse_id: 1, translate_role: 1]

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      FederationPubSub.subscribe_user_feed(user.id)
    end

    can_post = Auth.can_create_content?(user)

    {article_count, comment_count} = Content.count_user_content_stats(user.id)

    socket =
      socket
      |> assign(
        page_title: gettext("Feed"),
        wide_layout: true,
        article_count: article_count,
        comment_count: comment_count,
        can_post: can_post,
        replying_to: nil,
        reply_form: to_form(FeedItemReply.changeset(%FeedItemReply{}, %{}), as: :reply),
        reply_counts: %{},
        replies: %{},
        forwarding_item_id: nil,
        forwarding_item_type: nil,
        forward_search_results: [],
        forward_search_query: ""
      )
      |> then(fn s ->
        if can_post do
          s
          |> assign(:form, to_form(Content.change_article(), as: :article))
          |> assign(:uploaded_images, [])
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
          )
        else
          s
        end
      end)

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    user = socket.assigns.current_user
    page = parse_page(params["page"])
    result = Federation.list_feed_items(user, page: page)

    # Collect remote feed item IDs for reply counts
    remote_feed_item_ids =
      result.items
      |> Enum.filter(&(&1.source == :remote))
      |> Enum.map(& &1.feed_item.id)

    reply_counts = Federation.count_feed_item_replies(remote_feed_item_ids)

    # Collect article IDs for like/boost state
    local_article_ids =
      result.items
      |> Enum.filter(&(&1.source == :local))
      |> Enum.map(& &1.article.id)

    # Collect comment IDs for like/boost state
    local_comment_ids =
      result.items
      |> Enum.filter(&(&1.source == :local_comment))
      |> Enum.map(& &1.comment.id)

    {:noreply,
     socket
     |> assign(:items, result.items)
     |> assign(:page, result.page)
     |> assign(:total_pages, result.total_pages)
     |> assign(:total, result.total)
     |> assign(:reply_counts, reply_counts)
     |> assign(:replies, %{})
     |> assign(:replying_to, nil)
     |> assign(:article_liked_ids, Content.article_likes_by_user(user.id, local_article_ids))
     |> assign(:article_boosted_ids, Content.article_boosts_by_user(user.id, local_article_ids))
     |> assign(:article_like_counts, Content.article_like_counts(local_article_ids))
     |> assign(:article_boost_counts, Content.article_boost_counts(local_article_ids))
     |> assign(:comment_liked_ids, Content.comment_likes_by_user(user.id, local_comment_ids))
     |> assign(:comment_boosted_ids, Content.comment_boosts_by_user(user.id, local_comment_ids))
     |> assign(:comment_like_counts, Content.comment_like_counts(local_comment_ids))
     |> assign(:comment_boost_counts, Content.comment_boost_counts(local_comment_ids))
     |> assign(
       :feed_item_liked_ids,
       Federation.feed_item_likes_by_user(user.id, remote_feed_item_ids)
     )
     |> assign(
       :feed_item_boosted_ids,
       Federation.feed_item_boosts_by_user(user.id, remote_feed_item_ids)
     )}
  end

  def handle_info({:feed_item_created, _payload}, socket) do
    user = socket.assigns.current_user
    page = socket.assigns.page
    result = Federation.list_feed_items(user, page: page)

    remote_feed_item_ids =
      result.items
      |> Enum.filter(&(&1.source == :remote))
      |> Enum.map(& &1.feed_item.id)

    reply_counts = Federation.count_feed_item_replies(remote_feed_item_ids)

    {:noreply,
     socket
     |> assign(:items, result.items)
     |> assign(:total_pages, result.total_pages)
     |> assign(:total, result.total)
     |> assign(:reply_counts, reply_counts)}
  end

  def handle_event("validate_post", %{"article" => params}, socket) do
    changeset =
      Content.change_article(%Article{}, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :article))}
  end

  def handle_event("submit_post", %{"article" => params} = all_params, socket) do
    user = socket.assigns.current_user

    if user.role.name == "admin" do
      do_create_post(socket, user, params, all_params)
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
          do_create_post(socket, user, params, all_params)
      end
    end
  end

  def handle_event("hashtag_suggest", %{"prefix" => prefix}, socket) do
    tags = Content.search_tags(prefix, limit: 10)
    {:noreply, push_event(socket, "hashtag_suggestions", %{tags: tags})}
  end

  def handle_event("mention_suggest", %{"prefix" => prefix}, socket) do
    users =
      Baudrate.Auth.search_users(prefix,
        limit: 10,
        exclude_id: socket.assigns.current_user.id
      )
      |> Enum.map(&%{username: &1.username, type: "local"})

    {:noreply, push_event(socket, "mention_suggestions", %{users: users})}
  end

  def handle_event("remove_image", %{"id" => id}, socket) do
    uploaded_ids = Enum.map(socket.assigns.uploaded_images, & &1.id)

    with {:ok, image_id} <- parse_id(id),
         true <- image_id in uploaded_ids do
      image = Content.get_article_image!(image_id)
      Content.delete_article_image(image)

      updated = Enum.reject(socket.assigns.uploaded_images, &(&1.id == image_id))
      {:noreply, assign(socket, :uploaded_images, updated)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Image not found."))}
    end
  end

  def handle_event("cancel_image_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :article_images, ref)}
  end

  def handle_event("toggle_poll", _params, socket) do
    {:noreply, assign(socket, :poll_enabled, !socket.assigns.poll_enabled)}
  end

  def handle_event("add_poll_option", _params, socket) do
    options = socket.assigns.poll_options

    if length(options) < 4 do
      {:noreply, assign(socket, :poll_options, options ++ [""])}
    else
      {:noreply, socket}
    end
  end

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

  def handle_event("toggle_reply", %{"id" => feed_item_id_str}, socket) do
    case parse_id(feed_item_id_str) do
      :error ->
        {:noreply, socket}

      {:ok, feed_item_id} ->
        if socket.assigns.replying_to == feed_item_id do
          {:noreply,
           socket
           |> assign(:replying_to, nil)
           |> assign(:replies, %{})}
        else
          replies = Federation.list_feed_item_replies(feed_item_id)

          {:noreply,
           socket
           |> assign(:replying_to, feed_item_id)
           |> assign(
             :reply_form,
             to_form(FeedItemReply.changeset(%FeedItemReply{}, %{}), as: :reply)
           )
           |> assign(:replies, %{feed_item_id => replies})}
        end
    end
  end

  def handle_event("validate_reply", %{"reply" => params}, socket) do
    changeset =
      FeedItemReply.changeset(%FeedItemReply{}, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :reply_form, to_form(changeset, as: :reply))}
  end

  def handle_event("submit_reply", %{"reply" => params, "feed_item_id" => fi_id_str}, socket) do
    case parse_id(fi_id_str) do
      :error ->
        {:noreply, socket}

      {:ok, feed_item_id} ->
        user = socket.assigns.current_user

        case RateLimits.check_feed_reply(user.id) do
          {:error, :rate_limited} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("You are replying too frequently. Please try again later.")
             )}

          :ok ->
            feed_item = Baudrate.Repo.get!(Federation.FeedItem, feed_item_id)
            do_create_reply(socket, feed_item, user, params["body"] || "")
        end
    end
  end

  def handle_event("toggle_article_like", %{"id" => id}, socket) do
    InteractionHelpers.handle_toggle_with_counts(
      socket,
      id,
      &Content.toggle_article_like/2,
      &Content.article_like_counts/1,
      :article_liked_ids,
      :article_like_counts,
      InteractionHelpers.article_like_opts()
    )
  end

  def handle_event("toggle_article_boost", %{"id" => id}, socket) do
    InteractionHelpers.handle_toggle_with_counts(
      socket,
      id,
      &Content.toggle_article_boost/2,
      &Content.article_boost_counts/1,
      :article_boosted_ids,
      :article_boost_counts,
      InteractionHelpers.article_boost_opts()
    )
  end

  def handle_event("toggle_comment_like", %{"id" => id}, socket) do
    InteractionHelpers.handle_toggle_with_counts(
      socket,
      id,
      &Content.toggle_comment_like/2,
      &Content.comment_like_counts/1,
      :comment_liked_ids,
      :comment_like_counts,
      InteractionHelpers.comment_like_opts()
    )
  end

  def handle_event("toggle_comment_boost", %{"id" => id}, socket) do
    InteractionHelpers.handle_toggle_with_counts(
      socket,
      id,
      &Content.toggle_comment_boost/2,
      &Content.comment_boost_counts/1,
      :comment_boosted_ids,
      :comment_boost_counts,
      InteractionHelpers.comment_boost_opts()
    )
  end

  def handle_event("toggle_feed_item_like", %{"id" => id}, socket) do
    InteractionHelpers.handle_toggle_mapset(
      socket,
      id,
      &Federation.toggle_feed_item_like/2,
      :feed_item_liked_ids,
      gettext("Failed to toggle like.")
    )
  end

  def handle_event("toggle_feed_item_boost", %{"id" => id}, socket) do
    InteractionHelpers.handle_toggle_mapset(
      socket,
      id,
      &Federation.toggle_feed_item_boost/2,
      :feed_item_boosted_ids,
      gettext("Failed to toggle boost.")
    )
  end

  def handle_event("cancel_reply", _params, socket) do
    {:noreply,
     socket
     |> assign(:replying_to, nil)
     |> assign(:replies, %{})}
  end

  def handle_event(
        "toggle_forward_search",
        %{"id" => id_str, "type" => type},
        socket
      ) do
    case parse_id(id_str) do
      {:ok, id} ->
        if socket.assigns.forwarding_item_id == id and socket.assigns.forwarding_item_type == type do
          {:noreply,
           socket
           |> assign(:forwarding_item_id, nil)
           |> assign(:forwarding_item_type, nil)
           |> assign(:forward_search_results, [])
           |> assign(:forward_search_query, "")}
        else
          {:noreply,
           socket
           |> assign(:forwarding_item_id, id)
           |> assign(:forwarding_item_type, type)
           |> assign(:forward_search_results, [])
           |> assign(:forward_search_query, "")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_forward_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:forwarding_item_id, nil)
     |> assign(:forwarding_item_type, nil)
     |> assign(:forward_search_results, [])
     |> assign(:forward_search_query, "")}
  end

  def handle_event("search_forward_board", %{"query" => query}, socket) do
    results =
      if String.length(String.trim(query)) >= 2 do
        Content.search_boards(query, socket.assigns.current_user)
      else
        []
      end

    {:noreply,
     socket
     |> assign(:forward_search_query, query)
     |> assign(:forward_search_results, results)}
  end

  def handle_event("forward_to_board", %{"board-id" => board_id_str}, socket) do
    user = socket.assigns.current_user
    item_id = socket.assigns.forwarding_item_id
    item_type = socket.assigns.forwarding_item_type

    with {:ok, board_id} <- parse_id(board_id_str),
         {:ok, board} <- Content.get_board(board_id) do
      result =
        case item_type do
          "feed_item" ->
            feed_item = Baudrate.Repo.get!(Federation.FeedItem, item_id)
            Content.forward_feed_item_to_board(feed_item, board, user)

          "comment" ->
            comment = Baudrate.Repo.get!(Baudrate.Content.Comment, item_id)
            Content.forward_comment_to_board(comment, board, user)

          _ ->
            {:error, :unknown_type}
        end

      case result do
        {:ok, _article} ->
          {:noreply,
           socket
           |> assign(:forwarding_item_id, nil)
           |> assign(:forwarding_item_type, nil)
           |> assign(:forward_search_results, [])
           |> assign(:forward_search_query, "")
           |> put_flash(:info, gettext("Forwarded to board."))}

        {:error, :unauthorized} ->
          {:noreply, put_flash(socket, :error, gettext("Not authorized."))}

        {:error, :cannot_post} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("You do not have permission to post in this board.")
           )}

        _ ->
          {:noreply, put_flash(socket, :error, gettext("Failed to forward."))}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Board not found."))}
    end
  end

  defp do_create_reply(socket, feed_item, user, body) do
    case Federation.create_feed_item_reply(feed_item, user, body) do
      {:ok, _reply} ->
        replies = Federation.list_feed_item_replies(feed_item.id)
        count = length(replies)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Reply sent!"))
         |> assign(:replying_to, nil)
         |> assign(:replies, %{})
         |> update(:reply_counts, &Map.put(&1, feed_item.id, count))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to send reply."))}
    end
  end

  defp do_create_post(socket, user, params, all_params) do
    slug = Content.generate_slug(params["title"] || "")

    attrs =
      params
      |> Map.put("slug", slug)
      |> Map.put("user_id", user.id)

    image_ids = Enum.map(socket.assigns.uploaded_images, & &1.id)
    poll_opts = build_poll_opts(socket, all_params)

    case Content.create_article(attrs, [], [image_ids: image_ids] ++ poll_opts) do
      {:ok, %{article: _article}} ->
        page = socket.assigns.page
        result = Federation.list_feed_items(user, page: page)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Article posted!"))
         |> assign(:form, to_form(Content.change_article(), as: :article))
         |> assign(:uploaded_images, [])
         |> assign(:poll_enabled, false)
         |> assign(:poll_options, ["", ""])
         |> assign(:poll_mode, "single")
         |> assign(:poll_expires, "")
         |> assign(:items, result.items)
         |> assign(:total_pages, result.total_pages)
         |> assign(:total, result.total)
         |> assign(:article_count, Content.count_articles_by_user(user.id))}

      {:error, :article, changeset, _} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :article))}

      {:error, :poll, changeset, _} ->
        {:noreply,
         socket
         |> assign(
           :form,
           to_form(Content.change_article(%Article{}, params), as: :article)
         )
         |> put_flash(:error, format_poll_errors(changeset))}

      {:error, _, _, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to create article."))}
    end
  end

  defp digest(nil), do: ""

  defp digest(text) do
    plain =
      text
      |> Baudrate.Sanitizer.Native.strip_tags()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.length(plain) > 200 do
      String.slice(plain, 0, 200) <> "…"
    else
      plain
    end
  end

  defp reply_count(assigns, feed_item_id) do
    Map.get(assigns.reply_counts, feed_item_id, 0)
  end

  defp handle_progress(:article_images, entry, socket) do
    max = Baudrate.Content.ArticleImage.max_images_per_article()

    if entry.done? and length(socket.assigns.uploaded_images) < max do
      user = socket.assigns.current_user

      case consume_uploaded_entry(socket, entry, fn %{path: path} ->
             case ArticleImageStorage.process_upload(path) do
               {:ok, file_info} ->
                 attrs = Map.merge(file_info, %{user_id: user.id})

                 case Content.create_article_image(attrs) do
                   {:ok, image} -> {:ok, image}
                   {:error, _} -> {:ok, :error}
                 end

               {:error, _} ->
                 {:ok, :error}
             end
           end) do
        :error ->
          {:noreply, socket}

        image ->
          {:noreply, assign(socket, :uploaded_images, socket.assigns.uploaded_images ++ [image])}
      end
    else
      {:noreply, socket}
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

  defp upload_error_to_string(err),
    do: BaudrateWeb.Helpers.upload_error_to_string(err, max_size: "5 MB", max_files: 4)
end
