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

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :baudrate, Baudrate.Mailer, adapter: Swoosh.Adapters.Local

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

config :gettext, default_locale: "en"
config :baudrate, BaudrateWeb.Gettext, default_locale: "en", locales: ~w(en zh_TW)

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
