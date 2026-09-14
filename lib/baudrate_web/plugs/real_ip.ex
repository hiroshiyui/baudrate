defmodule BaudrateWeb.Plugs.RealIp do
  @moduledoc """
  Plug to extract the real client IP from a reverse proxy header.

  In production, `conn.remote_ip` is typically the reverse proxy's IP,
  making per-IP rate limiting ineffective (all requests share one bucket).
  This plug reads the original client IP from a configurable header
  (e.g., `x-forwarded-for`) and overwrites `conn.remote_ip`.

  ## Configuration

  Only activates when a header is configured (safe no-op by default):

      # config/prod.exs
      config :baudrate, BaudrateWeb.Plugs.RealIp,
        header: "x-forwarded-for",
        trusted_proxies: ["127.0.0.1", "::1", "10.0.0.0/8"]

  ## Security — fail closed

  The header is honored **only** when the immediate peer (`conn.remote_ip`)
  matches one of the listed addresses or CIDR ranges. Requests arriving
  directly from untrusted peers cannot spoof their IP via the header.

    * Unconfigured `trusted_proxies` defaults to `["127.0.0.1", "::1"]` — the
      only peer that can plausibly be a same-host reverse proxy.
    * An **empty list** means trust nobody, which is what an operator writing
      `trusted_proxies: []` intends.

  There is deliberately no trust-everything mode. A spoofable client IP defeats
  every per-IP rate limit (login, TOTP, AP inbox, feeds, search) and poisons the
  persisted `ip_address` audit trail, so a broad CIDR entry is the correct way
  to widen trust.

  A proxy that is not on loopback is configured at runtime via
  `BAUDRATE_TRUSTED_PROXIES` (comma-separated IPs or CIDR ranges); the header
  name is overridable with `BAUDRATE_REAL_IP_HEADER`.

  The operator must still configure their reverse proxy to **set** (not append
  to) the header: this plug always extracts the **leftmost** (first) IP, which
  is the client IP when the proxy sets the header.

  ## IPv4-mapped IPv6 addresses

  In production the endpoint listens on the IPv6 any-address
  (`{0, 0, 0, 0, 0, 0, 0, 0}`), a dual-stack socket. An IPv4 peer, including
  nginx connecting from `127.0.0.1`, therefore arrives as the IPv4-mapped
  address `::ffff:127.0.0.1`. Every address (the peer, the forwarded client
  IP, and `trusted_proxies` entries) is passed through `unmap_ipv4/1` before
  it is compared or stored. Otherwise the loopback proxy never matches
  `"127.0.0.1"`, the header is never honored, and every visitor shares the
  proxy's rate-limit bucket and audit IP. That was the production behaviour
  before this was fixed.

  Only `::ffff:0:0/96` is unmapped, because on a dual-stack socket it is the
  *same* IPv4 host. NAT64 (`64:ff9b::/96`), 6to4, and the other IPv4-embedding
  prefixes are different hosts. Decoding them would widen trust, the opposite
  of `Federation.HTTPClient.private_ip?/1`, where decoding only adds denials.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    forwarded =
      case config_header() do
        nil -> nil
        header -> conn |> get_req_header(header) |> List.first()
      end

    %{conn | remote_ip: client_ip(conn.remote_ip, forwarded)}
  end

  @doc """
  Resolves the client IP from the immediate `peer_ip` and the raw value of the
  configured forwarding header (`nil` when absent or when no header is
  configured).

  The leftmost address in `forwarded` is used only when the peer is a trusted
  proxy and the address parses. Otherwise the peer itself is the client. The
  result is always unmapped (see "IPv4-mapped IPv6 addresses"). Shared by this
  plug and `BaudrateWeb.Helpers.extract_peer_ip/1`, so HTTP requests and
  LiveView sockets always reach the same verdict.
  """
  @spec client_ip(:inet.ip_address() | nil, String.t() | nil) :: :inet.ip_address() | nil
  def client_ip(peer_ip, forwarded) do
    peer_ip = unmap_ipv4(peer_ip)

    with value when is_binary(value) <- forwarded,
         true <- peer_trusted?(peer_ip),
         {:ok, ip} <- value |> String.split(",") |> List.first() |> String.trim() |> parse_ip() do
      ip
    else
      _ -> peer_ip
    end
  end

  @doc """
  Converts an IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) to its IPv4 tuple.
  Any other value, including other IPv4-embedding IPv6 prefixes, is returned
  unchanged.
  """
  @spec unmap_ipv4(:inet.ip_address() | nil) :: :inet.ip_address() | nil
  def unmap_ipv4({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    {div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)}
  end

  def unmap_ipv4(ip), do: ip

  defp config_header do
    Application.get_env(:baudrate, __MODULE__, [])
    |> Keyword.get(:header)
  end

  # Loopback-only by default. An unconfigured allow-list must not mean "trust
  # every peer" — see the Security section above.
  @default_trusted_proxies ["127.0.0.1", "::1"]

  defp config_trusted_proxies do
    case Application.get_env(:baudrate, __MODULE__, []) |> Keyword.get(:trusted_proxies) do
      list when is_list(list) -> list
      _ -> @default_trusted_proxies
    end
  end

  @doc """
  Returns `true` if `peer_ip` (an `:inet.ip_address/0` tuple or string) is in
  the `trusted_proxies` allow-list.

  With no allow-list configured this is loopback-only. With an explicitly empty
  list it is always `false`.
  """
  @spec peer_trusted?(:inet.ip_address() | String.t() | nil) :: boolean()
  def peer_trusted?(nil), do: false

  def peer_trusted?(peer_ip) when is_binary(peer_ip) do
    case :inet.parse_address(String.to_charlist(peer_ip)) do
      {:ok, ip} -> peer_trusted?(ip)
      _ -> false
    end
  end

  def peer_trusted?(peer_ip) when is_tuple(peer_ip) do
    peer_ip = unmap_ipv4(peer_ip)
    Enum.any?(config_trusted_proxies(), &match_trusted?(&1, peer_ip))
  end

  defp match_trusted?(spec, peer_ip) when is_binary(spec) do
    case String.split(spec, "/", parts: 2) do
      [ip_str] ->
        case :inet.parse_address(String.to_charlist(ip_str)) do
          {:ok, ip} -> unmap_ipv4(ip) == peer_ip
          _ -> false
        end

      [ip_str, prefix_str] ->
        with {prefix, ""} <- Integer.parse(prefix_str),
             {:ok, base} <- :inet.parse_address(String.to_charlist(ip_str)),
             {base, prefix} = unmap_cidr(base, prefix),
             true <- tuple_size(base) == tuple_size(peer_ip) do
          in_cidr?(base, prefix, peer_ip)
        else
          _ -> false
        end
    end
  end

  defp match_trusted?(_, _), do: false

  # A CIDR written in mapped form (e.g. "::ffff:10.0.0.0/104") names IPv4
  # hosts. Since peers are unmapped before matching, express the range in
  # IPv4 too. A mapped base with a prefix shorter than /96 would span beyond
  # the mapped block, so it is left as IPv6 and matches no unmapped peer
  # (fail closed).
  defp unmap_cidr({0, 0, 0, 0, 0, 0xFFFF, _, _} = base, prefix) when prefix >= 96 do
    {unmap_ipv4(base), prefix - 96}
  end

  defp unmap_cidr(base, prefix), do: {base, prefix}

  defp in_cidr?(base, prefix, ip) do
    bits =
      case tuple_size(base) do
        4 -> 8
        8 -> 16
      end

    base_int = ip_to_int(base, bits)
    ip_int = ip_to_int(ip, bits)
    total = tuple_size(base) * bits
    shift = total - prefix

    if shift < 0 or shift > total do
      false
    else
      Bitwise.bsr(Bitwise.bxor(base_int, ip_int), shift) == 0
    end
  end

  defp ip_to_int(tuple, bits) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> Bitwise.bsl(acc, bits) + part end)
  end

  defp parse_ip(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip} -> {:ok, unmap_ipv4(ip)}
      {:error, _} -> :error
    end
  end
end
