defmodule Baudrate.Federation.HTTPClient do
  @moduledoc """
  Safe HTTP client for ActivityPub federation with SSRF protection.

  Wraps `Req` with security constraints:
    * HTTPS only (except in test/dev for localhost)
    * Private/loopback IP rejection
    * Configurable timeouts and redirect limits
    * Response body size cap
    * Instance-identifying User-Agent header
  """

  require Logger

  @doc """
  Performs a GET request with SSRF protection and federation constraints.
  """
  def get(url, opts \\ []) do
    with :ok <- validate_url(url) do
      config = federation_config()
      headers = Keyword.get(opts, :headers, [])

      req_opts = [
        url: url,
        headers: [{"user-agent", user_agent()}, {"accept", "application/activity+json"} | headers],
        connect_options: [timeout: config[:http_connect_timeout]],
        receive_timeout: config[:http_receive_timeout],
        max_redirects: config[:max_redirects],
        redirect_log_level: false,
        max_retries: 0,
        decode_body: false
      ]

      case Req.get(req_opts) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          if byte_size(body) > config[:max_payload_size] do
            {:error, :response_too_large}
          else
            {:ok, %{status: status, body: body}}
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
  """
  def post(url, body, headers \\ [], _opts \\ []) do
    with :ok <- validate_url(url) do
      config = federation_config()

      all_headers = [
        {"user-agent", user_agent()},
        {"content-type", "application/activity+json"}
        | headers
      ]

      req_opts = [
        url: url,
        headers: all_headers,
        body: body,
        connect_options: [timeout: config[:http_connect_timeout]],
        receive_timeout: config[:http_receive_timeout],
        max_redirects: 0,
        max_retries: 0,
        decode_body: false
      ]

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
  Validates a URL for safe federation use.

  Rejects:
    * Non-HTTPS URLs (except localhost in dev/test)
    * URLs resolving to private/loopback IP ranges
    * Malformed URLs
  """
  def validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- validate_scheme(uri),
         :ok <- validate_host(uri),
         :ok <- validate_not_private(uri.host) do
      :ok
    end
  end

  def validate_url(_), do: {:error, :invalid_url}

  defp validate_scheme(%URI{scheme: "https"}), do: :ok

  defp validate_scheme(%URI{scheme: "http", host: host})
       when host in ["localhost", "127.0.0.1"] do
    if Mix.env() in [:dev, :test], do: :ok, else: {:error, :https_required}
  end

  defp validate_scheme(_), do: {:error, :https_required}

  defp validate_host(%URI{host: nil}), do: {:error, :invalid_host}
  defp validate_host(%URI{host: ""}), do: {:error, :invalid_host}
  defp validate_host(_), do: :ok

  defp validate_not_private(host) do
    case resolve_ip(host) do
      {:ok, ip} ->
        if private_ip?(ip) do
          {:error, :private_ip}
        else
          :ok
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
  # IPv6 loopback
  def private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # IPv6 fc00::/7
  def private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true
  # IPv6 fe80::/10
  def private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: true
  def private_ip?(_), do: false

  defp user_agent do
    "Baudrate/0.1.0 (+#{BaudrateWeb.Endpoint.url()})"
  end

  defp federation_config do
    Application.get_env(:baudrate, Baudrate.Federation, [])
  end
end
