defmodule Baudrate.Federation.Discovery do
  @moduledoc """
  WebFinger discovery, NodeInfo, and remote actor lookup for the Federation context.

  Handles:

  - Local WebFinger responses (`/.well-known/webfinger`) for user, board, and
    site actors, including Lemmy-compatible `!slug` board resolution and
    Mastodon-compatible bare-slug fallback.
  - NodeInfo 2.1 endpoint responses (`/nodeinfo/2.1`).
  - Remote actor lookup by `@user@domain` handle or direct actor URL.
  - Remote object fetch and materialization via `ObjectResolver`.
  """

  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Content.Board
  alias Baudrate.Federation.{ActorResolver, HTTPClient, ObjectResolver, RemoteActor}

  @doc """
  Resolves a WebFinger resource string and returns a JRD map.

  Supports:
    * `acct:site@host` → instance actor (Organization)
    * `acct:username@host` → user actor
    * `acct:!slug@host` → board actor (Lemmy-compatible `!` prefix)
    * `acct:slug@host` → board actor (Mastodon-compatible bare slug fallback;
      tries user first, falls back to board if no matching user exists)

  The instance actor (`site`) is resolved first, before user/board lookups.

  Board WebFinger responses use the bare slug in `subject` (no `!` prefix)
  to match Mastodon's expectation from `preferredUsername`, and include a
  `properties` map with `"https://www.w3.org/ns/activitystreams#type" => "Group"`
  for Lemmy-compatible type disambiguation.

  Only federated boards (public + AP-enabled) are discoverable via WebFinger.

  Returns `{:ok, jrd_map}` or `{:error, reason}`.
  """
  @spec webfinger(String.t()) :: {:ok, map()} | {:error, atom()}
  def webfinger(resource) when is_binary(resource) do
    host = URI.parse(base_url()).host

    with {:ok, type, identifier} <- parse_acct(resource, host) do
      case type do
        :user ->
          if identifier == "site" do
            {:ok, webfinger_jrd(:site, "site")}
          else
            user = Repo.get_by(Baudrate.Setup.User, username: identifier)

            if user do
              {:ok, webfinger_jrd(:user, identifier)}
            else
              resolve_board_webfinger(identifier)
            end
          end

        :board ->
          resolve_board_webfinger(identifier)
      end
    end
  end

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
    import Ecto.Query
    user_count = Repo.one(from u in Baudrate.Setup.User, select: count(u.id)) || 0
    article_count = Repo.one(from a in Baudrate.Content.Article, select: count(a.id)) || 0

    %{
      "version" => "2.1",
      "software" => %{
        "name" => "baudrate",
        "version" => Application.spec(:baudrate, :vsn) |> to_string(),
        "repository" => "https://github.com/hiroshiyui/baudrate"
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

  @doc """
  Returns a remote actor by ID, or nil if not found.
  """
  @spec get_remote_actor(integer()) :: RemoteActor.t() | nil
  def get_remote_actor(id) do
    Repo.get(RemoteActor, id)
  end

  @doc """
  Looks up a remote actor by `@user@domain` handle or actor URL.

  For `@user@domain` handles, performs a WebFinger lookup to discover the
  actor's AP ID, then resolves via `ActorResolver`. For direct actor URLs,
  resolves directly.

  Returns `{:ok, %RemoteActor{}}` or `{:error, reason}`.
  """
  @spec lookup_remote_actor(String.t()) :: {:ok, RemoteActor.t()} | {:error, term()}
  def lookup_remote_actor("@" <> rest) do
    lookup_remote_actor(rest)
  end

  def lookup_remote_actor(query) when is_binary(query) do
    cond do
      String.contains?(query, "@") && !String.contains?(query, "/") ->
        case String.split(query, "@", parts: 2) do
          [user, domain] when user != "" and domain != "" ->
            webfinger_lookup(user, domain)

          _ ->
            {:error, :invalid_query}
        end

      String.starts_with?(query, "https://") ->
        ActorResolver.resolve(query)

      true ->
        {:error, :invalid_query}
    end
  end

  @doc """
  Fetches a remote ActivityPub object for preview without storing it.

  Returns `{:ok, preview_map}` with title, body, author, visibility, etc.,
  or `{:ok, :existing, article}` if already stored locally.
  """
  @spec fetch_remote_object(String.t()) ::
          {:ok, map()} | {:ok, :existing, Baudrate.Content.Article.t()} | {:error, term()}
  def fetch_remote_object(url) when is_binary(url) do
    ObjectResolver.fetch(url)
  end

  @doc """
  Materializes a remote ActivityPub object as a local article for interaction.

  Fetches, validates, resolves the author, and stores as a remote article.
  Returns `{:ok, %Article{}}` or `{:error, reason}`. Deduplicates by `ap_id`.

  **Loop-safe:** does not trigger any outbound federation.
  """
  @spec lookup_remote_object(String.t()) :: {:ok, Baudrate.Content.Article.t()} | {:error, term()}
  def lookup_remote_object(url) when is_binary(url) do
    ObjectResolver.resolve(url)
  end

  # --- Private ---

  defp resolve_board_webfinger(slug) do
    board = Repo.get_by(Board, slug: slug)

    if board && Board.federated?(board),
      do: {:ok, webfinger_jrd(:board, slug)},
      else: {:error, :not_found}
  end

  defp parse_acct(resource, host) do
    case Regex.run(~r/\Aacct:(!?)([^@]+)@(.+)\z/, resource) do
      [_, "!", slug, ^host] ->
        if Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug) do
          {:ok, :board, slug}
        else
          {:error, :invalid_resource}
        end

      [_, "", name, ^host] ->
        cond do
          Regex.match?(~r/\A[a-zA-Z0-9_]+\z/, name) ->
            {:ok, :user, name}

          Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, name) ->
            {:ok, :board, name}

          true ->
            {:error, :invalid_resource}
        end

      _ ->
        {:error, :invalid_resource}
    end
  end

  defp webfinger_jrd(type, identifier) do
    uri = Baudrate.Federation.actor_uri(type, identifier)
    host = URI.parse(base_url()).host

    base = %{
      "subject" => "acct:#{identifier}@#{host}",
      "aliases" => [uri],
      "links" => [
        %{
          "rel" => "self",
          "type" => "application/activity+json",
          "href" => uri
        }
      ]
    }

    case type do
      :board ->
        Map.put(base, "properties", %{
          "https://www.w3.org/ns/activitystreams#type" => "Group"
        })

      :site ->
        Map.put(base, "properties", %{
          "https://www.w3.org/ns/activitystreams#type" => "Organization"
        })

      _ ->
        base
    end
  end

  defp webfinger_lookup(user, domain) do
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

  defp base_url, do: Baudrate.Federation.base_url()
end
