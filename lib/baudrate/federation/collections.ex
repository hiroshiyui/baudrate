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

  ## Pages (Phase 8D)

  The root answers `totalItems` and `first: <uri>?page=true`. A page is
  **keyset-paginated by row id**: `?page=true` is the newest page, and `next`
  is `?page=true&max_id=<id>`, the id of the last item shown. A page costs the
  same at any depth, and never skips or repeats a row when the collection
  changes between two requests, which an offset does. Replies read oldest
  first, like the conversation, and continue with `min_id`. A cursor that is
  not a positive integer is ignored (the first page is served).

  The old `?page=N` offset form is still answered, because peers have those
  URLs cached, and its `prev`/`next` stay in that form.

  A page of Articles is built with `ObjectBuilder.article_objects/1`, a fixed
  number of queries for the whole page (`collections_query_count_test.exs`).
  Search keeps its numbered pages: it is ordered by the reader's query, not by
  a row id.
  """

  import Ecto.Query

  alias Baudrate.Content
  alias Baudrate.Content.{Article, Board, BoardArticle}
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Federation.{BoardFollow, Follower, ObjectBuilder, UserFollow}

  @as_context "https://www.w3.org/ns/activitystreams"
  @as_public "https://www.w3.org/ns/activitystreams#Public"
  @state_accepted "accepted"
  @items_per_page 20
  # The largest value a bigint id can take; a larger cursor is not a cursor.
  @max_cursor 9_223_372_036_854_775_807

  @doc """
  Returns a paginated OrderedCollection for a user's outbox.

  Without `?page`, returns the root collection with `totalItems` and `first` link.
  With `?page=true` (or the older `?page=N`), returns an `OrderedCollectionPage`,
  newest first.

  The outbox contains `Create(Article)` activities for the user's published
  articles in federated boards — `min_role_to_view == "guest"` **and**
  `ap_enabled`, the same gate as `Baudrate.Content.Board.federated?/1`. An
  article that lives only in a guest-readable board whose federation the admin
  turned off is not listed here.
  """
  def user_outbox(user, page_params \\ %{})

  # A banned account's outbox is empty, as its actor is bare (ADR 0072).
  def user_outbox(%{status: "banned"} = user, page_params) do
    empty_collection("#{actor_uri(:user, user.username)}/outbox", page_params)
  end

  def user_outbox(user, page_params) do
    outbox_uri = "#{actor_uri(:user, user.username)}/outbox"
    query = public_user_articles_query(user.id)

    case page_mode(page_params, "max_id") do
      nil ->
        build_collection_root(outbox_uri, Repo.one(from(a in query, select: count(a.id))))

      mode ->
        articles =
          from(a in query, order_by: [desc: a.id], limit: ^@items_per_page)
          |> page_where(mode, fn q, max_id -> from(a in q, where: a.id < ^max_id) end)
          |> Repo.all()
          |> Repo.preload([:boards, :user])

        items =
          articles
          |> ObjectBuilder.article_objects()
          |> Enum.zip_with(articles, &wrap_create_activity/2)

        build_page(outbox_uri, mode, items, last_id(articles, & &1.id), "max_id")
    end
  end

  @doc """
  Returns a paginated OrderedCollection for a board's outbox.

  The outbox contains `Announce(Article)` activities for articles posted to
  the board, newest arrival first (`Content.list_board_arrivals/2`).
  """
  def board_outbox(board, page_params \\ %{}) do
    outbox_uri = "#{actor_uri(:board, board.slug)}/outbox"

    case page_mode(page_params, "max_id") do
      nil ->
        result = Content.paginate_articles_for_board(board, page: 1, per_page: 1)
        build_collection_root(outbox_uri, result.total)

      mode ->
        cursor_opts =
          case mode do
            {:keyset, nil} -> []
            {:keyset, max_id} -> [max_id: max_id]
            {:offset, page} -> [offset: (page - 1) * @items_per_page]
          end

        arrivals = Content.list_board_arrivals(board, [limit: @items_per_page] ++ cursor_opts)

        items =
          Enum.map(arrivals, fn {_arrival_id, article} ->
            wrap_announce_activity(article, board)
          end)

        build_page(outbox_uri, mode, items, last_id(arrivals, &elem(&1, 0)), "max_id")
    end
  end

  @doc """
  Returns the site actor's outbox: always empty.

  The instance actor exists to sign outbound fetches and to be discoverable as
  `acct:site@host`; it never posts. The collection is served rather than
  omitted because the actor document advertises it, and an advertised endpoint
  that answers 404 is a document a strict peer is entitled to reject.
  """
  def site_outbox(page_params \\ %{}) do
    empty_collection("#{actor_uri(:site, nil)}/outbox", page_params)
  end

  @doc """
  Returns a paginated `OrderedCollection` for the given actor's followers.

  Without `?page`, returns the root collection with `totalItems` and `first` link.
  With `?page=true` (or `?page=N`), returns an `OrderedCollectionPage` with
  follower URIs, newest first.
  """
  def followers_collection(actor_uri_value, page_params \\ %{}) do
    followers_uri = "#{actor_uri_value}/followers"

    case page_mode(page_params, "max_id") do
      nil ->
        total = Baudrate.Federation.count_followers(actor_uri_value)
        build_collection_root(followers_uri, total)

      mode ->
        rows =
          from(f in Follower,
            where: f.actor_uri == ^actor_uri_value and not is_nil(f.accepted_at),
            order_by: [desc: f.id],
            limit: ^@items_per_page,
            select: {f.id, f.follower_uri}
          )
          |> page_where(mode, fn q, max_id -> from(f in q, where: f.id < ^max_id) end)
          |> Repo.all()

        build_page(
          followers_uri,
          mode,
          Enum.map(rows, &elem(&1, 1)),
          last_id(rows, &elem(&1, 0)),
          "max_id"
        )
    end
  end

  @doc """
  Returns a paginated `OrderedCollection` for the given actor's following list.

  For user actors, returns accepted outbound follows. For board actors,
  returns accepted board follows (remote actors the board follows).

  Without `?page`, returns the root collection with `totalItems` and `first` link.
  With `?page=true` (or `?page=N`), returns an `OrderedCollectionPage` with
  followed actor URIs, newest first.
  """
  def following_collection(actor_uri_value, page_params \\ %{}) do
    following_uri = "#{actor_uri_value}/following"
    mode = page_mode(page_params, "max_id")

    case resolve_actor(actor_uri_value) do
      {:user, user} ->
        user_following_collection(following_uri, user, mode)

      {:board, board} ->
        board_following_collection(following_uri, board, mode)

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

  Paged like the others but oldest first: `?page=true`, then
  `?page=true&min_id=<id>` (`Content.list_replies_page/2`). It used to list
  every comment in one document.
  """
  def article_replies(article, page_params \\ %{}) do
    article = Repo.preload(article, [:user])
    replies_uri = "#{actor_uri(:article, article.slug)}/replies"

    case page_mode(page_params, "min_id") do
      nil ->
        build_collection_root(replies_uri, Content.count_comments_for_article(article))

      {:keyset, min_id} ->
        comments = Content.list_replies_page(article, limit: @items_per_page, min_id: min_id)
        items = Enum.map(comments, &reply_note(&1, article))
        build_page(replies_uri, {:keyset, min_id}, items, last_id(comments, & &1.id), "min_id")

      # No replies URL with `?page=N` was ever published; answer it as the
      # first page rather than inventing an offset form for it.
      {:offset, _page} ->
        article_replies(article, %{"page" => "true"})
    end
  end

  defp reply_note(comment, article) do
    attributed_to =
      cond do
        comment.user -> actor_uri(:user, comment.user.username)
        comment.remote_actor -> comment.remote_actor.ap_id
        true -> nil
      end

    %{
      "type" => "Note",
      # A local comment's fallback is its own canonical URI, never a
      # fragment of this collection's (ADR 0050) — a peer that follows the
      # id has to arrive at the Note.
      "id" => comment.ap_id || local_comment_uri(comment),
      "content" => comment.body_html || "",
      "attributedTo" => attributed_to,
      "inReplyTo" => ObjectBuilder.reply_target_uri(comment, article),
      "published" => DateTime.to_iso8601(comment.inserted_at)
    }
  end

  defp local_comment_uri(%{remote_actor_id: nil, id: id}),
    do: actor_uri(:comment, id)

  defp local_comment_uri(_comment), do: nil

  @doc """
  Returns a paginated `OrderedCollection` of search results as Article objects.
  """
  def search_collection(query, page_params) do
    page = parse_page(page_params) || 1
    search_uri = "#{base_url()}/ap/search"

    # `federated_only: true` is the outbound board gate: this collection is
    # unauthenticated and each item is a full Article object addressed
    # `as:Public`, so `ap_enabled` is required as well as guest-readability —
    # the same predicate `publicly_servable?/1` applies to a permalink.
    #
    # `sort: :newest` is pinned rather than inherited: an `OrderedCollection`
    # is reverse-chronological by contract, and a crawler walking these pages
    # must not have them reshuffle because the site's own default moved.
    result =
      Content.search_articles(query,
        page: page,
        per_page: @items_per_page,
        user: nil,
        federated_only: true,
        sort: :newest
      )

    items = ObjectBuilder.article_objects(result.articles)
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

  defp wrap_create_activity(object, article) do
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

  # A user's articles in at least one federated board: `ap_enabled` as well
  # as `min_role_to_view`, the documented federation gate. The board test is
  # an `exists`, not a join with `distinct`: Ecto compiles `distinct: a.id` to
  # `DISTINCT ON (a.id)` and puts `a.id` first in the `ORDER BY`, which
  # silently replaced the requested order — the outbox was oldest first. The
  # count and the pages share this query, so they cannot disagree.
  defp public_user_articles_query(user_id) do
    federated_board =
      from(ba in BoardArticle,
        join: b in Board,
        on: b.id == ba.board_id,
        where:
          ba.article_id == parent_as(:article).id and b.min_role_to_view == "guest" and
            b.ap_enabled,
        select: 1
      )

    from(a in Article,
      as: :article,
      where: a.user_id == ^user_id and is_nil(a.deleted_at) and exists(subquery(federated_board))
    )
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

  # One query over both kinds of follow, newest first. It used to load every
  # accepted follow the user had, remote and local, and page them in memory.
  defp user_following_collection(following_uri, user, mode) do
    rows =
      from(uf in UserFollow,
        left_join: ra in assoc(uf, :remote_actor),
        left_join: u in assoc(uf, :followed_user),
        where:
          uf.user_id == ^user.id and uf.state == @state_accepted and
            (not is_nil(ra.id) or not is_nil(u.id)),
        order_by: [desc: uf.id],
        limit: ^@items_per_page,
        select: {uf.id, ra.ap_id, u.username}
      )
      |> page_where(mode, fn q, max_id -> from(uf in q, where: uf.id < ^max_id) end)
      |> Repo.all()

    uris =
      Enum.map(rows, fn
        {_id, ap_id, _username} when is_binary(ap_id) -> ap_id
        {_id, nil, username} -> actor_uri(:user, username)
      end)

    build_page(following_uri, mode, uris, last_id(rows, &elem(&1, 0)), "max_id")
  end

  defp board_following_collection(following_uri, board, nil) do
    total = Baudrate.Federation.count_board_follows(board.id)
    build_collection_root(following_uri, total)
  end

  defp board_following_collection(following_uri, board, mode) do
    rows =
      from(bf in BoardFollow,
        where: bf.board_id == ^board.id and bf.state == @state_accepted,
        join: ra in assoc(bf, :remote_actor),
        order_by: [desc: bf.id],
        limit: ^@items_per_page,
        select: {bf.id, ra.ap_id}
      )
      |> page_where(mode, fn q, max_id -> from(bf in q, where: bf.id < ^max_id) end)
      |> Repo.all()

    build_page(
      following_uri,
      mode,
      Enum.map(rows, &elem(&1, 1)),
      last_id(rows, &elem(&1, 0)),
      "max_id"
    )
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

  defp empty_collection(uri, page_params) do
    case page_mode(page_params, "max_id") do
      nil -> build_collection_root(uri, 0)
      mode -> build_page(uri, mode, [], nil, "max_id")
    end
  end

  defp build_collection_root(uri, total) do
    %{
      "@context" => @as_context,
      "id" => uri,
      "type" => "OrderedCollection",
      "totalItems" => total,
      "first" => "#{uri}?page=true"
    }
  end

  # A page in the form it was asked for. A keyset page links `next` by the
  # last item's id, and only when the page is full; an offset page keeps the
  # `?page=N` links it was reached by.
  defp build_page(collection_uri, {:keyset, cursor}, items, last, cursor_key) do
    id =
      case cursor do
        nil -> "#{collection_uri}?page=true"
        cursor -> "#{collection_uri}?page=true&#{cursor_key}=#{cursor}"
      end

    %{
      "@context" => @as_context,
      "id" => id,
      "type" => "OrderedCollectionPage",
      "partOf" => collection_uri,
      "orderedItems" => items
    }
    |> maybe_put(
      "next",
      length(items) == @items_per_page and last != nil,
      "#{collection_uri}?page=true&#{cursor_key}=#{last}"
    )
  end

  defp build_page(collection_uri, {:offset, page}, items, _last, _cursor_key) do
    %{
      "@context" => @as_context,
      "id" => "#{collection_uri}?page=#{page}",
      "type" => "OrderedCollectionPage",
      "partOf" => collection_uri,
      "orderedItems" => items
    }
    |> maybe_put("prev", page > 1, "#{collection_uri}?page=#{page - 1}")
    |> maybe_put("next", length(items) == @items_per_page, "#{collection_uri}?page=#{page + 1}")
  end

  defp maybe_put(map, _key, false, _value), do: map
  defp maybe_put(map, key, true, value), do: Map.put(map, key, value)

  # Which page was asked for: `nil` (the collection root), `{:keyset,
  # cursor | nil}` for `?page=true`, or `{:offset, n}` for the older
  # `?page=N`.
  defp page_mode(%{"page" => "true"} = params, cursor_key),
    do: {:keyset, parse_cursor(params[cursor_key])}

  defp page_mode(params, _cursor_key) do
    case parse_page(params) do
      nil -> nil
      page -> {:offset, page}
    end
  end

  defp parse_cursor(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 1 and n <= @max_cursor -> n
      _ -> nil
    end
  end

  defp parse_cursor(_), do: nil

  # Narrows a page query to its cursor, or offsets it for `?page=N`.
  defp page_where(query, {:keyset, nil}, _narrow), do: query
  defp page_where(query, {:keyset, cursor}, narrow), do: narrow.(query, cursor)

  defp page_where(query, {:offset, page}, _narrow),
    do: from(q in query, offset: ^((page - 1) * @items_per_page))

  defp last_id([], _id_of), do: nil
  defp last_id(rows, id_of), do: rows |> List.last() |> id_of.()

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
