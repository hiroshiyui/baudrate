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

  Returns `{:ok, jrd_map}` or `{:error, reason}` — `:gone` for an account
  that deleted itself.
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
            case Repo.get_by(Baudrate.Setup.User, username: identifier) do
              # A deleted account is gone, not unknown: it keeps its name
              # reserved, and answering 404 would let a board of that name
              # answer for it (ADR 0072).
              %{status: "deleted"} -> {:error, :gone}
              nil -> resolve_board_webfinger(identifier)
              _user -> {:ok, webfinger_jrd(:user, identifier)}
            end
          end

        :board ->
          resolve_board_webfinger(identifier)
      end
    end
  end

  @doc """
  Returns the well-known nodeinfo links document.

  Both 2.0 and 2.1 are advertised. They describe the same instance and differ
  only in what the schema permits — 2.0 has no place for `software.repository`
  — but a consumer that only knows 2.0 finds nothing if only 2.1 is offered,
  and several fediverse crawlers are still in that position.
  """
  def nodeinfo_links do
    %{
      "links" =>
        Enum.map(["2.0", "2.1"], fn version ->
          %{
            "rel" => "http://nodeinfo.diaspora.software/ns/schema/#{version}",
            "href" => "#{base_url()}/nodeinfo/#{version}"
          }
        end)
    }
  end

  @doc """
  Returns the NodeInfo response map for the given schema version.

  ## What is counted, and what is not

  `users.total` counts **people**: bots are excluded, because a feed reader
  with a password nobody knows is not a member and counting one inflates
  every instance-size comparison this document exists for, and banned
  accounts are excluded, because a ban is a removal.

  `localPosts` counts **local, undeleted articles**. It counted every row,
  including articles mirrored from other instances — so an instance that
  followed a busy community reported that community's output as its own.
  `localComments` is the same rule for comments.

  `activeMonth` and `activeHalfyear` come from `users.last_active_on`, which
  is stamped on sign-in. They cannot come from `user_sessions`: a session
  lives 14 days and is then purged, so that table cannot answer a question
  about a month, let alone six. An account that has not signed in since the
  column was added counts as inactive rather than as active, which
  under-reports rather than over-reports.
  """
  @spec nodeinfo(String.t()) :: map()
  def nodeinfo(version \\ "2.1") do
    %{
      "version" => version,
      "software" => software(version),
      "protocols" => ["activitypub"],
      "services" => %{"inbound" => [], "outbound" => []},
      "openRegistrations" => Setup.registration_mode() == "open",
      "usage" => usage(),
      "metadata" => metadata()
    }
  end

  defp metadata do
    %{"nodeName" => Setup.get_setting("site_name") || "Baudrate"}
    |> put_present("nodeDescription", Setup.get_setting("site_description"))
  end

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # `repository` and `homepage` were added in 2.1; a 2.0 document carrying
  # them fails schema validation, which is the kind of thing a crawler reports
  # as a broken instance.
  defp software("2.0") do
    %{"name" => "baudrate", "version" => version_string()}
  end

  defp software(_) do
    %{
      "name" => "baudrate",
      "version" => version_string(),
      "repository" => "https://github.com/hiroshiyui/baudrate"
    }
  end

  defp version_string, do: Application.spec(:baudrate, :vsn) |> to_string()

  defp usage do
    import Ecto.Query

    alias Baudrate.Content.{Article, Comment}

    members = Baudrate.Auth.counted_members_query()
    today = Date.utc_today()

    %{
      "users" => %{
        "total" => Repo.aggregate(members, :count, :id) || 0,
        "activeMonth" => active_since(members, Date.add(today, -30)),
        "activeHalfyear" => active_since(members, Date.add(today, -180))
      },
      "localPosts" =>
        Repo.aggregate(
          from(a in Article, where: is_nil(a.remote_actor_id) and is_nil(a.deleted_at)),
          :count,
          :id
        ) || 0,
      "localComments" =>
        Repo.aggregate(
          from(c in Comment, where: is_nil(c.remote_actor_id) and is_nil(c.deleted_at)),
          :count,
          :id
        ) || 0
    }
  end

  defp active_since(members, since) do
    import Ecto.Query
    Repo.aggregate(from(u in members, where: u.last_active_on >= ^since), :count, :id) || 0
  end

  @doc """
  Returns a remote actor by ID, or nil if not found.
  """
  @spec get_remote_actor(integer()) :: RemoteActor.t() | nil
  def get_remote_actor(id) do
    Repo.get(RemoteActor, id)
  end

  @doc """
  Returns a known remote actor by its ActivityPub ID, or nil. Never fetches.
  """
  @spec get_remote_actor_by_ap_id(String.t()) :: RemoteActor.t() | nil
  def get_remote_actor_by_ap_id(ap_id) when is_binary(ap_id) do
    Repo.get_by(RemoteActor, ap_id: ap_id)
  end

  @doc """
  Returns the known remote actors for the given ActivityPub IDs as a map keyed
  by AP ID. Unknown IDs are left out. Never fetches.
  """
  @spec remote_actors_by_ap_ids([String.t()]) :: %{String.t() => RemoteActor.t()}
  def remote_actors_by_ap_ids([]), do: %{}

  def remote_actors_by_ap_ids(ap_ids) when is_list(ap_ids) do
    import Ecto.Query

    from(ra in RemoteActor, where: ra.ap_id in ^ap_ids)
    |> Repo.all()
    |> Map.new(&{&1.ap_id, &1})
  end

  @doc """
  Looks up a remote actor by `@user@domain` handle or actor URL.

  For `@user@domain` handles, performs a WebFinger lookup to discover the
  actor's AP ID, then resolves via `ActorResolver`. For direct actor URLs,
  resolves directly.

  Returns `{:ok, %RemoteActor{}}` or `{:error, reason}`.

  ## Options

    * `:timeout` — shortens the deadline for **both** fetches this makes (the
      WebFinger document and the actor). `Federation.Mentions` passes one,
      because it runs while a member's post is being saved and the federation
      defaults are sized for background delivery. It can only shorten.
  """
  @spec lookup_remote_actor(String.t(), keyword()) ::
          {:ok, RemoteActor.t()} | {:error, term()}
  def lookup_remote_actor(query, opts \\ [])

  def lookup_remote_actor("@" <> rest, opts) do
    lookup_remote_actor(rest, opts)
  end

  def lookup_remote_actor(query, opts) when is_binary(query) do
    cond do
      String.contains?(query, "@") && !String.contains?(query, "/") ->
        case String.split(query, "@", parts: 2) do
          [user, domain] when user != "" and domain != "" ->
            webfinger_lookup(user, domain, opts)

          _ ->
            {:error, :invalid_query}
        end

      String.starts_with?(query, "https://") ->
        ActorResolver.resolve(query, opts)

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

  @doc """
  Fetches and decodes a remote instance's WebFinger document for
  `acct:user@domain`.

  Returns the decoded JRD, whatever links it holds — callers pick the `rel`
  they care about. `lookup_remote_actor/2` wants `self`;
  `Baudrate.Federation.RemoteFollow` wants the OStatus subscribe template.

  **A blocked domain is refused here** (`refuse_blocked: true`, ADR 0030
  decision 9), on every redirect hop. That flag used to be missing, and the
  only reason it was not a hole is that the one caller followed this with
  `ActorResolver.resolve/2`, which re-checks. A caller that stops at the
  WebFinger document has no such backstop, and a guest chooses the domain.

  ## Options

    * `:timeout` — shortens the deadline. Somebody is usually waiting on this.
  """
  @spec webfinger_document(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def webfinger_document(user, domain, opts \\ []) do
    resource = "acct:#{user}@#{domain}"
    url = "https://#{domain}/.well-known/webfinger?resource=#{URI.encode_www_form(resource)}"

    get_opts = [
      headers: [{"accept", "application/jrd+json"}],
      timeout: opts[:timeout],
      refuse_blocked: true
    ]

    case HTTPClient.get(url, get_opts) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, jrd} when is_map(jrd) -> {:ok, jrd}
          _ -> {:error, :invalid_webfinger}
        end

      {:error, reason} ->
        {:error, {:webfinger_failed, reason}}
    end
  end

  defp webfinger_lookup(user, domain, opts) do
    with {:ok, jrd} <- webfinger_document(user, domain, opts),
         {:ok, actor_url} <- extract_self_link(jrd) do
      ActorResolver.resolve(actor_url, opts)
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
