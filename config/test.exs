import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :baudrate, Baudrate.Repo,
  username: "baudrate_db_user",
  password: "baudrate_database",
  # PGHOST lets CI reach the Postgres service container by name. PGPORT runs
  # the suite against a second server, such as production's major version in
  # a container. Both must be set here: the Repo does not pick up PGPORT on its
  # own, while raw Postgrex connections do, so setting it only in the
  # environment splits one test run across two servers.
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
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

# Disable settings ETS cache in tests — each test reads from its own Ecto
# sandbox transaction, avoiding cross-test interference via shared ETS state.
config :baudrate, settings_cache_enabled: false

# Run federation delivery synchronously in tests to avoid sandbox ownership
# errors from fire-and-forget Tasks that outlive the test process.
config :baudrate, federation_async: false

# The registration proof-of-work challenge (P5-D1) is off unless a test turns
# it on with the `registration_challenge_bits` setting: a LiveView test cannot
# run the browser worker that solves it, and only the tests about the
# challenge should have to answer one.
config :baudrate, registration_challenge_bits: 0

# The limits on new accounts (P5-D2, ADR 0064) are off unless a test turns them
# on with the `new_account_days` / `new_account_posts` settings: nearly every
# test posts from an account created a moment earlier, and only the tests
# about the limits should have to earn trust first.
config :baudrate, new_account_days: 0, new_account_posts: 0

# Run web push delivery synchronously in tests
config :baudrate, web_push_async: false

# Use ETS-backed sandbox for rate limiter in tests
config :baudrate, :rate_limiter, BaudrateWeb.RateLimiter.Sandbox

# Allow HTTP for localhost in tests (federation SSRF checks)
config :baudrate, allow_http_localhost: true

# Bypass SSRF checks in tests so Req.Test stubs can intercept HTTP calls
config :baudrate, :bypass_ssrf_check, true
config :baudrate, :req_test_options, plug: {Req.Test, Baudrate.Federation.HTTPClient}

# Each partition gets its own media cache directory. Cache tests wipe the
# directory in setup, so a shared one races against concurrent partitions.
config :baudrate, Baudrate.Media,
  media_cache_dir: Path.expand("../priv/static/uploads/media_cache_test#{partition}", __DIR__)

# WebAuthn — test server runs on http://localhost:#{4002 + partition}
config :wax_,
  origin: "http://localhost:#{4002 + partition}",
  rp_id: "localhost"

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
          "general.useragent.override" => "Wallaby/Firefox",
          # Firefox answers WebAuthn from the WebDriver virtual authenticator
          # (FeatureCase.add_virtual_authenticator/1) only with its software
          # token on and USB tokens off; otherwise requests fail or hang.
          "security.webauth.webauthn_enable_softtoken" => true,
          "security.webauth.webauthn_enable_usbtoken" => false,
          # Downloads (the data export archive) are saved without a prompt into
          # tmp/wallaby_downloads, where data_export_test.exs looks for them.
          "browser.download.folderList" => 2,
          "browser.download.dir" => Path.expand("../tmp/wallaby_downloads", __DIR__),
          "browser.download.useDownloadDir" => true,
          "browser.download.always_ask_before_handling_new_types" => false,
          "browser.helperApps.neverAsk.saveToDisk" => "application/zip"
        }
      }
    }
  ],
  screenshot_on_failure: true,
  screenshot_dir: "tmp/wallaby_screenshots"

# Media cache warming is opportunistic; disable it in tests so an incidental
# outbound fetch does not make unrelated tests depend on the HTTP stub.
config :baudrate, :media_warm_enabled, false

# Fixed, checked-in keys, so this environment exercises the keyring write path
# (ADR 0038): values are written self-describing and bound to their row. These
# are not secrets: production reads BAUDRATE_AUTH_KEYS and
# BAUDRATE_SIGNING_KEYS from the environment.
config :baudrate, Baudrate.Crypto.Keyring,
  auth_keys: [
    %{id: "testauth", key: Base.decode64!("TtVvLIlfpz47PogOCeFazt+f9V8oH0Npx2mLKIRuHbA=")}
  ],
  signing_keys: [
    %{id: "testsign", key: Base.decode64!("SwzYivkJMfXxkkSKv3DK0LXgDGIpjPSD/r05mrcQqdE=")}
  ]
