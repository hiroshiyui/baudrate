defmodule BaudrateWeb.FeedLive do
  @moduledoc """
  LiveView for the personal feed page.

  Displays incoming posts from remote actors the user follows,
  with a personal info sidebar showing the current user's profile summary.
  Includes a quick-post composer for creating board-less articles directly
  from the feed. Subscribes to `Federation.PubSub` for real-time updates.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Content
  alias Baudrate.Content.Article
  alias Baudrate.Federation
  alias Baudrate.Federation.PubSub, as: FederationPubSub
  alias BaudrateWeb.RateLimits
  import BaudrateWeb.Helpers, only: [parse_page: 1, translate_role: 1]

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      FederationPubSub.subscribe_user_feed(user.id)
    end

    can_post = Auth.can_create_content?(user)

    socket =
      socket
      |> assign(
        page_title: gettext("Feed"),
        wide_layout: true,
        article_count: Content.count_articles_by_user(user.id),
        comment_count: Content.count_comments_by_user(user.id),
        can_post: can_post
      )
      |> then(fn s ->
        if can_post do
          assign(s, :form, to_form(Content.change_article(), as: :article))
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

    {:noreply,
     socket
     |> assign(:items, result.items)
     |> assign(:page, result.page)
     |> assign(:total_pages, result.total_pages)
     |> assign(:total, result.total)}
  end

  def handle_info({:feed_item_created, _payload}, socket) do
    user = socket.assigns.current_user
    page = socket.assigns.page
    result = Federation.list_feed_items(user, page: page)

    {:noreply,
     socket
     |> assign(:items, result.items)
     |> assign(:total_pages, result.total_pages)
     |> assign(:total, result.total)}
  end

  def handle_event("validate_post", %{"article" => params}, socket) do
    changeset =
      Content.change_article(%Article{}, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :article))}
  end

  def handle_event("submit_post", %{"article" => params}, socket) do
    user = socket.assigns.current_user

    if user.role.name == "admin" do
      do_create_post(socket, user, params)
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
          do_create_post(socket, user, params)
      end
    end
  end

  defp do_create_post(socket, user, params) do
    slug = Content.generate_slug(params["title"] || "")

    attrs =
      params
      |> Map.put("slug", slug)
      |> Map.put("user_id", user.id)

    case Content.create_article(attrs, []) do
      {:ok, %{article: _article}} ->
        page = socket.assigns.page
        result = Federation.list_feed_items(user, page: page)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Article posted!"))
         |> assign(:form, to_form(Content.change_article(), as: :article))
         |> assign(:items, result.items)
         |> assign(:total_pages, result.total_pages)
         |> assign(:total, result.total)
         |> assign(:article_count, Content.count_articles_by_user(user.id))}

      {:error, :article, changeset, _} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :article))}

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
end
