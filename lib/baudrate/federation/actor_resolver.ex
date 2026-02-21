defmodule Baudrate.Federation.ActorResolver do
  @moduledoc """
  Fetches and caches remote ActivityPub actor profiles.

  Actors are cached in the `remote_actors` table with a configurable TTL.
  Cached actors are returned directly; stale or missing actors are fetched
  from the remote instance via `HTTPClient`.
  """

  require Logger

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Federation.{HTTPClient, RemoteActor, Validator}

  @doc """
  Resolves a remote actor by their AP ID.

  1. Checks DB for existing RemoteActor with matching `ap_id`
  2. If found and `fetched_at` within TTL, returns cached
  3. Otherwise fetches via HTTP, validates, and upserts into DB
  """
  def resolve(actor_ap_id) when is_binary(actor_ap_id) do
    case Repo.one(from r in RemoteActor, where: r.ap_id == ^actor_ap_id) do
      %RemoteActor{} = actor ->
        if stale?(actor) do
          fetch_and_upsert(actor_ap_id)
        else
          {:ok, actor}
        end

      nil ->
        fetch_and_upsert(actor_ap_id)
    end
  end

  @doc """
  Resolves an actor by key ID URL. Strips the fragment and resolves the actor.
  Returns `{:ok, %RemoteActor{}}` or `{:error, reason}`.
  """
  def resolve_by_key_id(key_id_url) when is_binary(key_id_url) do
    # Key IDs are typically "https://remote.example/users/alice#main-key"
    actor_url = key_id_url |> URI.parse() |> Map.put(:fragment, nil) |> URI.to_string()
    resolve(actor_url)
  end

  @doc """
  Force-refreshes a cached remote actor regardless of TTL.
  """
  def refresh(actor_ap_id) when is_binary(actor_ap_id) do
    fetch_and_upsert(actor_ap_id)
  end

  defp stale?(%RemoteActor{fetched_at: fetched_at}) do
    ttl = config(:actor_cache_ttl)
    age = DateTime.diff(DateTime.utc_now(), fetched_at, :second)
    age > ttl
  end

  defp fetch_and_upsert(actor_ap_id) do
    with :ok <- validate_fetchable(actor_ap_id),
         {:ok, %{body: body}} <- HTTPClient.get(actor_ap_id, headers: []),
         {:ok, json} <- Jason.decode(body),
         {:ok, attrs} <- extract_actor_attrs(json) do
      upsert_actor(attrs)
    else
      {:error, reason} = err ->
        Logger.warning(
          "federation.actor_resolve_failed: url=#{actor_ap_id} reason=#{inspect(reason)}"
        )

        err
    end
  end

  defp validate_fetchable(url) do
    cond do
      not Validator.valid_https_url?(url) -> {:error, :invalid_actor_url}
      Validator.local_actor?(url) -> {:error, :self_referencing}
      true -> :ok
    end
  end

  defp extract_actor_attrs(json) do
    with {:ok, ap_id} <- required_string(json, "id"),
         {:ok, actor_type} <- required_string(json, "type"),
         {:ok, inbox} <- required_string(json, "inbox"),
         {:ok, public_key_pem} <- extract_public_key(json) do
      username = json["preferredUsername"] || extract_username_from_id(ap_id)
      domain = URI.parse(ap_id).host

      {:ok,
       %{
         ap_id: ap_id,
         username: username,
         domain: domain,
         display_name: json["name"],
         avatar_url: extract_avatar(json),
         public_key_pem: public_key_pem,
         inbox: inbox,
         shared_inbox: get_in(json, ["endpoints", "sharedInbox"]),
         actor_type: actor_type,
         fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
       }}
    end
  end

  defp extract_public_key(%{"publicKey" => %{"publicKeyPem" => pem}}) when is_binary(pem) do
    {:ok, pem}
  end

  defp extract_public_key(_), do: {:error, :missing_public_key}

  defp extract_avatar(%{"icon" => %{"url" => url}}) when is_binary(url), do: url
  defp extract_avatar(%{"icon" => url}) when is_binary(url), do: url
  defp extract_avatar(_), do: nil

  defp extract_username_from_id(ap_id) do
    ap_id |> URI.parse() |> Map.get(:path, "") |> String.split("/") |> List.last() || "unknown"
  end

  defp required_string(json, key) do
    case json[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :"missing_#{key}"}
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
