defmodule Baudrate.Federation.HTTPClient do
  @moduledoc """
  Safe HTTP client for ActivityPub federation with SSRF protection.

  Wraps `Req` with security constraints:
    * HTTPS only (except in test/dev for localhost)
    * Private/loopback IP rejection (including IPv6 `::`)
    * DNS-pinned connections to prevent DNS rebinding attacks
    * Manual redirect following with IP validation at each hop
    * Configurable timeouts — connect, per-read (`receive_timeout`) **and**
      whole-request (`request_timeout`); without the last one a server
      trickling a byte every 29 s could hold a delivery job or media request
      open indefinitely
    * Response body size cap enforced **while streaming** (`into:` collector):
      the connection is halted the moment the accumulated bytes (or a declared
      `content-length`) exceed the cap, so an oversized body is never buffered
      in the BEAM heap — and this applies to POST responses too
    * No transparent decompression: `compressed: false` means Req never sends
      `accept-encoding` and never inflates a response, so the cap applies to
      the wire bytes (no decompression bombs); `decode_body: false` keeps the
      raw body
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

  ## Error Format

  Non-2xx responses return `{:error, {:http_error, status, body}}` where
  `body` is the response body truncated to 4 KB for diagnostic logging.
  """

  require Logger

  @max_redirects 5
  @default_request_timeout 60_000
  @default_max_payload_size 262_144
  @req_test_options Application.compile_env(:baudrate, :req_test_options, [])
  @bypass_ssrf Application.compile_env(:baudrate, :bypass_ssrf_check, false)
  @allow_http_localhost Application.compile_env(:baudrate, :allow_http_localhost, false)

  @doc """
  Performs a GET request with SSRF protection and federation constraints.

  DNS is resolved once and pinned to the connection. Redirects are followed
  manually with full SSRF validation at each hop.

  Returns `{:ok, %{status: status, body: body}}` on success (2xx), or
  `{:error, {:http_error, status, body}}` on non-2xx responses (body
  truncated to 4 KB for diagnostics).
  """
  def get(url, opts \\ []) do
    config = federation_config()
    headers = Keyword.get(opts, :headers, [])

    all_headers = [
      {"user-agent", user_agent()},
      {"accept", "application/activity+json"}
      | headers
    ]

    do_get(url, all_headers, config, @max_redirects, Keyword.get(opts, :refuse_blocked, false))
  end

  defp do_get(_url, _headers, _config, remaining, _block?) when remaining < 0 do
    {:error, :too_many_redirects}
  end

  defp do_get(url, headers, config, remaining, block?) do
    with {:ok, resolved} <- validate_and_resolve(url, block?) do
      req_opts = build_pinned_opts(resolved, headers, config)

      case Req.get(req_opts) |> finalize_streamed() do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, %{status: status, body: body}}

        {:ok, %Req.Response{status: status, headers: resp_headers}}
        when status in [301, 302, 303, 307, 308] ->
          case get_redirect_location(resp_headers, resolved.uri) do
            {:ok, location} ->
              do_get(location, drop_signature_headers(headers), config, remaining - 1, block?)

            :error ->
              {:error, {:http_error, status, ""}}
          end

        {:ok, %Req.Response{status: status, body: resp_body}} ->
          {:error, {:http_error, status, truncate_body(resp_body)}}

        {:error, :response_too_large} ->
          {:error, :response_too_large}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  @doc """
  Performs a GET request for HTML content with SSRF protection.

  Similar to `get/2` but uses a generic `Accept: text/html` header and
  a generic user-agent (not AP-specific). Used for link preview fetching.

  ## Options

    * `:headers` — extra request headers
    * `:max_size` — override maximum response size (default: federation config)
    * `:user_agent` — override the default User-Agent string
  """
  def get_html(url, opts \\ []) do
    config = federation_config()
    extra_headers = Keyword.get(opts, :headers, [])

    max_size =
      Keyword.get(opts, :max_size, config[:max_payload_size]) || @default_max_payload_size

    ua = Keyword.get(opts, :user_agent, generic_user_agent())
    config = Keyword.put(config, :max_payload_size, max_size)

    all_headers = [
      {"user-agent", ua},
      {"accept", "text/html, application/xhtml+xml"}
      | extra_headers
    ]

    do_get_html(
      url,
      all_headers,
      config,
      @max_redirects,
      Keyword.get(opts, :refuse_blocked, false)
    )
  end

  defp do_get_html(_url, _headers, _config, remaining, _block?) when remaining < 0 do
    {:error, :too_many_redirects}
  end

  defp do_get_html(url, headers, config, remaining, block?) do
    with {:ok, resolved} <- validate_and_resolve(url, block?) do
      req_opts = build_pinned_opts(resolved, headers, config)

      case Req.get(req_opts) |> finalize_streamed() do
        {:ok, %Req.Response{status: status, body: body, headers: resp_headers}}
        when status in 200..299 ->
          {:ok, %{status: status, body: body, headers: resp_headers}}

        {:ok, %Req.Response{status: status, headers: resp_headers}}
        when status in [301, 302, 303, 307, 308] ->
          case get_redirect_location(resp_headers, resolved.uri) do
            {:ok, location} ->
              do_get_html(
                location,
                drop_signature_headers(headers),
                config,
                remaining - 1,
                block?
              )

            :error ->
              {:error, {:http_error, status, ""}}
          end

        {:ok, %Req.Response{status: status, body: resp_body}} ->
          {:error, {:http_error, status, truncate_body(resp_body)}}

        {:error, :response_too_large} ->
          {:error, :response_too_large}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  @doc """
  Performs a POST request with SSRF protection and federation constraints.

  DNS is resolved once and pinned to the connection. Redirects are not
  followed for POST requests.

  Returns `{:ok, %{status: status, body: body}}` on success (2xx), or
  `{:error, {:http_error, status, body}}` on non-2xx responses (body
  truncated to 4 KB for diagnostics).
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

      case Req.post(req_opts) |> finalize_streamed() do
        {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
          {:ok, %{status: status, body: resp_body}}

        {:ok, %Req.Response{status: status, body: resp_body}} ->
          {:error, {:http_error, status, truncate_body(resp_body)}}

        {:error, :response_too_large} ->
          {:error, :response_too_large}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  @doc """
  Performs a POST request with caller-supplied headers and SSRF protection.

  This is for non-ActivityPub POSTs, such as Web Push delivery, where callers
  must control the content type and authentication headers. The destination is
  still validated and DNS-pinned before the request is made.
  """
  def post_raw(url, body, headers \\ [], _opts \\ []) do
    with {:ok, resolved} <- validate_and_resolve(url) do
      config = federation_config()

      req_opts =
        build_pinned_opts(resolved, headers, config)
        |> Keyword.put(:body, body)

      case Req.post(req_opts) |> finalize_streamed() do
        {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
          {:ok, %{status: status, body: resp_body}}

        {:ok, %Req.Response{status: status, body: resp_body}} ->
          {:error, {:http_error, status, truncate_body(resp_body)}}

        {:error, :response_too_large} ->
          {:error, :response_too_large}

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
    extra_headers = Map.to_list(sig_headers)
    existing_headers = Keyword.get(opts, :headers, [])

    get(url,
      headers: extra_headers ++ existing_headers,
      refuse_blocked: Keyword.get(opts, :refuse_blocked, false)
    )
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
  defp validate_and_resolve(url, block_check? \\ false)

  defp validate_and_resolve(url, block_check?) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- validate_scheme(uri),
         :ok <- validate_host(uri),
         :ok <- validate_not_blocked(uri.host, block_check?),
         {:ok, ip} <- safe_resolve_ip(uri.host) do
      {:ok, %{ip: ip, host: uri.host, uri: uri}}
    end
  end

  defp validate_and_resolve(_, _block_check?), do: {:error, :invalid_url}

  # Opt-in per caller, and re-applied on every redirect hop.
  #
  # The callers that check a domain block (`ActorResolver`, `ObjectResolver`,
  # the reply-chain walk, `MediaController`) only ever see the *first* URL, so
  # a redirect reached a blocked instance anyway: its operator had only to
  # stand up an unblocked host that 302s to it, and the media proxy would
  # fetch the image, cache it under `media_cache/` and re-serve it to every
  # viewer — with the per-domain fetch limit keyed on the pre-redirect host
  # too. ADR 0030 means a block stops us reaching out, on every hop.
  #
  # Deliberately not unconditional: `domain_blocked?/1` reads the database,
  # and in allowlist mode it answers true for every domain that is not on the
  # list — which is a statement about who may federate with us, not about
  # whether we may fetch a link preview from a news site.
  defp validate_not_blocked(host, true) when is_binary(host) do
    if Baudrate.Federation.Validator.domain_blocked?(host),
      do: {:error, :domain_blocked},
      else: :ok
  end

  defp validate_not_blocked(_host, _block_check?), do: :ok

  # An HTTP Signature is computed over one `(request-target)` and `host`, so it
  # is meaningless anywhere else — but the header list was forwarded verbatim to
  # every redirect hop, handing a third party a valid site-key signature (and
  # our `keyId`) over a request they did not receive. It cannot be replayed
  # usefully, but there is no reason to disclose it. Authorized-fetch peers do
  # not redirect their actor documents; one that does gets an unsigned retry,
  # which is the same outcome as before for anything that verifies.
  # A signature is computed over the original request line and host, so it is
  # meaningless to the redirect target and must not be handed to it — a
  # redirect is the cheapest way for one server to collect our signed
  # credentials addressed to another. `authorization` and `signature-input`
  # are not set by any caller today; they are here so that adding one cannot
  # quietly reintroduce the leak.
  defp drop_signature_headers(headers) do
    Enum.reject(headers, fn {name, _value} ->
      String.downcase(name) in [
        "signature",
        "signature-input",
        "digest",
        "date",
        "authorization"
      ]
    end)
  end

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
      # Whole-request deadline. `receive_timeout` alone is per read, so a
      # server trickling a byte every 29 s would never trip it.
      request_timeout: config[:http_request_timeout] || @default_request_timeout,
      max_redirects: 0,
      redirect: false,
      max_retries: 0,
      compressed: false,
      decode_body: false,
      into: body_collector(config[:max_payload_size] || @default_max_payload_size)
    ]

    Keyword.merge(base_opts, @req_test_options)
  end

  # Streaming body collector: accumulates chunks in `resp.private` and halts
  # the connection as soon as the declared `content-length` or the received
  # bytes exceed `max`. Checking `byte_size(body)` after the fact would have
  # meant buffering an attacker's multi-GB body in RAM first.
  # Guarded on purpose: with `max` nil, `size > nil` is false under Elixir's
  # term ordering, so the collector would accumulate an unbounded body and
  # never halt — a silent fail-open, in the one place built to fail closed.
  defp body_collector(max) when is_integer(max) and max > 0 do
    fn {:data, chunk}, {req, resp} ->
      declared = declared_content_length(resp)
      size = Req.Response.get_private(resp, :baudrate_size, 0) + byte_size(chunk)

      if size > max or (is_integer(declared) and declared > max) do
        {:halt, {req, Req.Response.put_private(resp, :baudrate_too_large, true)}}
      else
        chunks = Req.Response.get_private(resp, :baudrate_chunks, [])

        resp =
          resp
          |> Req.Response.put_private(:baudrate_chunks, [chunk | chunks])
          |> Req.Response.put_private(:baudrate_size, size)

        {:cont, {req, resp}}
      end
    end
  end

  defp declared_content_length(resp) do
    case Req.Response.get_header(resp, "content-length") do
      [value | _] ->
        case Integer.parse(value) do
          {n, ""} -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Turns the collector's private state back into a plain binary body, or
  # `{:error, :response_too_large}` when the collector halted.
  defp finalize_streamed({:ok, %Req.Response{} = resp}) do
    if Req.Response.get_private(resp, :baudrate_too_large, false) do
      {:error, :response_too_large}
    else
      body =
        resp
        |> Req.Response.get_private(:baudrate_chunks, [])
        |> Enum.reverse()
        |> IO.iodata_to_binary()

      {:ok, %{resp | body: body}}
    end
  end

  defp finalize_streamed(other), do: other

  # Extracts and resolves the Location header from a redirect response.
  # Handles both absolute and relative URLs.
  defp get_redirect_location(resp_headers, base_uri) do
    case Map.get(resp_headers, "location") do
      [location | _] ->
        # Resolve relative URLs against the base
        resolved =
          case URI.parse(location) do
            %URI{scheme: nil} -> URI.merge(base_uri, location) |> URI.to_string()
            _ -> location
          end

        {:ok, resolved}

      _ ->
        :error
    end
  end

  defp validate_scheme(%URI{scheme: "https"}), do: :ok

  defp validate_scheme(%URI{scheme: "http", host: host})
       when host in ["localhost", "127.0.0.1"] do
    if @allow_http_localhost, do: :ok, else: {:error, :https_required}
  end

  defp validate_scheme(_), do: {:error, :https_required}

  defp validate_host(%URI{host: nil}), do: {:error, :invalid_host}
  defp validate_host(%URI{host: ""}), do: {:error, :invalid_host}
  defp validate_host(_), do: :ok

  if @bypass_ssrf do
    defp safe_resolve_ip(_host), do: {:ok, {127, 0, 0, 1}}
  else
    defp safe_resolve_ip(host) do
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
  end

  @doc false
  def private_ip?({127, _, _, _}), do: true
  def private_ip?({10, _, _, _}), do: true
  def private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  def private_ip?({192, 168, _, _}), do: true
  def private_ip?({169, 254, _, _}), do: true
  def private_ip?({0, _, _, _}), do: true
  # 100.64.0.0/10 — CGNAT / shared address space (RFC 6598)
  def private_ip?({100, b, _, _}) when b >= 64 and b <= 127, do: true
  # 192.0.0.0/24 — IETF protocol assignments (RFC 6890), e.g. the DNS64 and
  # NAT64 well-known addresses. Not globally routable.
  def private_ip?({192, 0, 0, _}), do: true
  # 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24 — TEST-NET-1/2/3 (RFC 5737)
  def private_ip?({192, 0, 2, _}), do: true
  def private_ip?({198, 51, 100, _}), do: true
  def private_ip?({203, 0, 113, _}), do: true
  # 198.18.0.0/15 — benchmarking (RFC 2544); routed to lab gear on some networks
  def private_ip?({198, b, _, _}) when b in 18..19, do: true
  # 224.0.0.0/4 multicast and 240.0.0.0/4 reserved (covers 255.255.255.255)
  def private_ip?({a, _, _, _}) when a >= 224, do: true
  # IPv6 unspecified address ::
  def private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  # IPv6 loopback ::1
  def private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # IPv6 fc00::/7
  def private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true
  # IPv6 fe80::/10
  def private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: true
  # fec0::/10 — site-local unicast, deprecated by RFC 3879 but still routed on
  # some networks, so a host resolving here is still reaching inside.
  def private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFEC0 and a <= 0xFEFF, do: true
  # IPv6 ff00::/8 (multicast)
  def private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFF00 and a <= 0xFFFF, do: true
  # IPv4-mapped IPv6 (::ffff:x.y.z.w) — extract embedded IPv4 and re-check
  def private_ip?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    import Bitwise
    private_ip?({hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF})
  end

  # NAT64 (64:ff9b::/96, RFC 6052) — extract embedded IPv4 and re-check, so a
  # host resolving to e.g. 64:ff9b::7f00:1 cannot reach 127.0.0.1 via a NAT64 gateway.
  def private_ip?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}) do
    import Bitwise
    private_ip?({hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF})
  end

  # NAT64 local-use prefix (64:ff9b:1::/48, RFC 8215). Unlike the well-known
  # prefix above, the embedded IPv4 sits at a deployment-chosen offset, so
  # there is nothing reliable to decode — and an address in this range is by
  # definition behind a local NAT64 translator, so refuse the prefix outright.
  def private_ip?({0x64, 0xFF9B, 1, _, _, _, _, _}), do: true

  # 192.88.99.0/24 — deprecated 6to4 relay anycast (RFC 7526).
  def private_ip?({192, 88, 99, _}), do: true

  # 6to4 (2002::/16, RFC 3056) — the second and third groups carry the embedded
  # IPv4, so 2002:7f00:1:: reaches 127.0.0.1 through a 6to4 relay. Same class of
  # bypass as NAT64 and ::ffff:, so it gets the same treatment.
  def private_ip?({0x2002, hi, lo, _, _, _, _, _}) do
    import Bitwise
    private_ip?({hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF})
  end

  # Teredo (2001::/32, RFC 4380) — another IPv4-over-IPv6 tunnel. The embedded
  # client address is obfuscated (bitwise complement of the last group pair)
  # rather than plain, so the prefix is refused outright: an ActivityPub peer
  # has no business being reachable only through a Teredo relay.
  def private_ip?({0x2001, 0, _, _, _, _, _, _}), do: true
  # 2001:db8::/32 — documentation (RFC 3849)
  def private_ip?({0x2001, 0x0DB8, _, _, _, _, _, _}), do: true
  # 100::/64 — discard-only prefix (RFC 6666)
  def private_ip?({0x0100, 0, 0, 0, _, _, _, _}), do: true

  # IPv4-compatible IPv6 (::a.b.c.d, deprecated) — extract embedded IPv4 and re-check.
  # Placed after the explicit :: / ::1 clauses so those keep their exact match.
  def private_ip?({0, 0, 0, 0, 0, 0, hi, lo}) do
    import Bitwise
    private_ip?({hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF})
  end

  def private_ip?(_), do: false

  defp truncate_body(body) when is_binary(body), do: String.slice(body, 0, 4096)
  defp truncate_body(body), do: body |> inspect() |> String.slice(0, 4096)

  defp user_agent do
    version = Application.spec(:baudrate, :vsn) |> to_string()
    "Baudrate/#{version} (+#{BaudrateWeb.Endpoint.url()})"
  end

  defp generic_user_agent do
    version = Application.spec(:baudrate, :vsn) |> to_string()
    "Baudrate/#{version}"
  end

  defp federation_config do
    Application.get_env(:baudrate, Baudrate.Federation, [])
  end
end
