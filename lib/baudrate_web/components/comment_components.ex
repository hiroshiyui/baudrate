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
        />
      <% end %>
    </div>
    """
  end

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
