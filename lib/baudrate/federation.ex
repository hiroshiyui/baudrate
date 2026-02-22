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
    * `/ap/site` — site actor
    * `/ap/articles/:slug` — article object
    * `/ap/inbox` — shared inbox (POST)
    * `/ap/users/:username/inbox` — user inbox (POST)
    * `/ap/boards/:slug/inbox` — board inbox (POST)
    * `/ap/users/:username/followers` — user followers (GET)
    * `/ap/boards/:slug/followers` — board followers (GET)
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
      "endpoints" => %{"sharedInbox" => "#{base_url()}/ap/inbox"},
      "publicKey" => %{
        "id" => "#{uri}#main-key",
        "owner" => uri,
        "publicKeyPem" => KeyStore.get_public_key_pem(user)
      }
    }
  end

  @doc """
  Returns a Group JSON-LD map for the given board.
  """
  def board_actor(board) do
    uri = actor_uri(:board, board.slug)

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

  # --- Outbox ---

  @doc """
  Returns a paginated OrderedCollection for a user's outbox.

  The outbox contains `Create(Article)` activities for the user's published articles.
  """
  def user_outbox(user, page_params \\ %{}) do
    articles =
      from(a in Baudrate.Content.Article,
        where: a.user_id == ^user.id and is_nil(a.deleted_at),
        order_by: [desc: a.inserted_at],
        preload: [:boards, :user]
      )
      |> Repo.all()
      |> Enum.filter(fn article ->
        Enum.any?(article.boards, &(&1.min_role_to_view == "guest"))
      end)

    outbox_uri = "#{actor_uri(:user, user.username)}/outbox"
    build_outbox(outbox_uri, articles, page_params, :create)
  end

  @doc """
  Returns a paginated OrderedCollection for a board's outbox.

  The outbox contains `Announce(Article)` activities for articles posted to the board.
  """
  def board_outbox(board, page_params \\ %{}) do
    articles =
      Content.list_articles_for_board(board)
      |> Repo.preload([:boards])

    outbox_uri = "#{actor_uri(:board, board.slug)}/outbox"
    build_outbox(outbox_uri, articles, page_params, {:announce, board})
  end

  defp build_outbox(uri, articles, _page_params, wrap_type) do
    items =
      Enum.map(articles, fn article ->
        case wrap_type do
          :create ->
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

          {:announce, board} ->
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
      end)

    %{
      "@context" => @as_context,
      "id" => uri,
      "type" => "OrderedCollection",
      "totalItems" => length(items),
      "orderedItems" => items
    }
  end

  # --- Followers Collection ---

  @doc """
  Returns an `OrderedCollection` JSON-LD map for the given actor's followers.
  """
  def followers_collection(actor_uri) do
    followers = list_followers(actor_uri)
    follower_uris = Enum.map(followers, & &1.follower_uri)

    %{
      "@context" => @as_context,
      "id" => "#{actor_uri}/followers",
      "type" => "OrderedCollection",
      "totalItems" => length(follower_uris),
      "orderedItems" => follower_uris
    }
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
      "url" => "#{base_url()}/articles/#{article.slug}"
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
