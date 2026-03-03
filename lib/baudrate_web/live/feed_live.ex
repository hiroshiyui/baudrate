defmodule BaudrateWeb.FeedLive do
  @moduledoc """
  LiveView for the personal feed page.

  Displays incoming posts from remote actors the user follows, local articles
  from followed users, and comments (both local and from remote actors) on
  articles the user authored or previously commented on. Includes a personal
  info sidebar, a quick-post composer for creating board-less articles, and
  inline reply forms for responding to remote feed items via ActivityPub.
  Subscribes to `Federation.PubSub` for real-time updates.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Content
  alias Baudrate.Content.Article
  alias Baudrate.Federation
  alias Baudrate.Federation.FeedItemReply
  alias Baudrate.Federation.PubSub, as: FederationPubSub
  alias BaudrateWeb.RateLimits
  import BaudrateWeb.Helpers, only: [parse_page: 1, translate_role: 1]

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
        replies: %{}
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

    # Collect remote feed item IDs for reply counts
    remote_feed_item_ids =
      result.items
      |> Enum.filter(&(&1.source == :remote))
      |> Enum.map(& &1.feed_item.id)

    reply_counts = Federation.count_feed_item_replies(remote_feed_item_ids)

    {:noreply,
     socket
     |> assign(:items, result.items)
     |> assign(:page, result.page)
     |> assign(:total_pages, result.total_pages)
     |> assign(:total, result.total)
     |> assign(:reply_counts, reply_counts)
     |> assign(:replies, %{})
     |> assign(:replying_to, nil)}
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

  def handle_event("toggle_reply", %{"id" => feed_item_id_str}, socket) do
    feed_item_id = String.to_integer(feed_item_id_str)

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
       |> assign(:reply_form, to_form(FeedItemReply.changeset(%FeedItemReply{}, %{}), as: :reply))
       |> assign(:replies, %{feed_item_id => replies})}
    end
  end

  def handle_event("validate_reply", %{"reply" => params}, socket) do
    changeset =
      FeedItemReply.changeset(%FeedItemReply{}, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :reply_form, to_form(changeset, as: :reply))}
  end

  def handle_event("submit_reply", %{"reply" => params, "feed_item_id" => fi_id_str}, socket) do
    user = socket.assigns.current_user
    feed_item_id = String.to_integer(fi_id_str)

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

  def handle_event("cancel_reply", _params, socket) do
    {:noreply,
     socket
     |> assign(:replying_to, nil)
     |> assign(:replies, %{})}
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

  defp reply_count(assigns, feed_item_id) do
    Map.get(assigns.reply_counts, feed_item_id, 0)
  end
end
