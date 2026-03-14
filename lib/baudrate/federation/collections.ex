defmodule Baudrate.Federation.Collections do
  @moduledoc """
  Builds paginated ActivityPub `OrderedCollection` responses for AP endpoints.

  Handles:

  - User and board outboxes (Create/Announce activities)
  - Followers and following collections
  - Boards index collection
  - Article replies collection
  - Search collection

  All collections follow the ActivityPub `OrderedCollection` /
  `OrderedCollectionPage` pagination pattern.
  """

  import Ecto.Query

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Federation.{BoardFollow, Follower, ObjectBuilder, UserFollow}

  @as_context "https://www.w3.org/ns/activitystreams"
  @as_public "https://www.w3.org/ns/activitystreams#Public"
  @state_accepted "accepted"
  @items_per_page 20

  @doc """
  Returns a paginated OrderedCollection for a user's outbox.

  Without `?page`, returns the root collection with `totalItems` and `first` link.
  With `?page=N`, returns an `OrderedCollectionPage` with items.

  The outbox contains `Create(Article)` activities for the user's published articles
  in public boards.
  """
  def user_outbox(user, page_params \\ %{}) do
    outbox_uri = "#{actor_uri(:user, user.username)}/outbox"

    case parse_page(page_params) do
      nil ->
        total = count_public_user_articles(user.id)
        build_collection_root(outbox_uri, total)

      page ->
        articles = paginate_public_user_articles(user.id, page)
        items = Enum.map(articles, &wrap_create_activity/1)
        has_next = length(items) == @items_per_page
        build_collection_page(outbox_uri, items, page, has_next)
    end
  end

  @doc """
  Returns a paginated OrderedCollection for a board's outbox.

  The outbox contains `Announce(Article)` activities for articles posted to the board.
  """
  def board_outbox(board, page_params \\ %{}) do
    outbox_uri = "#{actor_uri(:board, board.slug)}/outbox"

    case parse_page(page_params) do
      nil ->
        result = Content.paginate_articles_for_board(board, page: 1, per_page: 1)
        build_collection_root(outbox_uri, result.total)

      page ->
        result = Content.paginate_articles_for_board(board, page: page, per_page: @items_per_page)
        articles = Repo.preload(result.articles, [:boards, :user])
        items = Enum.map(articles, &wrap_announce_activity(&1, board))
        has_next = page < result.total_pages
        build_collection_page(outbox_uri, items, page, has_next)
    end
  end

  @doc """
  Returns a paginated `OrderedCollection` for the given actor's followers.

  Without `?page`, returns the root collection with `totalItems` and `first` link.
  With `?page=N`, returns an `OrderedCollectionPage` with follower URIs.
  """
  def followers_collection(actor_uri_value, page_params \\ %{}) do
    followers_uri = "#{actor_uri_value}/followers"

    case parse_page(page_params) do
      nil ->
        total = Baudrate.Federation.count_followers(actor_uri_value)
        build_collection_root(followers_uri, total)

      page ->
        offset = (page - 1) * @items_per_page

        follower_uris =
          from(f in Follower,
            where: f.actor_uri == ^actor_uri_value,
            order_by: [desc: f.inserted_at, desc: f.id],
            offset: ^offset,
            limit: ^@items_per_page,
            select: f.follower_uri
          )
          |> Repo.all()

        has_next = length(follower_uris) == @items_per_page
        build_collection_page(followers_uri, follower_uris, page, has_next)
    end
  end

  @doc """
  Returns a paginated `OrderedCollection` for the given actor's following list.

  For user actors, returns accepted outbound follows. For board actors,
  returns accepted board follows (remote actors the board follows).

  Without `?page`, returns the root collection with `totalItems` and `first` link.
  With `?page=N`, returns an `OrderedCollectionPage` with followed actor URIs.
  """
  def following_collection(actor_uri_value, page_params \\ %{}) do
    following_uri = "#{actor_uri_value}/following"
    page = parse_page(page_params)

    case resolve_actor(actor_uri_value) do
      {:user, user} ->
        user_following_collection(following_uri, user, page)

      {:board, board} ->
        board_following_collection(following_uri, board, page)

      :site ->
        %{
          "@context" => @as_context,
          "id" => following_uri,
          "type" => "OrderedCollection",
          "totalItems" => 0,
          "orderedItems" => []
        }
    end
  end

  @doc """
  Returns an `OrderedCollection` of public, AP-enabled boards.
  """
  def boards_collection do
    boards =
      from(b in Board,
        where: b.min_role_to_view == "guest" and b.ap_enabled == true,
        order_by: [asc: b.position, asc: b.name]
      )
      |> Repo.all()

    items =
      Enum.map(boards, fn board ->
        uri = actor_uri(:board, board.slug)

        %{
          "id" => uri,
          "type" => "Group",
          "name" => board.name,
          "summary" => board.description,
          "url" => "#{base_url()}/boards/#{board.slug}"
        }
      end)

    %{
      "@context" => @as_context,
      "id" => "#{base_url()}/ap/boards",
      "type" => "OrderedCollection",
      "totalItems" => length(items),
      "orderedItems" => items
    }
  end

  @doc """
  Returns an `OrderedCollection` of comments (as `Note` objects) for an article.
  """
  def article_replies(article) do
    article = Repo.preload(article, [:user])
    comments = Content.list_comments_for_article(article)
    replies_uri = "#{actor_uri(:article, article.slug)}/replies"

    items =
      Enum.map(comments, fn comment ->
        attributed_to =
          cond do
            comment.user -> actor_uri(:user, comment.user.username)
            comment.remote_actor -> comment.remote_actor.ap_id
            true -> nil
          end

        %{
          "type" => "Note",
          "id" => comment.ap_id || "#{replies_uri}#comment-#{comment.id}",
          "content" => comment.body_html || "",
          "attributedTo" => attributed_to,
          "inReplyTo" => actor_uri(:article, article.slug),
          "published" => DateTime.to_iso8601(comment.inserted_at)
        }
      end)

    %{
      "@context" => @as_context,
      "id" => replies_uri,
      "type" => "OrderedCollection",
      "totalItems" => length(items),
      "orderedItems" => items
    }
  end

  @doc """
  Returns a paginated `OrderedCollection` of search results as Article objects.
  """
  def search_collection(query, page_params) do
    page = parse_page(page_params) || 1
    search_uri = "#{base_url()}/ap/search"

    result = Content.search_articles(query, page: page, per_page: @items_per_page, user: nil)

    items = Enum.map(result.articles, &ObjectBuilder.article_object/1)
    has_next = page < result.total_pages

    if page == 1 and parse_page(page_params) == nil do
      %{
        "@context" => @as_context,
        "id" => "#{search_uri}?q=#{URI.encode_www_form(query)}",
        "type" => "OrderedCollection",
        "totalItems" => result.total,
        "first" => "#{search_uri}?q=#{URI.encode_www_form(query)}&page=1"
      }
    else
      collection_uri = "#{search_uri}?q=#{URI.encode_www_form(query)}"

      %{
        "@context" => @as_context,
        "id" => "#{collection_uri}&page=#{page}",
        "type" => "OrderedCollectionPage",
        "partOf" => collection_uri,
        "totalItems" => result.total,
        "orderedItems" => items
      }
      |> maybe_put("prev", page > 1, "#{collection_uri}&page=#{page - 1}")
      |> maybe_put("next", has_next, "#{collection_uri}&page=#{page + 1}")
    end
  end

  # --- Private ---

  defp wrap_create_activity(article) do
    object = ObjectBuilder.article_object(article)

    %{
      "@context" => @as_context,
      "id" => "#{actor_uri(:article, article.slug)}#create",
      "type" => "Create",
      "actor" => actor_uri(:user, article.user.username),
      "published" => DateTime.to_iso8601(article.inserted_at),
      "to" => [@as_public],
      "object" => object
    }
  end

  defp wrap_announce_activity(article, board) do
    %{
      "@context" => @as_context,
      "id" => "#{actor_uri(:article, article.slug)}#announce",
      "type" => "Announce",
      "actor" => actor_uri(:board, board.slug),
      "published" => DateTime.to_iso8601(article.inserted_at),
      "to" => [@as_public],
      "object" => actor_uri(:article, article.slug)
    }
  end

  defp count_public_user_articles(user_id) do
    from(a in Baudrate.Content.Article,
      join: ba in Baudrate.Content.BoardArticle,
      on: ba.article_id == a.id,
      join: b in Board,
      on: b.id == ba.board_id,
      where: a.user_id == ^user_id and is_nil(a.deleted_at) and b.min_role_to_view == "guest",
      select: count(a.id, :distinct)
    )
    |> Repo.one() || 0
  end

  defp paginate_public_user_articles(user_id, page) do
    offset = (page - 1) * @items_per_page

    from(a in Baudrate.Content.Article,
      join: ba in Baudrate.Content.BoardArticle,
      on: ba.article_id == a.id,
      join: b in Board,
      on: b.id == ba.board_id,
      where: a.user_id == ^user_id and is_nil(a.deleted_at) and b.min_role_to_view == "guest",
      distinct: a.id,
      order_by: [desc: a.inserted_at, desc: a.id],
      offset: ^offset,
      limit: ^@items_per_page,
      preload: [:boards, :user]
    )
    |> Repo.all()
  end

  defp resolve_actor(uri) do
    case extract_user_from_actor_uri(uri) do
      {:ok, user} ->
        {:user, user}

      :error ->
        case extract_board_from_actor_uri(uri) do
          {:ok, board} -> {:board, board}
          :error -> :site
        end
    end
  end

  defp user_following_collection(following_uri, user, nil) do
    total = Baudrate.Federation.count_user_follows(user.id)
    build_collection_root(following_uri, total)
  end

  defp user_following_collection(following_uri, user, page) do
    offset = (page - 1) * @items_per_page

    remote_entries =
      from(uf in UserFollow,
        where:
          uf.user_id == ^user.id and uf.state == @state_accepted and
            not is_nil(uf.remote_actor_id),
        join: ra in assoc(uf, :remote_actor),
        select: %{ap_id: ra.ap_id, inserted_at: uf.inserted_at}
      )
      |> Repo.all()
      |> Enum.map(&{&1.ap_id, &1.inserted_at})

    local_entries =
      from(uf in UserFollow,
        where:
          uf.user_id == ^user.id and uf.state == @state_accepted and
            not is_nil(uf.followed_user_id),
        join: u in assoc(uf, :followed_user),
        select: %{username: u.username, inserted_at: uf.inserted_at}
      )
      |> Repo.all()
      |> Enum.map(&{actor_uri(:user, &1.username), &1.inserted_at})

    followed_uris =
      (remote_entries ++ local_entries)
      |> Enum.sort_by(&elem(&1, 1), {:desc, DateTime})
      |> Enum.drop(offset)
      |> Enum.take(@items_per_page)
      |> Enum.map(&elem(&1, 0))

    has_next = length(followed_uris) == @items_per_page
    build_collection_page(following_uri, followed_uris, page, has_next)
  end

  defp board_following_collection(following_uri, board, nil) do
    total = Baudrate.Federation.count_board_follows(board.id)
    build_collection_root(following_uri, total)
  end

  defp board_following_collection(following_uri, board, page) do
    offset = (page - 1) * @items_per_page

    followed_uris =
      from(bf in BoardFollow,
        where: bf.board_id == ^board.id and bf.state == @state_accepted,
        join: ra in assoc(bf, :remote_actor),
        order_by: [desc: bf.inserted_at, desc: bf.id],
        offset: ^offset,
        limit: ^@items_per_page,
        select: ra.ap_id
      )
      |> Repo.all()

    has_next = length(followed_uris) == @items_per_page
    build_collection_page(following_uri, followed_uris, page, has_next)
  end

  defp extract_user_from_actor_uri(uri) do
    base = base_url()
    prefix = "#{base}/ap/users/"

    if String.starts_with?(uri, prefix) do
      username = String.replace_prefix(uri, prefix, "")
      user = Repo.get_by(Setup.User, username: username)
      if user, do: {:ok, user}, else: :error
    else
      :error
    end
  end

  defp extract_board_from_actor_uri(uri) do
    base = base_url()
    prefix = "#{base}/ap/boards/"

    if String.starts_with?(uri, prefix) do
      slug = String.replace_prefix(uri, prefix, "")
      board = Repo.get_by(Board, slug: slug)

      if board && Board.federated?(board) do
        {:ok, board}
      else
        :error
      end
    else
      :error
    end
  end

  defp build_collection_root(uri, total) do
    %{
      "@context" => @as_context,
      "id" => uri,
      "type" => "OrderedCollection",
      "totalItems" => total,
      "first" => "#{uri}?page=1"
    }
  end

  defp build_collection_page(collection_uri, items, page, has_next) do
    %{
      "@context" => @as_context,
      "id" => "#{collection_uri}?page=#{page}",
      "type" => "OrderedCollectionPage",
      "partOf" => collection_uri,
      "orderedItems" => items
    }
    |> maybe_put("prev", page > 1, "#{collection_uri}?page=#{page - 1}")
    |> maybe_put("next", has_next, "#{collection_uri}?page=#{page + 1}")
  end

  defp maybe_put(map, _key, false, _value), do: map
  defp maybe_put(map, key, true, value), do: Map.put(map, key, value)

  defp parse_page(%{"page" => page}) when is_binary(page) do
    case Integer.parse(page) do
      {n, ""} when n >= 1 -> n
      _ -> nil
    end
  end

  defp parse_page(_), do: nil

  defp actor_uri(type, id), do: Baudrate.Federation.actor_uri(type, id)
  defp base_url, do: Baudrate.Federation.base_url()
end
