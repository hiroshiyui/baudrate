import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/baudrate start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :baudrate, BaudrateWeb.Endpoint, server: true
end

if config_env() != :test do
  config :baudrate, BaudrateWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :baudrate, Baudrate.Repo,
    ssl: System.get_env("DATABASE_SSL", "true") != "false",
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  # Gates the first-run setup wizard. Deliberately not `raise`d on here:
  # `runtime.exs` runs before the Repo starts, so it cannot tell whether setup
  # has already completed, and a raise would brick the node on restart.
  # Enforcement lives in `Baudrate.Setup.InstallationKey` + `EnsureSetup`, which
  # answer 503 while setup is incomplete and no key is set.
  installation_key =
    case System.get_env("INSTALLATION_KEY") do
      nil -> nil
      "" -> nil
      key -> key
    end

  config :baudrate, :installation_key, installation_key

  # Reverse proxies whose `x-forwarded-for` may be believed. `RealIp` is fail
  # closed — an unlisted peer cannot spoof its IP — so a proxy that is not on
  # loopback must be named here. Raising on a malformed entry is safe: this is
  # a static configuration error, not a transient condition.
  trusted_proxies =
    case System.get_env("BAUDRATE_TRUSTED_PROXIES") do
      blank when blank in [nil, ""] ->
        ["127.0.0.1", "::1"]

      raw ->
        raw
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end

  for spec <- trusted_proxies do
    [ip_string | mask] = String.split(spec, "/", parts: 2)

    valid_ip? = match?({:ok, _}, :inet.parse_address(String.to_charlist(ip_string)))
    valid_mask? = mask == [] or match?({_, ""}, Integer.parse(hd(mask)))

    unless valid_ip? and valid_mask? do
      raise """
      BAUDRATE_TRUSTED_PROXIES contains an invalid entry: #{inspect(spec)}

      Expected a comma-separated list of IP addresses or CIDR ranges, e.g.
          BAUDRATE_TRUSTED_PROXIES="127.0.0.1,::1,10.0.0.0/8"
      """
    end
  end

  config :baudrate, BaudrateWeb.Plugs.RealIp,
    header: System.get_env("BAUDRATE_REAL_IP_HEADER", "x-forwarded-for"),
    trusted_proxies: trusted_proxies

  config :wax_,
    origin: "https://#{host}",
    rp_id: host

  config :baudrate, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :baudrate, BaudrateWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      # Drain in-flight requests for up to 30s on shutdown (SIGTERM).
      # Works with systemd TimeoutStopSec=35 and nginx proxy_next_upstream
      # to achieve near-zero downtime deploys.
      thousand_island_options: [shutdown_timeout: 30_000]
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :baudrate, BaudrateWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :baudrate, BaudrateWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
