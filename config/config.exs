# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :baudrate,
  ecto_repos: [Baudrate.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :baudrate, BaudrateWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BaudrateWeb.ErrorHTML, json: BaudrateWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Baudrate.PubSub,
  live_view: [signing_salt: "nvvyKHu9"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  baudrate: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
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

# Rate limiting
config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 300_000 * 3, cleanup_interval_ms: 300_000]}

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Federation
config :baudrate, Baudrate.Federation,
  signature_max_age: 30,
  actor_cache_ttl: 86_400,
  max_payload_size: 262_144,
  max_content_size: 65_536,
  http_connect_timeout: 10_000,
  http_receive_timeout: 30_000,
  max_redirects: 3,
  delivery_max_attempts: 6,
  delivery_poll_interval: 60_000,
  delivery_batch_size: 50,
  delivery_backoff_schedule: [60, 300, 1800, 7200, 43200, 86400],
  stale_actor_cleanup_interval: 86_400_000,
  stale_actor_max_age: 2_592_000

config :gettext, default_locale: "en"
config :baudrate, BaudrateWeb.Gettext, default_locale: "en", locales: ~w(en zh_TW)

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
