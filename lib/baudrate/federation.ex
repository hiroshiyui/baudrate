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

  Phase 6 — User-level outbound follows: local users can follow remote
  actors via `Follow` / `Undo(Follow)` activities. `Accept(Follow)` and
  `Reject(Follow)` responses update follow state. Following collection
  endpoint populated with accepted follows. WebFinger client for remote
  actor discovery.

  Phase 7 — Personal feed: incoming `Create` activities from followed
  remote actors that don't land in a local board, comment thread, or DM
  are stored as `FeedItem` records. One row per activity (keyed by `ap_id`),
  visibility determined at query time via JOIN with `user_follows`. `Move`
  activity handling migrates follows to the new actor. `Delete` propagation
  soft-deletes feed items.

  Phase 8 — Local user follows: users can follow other local users via
  the same `user_follows` table (using `followed_user_id` instead of
  `remote_actor_id`). Local follows auto-accept immediately with no AP
  delivery. The personal feed shows articles from both remote actors and
  locally-followed users. Following collection includes local follow URIs.

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
    * `/ap/users/:username/following` — user following (GET, always empty)
    * `/ap/boards/:slug/followers` — board followers (GET, paginated)
    * `/ap/boards/:slug/following` — board following (GET, paginated)
  """

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Content
  alias Baudrate.Content.Markdown
  alias Baudrate.Auth

  alias Baudrate.Federation.{
    Announce,
    BoardFollow,
    FeedItem,
    Follower,
    KeyStore,
    Publisher,
    RemoteActor,
    UserFollow
  }

  alias Baudrate.Federation.PubSub, as: FederationPubSub

  @as_context "https://www.w3.org/ns/activitystreams"
  @security_context "https://w3id.org/security/v1"
  @as_public "https://www.w3.org/ns/activitystreams#Public"

  @state_accepted "accepted"
  @state_pending "pending"
  @state_rejected "rejected"

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

  # --- Remote Actor Lookup ---

  @doc """
  Looks up a remote actor by `@user@domain` handle or actor URL.

  For `@user@domain` handles, performs a WebFinger lookup to discover the
  actor's AP ID, then resolves via `ActorResolver`. For direct actor URLs,
  resolves directly.

  Returns `{:ok, %RemoteActor{}}` or `{:error, reason}`.
  """
  def lookup_remote_actor("@" <> rest) do
    lookup_remote_actor(rest)
  end

  def lookup_remote_actor(query) when is_binary(query) do
    cond do
      # Handle @user@domain format
      String.contains?(query, "@") && !String.contains?(query, "/") ->
        case String.split(query, "@", parts: 2) do
          [user, domain] when user != "" and domain != "" ->
            webfinger_lookup(user, domain)

          _ ->
            {:error, :invalid_query}
        end

      # Handle direct actor URL
      String.starts_with?(query, "https://") ->
        alias Baudrate.Federation.ActorResolver
        ActorResolver.resolve(query)

      true ->
        {:error, :invalid_query}
    end
  end

  defp webfinger_lookup(user, domain) do
    alias Baudrate.Federation.{ActorResolver, HTTPClient}

    resource = "acct:#{user}@#{domain}"
    url = "https://#{domain}/.well-known/webfinger?resource=#{URI.encode_www_form(resource)}"

    case HTTPClient.get(url, headers: [{"accept", "application/jrd+json"}]) do
      {:ok, %{body: body}} ->
        with {:ok, jrd} <- Jason.decode(body),
             {:ok, actor_url} <- extract_self_link(jrd) do
          ActorResolver.resolve(actor_url)
        end

      {:error, reason} ->
        {:error, {:webfinger_failed, reason}}
    end
  end

  defp extract_self_link(%{"links" => links}) when is_list(links) do
    ap_link =
      Enum.find(links, fn link ->
        link["rel"] == "self" &&
          link["type"] in [
            "application/activity+json",
            "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""
          ]
      end)

    case ap_link do
      %{"href" => href} when is_binary(href) and href != "" -> {:ok, href}
      _ -> {:error, :no_self_link}
    end
  end

  defp extract_self_link(_), do: {:error, :invalid_jrd}

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
      "following" => "#{uri}/following",
      "url" => "#{base_url()}/@#{user.username}",
      "published" => DateTime.to_iso8601(user.inserted_at),
      "endpoints" => %{"sharedInbox" => "#{base_url()}/ap/inbox"},
      "publicKey" => %{
        "id" => "#{uri}#main-key",
        "owner" => uri,
        "publicKeyPem" => KeyStore.get_public_key_pem(user)
      }
    }
    |> put_if("name", user.display_name)
    |> put_if("summary", render_bio_html(user.bio))
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

  @doc false
  def render_bio_html(nil), do: nil
  def render_bio_html(""), do: nil

  def render_bio_html(bio) when is_binary(bio) do
    bio
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace("\n", "<br>")
    |> Baudrate.Content.Markdown.linkify_hashtags()
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, ""), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  @doc """
  Returns a Group JSON-LD map for the given board.
  """
  def board_actor(board) do
    uri = actor_uri(:board, board.slug)

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
      "following" => "#{uri}/following",
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
      "followers" => "#{uri}/followers",
      "url" => base_url(),
      "endpoints" => %{"sharedInbox" => "#{base_url()}/ap/inbox"},
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

  # --- Following Collection ---

  @doc """
  Returns a paginated `OrderedCollection` for the given actor's following list.

  For user actors, returns accepted outbound follows. For board actors,
  returns accepted board follows (remote actors the board follows).

  Without `?page`, returns the root collection with `totalItems` and `first` link.
  With `?page=N`, returns an `OrderedCollectionPage` with followed actor URIs.
  """
  def following_collection(actor_uri, page_params \\ %{}) do
    following_uri = "#{actor_uri}/following"
    page = parse_page(page_params)

    case resolve_actor(actor_uri) do
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
    total = count_user_follows(user.id)
    build_collection_root(following_uri, total)
  end

  defp user_following_collection(following_uri, user, page) do
    offset = (page - 1) * @items_per_page

    # Remote follows: use remote_actor.ap_id
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

    # Local follows: build actor_uri from followed user's username
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
    total = count_board_follows(board.id)
    build_collection_root(following_uri, total)
  end

  defp board_following_collection(following_uri, board, page) do
    offset = (page - 1) * @items_per_page

    followed_uris =
      from(bf in BoardFollow,
        where: bf.board_id == ^board.id and bf.state == @state_accepted,
        join: ra in assoc(bf, :remote_actor),
        order_by: [desc: bf.inserted_at],
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
      board = Repo.get_by(Content.Board, slug: slug)

      if board && board.ap_enabled && board.min_role_to_view == "guest" do
        {:ok, board}
      else
        :error
      end
    else
      :error
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

  # --- User Follows (Outbound) ---

  @doc """
  Creates a user follow record and returns the generated Follow AP ID.

  Inserts a `UserFollow` with state `"pending"`. The caller is responsible
  for building and delivering the Follow activity using the returned AP ID.

  Returns `{:ok, %UserFollow{}}` or `{:error, changeset}`.
  """
  def create_user_follow(user, remote_actor) do
    ap_id = "#{actor_uri(:user, user.username)}#follow-#{System.unique_integer([:positive])}"

    %UserFollow{}
    |> UserFollow.changeset(%{
      user_id: user.id,
      remote_actor_id: remote_actor.id,
      state: @state_pending,
      ap_id: ap_id
    })
    |> Repo.insert()
  end

  @doc """
  Marks an outbound follow as accepted by matching the Follow activity's AP ID.

  Called when an `Accept(Follow)` activity is received from the remote actor.
  Returns `{:ok, %UserFollow{}}` or `{:error, :not_found}`.
  """
  def accept_user_follow(follow_ap_id) when is_binary(follow_ap_id) do
    case Repo.one(from(uf in UserFollow, where: uf.ap_id == ^follow_ap_id)) do
      nil ->
        {:error, :not_found}

      %UserFollow{} = follow ->
        follow
        |> UserFollow.changeset(%{
          state: @state_accepted,
          accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()
    end
  end

  @doc """
  Marks an outbound follow as rejected by matching the Follow activity's AP ID.

  Called when a `Reject(Follow)` activity is received from the remote actor.
  Returns `{:ok, %UserFollow{}}` or `{:error, :not_found}`.
  """
  def reject_user_follow(follow_ap_id) when is_binary(follow_ap_id) do
    case Repo.one(from(uf in UserFollow, where: uf.ap_id == ^follow_ap_id)) do
      nil ->
        {:error, :not_found}

      %UserFollow{} = follow ->
        follow
        |> UserFollow.changeset(%{
          state: @state_rejected,
          rejected_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()
    end
  end

  @doc """
  Deletes a user follow record (for unfollow).

  Returns `{:ok, %UserFollow{}}` or `{:error, :not_found}`.
  """
  def delete_user_follow(user, remote_actor) do
    case Repo.one(
           from(uf in UserFollow,
             where: uf.user_id == ^user.id and uf.remote_actor_id == ^remote_actor.id
           )
         ) do
      nil -> {:error, :not_found}
      %UserFollow{} = follow -> Repo.delete(follow)
    end
  end

  @doc """
  Returns the user follow record for the given user and remote actor pair, or nil.
  """
  def get_user_follow(user_id, remote_actor_id) do
    Repo.one(
      from(uf in UserFollow,
        where: uf.user_id == ^user_id and uf.remote_actor_id == ^remote_actor_id
      )
    )
  end

  @doc """
  Returns the user follow record matching the given Follow activity AP ID, or nil.
  """
  def get_user_follow_by_ap_id(ap_id) do
    Repo.one(from(uf in UserFollow, where: uf.ap_id == ^ap_id))
  end

  @doc """
  Returns true if a follow record exists for the user/remote_actor pair (any state).
  """
  def user_follows?(user_id, remote_actor_id) do
    Repo.exists?(
      from(uf in UserFollow,
        where: uf.user_id == ^user_id and uf.remote_actor_id == ^remote_actor_id
      )
    )
  end

  @doc """
  Returns true if an accepted follow record exists for the user/remote_actor pair.
  """
  def user_follows_accepted?(user_id, remote_actor_id) do
    Repo.exists?(
      from(uf in UserFollow,
        where:
          uf.user_id == ^user_id and uf.remote_actor_id == ^remote_actor_id and
            uf.state == @state_accepted
      )
    )
  end

  @doc """
  Lists followed remote actors for a user with optional state filter.

  ## Options

    * `:state` — filter by state (e.g., `"accepted"`, `"pending"`)

  Returns a list of `%UserFollow{}` structs with `:remote_actor` preloaded.
  """
  def list_user_follows(user_id, opts \\ []) do
    state = Keyword.get(opts, :state)

    query =
      from(uf in UserFollow,
        where: uf.user_id == ^user_id,
        order_by: [desc: uf.inserted_at],
        preload: [:remote_actor, followed_user: :role]
      )

    query =
      if state do
        from(uf in query, where: uf.state == ^state)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Returns the count of accepted outbound follows for the given user.
  """
  def count_user_follows(user_id) do
    Repo.one(
      from(uf in UserFollow,
        where: uf.user_id == ^user_id and uf.state == @state_accepted,
        select: count(uf.id)
      )
    ) || 0
  end

  # --- Board Follows ---

  @doc """
  Creates a board follow record and returns the generated Follow AP ID.

  Inserts a `BoardFollow` with state `"pending"`. The caller is responsible
  for building and delivering the Follow activity using the returned AP ID.

  Returns `{:ok, %BoardFollow{}}` or `{:error, changeset}`.
  """
  def create_board_follow(board, remote_actor) do
    ap_id = "#{actor_uri(:board, board.slug)}#follow-#{System.unique_integer([:positive])}"

    %BoardFollow{}
    |> BoardFollow.changeset(%{
      board_id: board.id,
      remote_actor_id: remote_actor.id,
      state: @state_pending,
      ap_id: ap_id
    })
    |> Repo.insert()
  end

  @doc """
  Marks a board follow as accepted by matching the Follow activity's AP ID.

  Called when an `Accept(Follow)` activity is received from the remote actor.
  Returns `{:ok, %BoardFollow{}}` or `{:error, :not_found}`.
  """
  def accept_board_follow(follow_ap_id) when is_binary(follow_ap_id) do
    case Repo.one(from(bf in BoardFollow, where: bf.ap_id == ^follow_ap_id)) do
      nil ->
        {:error, :not_found}

      %BoardFollow{} = follow ->
        follow
        |> BoardFollow.changeset(%{
          state: @state_accepted,
          accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()
    end
  end

  @doc """
  Marks a board follow as rejected by matching the Follow activity's AP ID.

  Called when a `Reject(Follow)` activity is received from the remote actor.
  Returns `{:ok, %BoardFollow{}}` or `{:error, :not_found}`.
  """
  def reject_board_follow(follow_ap_id) when is_binary(follow_ap_id) do
    case Repo.one(from(bf in BoardFollow, where: bf.ap_id == ^follow_ap_id)) do
      nil ->
        {:error, :not_found}

      %BoardFollow{} = follow ->
        follow
        |> BoardFollow.changeset(%{
          state: @state_rejected,
          rejected_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()
    end
  end

  @doc """
  Deletes a board follow record (for unfollow).

  Returns `{:ok, %BoardFollow{}}` or `{:error, :not_found}`.
  """
  def delete_board_follow(board, remote_actor) do
    case Repo.one(
           from(bf in BoardFollow,
             where: bf.board_id == ^board.id and bf.remote_actor_id == ^remote_actor.id
           )
         ) do
      nil -> {:error, :not_found}
      %BoardFollow{} = follow -> Repo.delete(follow)
    end
  end

  @doc """
  Returns the board follow record for the given board and remote actor pair, or nil.
  """
  def get_board_follow(board_id, remote_actor_id) do
    Repo.one(
      from(bf in BoardFollow,
        where: bf.board_id == ^board_id and bf.remote_actor_id == ^remote_actor_id
      )
    )
  end

  @doc """
  Returns the board follow record matching the given Follow activity AP ID, or nil.
  """
  def get_board_follow_by_ap_id(ap_id) do
    Repo.one(from(bf in BoardFollow, where: bf.ap_id == ^ap_id))
  end

  @doc """
  Returns true if an accepted follow record exists for the board/remote_actor pair.
  """
  def board_follows_actor?(board_id, remote_actor_id) do
    Repo.exists?(
      from(bf in BoardFollow,
        where:
          bf.board_id == ^board_id and bf.remote_actor_id == ^remote_actor_id and
            bf.state == @state_accepted
      )
    )
  end

  @doc """
  Returns boards with accepted follows for a given remote actor.

  Used for auto-routing: when a followed actor sends a Create activity
  that doesn't explicitly address a board, this determines which boards
  should receive it.
  """
  def boards_following_actor(remote_actor_id) do
    from(bf in BoardFollow,
      where: bf.remote_actor_id == ^remote_actor_id and bf.state == @state_accepted,
      join: b in assoc(bf, :board),
      where: b.ap_enabled == true and b.min_role_to_view == "guest",
      select: b
    )
    |> Repo.all()
  end

  @doc """
  Lists board follows with optional state filter, preloading remote actors.

  ## Options

    * `:state` — filter by state (e.g., `"accepted"`, `"pending"`)

  Returns a list of `%BoardFollow{}` structs with `:remote_actor` preloaded.
  """
  def list_board_follows(board_id, opts \\ []) do
    state = Keyword.get(opts, :state)

    query =
      from(bf in BoardFollow,
        where: bf.board_id == ^board_id,
        order_by: [desc: bf.inserted_at],
        preload: [:remote_actor]
      )

    query =
      if state do
        from(bf in query, where: bf.state == ^state)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Returns the count of accepted board follows for the given board.
  """
  def count_board_follows(board_id) do
    Repo.one(
      from(bf in BoardFollow,
        where: bf.board_id == ^board_id and bf.state == @state_accepted,
        select: count(bf.id)
      )
    ) || 0
  end

  # --- Feed Items ---

  @feed_per_page 20

  @doc """
  Creates a feed item and broadcasts to all local followers of the source actor.

  Returns `{:ok, %FeedItem{}}` or `{:error, changeset}`.
  """
  def create_feed_item(attrs) do
    case %FeedItem{} |> FeedItem.changeset(attrs) |> Repo.insert() do
      {:ok, feed_item} ->
        remote_actor_id = feed_item.remote_actor_id

        for user_id <- local_followers_of_remote_actor(remote_actor_id) do
          FederationPubSub.broadcast_to_user_feed(
            user_id,
            :feed_item_created,
            %{feed_item_id: feed_item.id}
          )
        end

        {:ok, feed_item}

      error ->
        error
    end
  end

  @doc """
  Lists paginated feed items for a user.

  Includes the user's own articles, remote feed items and local articles
  from accepted follows, and comments on articles the user authored or
  previously commented on (including the user's own comments). Excludes
  soft-deleted items and items from blocked/muted actors. Local article
  items include a `comment_count` key; comment items include the comment
  with preloaded `:user` and `article: :user`.

  Returns `%{items: [...], total: n, page: n, per_page: n, total_pages: n}`.
  """
  def list_feed_items(user, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, @feed_per_page)
    offset = (page - 1) * per_page

    {hidden_user_ids, hidden_ap_ids} = Auth.hidden_ids(user)

    # Remote feed items from followed remote actors
    remote_query =
      from(fi in FeedItem,
        join: uf in UserFollow,
        on: uf.remote_actor_id == fi.remote_actor_id,
        join: ra in RemoteActor,
        on: ra.id == fi.remote_actor_id,
        where: uf.user_id == ^user.id and uf.state == @state_accepted,
        where: is_nil(fi.deleted_at)
      )

    remote_query =
      if hidden_ap_ids != [] do
        from([fi, _uf, ra] in remote_query, where: ra.ap_id not in ^hidden_ap_ids)
      else
        remote_query
      end

    remote_total = Repo.one(from(q in remote_query, select: count(q.id)))

    # Local articles from self + followed local users
    local_query =
      from(a in Baudrate.Content.Article,
        left_join: uf in UserFollow,
        on:
          uf.followed_user_id == a.user_id and uf.user_id == ^user.id and
            uf.state == @state_accepted,
        where: a.user_id == ^user.id or not is_nil(uf.id),
        where: is_nil(a.deleted_at)
      )

    local_query =
      if hidden_user_ids != [] do
        from(a in local_query, where: a.user_id not in ^hidden_user_ids)
      else
        local_query
      end

    local_total = Repo.one(from(a in local_query, select: count(a.id)))

    # Comments on articles the user authored or commented on
    participated_subquery =
      from(oc in Baudrate.Content.Comment,
        where: oc.article_id == parent_as(:article).id and oc.user_id == ^user.id,
        select: 1
      )

    comment_query =
      from(c in Baudrate.Content.Comment,
        join: a in Baudrate.Content.Article,
        as: :article,
        on: a.id == c.article_id,
        where: a.user_id == ^user.id or exists(participated_subquery),
        where: is_nil(c.deleted_at) and is_nil(a.deleted_at)
      )

    comment_query =
      if hidden_user_ids != [] do
        from([c, _a] in comment_query, where: c.user_id not in ^hidden_user_ids)
      else
        comment_query
      end

    comment_total = Repo.one(from([c, _a] in comment_query, select: count(c.id)))

    total = remote_total + local_total + comment_total

    # Fetch all sets with extra items for proper merge-sort pagination
    remote_items =
      from([fi, _uf, ra] in remote_query,
        order_by: [desc: fi.published_at],
        limit: ^(offset + per_page),
        preload: [:remote_actor]
      )
      |> Repo.all()
      |> Enum.map(fn fi ->
        %{source: :remote, feed_item: fi, sorted_at: fi.published_at}
      end)

    local_articles =
      from(a in local_query,
        order_by: [desc: a.inserted_at],
        limit: ^(offset + per_page),
        preload: [:user, boards: []]
      )
      |> Repo.all()

    # Batch-load comment counts for local articles
    local_article_ids = Enum.map(local_articles, & &1.id)

    comment_counts =
      if local_article_ids != [] do
        from(c in Baudrate.Content.Comment,
          where: c.article_id in ^local_article_ids and is_nil(c.deleted_at),
          group_by: c.article_id,
          select: {c.article_id, count(c.id)}
        )
        |> Repo.all()
        |> Map.new()
      else
        %{}
      end

    local_items =
      Enum.map(local_articles, fn article ->
        %{
          source: :local,
          article: article,
          comment_count: Map.get(comment_counts, article.id, 0),
          sorted_at: article.inserted_at
        }
      end)

    comment_items =
      from([c, _a] in comment_query,
        order_by: [desc: c.inserted_at],
        limit: ^(offset + per_page),
        preload: [:user, article: :user]
      )
      |> Repo.all()
      |> Enum.map(fn c ->
        %{source: :local_comment, comment: c, sorted_at: c.inserted_at}
      end)

    # Merge, sort, paginate
    items =
      (remote_items ++ local_items ++ comment_items)
      |> Enum.sort_by(& &1.sorted_at, {:desc, DateTime})
      |> Enum.drop(offset)
      |> Enum.take(per_page)

    total_pages = max(ceil(total / per_page), 1)

    %{
      items: items,
      total: total,
      page: page,
      per_page: per_page,
      total_pages: total_pages
    }
  end

  @doc """
  Returns a feed item by its ActivityPub ID, or nil.
  """
  def get_feed_item_by_ap_id(ap_id) when is_binary(ap_id) do
    Repo.one(from(fi in FeedItem, where: fi.ap_id == ^ap_id))
  end

  @doc """
  Soft-deletes a feed item by AP ID, scoped to a remote actor.

  Returns `{count, nil}`.
  """
  def soft_delete_feed_item_by_ap_id(ap_id, remote_actor_id) when is_binary(ap_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(fi in FeedItem,
      where:
        fi.ap_id == ^ap_id and fi.remote_actor_id == ^remote_actor_id and is_nil(fi.deleted_at)
    )
    |> Repo.update_all(set: [deleted_at: now])
  end

  @doc """
  Bulk soft-deletes all feed items from a given remote actor.

  Used when a remote actor is deleted. Returns `{count, nil}`.
  """
  def cleanup_feed_items_for_actor(remote_actor_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(fi in FeedItem,
      where: fi.remote_actor_id == ^remote_actor_id and is_nil(fi.deleted_at)
    )
    |> Repo.update_all(set: [deleted_at: now])
  end

  @doc """
  Returns user IDs of local users with accepted follows for the given remote actor.
  """
  def local_followers_of_remote_actor(remote_actor_id) do
    from(uf in UserFollow,
      where: uf.remote_actor_id == ^remote_actor_id and uf.state == @state_accepted,
      select: uf.user_id
    )
    |> Repo.all()
  end

  # --- Local User Follows ---

  @doc """
  Creates a local follow (user → user on same instance).

  The follow is auto-accepted immediately with no AP delivery required.
  Returns `{:ok, %UserFollow{}}` or `{:error, changeset}`.
  """
  def create_local_follow(%{id: follower_id} = follower, %{id: followed_id}) do
    if follower_id == followed_id do
      {:error, :self_follow}
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      ap_id =
        "#{actor_uri(:user, follower.username)}#follow-#{System.unique_integer([:positive])}"

      result =
        %UserFollow{}
        |> UserFollow.changeset(%{
          user_id: follower_id,
          followed_user_id: followed_id,
          state: @state_accepted,
          ap_id: ap_id,
          accepted_at: now
        })
        |> Repo.insert()

      with {:ok, _follow} <- result do
        Baudrate.Notification.Hooks.notify_local_follow(follower_id, followed_id)
        result
      end
    end
  end

  @doc """
  Deletes a local follow record (user → user unfollow).

  Returns `{:ok, %UserFollow{}}` or `{:error, :not_found}`.
  """
  def delete_local_follow(%{id: follower_id}, %{id: followed_id}) do
    case Repo.one(
           from(uf in UserFollow,
             where: uf.user_id == ^follower_id and uf.followed_user_id == ^followed_id
           )
         ) do
      nil -> {:error, :not_found}
      %UserFollow{} = follow -> Repo.delete(follow)
    end
  end

  @doc """
  Returns the local follow record for the given follower/followed user pair, or nil.
  """
  def get_local_follow(follower_user_id, followed_user_id) do
    Repo.one(
      from(uf in UserFollow,
        where: uf.user_id == ^follower_user_id and uf.followed_user_id == ^followed_user_id
      )
    )
  end

  @doc """
  Returns true if a local follow record exists for the user pair (any state).
  """
  def local_follows?(user_id, followed_user_id) do
    Repo.exists?(
      from(uf in UserFollow,
        where: uf.user_id == ^user_id and uf.followed_user_id == ^followed_user_id
      )
    )
  end

  @doc """
  Returns user IDs of local users with accepted follows for the given local user.
  """
  def local_followers_of_user(followed_user_id) do
    from(uf in UserFollow,
      where: uf.followed_user_id == ^followed_user_id and uf.state == @state_accepted,
      select: uf.user_id
    )
    |> Repo.all()
  end

  @doc """
  Migrates user follows from one remote actor to another (for Move activity).

  Updates all follows pointing to `old_actor_id` to point to `new_actor_id`.
  If a user already follows the new actor, the duplicate follow is deleted.

  Returns `{migrated_count, deleted_count}`.
  """
  def migrate_user_follows(old_actor_id, new_actor_id) do
    follows = Repo.all(from(uf in UserFollow, where: uf.remote_actor_id == ^old_actor_id))

    {migrated, deleted} =
      Enum.reduce(follows, {0, 0}, fn follow, {m, d} ->
        if user_follows?(follow.user_id, new_actor_id) do
          Repo.delete!(follow)
          {m, d + 1}
        else
          follow
          |> UserFollow.changeset(%{remote_actor_id: new_actor_id})
          |> Repo.update!()

          {m + 1, d}
        end
      end)

    {migrated, deleted}
  end

  # --- Article Object ---

  @doc """
  Returns an Article JSON-LD map for the given article.
  """
  def article_object(article) do
    article = Repo.preload(article, [:boards, :user, poll: :options])

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

    map = if tags == [], do: map, else: Map.put(map, "tag", tags)
    maybe_embed_poll(map, article.poll)
  end

  defp maybe_embed_poll(map, nil), do: map

  defp maybe_embed_poll(map, %Content.Poll{} = poll) do
    choice_key = if poll.mode == "single", do: "oneOf", else: "anyOf"

    options =
      Enum.map(poll.options, fn opt ->
        %{
          "type" => "Note",
          "name" => opt.text,
          "replies" => %{
            "type" => "Collection",
            "totalItems" => opt.votes_count
          }
        }
      end)

    question = %{
      "type" => "Question",
      choice_key => options,
      "votersCount" => poll.voters_count
    }

    question =
      if poll.closes_at do
        Map.put(question, "endTime", DateTime.to_iso8601(poll.closes_at))
      else
        question
      end

    existing_attachment = Map.get(map, "attachment", [])
    Map.put(map, "attachment", existing_attachment ++ [question])
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
    Baudrate.Content.extract_tags(body)
    |> Enum.map(fn tag ->
      %{
        "type" => "Hashtag",
        "name" => "##{tag}",
        "href" => "#{base_url()}/tags/#{tag}"
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
  Deletes an announce record by its ActivityPub ID, scoped to the given remote actor.
  Returns `{count, nil}` — only deletes if both ap_id and remote_actor_id match.
  """
  def delete_announce_by_ap_id(ap_id, remote_actor_id) when is_binary(ap_id) do
    from(a in Announce,
      where: a.ap_id == ^ap_id and a.remote_actor_id == ^remote_actor_id
    )
    |> Repo.delete_all()
  end

  @doc """
  Returns the count of announces for the given target AP ID.
  """
  def count_announces(target_ap_id) when is_binary(target_ap_id) do
    Repo.one(from(a in Announce, where: a.target_ap_id == ^target_ap_id, select: count(a.id))) ||
      0
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

  # --- Actor Cleanup ---

  @doc """
  Soft-deletes all content authored by a remote actor when that actor is deleted.

  Marks articles, comments, and direct messages from the actor as deleted
  by setting their `deleted_at` timestamp.
  """
  def cleanup_deleted_actor(remote_actor_ap_id) do
    alias Baudrate.Federation.RemoteActor

    case Repo.get_by(RemoteActor, ap_id: remote_actor_ap_id) do
      nil ->
        :ok

      actor ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        from(a in Baudrate.Content.Article,
          where: a.remote_actor_id == ^actor.id and is_nil(a.deleted_at)
        )
        |> Repo.update_all(set: [deleted_at: now])

        from(c in Baudrate.Content.Comment,
          where: c.remote_actor_id == ^actor.id and is_nil(c.deleted_at)
        )
        |> Repo.update_all(set: [deleted_at: now])

        from(dm in Baudrate.Messaging.DirectMessage,
          where: dm.sender_remote_actor_id == ^actor.id and is_nil(dm.deleted_at)
        )
        |> Repo.update_all(set: [deleted_at: now])

        cleanup_feed_items_for_actor(actor.id)

        :ok
    end
  end

  # --- Key Rotation ---

  @doc """
  Rotates the keypair for an actor and distributes the new public key
  to followers via an `Update` activity.

  ## Parameters

    * `actor_type` — `:user`, `:board`, or `:site`
    * `entity` — the user/board struct (ignored for `:site`)

  Returns `{:ok, updated_entity}` or `{:error, reason}`.
  """
  def rotate_keys(actor_type, entity) do
    with {:ok, updated} <- do_rotate(actor_type, entity) do
      Publisher.publish_key_rotation(actor_type, updated)
      {:ok, updated}
    end
  end

  defp do_rotate(:user, user), do: KeyStore.rotate_user_keypair(user)
  defp do_rotate(:board, board), do: KeyStore.rotate_board_keypair(board)
  defp do_rotate(:site, _), do: KeyStore.rotate_site_keypair()

  @doc """
  Schedules a federation task for async delivery.

  In production, starts the task under `Baudrate.Federation.TaskSupervisor`.
  In test (when `federation_async: false`), runs synchronously to avoid
  sandbox ownership errors.
  """
  def schedule_federation_task(fun) do
    if Application.get_env(:baudrate, :federation_async, true) do
      Task.Supervisor.start_child(Baudrate.Federation.TaskSupervisor, fun)
    else
      fun.()
      :ok
    end
  end
end
