{:ok, _} = Application.ensure_all_started(:wallaby)

# Patch Wallaby.HTTPClient for W3C WebDriver compatibility (Selenium 4).
# Wallaby 0.30 sends empty string "" as POST body for requests with no params
# (e.g. element/clear, element/click). Selenium 4 expects valid JSON "{}".
# Also transforms set_value from JSON Wire Protocol to W3C format.
# Suppress the "redefining module" warning since this is intentional.
Code.put_compiler_option(:ignore_module_conflict, true)
Code.compile_file("test/support/wallaby_httpclient_patch.exs")
Code.put_compiler_option(:ignore_module_conflict, false)

ExUnit.start(exclude: [:feature])

# Seed the roles and permissions once, committed, before the sandbox takes
# over. About twenty async test files (and `setup_user/2`) call
# `seed_roles_and_permissions/0` in their setup. Against an empty table each
# one inserted the same unique names inside its own sandbox transaction, and
# PostgreSQL makes the second insert wait until the first transaction ends,
# which is the whole of another test. Under load that wait passed the
# 15-second timeout (CI, 2026-09-24). Against committed rows the insert
# conflicts at once and `on_conflict: :nothing` returns. A test that inserts a
# role or permission of its own therefore uses a name nothing seeds.
Baudrate.Setup.seed_roles_and_permissions()

Ecto.Adapters.SQL.Sandbox.mode(Baudrate.Repo, :manual)

BaudrateWeb.RateLimiter.Sandbox.start()

if :feature in (ExUnit.configuration()[:include] || []) do
  BaudrateWeb.SeleniumServer.ensure_running()
end
