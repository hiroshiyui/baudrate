defmodule Baudrate.Federation do
  @moduledoc """
  The Federation context provides ActivityPub endpoints, follower management,
  announce (boost) tracking, and followers collection.

  Phase 1 exposes actors, outbox collections, and article objects as
  JSON-LD, along with WebFinger and NodeInfo discovery endpoints.

  Phase 2a adds inbox endpoints, HTTP Signature verification, remote actor
  resolution, and Follow/Undo(Follow) handling with auto-accept.

  Phase 2b adds content activity handling: Create(Note/Article), Like,
  Announce, Delete, Update, and their Undo variants.

  Phase 3 adds outbound delivery: when local users create, update, or
  delete articles, activities are pushed to remote followers' inboxes
  via a DB-backed delivery queue with exponential backoff retry.

  Phase 4a adds Mastodon/Lemmy compatibility: Lemmy `Page` objects are
  treated as `Article`, `Announce` with embedded object maps is supported,
  `attributedTo` arrays are handled, `sensitive`/`summary` content warnings
  are preserved, `<span>` tags with safe classes are allowed through the
  sanitizer, and outbound Note/Article objects include `to`/`cc` addressing.

  Phase 4b completes Mastodon/Lemmy interop: outbound Article objects include
  a plain-text `summary` (≤ 500 chars) for Mastodon preview display and a
  `tag` array with `Hashtag` objects extracted from the article body (code
  blocks excluded). Cross-post deduplication links a remote article to
  additional boards when the same `ap_id` arrives via multiple board inboxes.

  Phase 5 — Public API: the AP endpoints serve as the public API. Accepts
  `application/json` in addition to AP media types, CORS enabled on all GET
  endpoints, `Vary: Accept` on content-negotiated endpoints. Outbox and
  followers collections are paginated via `?page=N` (20 items/page,
  `OrderedCollectionPage`). New endpoints: boards index (`/ap/boards`),
  article replies (`/ap/articles/:slug/replies`), search (`/ap/search?q=`).
  Article objects enriched with `replies`, `baudrate:pinned`, `baudrate:locked`,
  `baudrate:commentCount`, `baudrate:likeCount`. User actors include
  `published`, `summary` (signature), and `icon` (avatar). Board actors
  include `baudrate:parentBoard` and `baudrate:subBoards`.

  Private boards are excluded from all federation endpoints — WebFinger,
  actor profiles, outbox, inbox, followers, and audience resolution all
  return 404 or skip private boards. Articles exclusively in private
  boards are also hidden from user outbox and article endpoints.

  ## Actor Mapping

    * `User` → `Person`
    * `Board` → `Group`
    * Site → `Organization`
    * `Article` → `Article`

  ## URI Scheme

    * `/ap/users/:username` — user actor
    * `/ap/boards/:slug` — board actor
    * `/ap/boards` — boards index
    * `/ap/site` — site actor
    * `/ap/articles/:slug` — article object
    * `/ap/articles/:slug/replies` — article replies
    * `/ap/search?q=...` — search
    * `/ap/inbox` — shared inbox (POST)
    * `/ap/users/:username/inbox` — user inbox (POST)
    * `/ap/boards/:slug/inbox` — board inbox (POST)
    * `/ap/users/:username/outbox` — user outbox (GET, paginated)
    * `/ap/boards/:slug/outbox` — board outbox (GET, paginated)
    * `/ap/users/:username/followers` — user followers (GET, paginated)
    * `/ap/boards/:slug/followers` — board followers (GET, paginated)
  """

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Content
  alias Baudrate.Content.Markdown
  alias Baudrate.Federation.{Announce, Follower, KeyStore}

  @as_context "https://www.w3.org/ns/activitystreams"
  @security_context "https://w3id.org/security/v1"
  @as_public "https://www.w3.org/ns/activitystreams#Public"

  @doc """
  Returns the base URL from the endpoint configuration.
  """
  def base_url do
    BaudrateWeb.Endpoint.url()
  end

  @doc """
  Builds an actor URI for the given type and identifier.

  ## Examples

      iex> actor_uri(:user, "alice")
      "https://example.com/ap/users/alice"

      iex> actor_uri(:board, "sysop")
      "https://example.com/ap/boards/sysop"

      iex> actor_uri(:site, nil)
      "https://example.com/ap/site"
  """
  def actor_uri(:user, username), do: "#{base_url()}/ap/users/#{username}"
  def actor_uri(:board, slug), do: "#{base_url()}/ap/boards/#{slug}"
  def actor_uri(:site, _), do: "#{base_url()}/ap/site"
  def actor_uri(:article, slug), do: "#{base_url()}/ap/articles/#{slug}"

  # --- WebFinger ---

  @doc """
  Resolves a WebFinger resource string and returns a JRD map.

  Supports:
    * `acct:username@host` → user actor
    * `acct:!slug@host` → board actor (Lemmy-compatible)

  Returns `{:ok, jrd_map}` or `{:error, reason}`.
  """
  def webfinger(resource) when is_binary(resource) do
    host = URI.parse(base_url()).host

    with {:ok, type, identifier} <- parse_acct(resource, host) do
      case type do
        :user ->
          user = Repo.get_by(Baudrate.Setup.User, username: identifier)
          if user, do: {:ok, webfinger_jrd(:user, identifier)}, else: {:error, :not_found}

        :board ->
          board = Repo.get_by(Baudrate.Content.Board, slug: identifier)

          if board && board.min_role_to_view == "guest",
            do: {:ok, webfinger_jrd(:board, identifier)},
            else: {:error, :not_found}
      end
    end
  end

  defp parse_acct(resource, host) do
    case Regex.run(~r/\Aacct:(!?)([^@]+)@(.+)\z/, resource) do
      [_, "!", slug, ^host] ->
        if Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug) do
          {:ok, :board, slug}
        else
          {:error, :invalid_resource}
        end

      [_, "", username, ^host] ->
        if Regex.match?(~r/\A[a-zA-Z0-9_]+\z/, username) do
          {:ok, :user, username}
        else
          {:error, :invalid_resource}
        end

      _ ->
        {:error, :invalid_resource}
    end
  end

  defp webfinger_jrd(type, identifier) do
    uri = actor_uri(type, identifier)

    %{
      "subject" =>
        case type do
          :user -> "acct:#{identifier}@#{URI.parse(base_url()).host}"
          :board -> "acct:!#{identifier}@#{URI.parse(base_url()).host}"
        end,
      "aliases" => [uri],
      "links" => [
        %{
          "rel" => "self",
          "type" => "application/activity+json",
          "href" => uri
        }
      ]
    }
  end

  # --- NodeInfo ---

  @doc """
  Returns the well-known nodeinfo links document.
  """
  def nodeinfo_links do
    %{
      "links" => [
        %{
          "rel" => "http://nodeinfo.diaspora.software/ns/schema/2.1",
          "href" => "#{base_url()}/nodeinfo/2.1"
        }
      ]
    }
  end

  @doc """
  Returns the NodeInfo 2.1 response map with usage stats.
  """
  def nodeinfo do
    user_count = Repo.one(from u in Baudrate.Setup.User, select: count(u.id)) || 0
    article_count = Repo.one(from a in Baudrate.Content.Article, select: count(a.id)) || 0

    %{
      "version" => "2.1",
      "software" => %{
        "name" => "baudrate",
        "version" => Application.spec(:baudrate, :vsn) |> to_string(),
        "repository" => "https://github.com/baudrate-forum/baudrate"
      },
      "protocols" => ["activitypub"],
      "services" => %{"inbound" => [], "outbound" => []},
      "openRegistrations" => Setup.registration_mode() == "open",
      "usage" => %{
        "users" => %{"total" => user_count},
        "localPosts" => article_count
      },
      "metadata" => %{
        "nodeName" => Setup.get_setting("site_name") || "Baudrate"
      }
    }
  end

  # --- Actor Endpoints ---

  @doc """
  Returns a Person JSON-LD map for the given user.
  """
  def user_actor(user) do
    uri = actor_uri(:user, user.username)

    %{
      "@context" => [@as_context, @security_context],
      "id" => uri,
      "type" => "Person",
      "preferredUsername" => user.username,
      "inbox" => "#{uri}/inbox",
      "outbox" => "#{uri}/outbox",
      "followers" => "#{uri}/followers",
      "url" => "#{base_url()}/@#{user.username}",
      "published" => DateTime.to_iso8601(user.inserted_at),
      "endpoints" => %{"sharedInbox" => "#{base_url()}/ap/inbox"},
      "publicKey" => %{
        "id" => "#{uri}#main-key",
        "owner" => uri,
        "publicKeyPem" => KeyStore.get_public_key_pem(user)
      }
    }
    |> put_if("summary", user.signature)
    |> put_if("icon", user_avatar_icon(user))
  end

  defp user_avatar_icon(%{avatar_id: nil}), do: nil

  defp user_avatar_icon(%{avatar_id: avatar_id}) do
    %{
      "type" => "Image",
      "mediaType" => "image/webp",
      "url" => "#{base_url()}#{Baudrate.Avatar.avatar_url(avatar_id, "medium")}"
    }
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, ""), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  @doc """
  Returns a Group JSON-LD map for the given board.
  """
  def board_actor(board) do
    uri = actor_uri(:board, board.slug)
    board = Repo.preload(board, [])

    sub_boards =
      Content.list_sub_boards(board)
      |> Enum.filter(&(&1.min_role_to_view == "guest" and &1.ap_enabled))
      |> Enum.map(&actor_uri(:board, &1.slug))

    parent_uri =
      if board.parent_id do
        parent = Repo.get(Baudrate.Content.Board, board.parent_id)

        if parent && parent.min_role_to_view == "guest" && parent.ap_enabled,
          do: actor_uri(:board, parent.slug)
      end

    %{
      "@context" => [@as_context, @security_context],
      "id" => uri,
      "type" => "Group",
      "preferredUsername" => board.slug,
      "name" => board.name,
      "summary" => board.description,
      "inbox" => "#{uri}/inbox",
      "outbox" => "#{uri}/outbox",
      "followers" => "#{uri}/followers",
      "url" => "#{base_url()}/boards/#{board.slug}",
      "endpoints" => %{"sharedInbox" => "#{base_url()}/ap/inbox"},
      "publicKey" => %{
        "id" => "#{uri}#main-key",
        "owner" => uri,
        "publicKeyPem" => KeyStore.get_public_key_pem(board)
      }
    }
    |> put_if("baudrate:parentBoard", parent_uri)
    |> put_if("baudrate:subBoards", if(sub_boards != [], do: sub_boards))
  end

  @doc """
  Returns an Organization JSON-LD map for the site actor.
  """
  def site_actor do
    uri = actor_uri(:site, nil)
    site_name = Setup.get_setting("site_name") || "Baudrate"

    {:ok, %{public_pem: public_pem}} = KeyStore.ensure_site_keypair()

    %{
      "@context" => [@as_context, @security_context],
      "id" => uri,
      "type" => "Organization",
      "preferredUsername" => "site",
      "name" => site_name,
      "inbox" => "#{uri}/inbox",
      "outbox" => "#{uri}/outbox",
      "url" => base_url(),
      "publicKey" => %{
        "id" => "#{uri}#main-key",
        "owner" => uri,
        "publicKeyPem" => public_pem
      }
    }
  end

  @items_per_page 20

  # --- Outbox ---

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

  defp wrap_create_activity(article) do
    object = article_object(article)

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
      join: b in Baudrate.Content.Board,
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
      join: b in Baudrate.Content.Board,
      on: b.id == ba.board_id,
      where: a.user_id == ^user_id and is_nil(a.deleted_at) and b.min_role_to_view == "guest",
      distinct: a.id,
      order_by: [desc: a.inserted_at],
      offset: ^offset,
      limit: ^@items_per_page,
      preload: [:boards, :user]
    )
    |> Repo.all()
  end

  # --- Followers Collection ---

  @doc """
  Returns a paginated `OrderedCollection` for the given actor's followers.

  Without `?page`, returns the root collection with `totalItems` and `first` link.
  With `?page=N`, returns an `OrderedCollectionPage` with follower URIs.
  """
  def followers_collection(actor_uri, page_params \\ %{}) do
    followers_uri = "#{actor_uri}/followers"

    case parse_page(page_params) do
      nil ->
        total = count_followers(actor_uri)
        build_collection_root(followers_uri, total)

      page ->
        offset = (page - 1) * @items_per_page

        follower_uris =
          from(f in Follower,
            where: f.actor_uri == ^actor_uri,
            order_by: [desc: f.inserted_at],
            offset: ^offset,
            limit: ^@items_per_page,
            select: f.follower_uri
          )
          |> Repo.all()

        has_next = length(follower_uris) == @items_per_page
        build_collection_page(followers_uri, follower_uris, page, has_next)
    end
  end

  # --- Pagination Helpers ---

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

  # --- Boards Collection ---

  @doc """
  Returns an `OrderedCollection` of public, AP-enabled boards.
  """
  def boards_collection do
    boards =
      from(b in Baudrate.Content.Board,
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

  # --- Article Replies Collection ---

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

  # --- Search Collection ---

  @doc """
  Returns a paginated `OrderedCollection` of search results as Article objects.
  """
  def search_collection(query, page_params) do
    page = parse_page(page_params) || 1
    search_uri = "#{base_url()}/ap/search"

    result = Content.search_articles(query, page: page, per_page: @items_per_page, user: nil)

    items = Enum.map(result.articles, &article_object/1)
    has_next = page < result.total_pages

    if page == 1 and parse_page(page_params) == nil do
      # Root collection with first page inline
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

  # --- Followers ---

  @doc """
  Creates a follower record for a remote actor following a local actor.
  """
  def create_follower(actor_uri, remote_actor, activity_id) do
    %Follower{}
    |> Follower.changeset(%{
      actor_uri: actor_uri,
      follower_uri: remote_actor.ap_id,
      remote_actor_id: remote_actor.id,
      activity_id: activity_id,
      accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert()
  end

  @doc """
  Deletes a follower record matching the given actor and follower URIs.
  """
  def delete_follower(actor_uri, follower_uri) do
    from(f in Follower,
      where: f.actor_uri == ^actor_uri and f.follower_uri == ^follower_uri
    )
    |> Repo.delete_all()
  end

  @doc """
  Deletes all follower records where the remote actor matches the given AP ID.
  Used when a remote actor is deleted.
  """
  def delete_followers_by_remote(remote_actor_ap_id) do
    from(f in Follower, where: f.follower_uri == ^remote_actor_ap_id)
    |> Repo.delete_all()
  end

  @doc """
  Returns true if the given follower relationship exists.
  """
  def follower_exists?(actor_uri, follower_uri) do
    Repo.exists?(
      from(f in Follower,
        where: f.actor_uri == ^actor_uri and f.follower_uri == ^follower_uri
      )
    )
  end

  @doc """
  Lists all followers of the given local actor URI.
  """
  def list_followers(actor_uri) do
    from(f in Follower,
      where: f.actor_uri == ^actor_uri,
      preload: [:remote_actor],
      order_by: [desc: f.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Returns the count of followers for the given local actor URI.
  """
  def count_followers(actor_uri) do
    Repo.one(from(f in Follower, where: f.actor_uri == ^actor_uri, select: count(f.id))) || 0
  end

  # --- Article Object ---

  @doc """
  Returns an Article JSON-LD map for the given article.
  """
  def article_object(article) do
    article = Repo.preload(article, [:boards, :user])

    board_uris =
      Enum.map(article.boards, fn board ->
        actor_uri(:board, board.slug)
      end)

    tags = extract_hashtags(article.body)

    map = %{
      "@context" => @as_context,
      "id" => actor_uri(:article, article.slug),
      "type" => "Article",
      "name" => article.title,
      "summary" => build_article_summary(article.body),
      "content" => Markdown.to_html(article.body),
      "mediaType" => "text/html",
      "source" => %{
        "content" => article.body || "",
        "mediaType" => "text/markdown"
      },
      "attributedTo" => actor_uri(:user, article.user.username),
      "published" => DateTime.to_iso8601(article.inserted_at),
      "updated" => DateTime.to_iso8601(article.updated_at),
      "to" => [@as_public],
      "cc" => board_uris,
      "audience" => board_uris,
      "url" => "#{base_url()}/articles/#{article.slug}",
      "replies" => "#{actor_uri(:article, article.slug)}/replies",
      "baudrate:pinned" => article.pinned,
      "baudrate:locked" => article.locked,
      "baudrate:commentCount" => Content.count_comments_for_article(article),
      "baudrate:likeCount" => Content.count_article_likes(article)
    }

    if tags == [], do: map, else: Map.put(map, "tag", tags)
  end

  # --- Article summary/tag helpers ---

  defp build_article_summary(nil), do: ""

  defp build_article_summary(body) do
    body
    |> strip_markdown()
    |> truncate_text(500)
  end

  defp strip_markdown(text) do
    text
    |> String.replace(~r/```[\s\S]*?```/u, "")
    |> String.replace(~r/`[^`]+`/, "")
    |> String.replace(~r/!\[[^\]]*\]\([^)]*\)/, "")
    |> String.replace(~r/\[[^\]]*\]\([^)]*\)/, fn m ->
      case Regex.run(~r/\[([^\]]*)\]/, m) do
        [_, text] -> text
        _ -> m
      end
    end)
    |> String.replace(~r/^\#{1,6}\s+/m, "")
    |> String.replace(~r/[*_~]{1,3}/, "")
    |> String.replace(~r/^>\s?/m, "")
    |> String.replace(~r/^[-*+]\s/m, "")
    |> String.replace(~r/^\d+\.\s/m, "")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp truncate_text(text, max_length) do
    if String.length(text) <= max_length do
      text
    else
      text
      |> String.slice(0, max_length)
      |> String.replace(~r/\s\S*$/, "")
      |> Kernel.<>("…")
    end
  end

  defp extract_hashtags(nil), do: []

  defp extract_hashtags(body) do
    cleaned =
      body
      |> String.replace(~r/```[\s\S]*?```/u, "")
      |> String.replace(~r/`[^`]+`/, "")

    Regex.scan(~r/(?:^|[^&\w])#([a-zA-Z]\w{0,63})/u, cleaned, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.map(fn tag ->
      %{
        "type" => "Hashtag",
        "name" => "##{tag}",
        "href" => "#{base_url()}/tags/#{String.downcase(tag)}"
      }
    end)
  end

  # --- Announces ---

  @doc """
  Creates an announce (boost) record for a remote actor.
  """
  def create_announce(attrs) do
    %Announce{}
    |> Announce.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Deletes an announce record by its ActivityPub ID.
  """
  def delete_announce_by_ap_id(ap_id) when is_binary(ap_id) do
    from(a in Announce, where: a.ap_id == ^ap_id)
    |> Repo.delete_all()
  end

  @doc """
  Returns the count of announces for the given target AP ID.
  """
  def count_announces(target_ap_id) when is_binary(target_ap_id) do
    Repo.one(
      from(a in Announce, where: a.target_ap_id == ^target_ap_id, select: count(a.id))
    ) || 0
  end

  # --- Board Resolution ---

  @doc """
  Resolves a local board from audience/to/cc fields in an ActivityPub object.

  Scans the list of URIs for one matching the local board actor pattern
  `/ap/boards/:slug` and returns the board if found.
  """
  def resolve_board_from_audience(uris) when is_list(uris) do
    board_prefix = "#{base_url()}/ap/boards/"

    uris
    |> List.flatten()
    |> Enum.find_value(fn uri ->
      case uri do
        <<^board_prefix::binary, slug::binary>> ->
          if Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug) do
            board = Repo.get_by(Baudrate.Content.Board, slug: slug)
            if board && board.min_role_to_view == "guest" && board.ap_enabled, do: board
          end

        _ ->
          nil
      end
    end)
  end

  def resolve_board_from_audience(_), do: nil
end
