import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :baudrate, Baudrate.Repo,
  username: "baudrate_db_user",
  password: "baudrate_database",
  hostname: "localhost",
  database: "baudrate_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Start the server for browser (feature) tests.
# Each partition gets its own port to avoid collisions.
partition = String.to_integer(System.get_env("MIX_TEST_PARTITION") || "1")

config :baudrate, BaudrateWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002 + partition],
  secret_key_base: "qMZzvuSIyA9yTsYnWHQ2a3Yj1ICdEOTpsRVEwhHaN2mE1GqbomjgMl5G7cw/XUxL",
  server: true

# Enable Ecto SQL sandbox for browser tests (Wallaby)
config :baudrate, :sql_sandbox, true

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Run federation delivery synchronously in tests to avoid sandbox ownership
# errors from fire-and-forget Tasks that outlive the test process.
config :baudrate, federation_async: false

# Run web push delivery synchronously in tests
config :baudrate, web_push_async: false
config :baudrate, :req_web_push_test_options, plug: {Req.Test, Baudrate.Notification.WebPush}

# Use ETS-backed sandbox for rate limiter in tests
config :baudrate, :rate_limiter, BaudrateWeb.RateLimiter.Sandbox

# Allow HTTP for localhost in tests (federation SSRF checks)
config :baudrate, allow_http_localhost: true

# Bypass SSRF checks in tests so Req.Test stubs can intercept HTTP calls
config :baudrate, :bypass_ssrf_check, true
config :baudrate, :req_test_options, plug: {Req.Test, Baudrate.Federation.HTTPClient}

# Wallaby browser testing (Firefox via Selenium)
config :wallaby,
  driver: Wallaby.Selenium,
  base_url: "http://localhost:#{4002 + partition}",
  selenium: [
    capabilities: %{
      "browserName" => "firefox",
      "moz:firefoxOptions" => %{
        "args" => ["-headless"],
        "prefs" => %{
          "general.useragent.override" => "Wallaby/Firefox"
        }
      }
    }
  ],
  screenshot_on_failure: true,
  screenshot_dir: "tmp/wallaby_screenshots"
