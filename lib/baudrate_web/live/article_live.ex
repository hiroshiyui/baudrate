defmodule BaudrateWeb.ArticleLive do
  @moduledoc """
  LiveView for displaying a single article with comments.

  Accessible to both guests and authenticated users via `:optional_auth`.
  Guests can only view articles that belong to at least one board they can view;
  articles exclusively in restricted boards redirect appropriately.
  """

  use BaudrateWeb, :live_view

  import BaudrateWeb.CommentComponents
  import BaudrateWeb.ArticleHelpers

  alias Baudrate.Content
  alias Baudrate.Content.ArticleImageStorage
  alias Baudrate.Content.Board
  alias Baudrate.Content.Comment
  alias Baudrate.Content.PubSub, as: ContentPubSub
  alias Baudrate.Federation
  alias Baudrate.Moderation
  alias Baudrate.Notification.Hooks
  alias BaudrateWeb.LinkedData
  alias BaudrateWeb.OpenGraph
  alias BaudrateWeb.RateLimits
  alias BaudrateWeb.InteractionHelpers
  alias BaudrateWeb.SafetyActions
  import BaudrateWeb.Helpers, only: [parse_id: 1, parse_page: 1, last_board_message: 0]

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

      removable_board_ids = removable_board_ids(article, current_user)

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
        |> assign(:removable_board_ids, removable_board_ids)
        |> assign(:can_pin, can_pin)
        |> assign(:can_lock, can_lock)
        |> assign(:is_board_mod, is_board_mod)
        |> assign(:move_open, false)
        |> assign(:move_from_options, [])
        |> assign(:move_targets, [])
        |> assign(:comment_roots, [])
        |> assign(:children_map, %{})
        |> assign(:comment_page, 1)
        |> assign(:comment_total_pages, 1)
        |> assign(:comment_total, 0)
        |> assign(:unread_since, nil)
        |> assign(:new_comment_ids, MapSet.new())
        |> assign(:first_new_comment_path, nil)
        |> assign(:member_could_comment, Content.member_could_comment?(article))
        |> assign(:guest_can_register, Baudrate.Setup.registration_mode() != "invite_only")
        |> assign(:can_comment, can_comment)
        |> assign(:comment_form, to_form(comment_changeset, as: :comment))
        |> assign(:replying_to, nil)
        |> assign(:editing, nil)
        |> assign(:comment_edit_form, nil)
        |> assign(:revision_counts, %{})
        |> assign(:comments_live_status, "")
        |> assign(:article_images, article_images)
        |> assign(:revision_count, revision_count)
        |> assign(:page_title, article.title)
        |> assign(
          :linked_data_json,
          LinkedData.article_jsonld(article) |> LinkedData.encode_jsonld()
        )
        |> assign(:dc_meta, LinkedData.dublin_core_meta(:article, article))
        |> assign(:og_meta, OpenGraph.article_tags(article, article_images))
        |> assign(:ap_alternate_url, ap_alternate_url(article))
        # "Unlisted" is a word with a promise in it, so the page keeps it
        # (ADR 0057). `follow` because the board it sits in is still worth
        # crawling; only this page is held back. An author who opted out of
        # discovery is held back the same way (ADR 0073).
        |> assign(
          :noindex,
          article.visibility == "unlisted" or
            match?(%{discoverable: false}, article.user)
        )
        |> assign(:can_forward, Content.can_forward_article?(current_user, article))
        |> assign(:forward_search_open, false)
        |> assign(:forward_search_results, [])
        |> assign(:forward_search_query, "")
        |> assign(:forwarding_comment_id, nil)
        |> assign(:comment_forward_search_results, [])
        |> assign(:comment_forward_search_query, "")
        |> assign(:uploaded_comment_images, [])
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
        |> assign(
          :boosted,
          if(current_user,
            do: Content.article_boosted?(current_user.id, article.id),
            else: false
          )
        )
        |> assign(:boost_count, Content.count_article_boosts(article))
        |> assign(:comment_liked_ids, MapSet.new())
        |> assign(:comment_like_counts, %{})
        |> assign(:comment_boosted_ids, MapSet.new())
        |> assign(:comment_boost_counts, %{})
        |> assign(:comment_bookmarked_ids, MapSet.new())
        |> assign(:watched, Content.article_watched?(current_user, article.id))
        |> assign(
          :bookmarked,
          if(current_user,
            do: Content.article_bookmarked?(current_user.id, article.id),
            else: false
          )
        )
        |> assign_poll_data(article, current_user)

      socket =
        if can_comment do
          allow_upload(socket, :comment_images,
            accept: ~w(.jpg .jpeg .png .webp .gif),
            max_entries: 4,
            max_file_size: 8_000_000,
            auto_upload: true,
            progress: &handle_comment_image_progress/3
          )
        else
          socket
        end

      # What counts as new is fixed for the whole visit: read the floor before
      # this visit overwrites it, or every comment would already be read.
      socket =
        if connected?(socket) do
          ContentPubSub.subscribe_article(article.id)
          unread_since = Content.last_read_at(current_user, article)

          if current_user do
            Content.mark_article_read(current_user.id, article.id)
          end

          assign(socket, :unread_since, unread_since)
        else
          socket
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
      case check_delete_limit(user, article.user_id) do
        {:error, :rate_limited} ->
          {:noreply,
           put_flash(socket, :error, gettext("Too many actions. Please try again later."))}

        :ok ->
          do_delete_article(socket, article, user)
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  @impl true
  def handle_event("remove_from_board", %{"board-id" => board_id_str}, socket) do
    article = socket.assigns.article
    user = socket.assigns.current_user

    with {:ok, board_id} <- parse_id(board_id_str),
         true <- board_id in socket.assigns.removable_board_ids,
         board when not is_nil(board) <- Enum.find(article.boards, &(&1.id == board_id)),
         {:ok, updated} <- Content.remove_article_from_board(article, board, user) do
      Moderation.log_action(user.id, "remove_article_from_board",
        target_type: "article",
        target_id: article.id,
        details: %{"title" => article.title, "board" => board.name, "board_id" => board.id}
      )

      {:noreply,
       socket
       |> put_flash(:info, gettext("Article removed from %{board}.", board: board.name))
       |> assign(
         :article,
         Baudrate.Repo.preload(updated, [:user, :remote_actor, :link_preview, poll: :options])
       )
       |> assign(:removable_board_ids, removable_board_ids(updated, user))}
    else
      {:error, :last_board} ->
        {:noreply, put_flash(socket, :error, last_board_message())}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Failed to remove article from board."))}
    end
  end

  @impl true
  def handle_event("toggle_pin", _params, socket) do
    article = socket.assigns.article

    if socket.assigns.can_pin do
      case Content.toggle_pin_article(article, socket.assigns.current_user) do
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
      case Content.toggle_lock_article(article, socket.assigns.current_user) do
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
  def handle_event("toggle_watch", _params, %{assigns: %{current_user: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("toggle_watch", _params, socket) do
    %{current_user: user, article: article} = socket.assigns

    case Content.toggle_article_watch(user, article.id) do
      {:ok, _} ->
        {:noreply, assign(socket, :watched, Content.article_watched?(user, article.id))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not change whether you watch this."))}
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
  def handle_event("toggle_comment_bookmark", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, comment_id} <- parse_id(id),
         {:ok, _} <- Content.toggle_comment_bookmark(user.id, comment_id) do
      bookmarked = Content.comment_bookmarked?(user.id, comment_id)

      ids =
        if bookmarked do
          MapSet.put(socket.assigns.comment_bookmarked_ids, comment_id)
        else
          MapSet.delete(socket.assigns.comment_bookmarked_ids, comment_id)
        end

      {:noreply, assign(socket, :comment_bookmarked_ids, ids)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Failed to toggle bookmark."))}
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

      {:error, :blocked} ->
        {:noreply, put_flash(socket, :error, BaudrateWeb.Helpers.blocked_interaction_message())}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, refusal(socket, reason, gettext("Failed to toggle like.")))}
    end
  end

  @impl true
  def handle_event("toggle_boost", _params, socket) do
    user = socket.assigns.current_user
    article = socket.assigns.article

    case Content.toggle_article_boost(user.id, article.id) do
      {:ok, _} ->
        boosted = Content.article_boosted?(user.id, article.id)
        boost_count = Content.count_article_boosts(article)
        {:noreply, socket |> assign(:boosted, boosted) |> assign(:boost_count, boost_count)}

      {:error, :self_boost} ->
        {:noreply, put_flash(socket, :error, gettext("You cannot boost your own article."))}

      {:error, :blocked} ->
        {:noreply, put_flash(socket, :error, BaudrateWeb.Helpers.blocked_interaction_message())}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, refusal(socket, reason, gettext("Failed to toggle boost.")))}
    end
  end

  @impl true
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

  @impl true
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

  @impl true
  def handle_event("delete_comment", %{"id" => id}, socket) do
    case parse_id(id) do
      :error ->
        {:noreply, socket}

      {:ok, comment_id} ->
        do_delete_comment(socket, comment_id, socket.assigns.current_user)
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
  def handle_event("edit_comment", %{"id" => comment_id}, socket) do
    with {:ok, id} <- parse_id(comment_id),
         %Comment{} = comment <- find_loaded_comment(socket, id),
         true <- Content.can_edit_comment?(socket.assigns.current_user, comment) do
      form =
        comment
        |> Content.change_comment(%{})
        |> to_form(as: :comment_edit)

      {:noreply,
       socket
       # Opening an edit closes any open reply: both reuse the page's one
       # composer slot, and two open forms is two places to type the same
       # thought.
       |> assign(:replying_to, nil)
       |> assign(:editing, id)
       |> assign(:comment_edit_form, form)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_comment_edit", _params, socket) do
    {:noreply, socket |> assign(:editing, nil) |> assign(:comment_edit_form, nil)}
  end

  @impl true
  def handle_event("validate_comment_edit", %{"comment_edit" => params}, socket) do
    # The params are assigned straight back, so what was typed survives the
    # re-render this event triggers.
    {:noreply, assign(socket, :comment_edit_form, to_form(params, as: :comment_edit))}
  end

  @impl true
  def handle_event("save_comment_edit", _params, %{assigns: %{current_user: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("save_comment_edit", %{"comment_edit" => params} = all, socket) do
    user = socket.assigns.current_user

    with {:ok, id} <- editing_comment_id(all, socket),
         %Comment{} = comment <- find_loaded_comment(socket, id),
         :ok <- edit_rate_limit(user) do
      save_comment_edit(socket, comment, params, user)
    else
      {:error, :rate_limited} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You are editing too frequently. Please try again later.")
         )}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Comment not found."))}
    end
  end

  @impl true
  def handle_event("reply_to", %{"id" => comment_id}, socket) do
    case parse_id(comment_id) do
      {:ok, id} ->
        socket = clear_uploaded_comment_images(socket)
        {:noreply, socket |> assign(:editing, nil) |> assign(:replying_to, id)}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_reply", _params, socket) do
    socket = clear_uploaded_comment_images(socket)
    {:noreply, assign(socket, :replying_to, nil)}
  end

  @impl true
  # This page is `:optional_auth`, so every client-driven handler here has to
  # survive a guest sending the event by hand.
  def handle_event("save_image_alt", _params, %{assigns: %{current_user: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("save_image_alt", %{"id" => image_id} = params, socket) do
    case Content.update_comment_image_alt(
           image_id,
           socket.assigns.current_user.id,
           params["value"]
         ) do
      {:ok, image} ->
        {:noreply, replace_image(socket, :uploaded_comment_images, image)}

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
  def handle_event("remove_comment_image", %{"id" => id}, socket) do
    uploaded_ids = Enum.map(socket.assigns.uploaded_comment_images, & &1.id)

    with {:ok, image_id} <- parse_id(id),
         true <- image_id in uploaded_ids do
      image = Content.get_comment_image!(image_id)
      Content.delete_comment_image(image)

      updated = Enum.reject(socket.assigns.uploaded_comment_images, &(&1.id == image_id))
      {:noreply, assign(socket, :uploaded_comment_images, updated)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Image not found."))}
    end
  end

  @impl true
  def handle_event("cancel_comment_image_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :comment_images, ref)}
  end

  # Moving the article to another board (7C, ADR 0075). The options are the
  # boards this member moderates; the context checks it all again.
  @impl true
  def handle_event("open_move", _params, socket) do
    user = socket.assigns.current_user
    article = socket.assigns.article
    in_article = MapSet.new(article.boards, & &1.id)
    moderated = MapSet.new(Content.moderated_board_ids(user))

    from_options = Enum.filter(article.boards, &MapSet.member?(moderated, &1.id))

    targets =
      Content.list_visible_boards(user)
      |> Enum.filter(
        &(MapSet.member?(moderated, &1.id) and not MapSet.member?(in_article, &1.id))
      )

    {:noreply,
     socket
     |> assign(move_open: true, move_from_options: from_options, move_targets: targets)
     |> push_event("focus", %{id: "article-move-to"})}
  end

  def handle_event("close_move", _params, socket) do
    {:noreply,
     socket
     |> assign(:move_open, false)
     |> push_event("focus", %{id: "article-menu-trigger"})}
  end

  def handle_event("move_article", %{"from_id" => from_id, "to_id" => to_id}, socket) do
    user = socket.assigns.current_user
    article = socket.assigns.article

    with {:ok, from_id} <- parse_id(from_id),
         {:ok, to_id} <- parse_id(to_id),
         %{} = from <- Enum.find(article.boards, &(&1.id == from_id)),
         {:ok, to} <- Content.get_board(to_id),
         {:ok, moved} <- Content.move_article_to_board(article, from, to, user) do
      Moderation.log_action(user.id, "move_article",
        target_type: "article",
        target_id: article.id,
        details: %{"title" => article.title, "from" => from.name, "to" => to.name}
      )

      moved = Baudrate.Repo.preload(moved, [:user, :remote_actor, :link_preview, poll: :options])

      {:noreply,
       socket
       |> assign(:article, moved)
       |> assign(:move_open, false)
       |> assign(:removable_board_ids, removable_board_ids(moved, user))
       |> put_flash(:info, gettext("Article moved to %{board}.", board: to.name))
       |> push_event("focus", %{id: "article-menu-trigger"})}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Failed to move the article."))}
    end
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
  def handle_event("toggle_comment_forward", %{"id" => id_str}, socket) do
    case parse_id(id_str) do
      {:ok, id} ->
        if socket.assigns.forwarding_comment_id == id do
          {:noreply,
           socket
           |> assign(:forwarding_comment_id, nil)
           |> assign(:comment_forward_search_results, [])
           |> assign(:comment_forward_search_query, "")}
        else
          {:noreply,
           socket
           |> assign(:forwarding_comment_id, id)
           |> assign(:comment_forward_search_results, [])
           |> assign(:comment_forward_search_query, "")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search_comment_forward_board", %{"query" => query}, socket) do
    results =
      if String.length(String.trim(query)) >= 2 do
        Content.search_boards(query, socket.assigns.current_user)
      else
        []
      end

    {:noreply,
     socket
     |> assign(:comment_forward_search_query, query)
     |> assign(:comment_forward_search_results, results)}
  end

  @impl true
  def handle_event("forward_comment_to_board", %{"board-id" => board_id_str}, socket) do
    user = socket.assigns.current_user
    comment_id = socket.assigns.forwarding_comment_id

    with {:ok, board_id} <- parse_id(board_id_str),
         {:ok, board} <- Content.get_board(board_id),
         %Baudrate.Content.Comment{} = comment <-
           Baudrate.Repo.get(Baudrate.Content.Comment, comment_id) || {:error, :not_found},
         {:ok, _article} <- Content.forward_comment_to_board(comment, board, user) do
      {:noreply,
       socket
       |> assign(:forwarding_comment_id, nil)
       |> assign(:comment_forward_search_results, [])
       |> assign(:comment_forward_search_query, "")
       |> put_flash(:info, gettext("Comment forwarded to board."))}
    else
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
        {:noreply, put_flash(socket, :error, gettext("Failed to forward comment."))}
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

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, refusal(socket, reason, gettext("Failed to record vote.")))}
      end
    end
  end

  # Blocking or muting a remote commenter hides their comments, so the thread
  # is reloaded and focus moves to the comments heading.
  @impl true
  def handle_event(event, %{"id" => id}, socket)
      when event in ["block_remote_actor", "mute_remote_actor"] do
    action = if event == "block_remote_actor", do: :block, else: :mute

    case SafetyActions.remote_actor_action(socket, action, id) do
      {:ok, socket} ->
        {:noreply,
         socket
         |> load_comments(socket.assigns.comment_page)
         |> push_event("focus", %{id: "comments-heading"})}

      {:error, socket} ->
        {:noreply, socket}
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
  def handle_event("submit_report", %{"reason" => _} = params, socket) do
    if socket.assigns.report_target_type in SafetyActions.report_types() do
      {:noreply, SafetyActions.submit_report(socket, params)}
    else
      submit_content_report(socket, SafetyActions.report_details(params))
    end
  end

  # Which boards this member may take the article out of (P1-D5): their own
  # boards, or every board for the author and staff — never the last one
  # unless it federates, because an article in no board is public.
  defp removable_board_ids(article, %{} = user) do
    for board <- article.boards,
        Content.can_remove_from_board?(user, article, board),
        Content.may_leave_board?(article, board),
        do: board.id
  end

  defp removable_board_ids(_article, _user), do: []

  defp submit_content_report(socket, details) do
    user = socket.assigns.current_user

    case RateLimits.check_create_report(user.id) do
      {:error, :rate_limited} ->
        {:noreply,
         socket
         |> assign(:show_report_modal, false)
         |> put_flash(:error, gettext("Too many reports. Please try again later."))}

      :ok ->
        target_attrs =
          build_report_target(
            socket.assigns.article,
            socket.assigns.report_target_type,
            socket.assigns.report_target_id
          )

        cond do
          target_attrs == %{} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to submit report."))}

          Moderation.has_open_report?(user.id, target_attrs) ->
            {:noreply,
             socket
             |> assign(:show_report_modal, false)
             |> put_flash(:error, gettext("You have already reported this."))}

          true ->
            attrs = target_attrs |> Map.merge(details) |> Map.put(:reporter_id, user.id)

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

  # Reports name this article or one of its comments. When the content came
  # from another instance, its remote author is recorded as the reported actor,
  # so moderators can forward the report with "Send Flag".
  defp build_report_target(article, "article", id) do
    case Integer.parse(id) do
      {num, ""} when num == article.id ->
        %{article_id: num} |> with_remote_author(article.remote_actor_id)

      _ ->
        %{}
    end
  end

  defp build_report_target(article, "comment", id) do
    with {num, ""} <- Integer.parse(id),
         %{article_id: article_id} = comment when article_id == article.id <-
           Content.get_comment(num) do
      %{comment_id: num} |> with_remote_author(comment.remote_actor_id)
    else
      _ -> %{}
    end
  end

  defp build_report_target(_article, _, _), do: %{}

  defp with_remote_author(attrs, nil), do: attrs

  defp with_remote_author(attrs, remote_actor_id),
    do: Map.put(attrs, :remote_actor_id, remote_actor_id)

  @impl true
  def handle_info({:comment_created, payload}, socket) do
    # Seen live, so it is not new again on the next visit. It is still
    # marked new on this one: `unread_since` is fixed at mount.
    if user = socket.assigns.current_user do
      Content.mark_article_read(user.id, socket.assigns.article.id)
    end

    socket = load_comments(socket, socket.assigns.comment_page)
    {:noreply, announce_new_comment(socket, payload)}
  end

  @impl true
  def handle_info({:comment_deleted, _payload}, socket) do
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

  # Ignore PubSub messages forwarded by the unread DM / notification count
  # hooks (e.g. :dm_received, :notification_created) for logged-in viewers.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Authors are held to the ordinary deletion limit; moderators removing other
  # people's content get their own, higher one (1B). Admins are unlimited, as
  # everywhere else.
  defp check_delete_limit(%{role: %{name: "admin"}}, _author_id), do: :ok

  defp check_delete_limit(%{id: user_id}, author_id) when user_id == author_id,
    do: RateLimits.check_delete_content(user_id)

  defp check_delete_limit(%{id: user_id}, _author_id),
    do: RateLimits.check_moderator_delete(user_id)

  defp do_delete_article(socket, article, user) do
    case Content.soft_delete_article(article, deleted_by: user.id) do
      {:ok, _} ->
        if user.id != article.user_id do
          Hooks.notify_content_removed(article, user.id)

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

      %{article_id: cid, deleted_at: deleted_at} when cid != article.id or deleted_at != nil ->
        {:noreply, put_flash(socket, :error, gettext("Comment not found."))}

      comment ->
        if Content.can_delete_comment?(user, comment, article) do
          case check_delete_limit(user, comment.user_id) do
            {:error, :rate_limited} ->
              {:noreply,
               put_flash(socket, :error, gettext("Too many actions. Please try again later."))}

            :ok ->
              do_soft_delete_comment(socket, comment, article, user)
          end
        else
          {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
        end
    end
  end

  defp do_soft_delete_comment(socket, comment, article, user) do
    case Content.soft_delete_comment(comment, deleted_by: user.id) do
      {:ok, _} ->
        if user.id != comment.user_id do
          Hooks.notify_content_removed(comment, user.id)

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
  end

  defp do_create_comment(socket, user, params) do
    article = socket.assigns.article
    image_ids = Enum.map(socket.assigns.uploaded_comment_images, & &1.id)
    replying_to = socket.assigns.replying_to

    cond do
      not Content.can_comment_on_article?(user, article) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You are not allowed to comment on this article.")
         )}

      replying_to && not parent_comment_belongs_to_article?(replying_to, article.id) ->
        {:noreply,
         socket
         |> assign(:replying_to, nil)
         |> put_flash(:error, gettext("Invalid reply target."))}

      true ->
        do_create_comment_unchecked(socket, user, params, article, image_ids, replying_to)
    end
  end

  defp parent_comment_belongs_to_article?(parent_id, article_id) do
    case Content.get_comment(parent_id) do
      %{article_id: ^article_id} -> true
      _ -> false
    end
  end

  defp do_create_comment_unchecked(socket, user, params, article, image_ids, replying_to) do
    # Allow-list the form fields and always set `parent_id` from the
    # server-side reply target: a client-supplied `parent_id` bypassed the
    # same-article check above and could thread a comment under (and notify
    # the author of) a comment in a board the user cannot see.
    attrs =
      params
      |> Map.take(~w(body visibility summary))
      |> Map.put("article_id", article.id)
      |> Map.put("user_id", user.id)
      |> Map.put("parent_id", replying_to)

    case Content.submit_comment(attrs, image_ids: image_ids) do
      {:ok, _comment} ->
        {:noreply,
         socket
         |> load_comments(socket.assigns.comment_page)
         |> assign(:comment_form, to_form(Content.change_comment(), as: :comment))
         |> assign(:replying_to, nil)
         |> assign(:uploaded_comment_images, [])
         |> put_flash(:info, gettext("Comment posted."))}

      # Waiting for a moderator (ADR 0065). The uploads are not deleted: the
      # held row names them.
      {:held, _held} ->
        {:noreply,
         socket
         |> assign(:comment_form, to_form(Content.change_comment(), as: :comment))
         |> assign(:replying_to, nil)
         |> assign(:uploaded_comment_images, [])
         |> put_flash(:info, BaudrateWeb.Helpers.held_post_message())}

      {:error, :blocked} ->
        {:noreply, put_flash(socket, :error, BaudrateWeb.Helpers.blocked_interaction_message())}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :comment_form, to_form(changeset, as: :comment))}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, refusal(socket, reason, gettext("Failed to post comment.")))}
    end
  end

  defp handle_comment_image_progress(:comment_images, entry, socket) do
    max = Baudrate.Content.CommentImage.max_images_per_comment()

    if entry.done? and length(socket.assigns.uploaded_comment_images) < max do
      user = socket.assigns.current_user

      case consume_uploaded_entry(socket, entry, fn %{path: path} ->
             case ArticleImageStorage.process_upload(path) do
               {:ok, file_info} ->
                 attrs = Map.merge(file_info, %{user_id: user.id})

                 case Content.create_comment_image(attrs) do
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
          {:noreply,
           assign(
             socket,
             :uploaded_comment_images,
             socket.assigns.uploaded_comment_images ++ [image]
           )}
      end
    else
      {:noreply, socket}
    end
  end

  defp clear_uploaded_comment_images(socket) do
    for image <- socket.assigns.uploaded_comment_images do
      Content.delete_comment_image(image)
    end

    assign(socket, :uploaded_comment_images, [])
  end

  # Announces a newly arrived comment through the `role="status"` node, since
  # the re-rendered comment tree itself is not a live region. Only comments
  # that are actually rendered for this viewer (i.e. passed the visibility,
  # block and mute filters of `load_comments/2`) and that were not written
  # by the viewer are announced, so nothing hidden leaks through the status.
  defp announce_new_comment(socket, %{comment_id: comment_id}) do
    current_user = socket.assigns.current_user

    comment =
      (socket.assigns.comment_roots ++ List.flatten(Map.values(socket.assigns.children_map)))
      |> Enum.find(&(&1.id == comment_id))

    cond do
      is_nil(comment) ->
        socket

      current_user && comment.user_id == current_user.id ->
        socket

      name = comment_author_name(comment) ->
        assign(
          socket,
          :comments_live_status,
          gettext("New comment by %{name}", name: name)
        )

      true ->
        assign(socket, :comments_live_status, gettext("New comment"))
    end
  end

  defp announce_new_comment(socket, _payload), do: socket

  defp comment_author_name(%{user: %Baudrate.Setup.User{} = user}),
    do: BaudrateWeb.Helpers.display_name(user)

  defp comment_author_name(%{remote_actor: %Baudrate.Federation.RemoteActor{} = actor}),
    do: BaudrateWeb.Helpers.display_name(actor)

  defp comment_author_name(_), do: nil

  # The form's own hidden field, falling back to the open editor. `parse_id/1`
  # takes only a binary, so the fallback has to be read as the integer it is
  # rather than passed through it.
  defp editing_comment_id(%{"comment_id" => id}, _socket) when is_binary(id), do: parse_id(id)

  defp editing_comment_id(_params, socket) do
    case socket.assigns[:editing] do
      id when is_integer(id) and id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp edit_rate_limit(%{role: %{name: "admin"}}), do: :ok
  defp edit_rate_limit(user), do: RateLimits.check_update_comment(user.id)

  defp save_comment_edit(socket, comment, params, user) do
    attrs = Map.take(params, ~w(body summary sensitive))

    case Content.update_comment(comment, attrs, user) do
      {:ok, _comment} ->
        {:noreply,
         socket
         |> assign(:editing, nil)
         |> assign(:comment_edit_form, nil)
         |> load_comments(socket.assigns.comment_page)
         |> put_flash(:info, gettext("Comment updated."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:comment_edit_form, to_form(changeset, as: :comment_edit))
         |> put_flash(:error, gettext("Failed to update comment."))}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           refusal(socket, reason, gettext("Failed to update comment."))
         )}
    end
  end

  # Only a comment already on this page may be edited: the id comes from the
  # client, and the tree is the list the viewer was actually served, so this
  # is both the cross-article guard and the view gate in one step. The context
  # re-checks authorship regardless.
  defp find_loaded_comment(socket, id) do
    (socket.assigns[:comment_roots] || [])
    |> Enum.concat(Map.values(socket.assigns[:children_map] || %{}) |> List.flatten())
    |> Enum.find(&(&1.id == id))
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

    comment_boosted_ids =
      if current_user do
        Content.comment_boosts_by_user(current_user.id, all_comment_ids)
      else
        MapSet.new()
      end

    comment_boost_counts = Content.comment_boost_counts(all_comment_ids)

    unread_since = socket.assigns.unread_since

    new_comment_ids =
      if current_user && unread_since do
        for c <- comments,
            is_nil(c.deleted_at),
            c.user_id != current_user.id,
            DateTime.compare(c.inserted_at, unread_since) == :gt,
            into: MapSet.new(),
            do: c.id
      else
        MapSet.new()
      end

    comment_bookmarked_ids =
      if current_user do
        Content.comment_bookmarks_by_user(current_user.id, all_comment_ids)
      else
        MapSet.new()
      end

    assign(socket,
      comment_roots: roots,
      children_map: children_map,
      # One query for the page, not one per comment: the marker is rendered
      # for every node in the tree.
      revision_counts: Content.count_comment_revisions_for(all_comment_ids),
      comment_page: comment_page,
      comment_total_pages: comment_total_pages,
      comment_total: Content.count_comments_for_article(article),
      new_comment_ids: new_comment_ids,
      first_new_comment_path: first_new_comment_path(article, current_user, unread_since),
      comment_liked_ids: comment_liked_ids,
      comment_like_counts: comment_like_counts,
      comment_boosted_ids: comment_boosted_ids,
      comment_boost_counts: comment_boost_counts,
      comment_bookmarked_ids: comment_bookmarked_ids
    )
  end

  # Where the earliest comment the viewer has not seen is, across pages.
  defp first_new_comment_path(_article, nil, _since), do: nil
  defp first_new_comment_path(_article, _user, nil), do: nil

  defp first_new_comment_path(article, user, since) do
    with %{} = comment <- Content.first_comment_since(article, user, since),
         {page, anchor} <- Content.comment_location(comment, user) do
      BaudrateWeb.Helpers.comment_path(article, page, anchor)
    end
  end

  # Returns the ActivityPub `id` for the article when it lives in at least one
  # federated board (public + ap_enabled), so the layout can advertise it via
  # `<link rel="alternate" type="application/activity+json">`. Remote
  # implementations use this to discover the AP object from the human URL.
  defp ap_alternate_url(article) do
    boards = article.boards || []

    if Enum.any?(boards, &Board.federated?/1) do
      article.ap_id || Federation.actor_uri(:article, article.slug)
    end
  end

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
