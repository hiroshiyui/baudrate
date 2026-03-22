defmodule BaudrateWeb.CommentComponents do
  @moduledoc """
  Function components for rendering comment threads.

  Extracted from `BaudrateWeb.ArticleLive` to allow focused composition
  and potential reuse across LiveViews that display comment threads.
  """

  use BaudrateWeb, :html

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
  attr :comment_boosted_ids, :any, default: nil
  attr :comment_boost_counts, :any, default: nil
  attr :forwarding_comment_id, :any, default: nil
  attr :comment_forward_search_results, :list, default: []
  attr :comment_forward_search_query, :string, default: ""
  attr :uploads, :any, default: nil
  attr :uploaded_comment_images, :list, default: []

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
          <a
            :if={@comment.remote_actor}
            href={@comment.url || @comment.ap_id}
            target="_blank"
            rel="nofollow noopener noreferrer"
            class="link link-hover"
            title={gettext("View original")}
          >
            <time datetime={datetime_attr(@comment.inserted_at)}>
              {format_datetime(@comment.inserted_at)}
            </time>
          </a>
          <a
            :if={!@comment.remote_actor}
            href={"#comment-#{@comment.id}"}
            class="link link-hover"
          >
            <time datetime={datetime_attr(@comment.inserted_at)}>
              {format_datetime(@comment.inserted_at)}
            </time>
          </a>

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

        <%!-- Comment image gallery --%>
        <div
          :if={is_list(@comment.images) && @comment.images != []}
          class={[
            "grid gap-2 mt-2",
            length(@comment.images) == 1 && "grid-cols-1",
            length(@comment.images) >= 2 && "grid-cols-2"
          ]}
        >
          <a
            :for={img <- @comment.images}
            href={Baudrate.Content.ArticleImageStorage.image_url(img.filename)}
            target="_blank"
            rel="noopener"
            class="block overflow-hidden rounded-lg"
            aria-label={
              gettext("Image %{number} (opens in new tab)",
                number: Enum.find_index(@comment.images, &(&1.id == img.id)) + 1
              )
            }
          >
            <img
              src={Baudrate.Content.ArticleImageStorage.image_url(img.filename)}
              width={img.width}
              height={img.height}
              loading="lazy"
              class="w-full h-auto object-cover rounded-lg border border-base-300 hover:scale-[1.02] transition-transform duration-200"
              alt={
                gettext("Image %{number}",
                  number: Enum.find_index(@comment.images, &(&1.id == img.id)) + 1
                )
              }
            />
          </a>
        </div>

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
          <%!-- Comment boost button --%>
          <.comment_boost_button
            comment={@comment}
            current_user={@current_user}
            comment_boosted_ids={@comment_boosted_ids}
            comment_boost_counts={@comment_boost_counts}
          />
          <%!-- Forward comment to board --%>
          <button
            :if={@current_user && @comment.visibility in ["public", "unlisted"]}
            phx-click="toggle_comment_forward"
            phx-value-id={@comment.id}
            class="btn btn-ghost btn-xs"
            aria-label={gettext("Forward to Board")}
            title={gettext("Forward to Board")}
          >
            <.icon name="hero-arrow-uturn-right" class="size-3" />
          </button>
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

        <%!-- Comment forward search panel --%>
        <div
          :if={@forwarding_comment_id == @comment.id}
          id={"comment-forward-search-#{@comment.id}"}
          class="flex items-center gap-2 text-sm mt-2"
        >
          <div class="w-full max-w-md">
            <.form
              for={%{}}
              phx-change="search_comment_forward_board"
              class="flex items-center gap-2"
            >
              <input
                type="text"
                name="query"
                value={@comment_forward_search_query}
                placeholder={gettext("Search boards...")}
                phx-debounce="300"
                autocomplete="off"
                class="input input-sm input-bordered w-full"
                aria-label={gettext("Search boards")}
                role="combobox"
              />
              <button
                type="button"
                phx-click="toggle_comment_forward"
                phx-value-id={@comment.id}
                class="btn btn-sm btn-ghost"
                aria-label={gettext("Cancel")}
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </.form>
            <ul
              :if={@comment_forward_search_results != []}
              id={"comment-forward-results-#{@comment.id}"}
              role="listbox"
              class="menu bg-base-200 rounded-box mt-1 shadow-lg max-h-48 overflow-y-auto"
            >
              <li :for={board <- @comment_forward_search_results}>
                <button
                  phx-click="forward_comment_to_board"
                  phx-value-board-id={board.id}
                  role="option"
                >
                  {board.name}
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
            <%!-- Image upload for reply --%>
            <.comment_image_upload_area
              :if={@uploads}
              uploads={@uploads}
              uploaded_images={@uploaded_comment_images}
            />
            <div class="flex flex-wrap items-center gap-2 [&>.fieldset]:mb-0 [&>.fieldset]:p-0 [&_.label]:py-0">
              <.input
                field={@comment_form[:visibility]}
                type="select"
                options={[
                  {gettext("Public"), "public"},
                  {gettext("Unlisted"), "unlisted"},
                  {gettext("Followers only"), "followers_only"},
                  {gettext("Direct"), "direct"}
                ]}
                class="select select-sm"
                aria-label={gettext("Visibility")}
              />
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
          comment_boosted_ids={@comment_boosted_ids}
          comment_boost_counts={@comment_boost_counts}
          forwarding_comment_id={@forwarding_comment_id}
          comment_forward_search_results={@comment_forward_search_results}
          comment_forward_search_query={@comment_forward_search_query}
          uploads={@uploads}
          uploaded_comment_images={@uploaded_comment_images}
        />
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the image upload area for a comment or reply form.

  Shows an add-images button, uploaded image thumbnails with remove buttons,
  upload progress indicators, and error messages.
  """
  attr :uploads, :any, required: true
  attr :uploaded_images, :list, default: []

  def comment_image_upload_area(assigns) do
    ~H"""
    <div class="comment-image-upload">
      <%!-- Add images button (hidden file input + label) --%>
      <div :if={length(@uploaded_images) < 4} class="flex items-center gap-1 mb-2">
        <.live_file_input upload={@uploads.comment_images} class="hidden" />
        <label
          for={@uploads.comment_images.ref}
          class="btn btn-sm btn-ghost gap-1 cursor-pointer"
          aria-label={gettext("Add Images")}
        >
          <.icon name="hero-photo" class="size-4" />
          {gettext("Add Images")}
        </label>
      </div>

      <%!-- Uploaded thumbnails --%>
      <div :if={@uploaded_images != []} class="grid grid-cols-2 sm:grid-cols-4 gap-2 mb-2">
        <div :for={img <- @uploaded_images} class="relative group aspect-square">
          <img
            src={Baudrate.Content.ArticleImageStorage.image_url(img.filename)}
            class="w-full h-full object-cover rounded-lg border border-base-300"
            loading="lazy"
            alt={gettext("Uploaded image")}
          />
          <button
            type="button"
            phx-click="remove_comment_image"
            phx-value-id={img.id}
            class="absolute top-1 right-1 btn btn-circle btn-error min-h-[44px] min-w-[44px] opacity-80 sm:opacity-0 sm:group-hover:opacity-100 transition-opacity"
            aria-label={gettext("Remove image")}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
      </div>

      <%!-- Upload progress --%>
      <div
        :for={entry <- @uploads.comment_images.entries}
        class="flex items-center gap-2 text-sm mb-1"
      >
        <span class="truncate max-w-48">{entry.client_name}</span>
        <progress value={entry.progress} max="100" class="progress progress-primary w-24">
          {entry.progress}%
        </progress>
        <button
          type="button"
          phx-click="cancel_comment_image_upload"
          phx-value-ref={entry.ref}
          class="btn btn-sm btn-ghost text-error"
          aria-label={gettext("Cancel upload")}
        >
          &times;
        </button>
      </div>

      <%!-- Upload errors --%>
      <div
        :for={err <- upload_errors(@uploads.comment_images)}
        class="text-sm text-error"
        role="alert"
      >
        {upload_error_to_string(err)}
      </div>
      <div
        :for={entry <- @uploads.comment_images.entries}
        :if={upload_errors(@uploads.comment_images, entry) != []}
      >
        <div
          :for={err <- upload_errors(@uploads.comment_images, entry)}
          class="text-sm text-error"
          role="alert"
        >
          {upload_error_to_string(err)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the image upload area for a feed item reply form.

  Identical layout to `comment_image_upload_area/1` but targets the
  `:reply_images` upload channel and `remove_reply_image` / `cancel_reply_image_upload`
  events.
  """
  attr :uploads, :any, required: true
  attr :uploaded_images, :list, default: []

  def reply_image_upload_area(assigns) do
    ~H"""
    <div class="reply-image-upload">
      <div :if={length(@uploaded_images) < 4} class="flex items-center gap-1 mb-2">
        <.live_file_input upload={@uploads.reply_images} class="hidden" />
        <label
          for={@uploads.reply_images.ref}
          class="btn btn-sm btn-ghost gap-1 cursor-pointer"
          aria-label={gettext("Add Images")}
        >
          <.icon name="hero-photo" class="size-4" />
          {gettext("Add Images")}
        </label>
      </div>

      <div :if={@uploaded_images != []} class="grid grid-cols-2 sm:grid-cols-4 gap-2 mb-2">
        <div :for={img <- @uploaded_images} class="relative group aspect-square">
          <img
            src={Baudrate.Content.ArticleImageStorage.image_url(img.filename)}
            class="w-full h-full object-cover rounded-lg border border-base-300"
            loading="lazy"
            alt={gettext("Uploaded image")}
          />
          <button
            type="button"
            phx-click="remove_reply_image"
            phx-value-id={img.id}
            class="absolute top-1 right-1 btn btn-circle btn-error min-h-[44px] min-w-[44px] opacity-80 sm:opacity-0 sm:group-hover:opacity-100 transition-opacity"
            aria-label={gettext("Remove image")}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
      </div>

      <div
        :for={entry <- @uploads.reply_images.entries}
        class="flex items-center gap-2 text-sm mb-1"
      >
        <span class="truncate max-w-48">{entry.client_name}</span>
        <progress value={entry.progress} max="100" class="progress progress-primary w-24">
          {entry.progress}%
        </progress>
        <button
          type="button"
          phx-click="cancel_reply_image_upload"
          phx-value-ref={entry.ref}
          class="btn btn-sm btn-ghost text-error"
          aria-label={gettext("Cancel upload")}
        >
          &times;
        </button>
      </div>

      <div
        :for={err <- upload_errors(@uploads.reply_images)}
        class="text-sm text-error"
        role="alert"
      >
        {upload_error_to_string(err)}
      </div>
      <div
        :for={entry <- @uploads.reply_images.entries}
        :if={upload_errors(@uploads.reply_images, entry) != []}
      >
        <div
          :for={err <- upload_errors(@uploads.reply_images, entry)}
          class="text-sm text-error"
          role="alert"
        >
          {upload_error_to_string(err)}
        </div>
      </div>
    </div>
    """
  end

  defp upload_error_to_string(err),
    do: BaudrateWeb.Helpers.upload_error_to_string(err, max_size: "8 MB", max_files: 4)

  attr :comment, :map, required: true
  attr :current_user, :any, default: nil
  attr :comment_liked_ids, :any, default: nil
  attr :comment_like_counts, :any, default: nil

  def comment_like_button(assigns) do
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

  attr :comment, :map, required: true
  attr :current_user, :any, default: nil
  attr :comment_boosted_ids, :any, default: nil
  attr :comment_boost_counts, :any, default: nil

  def comment_boost_button(assigns) do
    boosted_ids = assigns.comment_boosted_ids || MapSet.new()
    counts = assigns.comment_boost_counts || %{}
    is_boosted = MapSet.member?(boosted_ids, assigns.comment.id)
    is_own = assigns.current_user && assigns.comment.user_id == assigns.current_user.id
    boost_count = Map.get(counts, assigns.comment.id, 0)

    assigns =
      assigns
      |> assign(:is_boosted, is_boosted)
      |> assign(:is_own, is_own)
      |> assign(:boost_count, boost_count)

    ~H"""
    <span class="inline-flex items-center gap-1 text-sm text-base-content/70">
      <button
        :if={@current_user && !@is_own}
        type="button"
        phx-click="toggle_comment_boost"
        phx-value-id={@comment.id}
        class="hover:text-success cursor-pointer"
        aria-label={if @is_boosted, do: gettext("Unboost"), else: gettext("Boost")}
      >
        <.icon
          name={
            if @is_boosted,
              do: "hero-arrow-path-rounded-square-solid",
              else: "hero-arrow-path-rounded-square"
          }
          class={["size-4", @is_boosted && "text-success"]}
        />
      </button>
      <.icon
        :if={!@current_user || @is_own}
        name="hero-arrow-path-rounded-square"
        class="size-4"
      />
      <span :if={@boost_count > 0}>{@boost_count}</span>
    </span>
    """
  end
end
