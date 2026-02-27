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
Ecto.Adapters.SQL.Sandbox.mode(Baudrate.Repo, :manual)

BaudrateWeb.RateLimiter.Sandbox.start()

if :feature in (ExUnit.configuration()[:include] || []) do
  BaudrateWeb.SeleniumServer.ensure_running()
end
