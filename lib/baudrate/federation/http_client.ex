defmodule Baudrate.Federation.HTTPClient do
  @moduledoc """
  Safe HTTP client for ActivityPub federation with SSRF protection.

  Wraps `Req` with security constraints:
    * HTTPS only (except in test/dev for localhost)
    * Private/loopback IP rejection (including IPv6 `::`)
    * DNS-pinned connections to prevent DNS rebinding attacks
    * Manual redirect following with IP validation at each hop
    * Configurable timeouts
    * Response body size cap
    * Instance-identifying User-Agent header

  ## DNS Pinning

  DNS is resolved once before connecting and the resolved IP is pinned to
  the connection via `:connect_options`. This prevents DNS rebinding attacks
  where a malicious server returns a public IP on the first DNS lookup and
  a private IP on the second (which `Req` would use for the actual connection).

  ## Redirect Handling

  Automatic redirects are disabled (`max_redirects: 0`). Redirects are
  followed manually in a loop, with each redirect destination validated
  against the SSRF rules (scheme, host, DNS, private IP) before connecting.
  """

  require Logger

  @max_redirects 5

  @doc """
  Performs a GET request with SSRF protection and federation constraints.

  DNS is resolved once and pinned to the connection. Redirects are followed
  manually with full SSRF validation at each hop.
  """
  def get(url, opts \\ []) do
    config = federation_config()
    headers = Keyword.get(opts, :headers, [])

    all_headers = [
      {"user-agent", user_agent()},
      {"accept", "application/activity+json"}
      | headers
    ]

    do_get(url, all_headers, config, @max_redirects)
  end

  defp do_get(_url, _headers, _config, remaining) when remaining < 0 do
    {:error, :too_many_redirects}
  end

  defp do_get(url, headers, config, remaining) do
    with {:ok, resolved} <- validate_and_resolve(url) do
      req_opts = build_pinned_opts(resolved, headers, config)

      case Req.get(req_opts) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          if byte_size(body) > config[:max_payload_size] do
            {:error, :response_too_large}
          else
            {:ok, %{status: status, body: body}}
          end

        {:ok, %Req.Response{status: status, headers: resp_headers}}
        when status in [301, 302, 303, 307, 308] ->
          case get_redirect_location(resp_headers, resolved.uri) do
            {:ok, location} -> do_get(location, headers, config, remaining - 1)
            :error -> {:error, {:http_error, status}}
          end

        {:ok, %Req.Response{status: status}} ->
          {:error, {:http_error, status}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  @doc """
  Performs a POST request with SSRF protection and federation constraints.

  DNS is resolved once and pinned to the connection. Redirects are not
  followed for POST requests.
  """
  def post(url, body, headers \\ [], _opts \\ []) do
    with {:ok, resolved} <- validate_and_resolve(url) do
      config = federation_config()

      all_headers = [
        {"user-agent", user_agent()},
        {"content-type", "application/activity+json"}
        | headers
      ]

      req_opts =
        build_pinned_opts(resolved, all_headers, config)
        |> Keyword.put(:body, body)

      case Req.post(req_opts) do
        {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
          {:ok, %{status: status, body: resp_body}}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:http_error, status}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  @doc """
  Performs a signed GET request with HTTP Signature headers.

  Uses the given private key and key ID to sign the request.
  """
  def signed_get(url, private_key_pem, key_id, opts \\ []) do
    alias Baudrate.Federation.HTTPSignature

    sig_headers = HTTPSignature.sign_get(url, private_key_pem, key_id)
    extra_headers = Enum.map(sig_headers, fn {k, v} -> {k, v} end)
    existing_headers = Keyword.get(opts, :headers, [])
    get(url, headers: extra_headers ++ existing_headers)
  end

  @doc """
  Validates a URL for safe federation use.

  Rejects:
    * Non-HTTPS URLs (except localhost in dev/test)
    * URLs resolving to private/loopback IP ranges
    * Malformed URLs
  """
  def validate_url(url) when is_binary(url) do
    case validate_and_resolve(url) do
      {:ok, _resolved} -> :ok
      {:error, _} = error -> error
    end
  end

  def validate_url(_), do: {:error, :invalid_url}

  # Parses, validates, and resolves a URL. Returns the resolved IP, host,
  # and URI so the caller can pin the connection to the resolved IP.
  defp validate_and_resolve(url) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- validate_scheme(uri),
         :ok <- validate_host(uri),
         {:ok, ip} <- resolve_and_check_ip(uri.host) do
      {:ok, %{ip: ip, host: uri.host, uri: uri}}
    end
  end

  defp validate_and_resolve(_), do: {:error, :invalid_url}

  # Builds Req options pinned to the resolved IP address. The connection
  # goes to the IP directly while SNI and Host header use the original hostname.
  defp build_pinned_opts(resolved, headers, config) do
    %{ip: ip, host: host, uri: %URI{} = uri} = resolved
    ip_string = :inet.ntoa(ip) |> to_string()
    port = uri.port || if(uri.scheme == "https", do: 443, else: 80)

    # Build the URL with the IP address instead of the hostname
    pinned_url = %URI{uri | host: ip_string, port: port} |> URI.to_string()

    # Set Host header to original hostname (not the IP)
    headers_with_host = [{"host", host} | headers]

    base_opts = [
      url: pinned_url,
      headers: headers_with_host,
      connect_options: [
        timeout: config[:http_connect_timeout],
        transport_opts: [server_name_indication: String.to_charlist(host)]
      ],
      receive_timeout: config[:http_receive_timeout],
      max_redirects: 0,
      redirect: false,
      max_retries: 0,
      decode_body: false
    ]

    base_opts
  end

  # Extracts and resolves the Location header from a redirect response.
  # Handles both absolute and relative URLs.
  defp get_redirect_location(resp_headers, base_uri) do
    case List.keyfind(resp_headers, "location", 0) do
      {_, location} ->
        # Resolve relative URLs against the base
        resolved =
          case URI.parse(location) do
            %URI{scheme: nil} -> URI.merge(base_uri, location) |> URI.to_string()
            _ -> location
          end

        {:ok, resolved}

      nil ->
        :error
    end
  end

  defp validate_scheme(%URI{scheme: "https"}), do: :ok

  defp validate_scheme(%URI{scheme: "http", host: host})
       when host in ["localhost", "127.0.0.1"] do
    if Mix.env() in [:dev, :test], do: :ok, else: {:error, :https_required}
  end

  defp validate_scheme(_), do: {:error, :https_required}

  defp validate_host(%URI{host: nil}), do: {:error, :invalid_host}
  defp validate_host(%URI{host: ""}), do: {:error, :invalid_host}
  defp validate_host(_), do: :ok

  defp resolve_and_check_ip(host) do
    case resolve_ip(host) do
      {:ok, ip} ->
        if private_ip?(ip) do
          {:error, :private_ip}
        else
          {:ok, ip}
        end

      {:error, _} ->
        {:error, :dns_resolution_failed}
    end
  end

  defp resolve_ip(host) do
    host_charlist = String.to_charlist(host)

    case :inet.getaddr(host_charlist, :inet) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :inet.getaddr(host_charlist, :inet6)
    end
  end

  @doc false
  def private_ip?({127, _, _, _}), do: true
  def private_ip?({10, _, _, _}), do: true
  def private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  def private_ip?({192, 168, _, _}), do: true
  def private_ip?({169, 254, _, _}), do: true
  def private_ip?({0, _, _, _}), do: true
  # IPv6 unspecified address ::
  def private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  # IPv6 loopback ::1
  def private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # IPv6 fc00::/7
  def private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true
  # IPv6 fe80::/10
  def private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: true
  # IPv4-mapped IPv6 (::ffff:x.y.z.w) — extract embedded IPv4 and re-check
  def private_ip?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    import Bitwise
    private_ip?({hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF})
  end

  def private_ip?(_), do: false

  defp user_agent do
    "Baudrate/0.1.0 (+#{BaudrateWeb.Endpoint.url()})"
  end

  defp federation_config do
    Application.get_env(:baudrate, Baudrate.Federation, [])
  end
end
