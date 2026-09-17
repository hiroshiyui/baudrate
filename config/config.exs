# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Redact credentials from request logs. Phoenix only filters "password" by
# default; step-up forms also send TOTP/recovery "code"s, and data export
# downloads carry a single-use "token" (ADR 0023). Matching is by substring,
# so e.g. "current_password", "challenge_token" and "invite_code" are covered.
config :phoenix, :filter_parameters, ["password", "token", "code", "secret"]

config :baudrate,
  ecto_repos: [Baudrate.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :baudrate, BaudrateWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BaudrateWeb.ErrorHTML, json: BaudrateWeb.ErrorJSON],
    layout: {BaudrateWeb.Layouts, :root}
  ],
  pubsub_server: Baudrate.PubSub,
  live_view: [signing_salt: "nvvyKHu9"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.2",
  # The CI image ships a checksum-verified binary (ci/image/Dockerfile); unset,
  # the binary is installed under _build as usual.
  path: System.get_env("MIX_ESBUILD_PATH"),
  baudrate: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  service_worker: [
    args:
      ~w(js/service_worker.js --bundle --target=es2022 --outdir=../priv/static --asset-names=[name]),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  path: System.get_env("MIX_TAILWIND_PATH"),
  baudrate: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Rate limiting: Hammer 7 uses a `use Hammer` store (`BaudrateWeb.RateLimit`)
# started in the supervision tree — no global `config :hammer, backend:` needed.

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Federation
config :baudrate, Baudrate.Federation,
  signature_max_age: 300,
  actor_cache_ttl: 86_400,
  max_payload_size: 262_144,
  max_content_size: 65_536,
  http_connect_timeout: 10_000,
  http_receive_timeout: 30_000,
  # Whole-request deadline (connect + all reads); receive_timeout is per read.
  http_request_timeout: 60_000,
  max_redirects: 3,
  delivery_max_attempts: 6,
  delivery_poll_interval: 60_000,
  delivery_max_concurrency: 10,
  delivery_backoff_schedule: [60, 300, 1800, 7200, 43200, 86400],
  # Per-domain circuit breaker (`Federation.DeliveryCircuits`): consecutive
  # unreachable results that open a domain's circuit, and how long each
  # successive opening lasts, in seconds.
  delivery_circuit_threshold: 5,
  delivery_circuit_schedule: [300, 1800, 7200, 21600, 43200, 86400],
  # Waiting jobs older than this (seconds) are abandoned.
  delivery_max_age: 604_800,
  # Inbound queue (`Federation.InboundWorker`). Keep the concurrency below the
  # database pool size, so web requests always find a connection.
  inbound_max_concurrency: 4,
  inbound_max_attempts: 3,
  inbound_poll_interval: 30_000,
  inbound_task_timeout: 300_000,
  # 24 hours in ms (Process.send_after)
  stale_actor_cleanup_interval: 86_400_000,
  # 30 days in seconds (matches actor_cache_ttl convention)
  stale_actor_max_age: 2_592_000

# Media proxy — local cache of remote images, so no viewer's browser ever
# contacts a third-party host. See `Baudrate.Media.Proxy`.
config :baudrate, Baudrate.Media,
  # Entries untouched for this long are evicted by SessionCleaner.
  media_cache_ttl_days: 30,
  # Hard ceiling; oldest-first eviction kicks in above this.
  media_cache_max_bytes: 2 * 1024 * 1024 * 1024

# WebAuthn / FIDO2 — base configuration (attestation policy and flags).
# origin and rp_id are environment-specific; set in dev.exs, test.exs, and runtime.exs.
# attestation and user_verification default to "none" and "preferred" (strings) in Wax.Challenge.

config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :gettext, default_locale: "en"
config :baudrate, BaudrateWeb.Gettext, default_locale: "en", locales: ~w(en zh_TW)

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
