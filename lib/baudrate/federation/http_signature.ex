defmodule Baudrate.Federation.HTTPSignature do
  @moduledoc """
  HTTP Signature verification and signing for ActivityPub federation.

  Implements draft-cavage-http-signatures with `rsa-sha256` algorithm.

  **Verification** (incoming inbox requests):
    1. Parse `Signature` header
    2. Require `(request-target)`, `host`, `date`, `digest` in signed headers
    3. Validate `Date` within ±30s
    4. Validate `Digest` matches body SHA-256
    5. Resolve remote actor and verify signature with public key

  **Signing** (outgoing Accept(Follow) responses):
    1. Build signing string from required headers
    2. Sign with local actor's RSA private key
  """

  require Logger

  alias Baudrate.Federation.ActorResolver

  @required_signed_headers ["(request-target)", "host", "date", "digest"]
  @signature_max_age_default 30

  # --- Verification ---

  @doc """
  Verifies the HTTP Signature on an incoming connection.

  Returns `{:ok, %RemoteActor{}}` on success or `{:error, reason}` on failure.
  Expects `conn.assigns.raw_body` to be set by the CacheBody plug.
  """
  def verify(conn) do
    with {:ok, sig_params} <- parse_signature_header(conn),
         :ok <- validate_required_headers(sig_params),
         :ok <- validate_algorithm(sig_params),
         :ok <- validate_date(conn),
         :ok <- verify_digest(conn),
         {:ok, remote_actor} <- ActorResolver.resolve_by_key_id(sig_params["keyId"]),
         :ok <- verify_signature(conn, sig_params, remote_actor.public_key_pem) do
      {:ok, remote_actor}
    end
  end

  @doc """
  Parses the Signature header value into a map of key-value pairs.
  """
  def parse_signature_header(conn) when is_struct(conn, Plug.Conn) do
    case Plug.Conn.get_req_header(conn, "signature") do
      [sig_header | _] -> parse_signature_string(sig_header)
      [] -> {:error, :missing_signature_header}
    end
  end

  @doc """
  Parses a raw Signature header string.
  """
  def parse_signature_string(header) when is_binary(header) do
    params =
      Regex.scan(~r/(\w+)="([^"]*)"/, header)
      |> Enum.map(fn [_, key, value] -> {key, value} end)
      |> Map.new()

    if Map.has_key?(params, "keyId") and Map.has_key?(params, "signature") do
      # Default headers to "date" per spec
      params = Map.put_new(params, "headers", "date")
      {:ok, params}
    else
      {:error, :invalid_signature_header}
    end
  end

  @doc """
  Builds the signing string for verification or signing.
  """
  def build_signing_string(conn, headers_list) do
    headers_list
    |> Enum.map(fn
      "(request-target)" ->
        method = conn.method |> String.downcase()
        path = conn.request_path
        query = if conn.query_string != "", do: "?#{conn.query_string}", else: ""
        "(request-target): #{method} #{path}#{query}"

      header_name ->
        values = Plug.Conn.get_req_header(conn, header_name)
        "#{header_name}: #{Enum.join(values, ", ")}"
    end)
    |> Enum.join("\n")
  end

  @doc """
  Verifies the Digest header matches the SHA-256 hash of the raw body.
  """
  def verify_digest(conn) do
    raw_body = conn.assigns[:raw_body] || ""

    case Plug.Conn.get_req_header(conn, "digest") do
      ["SHA-256=" <> digest_b64 | _] ->
        computed = :crypto.hash(:sha256, raw_body) |> Base.encode64()

        if Plug.Crypto.secure_compare(computed, digest_b64) do
          :ok
        else
          {:error, :digest_mismatch}
        end

      _ ->
        {:error, :missing_digest}
    end
  end

  # --- GET Verification (Authorized Fetch) ---

  @required_signed_headers_get ["(request-target)", "host", "date"]

  @doc """
  Verifies the HTTP Signature on an incoming GET request.

  GET requests don't have a body, so `digest` is not required.
  Returns `{:ok, %RemoteActor{}}` on success or `{:error, reason}` on failure.
  """
  def verify_get(conn) do
    with {:ok, sig_params} <- parse_signature_header(conn),
         :ok <- validate_required_headers_get(sig_params),
         :ok <- validate_algorithm(sig_params),
         :ok <- validate_date(conn),
         {:ok, remote_actor} <- ActorResolver.resolve_by_key_id(sig_params["keyId"]),
         :ok <- verify_signature(conn, sig_params, remote_actor.public_key_pem) do
      {:ok, remote_actor}
    end
  end

  defp validate_required_headers_get(%{"headers" => headers_str}) do
    signed = String.split(headers_str, " ")
    missing = @required_signed_headers_get -- signed

    if missing == [] do
      :ok
    else
      {:error, {:missing_signed_headers, missing}}
    end
  end

  # --- Signing ---

  @doc """
  Signs an outgoing HTTP request and returns a map of headers to include.

  Returns a map with `"signature"`, `"date"`, `"digest"`, and `"host"` keys.
  """
  def sign(method, url, body, private_key_pem, key_id) do
    uri = URI.parse(url)
    now = format_http_date(DateTime.utc_now())
    digest = "SHA-256=" <> (body |> then(&:crypto.hash(:sha256, &1)) |> Base.encode64())
    host = uri.host

    path = uri.path || "/"
    query = if uri.query, do: "?#{uri.query}", else: ""
    target = "#{String.downcase(to_string(method))} #{path}#{query}"

    signing_string =
      [
        "(request-target): #{target}",
        "host: #{host}",
        "date: #{now}",
        "digest: #{digest}"
      ]
      |> Enum.join("\n")

    {:ok, private_key} = decode_private_key(private_key_pem)
    signature = :public_key.sign(signing_string, :sha256, private_key) |> Base.encode64()

    sig_header =
      ~s[keyId="#{key_id}",algorithm="rsa-sha256",headers="(request-target) host date digest",signature="#{signature}"]

    %{
      "signature" => sig_header,
      "date" => now,
      "digest" => digest,
      "host" => host
    }
  end

  @doc """
  Signs an outgoing HTTP GET request and returns a map of headers to include.

  Returns a map with `"signature"`, `"date"`, and `"host"` keys.
  GET requests don't have a body, so no `digest` is included.
  """
  def sign_get(url, private_key_pem, key_id) do
    uri = URI.parse(url)
    now = format_http_date(DateTime.utc_now())
    host = uri.host

    path = uri.path || "/"
    query = if uri.query, do: "?#{uri.query}", else: ""
    target = "get #{path}#{query}"

    signing_string =
      [
        "(request-target): #{target}",
        "host: #{host}",
        "date: #{now}"
      ]
      |> Enum.join("\n")

    {:ok, private_key} = decode_private_key(private_key_pem)
    signature = :public_key.sign(signing_string, :sha256, private_key) |> Base.encode64()

    sig_header =
      ~s[keyId="#{key_id}",algorithm="rsa-sha256",headers="(request-target) host date",signature="#{signature}"]

    %{
      "signature" => sig_header,
      "date" => now,
      "host" => host
    }
  end

  # --- Private ---

  defp validate_required_headers(%{"headers" => headers_str}) do
    signed = String.split(headers_str, " ")
    missing = @required_signed_headers -- signed

    if missing == [] do
      :ok
    else
      {:error, {:missing_signed_headers, missing}}
    end
  end

  defp validate_algorithm(%{"algorithm" => algo}) when algo in ["rsa-sha256", "hs2019"], do: :ok
  defp validate_algorithm(%{"algorithm" => _}), do: {:error, :unsupported_algorithm}
  # If algorithm is not specified, default to rsa-sha256 per spec
  defp validate_algorithm(_), do: :ok

  defp validate_date(conn) do
    case Plug.Conn.get_req_header(conn, "date") do
      [date_str | _] ->
        case parse_http_date(date_str) do
          {:ok, date} ->
            max_age = signature_max_age()
            age = abs(DateTime.diff(DateTime.utc_now(), date, :second))

            if age <= max_age do
              :ok
            else
              {:error, :signature_expired}
            end

          {:error, _} ->
            {:error, :invalid_date}
        end

      [] ->
        {:error, :missing_date}
    end
  end

  defp verify_signature(conn, sig_params, public_key_pem) do
    headers_list = String.split(sig_params["headers"], " ")
    signing_string = build_signing_string(conn, headers_list)

    case Base.decode64(sig_params["signature"]) do
      {:ok, signature_bytes} ->
        case decode_public_key(public_key_pem) do
          {:ok, public_key} ->
            if :public_key.verify(signing_string, :sha256, signature_bytes, public_key) do
              :ok
            else
              {:error, :signature_invalid}
            end

          {:error, _} = err ->
            err
        end

      :error ->
        {:error, :invalid_signature_encoding}
    end
  end

  defp decode_public_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] ->
        case :public_key.pem_entry_decode(entry) do
          {:RSAPublicKey, _, _} = key -> {:ok, key}
          {:SubjectPublicKeyInfo, _, _} -> {:ok, :public_key.pem_entry_decode(entry)}
          key -> {:ok, key}
        end

      _ ->
        {:error, :invalid_public_key}
    end
  rescue
    _ -> {:error, :invalid_public_key}
  end

  defp decode_private_key(pem) do
    [entry | _] = :public_key.pem_decode(pem)
    {:ok, :public_key.pem_entry_decode(entry)}
  rescue
    _ -> {:error, :invalid_private_key}
  end

  defp signature_max_age do
    Application.get_env(:baudrate, Baudrate.Federation, [])
    |> Keyword.get(:signature_max_age, @signature_max_age_default)
  end

  @doc false
  def format_http_date(datetime) do
    Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S GMT")
  end

  defp parse_http_date(date_str) do
    # Parse RFC 7231 date format: "Sun, 06 Nov 1994 08:49:37 GMT"
    months = %{
      "Jan" => 1,
      "Feb" => 2,
      "Mar" => 3,
      "Apr" => 4,
      "May" => 5,
      "Jun" => 6,
      "Jul" => 7,
      "Aug" => 8,
      "Sep" => 9,
      "Oct" => 10,
      "Nov" => 11,
      "Dec" => 12
    }

    case Regex.run(
           ~r/\w+,\s+(\d{2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT/,
           date_str
         ) do
      [_, day, month_str, year, hour, min, sec] ->
        month = Map.get(months, month_str)

        if month do
          DateTime.new(
            Date.new!(String.to_integer(year), month, String.to_integer(day)),
            Time.new!(String.to_integer(hour), String.to_integer(min), String.to_integer(sec))
          )
        else
          {:error, :invalid_month}
        end

      _ ->
        {:error, :unparseable_date}
    end
  end
end
