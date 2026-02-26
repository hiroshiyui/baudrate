defmodule Baudrate.Federation.Validator do
  @moduledoc """
  Input validation for incoming ActivityPub data.

  Provides checks for URL format, object ID validation, payload sizes,
  required activity fields, domain blocking, self-referencing URIs,
  and attribution consistency.
  """

  alias Baudrate.Setup

  @doc """
  Returns true if the URL is a well-formed HTTPS URL.
  """
  def valid_https_url?(url) when is_binary(url) do
    uri = URI.parse(url)
    uri.scheme == "https" and is_binary(uri.host) and uri.host != ""
  end

  def valid_https_url?(_), do: false

  @doc """
  Validates that the raw payload does not exceed the maximum size.
  """
  def validate_payload_size(body) when is_binary(body) do
    max = config(:max_payload_size)

    if byte_size(body) <= max do
      :ok
    else
      {:error, :payload_too_large}
    end
  end

  @doc """
  Validates that a content field does not exceed the maximum content size.
  """
  def validate_content_size(content) when is_binary(content) do
    max = config(:max_content_size)

    if byte_size(content) <= max do
      :ok
    else
      {:error, :content_too_large}
    end
  end

  def validate_content_size(nil), do: :ok

  @doc """
  Validates that an object's `id` is a valid HTTPS URL.

  When the object is a map (inline object), validates `object["id"]`.
  When the object is a string (URI reference), validates the string itself.
  Returns `{:ok, id}` or `{:error, :invalid_object_id}`.
  """
  def validate_object_id(%{"id" => id}) when is_binary(id) do
    if valid_https_url?(id), do: {:ok, id}, else: {:error, :invalid_object_id}
  end

  def validate_object_id(%{}), do: {:error, :invalid_object_id}

  def validate_object_id(uri) when is_binary(uri) do
    if valid_https_url?(uri), do: {:ok, uri}, else: {:error, :invalid_object_id}
  end

  def validate_object_id(_), do: {:error, :invalid_object_id}

  @doc """
  Validates that an activity JSON has the required fields.
  Returns `{:ok, activity}` or `{:error, reason}`.
  """
  def validate_activity(%{"type" => type, "actor" => actor} = activity)
      when is_binary(type) and is_binary(actor) do
    cond do
      not is_binary(activity["id"]) or not valid_https_url?(activity["id"]) ->
        {:error, :missing_activity_id}

      not valid_https_url?(actor) ->
        {:error, :invalid_actor_url}

      is_nil(activity["object"]) and type not in ["Delete"] ->
        {:error, :missing_object}

      true ->
        {:ok, activity}
    end
  end

  def validate_activity(_), do: {:error, :invalid_activity}

  @doc """
  Returns true if the domain is blocked based on the current federation mode.

  In `"blocklist"` mode (default), the domain is blocked if it appears in
  the `ap_domain_blocklist` setting. In `"allowlist"` mode, the domain is
  blocked unless it appears in the `ap_domain_allowlist` setting. When the
  allowlist is empty in allowlist mode, all domains are blocked (safe default).
  """
  def domain_blocked?(domain) when is_binary(domain) do
    mode = Setup.get_setting("ap_federation_mode") || "blocklist"

    case mode do
      "allowlist" ->
        allowed = parse_domain_list(Setup.get_setting("ap_domain_allowlist") || "")
        allowed == MapSet.new() or not MapSet.member?(allowed, String.downcase(domain))

      _ ->
        blocked = parse_domain_list(Setup.get_setting("ap_domain_blocklist") || "")
        MapSet.member?(blocked, String.downcase(domain))
    end
  end

  defp parse_domain_list(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  @doc """
  Returns true if the URI refers to a local actor (self-referencing).
  """
  def local_actor?(uri) when is_binary(uri) do
    base = BaudrateWeb.Endpoint.url()
    String.starts_with?(uri, base <> "/")
  end

  def local_actor?(_), do: false

  @doc """
  Validates that the activity's actor matches the object's attributedTo.
  Returns true if attribution is valid or not applicable.
  """
  def valid_attribution?(%{"actor" => actor, "object" => %{"attributedTo" => attributed}}) do
    actor == attributed
  end

  def valid_attribution?(%{"actor" => _actor, "object" => object}) when is_binary(object) do
    # Object is a URI reference, attribution check not applicable
    true
  end

  def valid_attribution?(_), do: true

  defp config(key) do
    Application.get_env(:baudrate, Baudrate.Federation, [])
    |> Keyword.get(key)
  end
end
