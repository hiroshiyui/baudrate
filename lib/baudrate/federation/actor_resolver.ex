defmodule Baudrate.Federation.ActorResolver do
  @moduledoc """
  Fetches and caches remote ActivityPub actor profiles.

  Actors are cached in the `remote_actors` table with a configurable TTL.
  Cached actors are returned directly; stale or missing actors are fetched
  from the remote instance via `HTTPClient`.
  """

  require Logger

  import Ecto.Query

  alias Baudrate.Media.NegativeCache
  alias Baudrate.Repo
  alias Baudrate.Federation

  alias Baudrate.Federation.{
    HTTPClient,
    HTTPSignature,
    KeyStore,
    RemoteActor,
    Sanitizer,
    Validator
  }

  # How long an unresolvable `keyId` is remembered before it is fetched again.
  @negative_ttl_seconds 600

  @doc """
  Resolves a remote actor by their AP ID.

  1. Checks DB for existing RemoteActor with matching `ap_id`
  2. If found and `fetched_at` within TTL, returns cached
  3. Otherwise fetches via HTTP, validates, and upserts into DB
  """
  def resolve(actor_ap_id, opts \\ []) when is_binary(actor_ap_id) do
    case Repo.one(from r in RemoteActor, where: r.ap_id == ^actor_ap_id) do
      %RemoteActor{} = actor ->
        if stale?(actor) do
          fetch_and_upsert(actor_ap_id, opts)
        else
          {:ok, actor}
        end

      nil ->
        fetch_and_upsert(actor_ap_id, opts)
    end
  end

  @doc """
  Resolves an actor by key ID URL. Strips the fragment and resolves the actor.
  Returns `{:ok, %RemoteActor{}}` or `{:error, reason}`.
  """
  def resolve_by_key_id(key_id_url) when is_binary(key_id_url) do
    # Key IDs are typically "https://remote.example/users/alice#main-key"
    actor_url = key_id_url |> URI.parse() |> Map.put(:fragment, nil) |> URI.to_string()

    # This is the one unauthenticated path that makes this instance send a
    # request: the `keyId` is read before the signature can be checked, and
    # an unknown actor must be fetched to check it. Cached actors cost
    # nothing. For a miss, a recent failure for the same URL is answered from
    # the negative cache, and fetches are bounded per target host, so a
    # stream of forged inbox POSTs cannot aim our GETs at a third party or
    # mint a `remote_actors` row per request.
    case Repo.one(from r in RemoteActor, where: r.ap_id == ^actor_url) do
      %RemoteActor{} ->
        resolve(actor_url)

      nil ->
        cond do
          NegativeCache.failed?("actor:" <> actor_url) ->
            {:error, :actor_fetch_failed_recently}

          actor_fetch_host_limited?(actor_url) ->
            {:error, :rate_limited}

          true ->
            case resolve(actor_url) do
              {:ok, _} = ok ->
                ok

              {:error, reason} = err ->
                unless reason in [:domain_blocked, :no_site_key],
                  do: NegativeCache.mark_failed("actor:" <> actor_url, @negative_ttl_seconds)

                err
            end
        end
    end
  end

  defp actor_fetch_host_limited?(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        BaudrateWeb.RateLimits.check_actor_fetch_host(String.downcase(host)) != :ok

      _ ->
        false
    end
  end

  @doc """
  Force-refreshes a cached remote actor regardless of TTL.
  """
  def refresh(actor_ap_id) when is_binary(actor_ap_id) do
    fetch_and_upsert(actor_ap_id)
  end

  defp stale?(%RemoteActor{fetched_at: fetched_at}) do
    ttl = config(:actor_cache_ttl) || 0
    age = DateTime.diff(DateTime.utc_now(), fetched_at, :second)
    age > ttl
  end

  defp fetch_and_upsert(actor_ap_id, opts \\ []) do
    with :ok <- validate_fetchable(actor_ap_id) do
      # `:timeout` shortens the deadline for a caller with somebody waiting on
      # the answer (a mention lookup during a post); absent, the federation
      # defaults apply. `refuse_blocked: true` on **both** the unsigned fetch
      # and the signed retry — answering the unsigned GET with 401/403/404 is
      # the documented way to trigger the retry, so a first-hop-only check was
      # bypassable (ADR 0030 decision 9).
      fetch_opts = [headers: [], refuse_blocked: true, timeout: opts[:timeout]]

      case HTTPClient.get(actor_ap_id, fetch_opts) do
        {:ok, %{body: body, url: final_url}} ->
          parse_and_upsert(body, final_url)

        {:error, {:http_error, status, _}} when status in [401, 403, 404] ->
          # Remote requires authorized fetch — retry with signed request.
          # Some instances (e.g. Threads.net) return 404 instead of 401
          # for unsigned requests.
          signed_fetch(actor_ap_id, opts)

        {:error, reason} = err ->
          Logger.warning(
            "federation.actor_resolve_failed: url=#{actor_ap_id} reason=#{inspect(reason)}"
          )

          err
      end
    end
  end

  # `fetched_url` is where the body was actually served from, after redirects.
  defp parse_and_upsert(body, fetched_url) do
    with {:ok, json} <- Jason.decode(body),
         {:ok, attrs} <- extract_actor_attrs(json),
         :ok <- validate_same_origin(attrs.ap_id, fetched_url),
         :ok <- validate_key_owner(json, attrs.ap_id) do
      upsert_actor(attrs)
    else
      {:error, reason} = err ->
        Logger.warning(
          "federation.actor_resolve_failed: url=#{fetched_url} reason=#{inspect(reason)}"
        )

        err
    end
  end

  # Binds the actor document's declared `id` to the URL it was served from.
  # During signature verification the fetched URL is derived from the
  # request's `keyId`, so a host controlling *any* HTTPS endpoint could serve
  # a document whose `id` claims a victim actor (with the attacker's public
  # key), forging the victim and poisoning the cached `remote_actors` row
  # keyed by `ap_id`. A host comparison was not enough: anyone who can place a
  # file on the victim's origin (user uploads, static paths) or trigger an
  # open redirect off it passed. The document must come back from exactly the
  # URL its `id` names — the one request only that actor's host can answer —
  # which is also what Mastodon requires (the CVE-2024-23832 class).
  defp validate_same_origin(doc_id, fetched_url)
       when is_binary(doc_id) and is_binary(fetched_url) do
    if normalize_uri(doc_id) == normalize_uri(fetched_url),
      do: :ok,
      else: {:error, :actor_id_origin_mismatch}
  end

  defp validate_same_origin(_, _), do: {:error, :actor_id_origin_mismatch}

  # Scheme and host are case-insensitive; the rest of the URI is compared as
  # written. A `keyId` fragment never reaches here (`resolve_by_key_id/1`).
  defp normalize_uri(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host} = parsed when is_binary(scheme) and is_binary(host) ->
        %URI{parsed | scheme: String.downcase(scheme), host: String.downcase(host), fragment: nil}
        |> URI.to_string()

      _ ->
        uri
    end
  end

  # A key that names an owner must name the actor it is embedded in; anything
  # else is a document lending one actor's key to another. The key `id` is not
  # compared: implementations differ on its shape, and the `keyId` path already
  # fetched exactly the URL it names.
  defp validate_key_owner(%{"publicKey" => %{"owner" => owner}}, ap_id) do
    if is_binary(owner) and normalize_uri(owner) == normalize_uri(ap_id),
      do: :ok,
      else: {:error, :key_owner_mismatch}
  end

  defp validate_key_owner(_json, _ap_id), do: :ok

  defp signed_fetch(actor_ap_id, opts) do
    with {:ok, _} <- KeyStore.ensure_site_keypair(),
         {:ok, private_key} <- KeyStore.decrypt_site_private_key() do
      site_uri = Federation.actor_uri(:site, nil)
      key_id = "#{site_uri}#main-key"

      # `refuse_blocked: true`, like the unsigned path: `validate_fetchable/1`
      # only covers the first hop, so without it a redirect from an allowed
      # domain into a blocked one was followed — and answering the unsigned
      # GET with 401/403/404 is the documented way to make us retry here.
      # ADR 0030 decision 9: a block stops us reaching out, not only
      # listening.
      signed_opts = [refuse_blocked: true, timeout: opts[:timeout]]

      case HTTPClient.signed_get(actor_ap_id, private_key, key_id, signed_opts) do
        {:ok, %{body: body, url: final_url}} ->
          parse_and_upsert(body, final_url)

        {:error, reason} = err ->
          Logger.warning(
            "federation.actor_resolve_failed: url=#{actor_ap_id} reason=#{inspect(reason)} (signed fetch)"
          )

          err
      end
    else
      _ ->
        Logger.warning("federation.actor_resolve_failed: url=#{actor_ap_id} reason=no_site_key")
        {:error, :no_site_key}
    end
  end

  defp validate_fetchable(url) do
    cond do
      not Validator.valid_https_url?(url) ->
        {:error, :invalid_actor_url}

      Validator.local_actor?(url) ->
        {:error, :self_referencing}

      # A block stops us reaching out as well as listening (ADR 0030).
      # Otherwise a blocked domain still got an outbound request from us — and
      # a cached `remote_actors` row — every time anything mentioned one of its
      # actors, which discloses our readers to an instance we have decided not
      # to federate with.
      domain_blocked?(url) ->
        {:error, :domain_blocked}

      true ->
        :ok
    end
  end

  defp domain_blocked?(url) do
    case URI.parse(url).host do
      host when is_binary(host) -> Validator.domain_blocked?(host)
      _ -> false
    end
  end

  defp extract_actor_attrs(json) do
    with {:ok, ap_id} <- required_string(json, "id", :missing_id),
         {:ok, actor_type} <- required_string(json, "type", :missing_type),
         {:ok, inbox} <- required_string(json, "inbox", :missing_inbox),
         {:ok, inbox} <- validate_inbox(inbox, ap_id),
         {:ok, public_key_pem} <- extract_public_key(json) do
      username =
        Sanitizer.sanitize_username(json["preferredUsername"]) ||
          extract_username_from_id(ap_id)

      domain = URI.parse(ap_id).host

      {:ok,
       %{
         ap_id: ap_id,
         username: username,
         domain: domain,
         display_name: Sanitizer.sanitize_display_name(json["name"]),
         avatar_url: extract_avatar(json),
         url: extract_url(json),
         summary: sanitize_summary(json["summary"]),
         profile_fields: extract_profile_fields(json),
         public_key_pem: public_key_pem,
         inbox: inbox,
         shared_inbox: extract_shared_inbox(json, ap_id),
         actor_type: actor_type,
         also_known_as: extract_also_known_as(json),
         moved_to_ap_id: extract_moved_to(json),
         fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
       }}
    end
  end

  # `inbox` was only required to be a non-empty string, and `sharedInbox` was
  # taken with a bare `get_in/2` — no https check, no origin binding, no
  # length bound — and `Delivery` then POSTs to whatever was stored. The SSRF
  # guard stops it reaching a private address, but it left this instance usable
  # as a signed-request reflector: declare `"inbox": "https://victim/expensive"`,
  # follow a busy local actor, and every activity we publish is POSTed to the
  # victim with a valid Digest and a body we generate. Mastodon and Lemmy both
  # host the inbox on the actor's own origin, so binding it breaks no real peer.
  defp validate_inbox(inbox, ap_id) do
    cond do
      not Validator.valid_https_url?(inbox) -> {:error, :invalid_inbox}
      not Validator.same_host?(inbox, ap_id) -> {:error, :inbox_origin_mismatch}
      true -> {:ok, inbox}
    end
  end

  defp extract_shared_inbox(json, ap_id) do
    case get_in(json, ["endpoints", "sharedInbox"]) do
      shared when is_binary(shared) ->
        if Validator.valid_https_url?(shared) and Validator.same_host?(shared, ap_id),
          do: shared,
          else: nil

      _ ->
        nil
    end
  end

  # `alsoKnownAs` may be a single URI string or a list of URI strings. Used to
  # verify inbound `Move` activities (the target actor must claim the moving
  # actor as an alias before its followers are migrated).
  # Capped: the list is attacker-controlled and only ever consulted as a
  # membership test, so an unbounded array is pure storage cost.
  @max_also_known_as 20

  defp extract_also_known_as(%{"alsoKnownAs" => aka}) when is_list(aka),
    do: aka |> Enum.filter(&is_binary/1) |> Enum.take(@max_also_known_as)

  defp extract_also_known_as(%{"alsoKnownAs" => aka}) when is_binary(aka), do: [aka]
  defp extract_also_known_as(_), do: []

  # `movedTo` on an actor document: the account moved there. A move target
  # that has itself moved is refused (ADR 0025). https only, bounded.
  defp extract_moved_to(%{"movedTo" => "https://" <> _ = uri}) when byte_size(uri) <= 2048,
    do: uri

  defp extract_moved_to(_), do: nil

  # Reject a weak or non-RSA key before the actor is cached, so the row never
  # exists rather than failing every later signature verification. The same
  # check runs again at verification time to cover rows cached before this
  # existed.
  defp extract_public_key(%{"publicKey" => %{"publicKeyPem" => pem}}) when is_binary(pem) do
    case HTTPSignature.validate_public_key_pem(pem) do
      :ok ->
        {:ok, pem}

      {:error, reason} = error ->
        Logger.warning("federation.actor_key_rejected: reason=#{inspect(reason)}")
        error
    end
  end

  defp extract_public_key(_), do: {:error, :missing_public_key}

  defp extract_avatar(%{"icon" => %{"url" => url}}) when is_binary(url),
    do: sanitize_avatar_url(url)

  defp extract_avatar(%{"icon" => url}) when is_binary(url), do: sanitize_avatar_url(url)
  defp extract_avatar(_), do: nil

  defp sanitize_avatar_url("https://" <> _ = url), do: url
  defp sanitize_avatar_url(_), do: nil

  defp extract_url(%{"url" => "https://" <> _ = url}) when is_binary(url), do: url
  defp extract_url(_), do: nil

  defp sanitize_summary(nil), do: nil
  defp sanitize_summary(""), do: nil

  defp sanitize_summary(summary) when is_binary(summary) do
    summary
    |> Sanitizer.sanitize()
    |> String.slice(0, 5000)
  end

  defp extract_profile_fields(%{"attachment" => attachments}) when is_list(attachments) do
    attachments
    |> Enum.filter(&(&1["type"] == "PropertyValue"))
    |> Enum.take(4)
    |> Enum.map(fn field ->
      %{
        "name" => sanitize_field_name(field["name"]),
        # Bounded for the same reason the summary is: sanitizing a value does
        # not shrink it, and an actor document may legally carry a megabyte of
        # markup in a profile field.
        "value" => field["value"] |> sanitize_field_value()
      }
    end)
    |> Enum.reject(fn %{"name" => name} -> is_nil(name) or name == "" end)
  end

  defp extract_profile_fields(_), do: []

  defp sanitize_field_name(nil), do: nil

  defp sanitize_field_name(name) when is_binary(name) do
    name
    |> Sanitizer.sanitize_display_name()
    |> String.slice(0, 255)
  end

  defp sanitize_field_value(value) when is_binary(value) do
    value |> Sanitizer.sanitize() |> String.slice(0, 1000)
  end

  defp sanitize_field_value(_), do: ""

  defp extract_username_from_id(ap_id) do
    derived = ap_id |> URI.parse() |> Map.get(:path, "") |> String.split("/") |> List.last()

    Sanitizer.sanitize_username(derived) || "unknown"
  end

  defp required_string(json, key, missing) do
    case json[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, missing}
    end
  end

  defp upsert_actor(attrs) do
    case Repo.one(from r in RemoteActor, where: r.ap_id == ^attrs.ap_id) do
      nil ->
        %RemoteActor{}
        |> RemoteActor.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> RemoteActor.changeset(attrs)
        |> Repo.update()
    end
  end

  defp config(key) do
    Application.get_env(:baudrate, Baudrate.Federation, []) |> Keyword.get(key)
  end
end
