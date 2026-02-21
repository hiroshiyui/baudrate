defmodule Baudrate.Federation do
  @moduledoc """
  The Federation context provides ActivityPub read-only endpoints.

  Phase 1 exposes actors, outbox collections, and article objects as
  JSON-LD, along with WebFinger and NodeInfo discovery endpoints.

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
  """

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Content
  alias Baudrate.Federation.KeyStore

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
          if board, do: {:ok, webfinger_jrd(:board, identifier)}, else: {:error, :not_found}
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
        where: a.user_id == ^user.id,
        order_by: [desc: a.inserted_at],
        preload: [:boards, :user]
      )
      |> Repo.all()

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

    %{
      "@context" => @as_context,
      "id" => actor_uri(:article, article.slug),
      "type" => "Article",
      "name" => article.title,
      "content" => article.body,
      "attributedTo" => actor_uri(:user, article.user.username),
      "published" => DateTime.to_iso8601(article.inserted_at),
      "updated" => DateTime.to_iso8601(article.updated_at),
      "to" => [@as_public],
      "audience" => board_uris,
      "url" => "#{base_url()}/articles/#{article.slug}"
    }
  end
end
