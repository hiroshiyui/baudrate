defmodule BaudrateWeb.ArticleNewLive do
  @moduledoc """
  LiveView for creating new articles.

  Accessible from both board pages (uses the board from the URL via a fixed
  hidden input, no picker shown) and as a standalone route at `/articles/new`
  where the user picks one or more boards via a debounced search input backed
  by `Content.search_boards/2`. Selected boards appear as removable chips
  above the search input; each chip renders a hidden `board_ids[]` input so
  the form submission carries the full selection. The search filter respects
  `can_post_in_board?/2`, and the add-board handler re-checks the permission
  server-side.

  Supports uploading up to 4 images (max 8 MB each) that are displayed as a
  media gallery at the end of the article. Images are processed to WebP,
  downscaled to max 1024px, and stripped of metadata.

  ## PWA Web Share Target

  When accessed with `?title=...&text=...&url=...` query params (from the
  PWA Share Target flow), the form is pre-filled with the shared content.
  In this mode, submitting without selecting a board is allowed — the
  article is created as a personal (boardless) article.

  Requires the user to be active and have `user.create_content` permission.
  """

  use BaudrateWeb, :live_view

  require Logger

  alias Baudrate.Auth
  alias Baudrate.Content
  alias Baudrate.Content.ArticleImageStorage
  alias BaudrateWeb.{PollComposer, RateLimits}
  import BaudrateWeb.Helpers, only: [parse_id: 1, interaction_refused_message: 2]

  # Long enough that ordinary typing produces one write every couple of
  # seconds rather than one per keystroke; short enough that a tab closed
  # mid-sentence has lost at most that.
  @autosave_after_ms 2_000

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user

    unless Auth.can_create_content?(user) do
      {:ok,
       socket
       |> put_flash(:error, composer_refusal_message(user))
       |> redirect(to: ~p"/")}
    else
      fixed_board =
        case params do
          %{"slug" => slug} -> Content.get_board_by_slug!(slug)
          _ -> nil
        end

      # Pre-fill from PWA Web Share Target query params
      share_title = params["title"] || ""
      share_text = params["text"] || ""
      share_url = params["url"] || ""
      from_share = share_title != "" or share_text != "" or share_url != ""
      body = compose_share_body(share_text, share_url)

      draft = restorable_draft(user, params, from_share, fixed_board)

      initial =
        cond do
          from_share -> %{"title" => share_title, "body" => body}
          draft -> draft_form_params(draft)
          true -> %{}
        end

      changeset = Content.change_article(%Baudrate.Content.Article{}, initial)

      {:ok,
       socket
       |> assign(:form, to_form(changeset, as: :article))
       |> assign(:fixed_board, fixed_board)
       |> assign(:board_slug, params["slug"])
       |> assign(:selected_boards, draft_boards(draft, user, fixed_board))
       |> assign(:board_search_query, "")
       |> assign(:board_search_results, [])
       |> assign(:from_share, from_share)
       |> assign(:uploaded_images, draft_images(draft, user))
       |> assign(:page_title, gettext("Create Article"))
       |> assign(:poll_enabled, (draft && draft.poll_enabled) || false)
       |> assign(:poll_options, draft_poll_options(draft))
       |> assign(:poll_mode, (draft && draft.poll_mode) || "single")
       |> assign(:poll_expires, (draft && draft.poll_expires) || "")
       |> assign(:draft_id, draft && draft.id)
       |> assign(:draft_restored, draft != nil)
       |> assign(:draft_quota_reached, false)
       |> assign(:max_drafts_allowed, Content.max_drafts())
       |> assign(:draft_timer, nil)
       |> assign(:draft_params, nil)
       |> allow_upload(:article_images,
         accept: ~w(.jpg .jpeg .png .webp .gif),
         max_entries: 4,
         max_file_size: 8_000_000,
         auto_upload: true,
         progress: &handle_progress/3
       )}
    end
  end

  @impl true
  def handle_event("search_boards", %{"value" => query}, socket) do
    selected_ids = MapSet.new(socket.assigns.selected_boards, & &1.id)

    results =
      if String.length(String.trim(query)) >= 2 do
        Content.search_boards(query, socket.assigns.current_user)
        |> Enum.reject(&MapSet.member?(selected_ids, &1.id))
      else
        []
      end

    {:noreply,
     socket
     |> assign(:board_search_query, query)
     |> assign(:board_search_results, results)}
  end

  @impl true
  def handle_event("add_board", %{"board-id" => board_id}, socket) do
    with {:ok, id} <- parse_id(board_id),
         %Baudrate.Content.Board{} = board <- find_result_board(socket, id),
         true <- Content.can_post_in_board?(board, socket.assigns.current_user) do
      selected = socket.assigns.selected_boards

      already_selected? = Enum.any?(selected, &(&1.id == board.id))

      new_selected = if already_selected?, do: selected, else: selected ++ [board]

      {:noreply,
       socket
       |> assign(:selected_boards, new_selected)
       |> assign(:board_search_query, "")
       |> assign(:board_search_results, [])}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_board", %{"board-id" => board_id}, socket) do
    case parse_id(board_id) do
      {:ok, id} ->
        selected = Enum.reject(socket.assigns.selected_boards, &(&1.id == id))
        {:noreply, assign(socket, :selected_boards, selected)}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("validate", %{"article" => params} = all_params, socket) do
    changeset =
      Content.change_article(%Baudrate.Content.Article{}, params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :article))
     |> PollComposer.assign_poll_params(all_params)
     |> schedule_draft_autosave(all_params)}
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
      {:ok, image} -> {:noreply, replace_image(socket, :uploaded_images, image)}
      {:error, _} -> {:noreply, socket}
    end
  end

  @impl true
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

    if length(options) < PollComposer.max_options() do
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
        "submit",
        %{"article" => params, "board_ids" => board_ids} = all_params,
        socket
      ) do
    do_create(socket, params, board_ids, all_params)
  end

  def handle_event("submit", %{"article" => params} = all_params, socket) do
    do_create(socket, params, [], all_params)
  end

  @impl true
  def handle_info(:autosave_draft, socket) do
    {:noreply, socket |> assign(:draft_timer, nil) |> autosave_draft()}
  end

  # Every authenticated LiveView needs this: the DM and notification count
  # hooks forward their PubSub messages into whatever view is mounted, and a
  # view with only guarded clauses crashes for any signed-in member who
  # receives one while writing.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

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
    cond do
      board_ids == [] and not socket.assigns.from_share ->
        {:noreply, put_flash(socket, :error, gettext("Please select at least one board."))}

      true ->
        user = socket.assigns.current_user

        # Re-authorize every board server-side. The form's board_ids[] could
        # have been forged by the client (e.g., via DevTools) with IDs of
        # boards the user cannot post in, and Content.create_article/3 does
        # not enforce per-board permissions on its own.
        case Content.authorize_post_in_boards(user, board_ids) do
          {:ok, _boards} ->
            run_create_with_rate_limit(socket, user, params, board_ids, all_params)

          {:error, _} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("You are not allowed to post in one or more of the selected boards.")
             )}
        end
    end
  end

  defp run_create_with_rate_limit(socket, user, params, board_ids, all_params) do
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

  defp do_create_article(socket, user, params, board_ids, all_params) do
    slug = Content.generate_slug(params["title"] || "")

    # Allow-list the form fields: everything else (`ap_id`, `url`,
    # `published_at`, ...) is server-owned and must not come from the client.
    attrs =
      params
      |> Map.take(~w(title body forwardable visibility summary))
      |> Map.put("slug", slug)
      |> Map.put("user_id", user.id)

    image_ids = Enum.map(socket.assigns.uploaded_images, & &1.id)
    poll_opts = build_poll_opts(socket, all_params)

    case Content.submit_article(attrs, board_ids, [image_ids: image_ids] ++ poll_opts) do
      {:ok, %{article: article}} ->
        # The draft has become the article, so it goes — and the pending
        # autosave goes with it, or it would fire after the redirect and
        # write the post back as a draft nobody asked to keep.
        {:noreply,
         socket
         |> discard_draft(user)
         |> put_flash(:info, gettext("Article created successfully."))
         |> redirect(to: ~p"/articles/#{article.slug}")}

      # Waiting for a moderator (ADR 0065). The submission now lives in the
      # held row, so the draft goes as it would on publishing, and the
      # uploads stay: the held row names them.
      {:held, _held} ->
        {:noreply,
         socket
         |> discard_draft(user)
         |> put_flash(:info, BaudrateWeb.Helpers.held_post_message())
         |> redirect(to: ~p"/drafts")}

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

      # Refused by a gate (ADR 0029, ADR 0064): say why, and keep what was
      # written — a new member told about the link limit has to be able to
      # take a link out rather than type the post again.
      {:error, :account, reason, _} ->
        {:noreply,
         socket
         |> assign(
           :form,
           to_form(Content.change_article(%Baudrate.Content.Article{}, params), as: :article)
         )
         |> put_flash(:error, refusal(socket, reason, gettext("Failed to create article.")))}

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

  defp upload_error_to_string(err),
    do: BaudrateWeb.Helpers.upload_error_to_string(err, max_size: "8 MB", max_files: 4)

  defp find_result_board(socket, id) do
    Enum.find(socket.assigns.board_search_results, &(&1.id == id))
  end

  defp compose_share_body("", ""), do: ""
  defp compose_share_body(text, ""), do: text
  defp compose_share_body("", url), do: url
  defp compose_share_body(text, url), do: text <> "\n" <> url

  # A member refused by the interaction gate is told which restriction stands
  # and until when; anything else keeps the caller's own message (ADR 0029).
  defp refusal(socket, reason, fallback) do
    BaudrateWeb.Helpers.refusal_message(reason, socket.assigns[:current_user], fallback)
  end

  # `can_create_content?/1` bundles three conditions, and the member needs to
  # know which one stands. A silenced member told "pending approval" waits for
  # staff who are not coming, and one who is only behind on the terms never
  # learns that a button on /terms would fix it (ADR 0029, ADR 0031).
  defp composer_refusal_message(user) do
    case Auth.ensure_can_interact(user) do
      {:error, reason} -> interaction_refused_message(reason, user)
      :ok -> gettext("Your account is pending approval.")
    end
  end

  # Swap the saved row back into the list the composer renders, so the
  # thumbnail's own alt text matches what was just typed. The input itself is
  # `phx-update="ignore"` and is not patched by this.
  defp replace_image(socket, key, image) do
    updated = Enum.map(socket.assigns[key], fn i -> if i.id == image.id, do: image, else: i end)
    assign(socket, key, updated)
  end

  # --- Drafts ---
  #
  # The server-side half of the composer's autosave. The localStorage hook is
  # untouched and still runs: it is the half that works with no connection,
  # and this is the half that follows a member to another device.

  # A draft is restored in two cases and refused in three, and each refusal is
  # a case where putting text in front of somebody would be wrong rather than
  # merely unhelpful:
  #
  #   * `?draft=N` — an explicit resume from /drafts. Scoped to the owner, so
  #     another member's id restores nothing.
  #   * a bare /articles/new — the most recent draft, which is what makes the
  #     phone-to-laptop case work with no action.
  #   * **not** when the composer was opened from the PWA share target: the
  #     member is posting the thing they just shared, and an old draft would
  #     overwrite it.
  #   * **not** when opened from a board ("post in #board"), where an
  #     unrelated draft addressed to other boards is a non-sequitur.
  defp restorable_draft(_user, _params, true, _fixed_board), do: nil

  defp restorable_draft(user, %{"draft" => id}, _from_share, _fixed_board) do
    case parse_id(id) do
      {:ok, draft_id} -> Content.get_draft(user.id, draft_id)
      :error -> nil
    end
  end

  defp restorable_draft(_user, _params, _from_share, %Baudrate.Content.Board{}), do: nil
  defp restorable_draft(user, _params, _from_share, nil), do: Content.latest_draft(user.id)

  defp draft_form_params(draft) do
    %{
      "title" => draft.title || "",
      "body" => draft.body || "",
      "summary" => draft.summary || "",
      "sensitive" => draft.sensitive,
      "visibility" => draft.visibility || "public",
      "forwardable" => draft.forwardable
    }
  end

  # Re-checked at resume rather than trusted from the row: a board can be
  # deleted, or the member's right to post in it withdrawn, between saving a
  # draft and coming back to it. A board that fails either test is dropped
  # silently — the alternative is a composer that refuses to submit and does
  # not say which of the chips is the problem.
  defp draft_boards(nil, _user, _fixed_board), do: []
  defp draft_boards(_draft, _user, %Baudrate.Content.Board{}), do: []

  defp draft_boards(draft, user, nil) do
    Enum.flat_map(draft.board_ids, fn board_id ->
      # `get_board/1` answers `{:ok, board}`. Treating that tuple as the board
      # crashed the composer for every draft that had a board chosen.
      case Content.get_board(board_id) do
        {:ok, board} -> if Content.can_post_in_board?(board, user), do: [board], else: []
        _ -> []
      end
    end)
  end

  # Only images that are still the member's own and still unattached. The
  # orphan sweep spares them while the draft holds them, but an image that was
  # attached to some other post in the meantime is no longer this draft's.
  defp draft_images(nil, _user), do: []

  defp draft_images(draft, user) do
    held = MapSet.new(draft.image_ids)

    user.id
    |> Content.list_orphan_article_images()
    |> Enum.filter(&MapSet.member?(held, &1.id))
  end

  defp draft_poll_options(%{poll_options: [_, _ | _] = options}), do: options
  defp draft_poll_options(_), do: ["", ""]

  defp schedule_draft_autosave(socket, all_params) do
    if timer = socket.assigns[:draft_timer], do: Process.cancel_timer(timer)

    socket
    |> assign(:draft_timer, Process.send_after(self(), :autosave_draft, @autosave_after_ms))
    |> assign(:draft_params, all_params)
  end

  defp cancel_draft_autosave(socket) do
    if timer = socket.assigns[:draft_timer], do: Process.cancel_timer(timer)
    socket |> assign(:draft_timer, nil) |> assign(:draft_params, nil)
  end

  defp discard_draft(socket, user) do
    if id = socket.assigns[:draft_id], do: Content.delete_draft(user.id, id)
    socket |> cancel_draft_autosave() |> assign(:draft_id, nil)
  end

  defp autosave_draft(%{assigns: %{draft_params: nil}} = socket), do: socket

  defp autosave_draft(socket) do
    user = socket.assigns.current_user
    all_params = socket.assigns.draft_params
    article = all_params["article"] || %{}

    if blank_draft?(article) do
      socket
    else
      case RateLimits.check_draft_save(user.id) do
        {:error, :rate_limited} -> socket
        :ok -> write_draft(socket, user, article, all_params)
      end
    end
  end

  # An empty composer is not a draft. Without this, opening /articles/new and
  # touching one field would leave a row behind, and the member's drafts list
  # would fill with blanks they never wrote.
  defp blank_draft?(article) do
    String.trim(article["title"] || "") == "" and String.trim(article["body"] || "") == ""
  end

  defp write_draft(socket, user, article, all_params) do
    attrs =
      article
      |> Map.take(~w(title body summary sensitive visibility forwardable))
      # An empty select value would fail `validate_inclusion` and make the
      # save fail silently, which is the one way this feature must not break:
      # the member is told nothing and believes their work is safe.
      |> Enum.reject(fn {k, v} -> k == "visibility" and v in [nil, ""] end)
      |> Map.new()
      |> Map.put("board_ids", Enum.map(socket.assigns.selected_boards, & &1.id))
      |> Map.put("image_ids", Enum.map(socket.assigns.uploaded_images, & &1.id))
      |> Map.put("poll_enabled", socket.assigns.poll_enabled)
      |> Map.put("poll_options", poll_option_values(all_params))
      |> Map.put("poll_mode", socket.assigns.poll_mode)
      |> Map.put("poll_expires", socket.assigns.poll_expires)

    case Content.save_draft(user.id, attrs, socket.assigns.draft_id) do
      {:ok, draft} ->
        socket |> assign(:draft_id, draft.id) |> assign(:draft_quota_reached, false)

      {:error, :quota_exceeded} ->
        # Said once, in the composer, rather than swallowed: the member's work
        # is still safe in localStorage, but they need to know the server half
        # has stopped and why.
        assign(socket, :draft_quota_reached, true)

      {:error, changeset} ->
        # Never silent. A draft that stops saving with nothing said is worse
        # than one that was never offered.
        Logger.warning(
          "drafts.save_failed: user_id=#{user.id} errors=#{inspect(changeset.errors)}"
        )

        socket
    end
  end

  defp poll_option_values(all_params) do
    all_params
    |> Map.get("poll_options", %{})
    |> Enum.sort_by(fn {k, _} ->
      case Integer.parse(k) do
        {n, ""} -> n
        _ -> 0
      end
    end)
    |> Enum.map(fn {_, v} -> v end)
  end
end
