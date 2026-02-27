{:ok, _} = Application.ensure_all_started(:wallaby)

ExUnit.start(exclude: [:feature])
Ecto.Adapters.SQL.Sandbox.mode(Baudrate.Repo, :manual)

BaudrateWeb.RateLimiter.Sandbox.start()

if :feature in (ExUnit.configuration()[:include] || []) do
  BaudrateWeb.SeleniumServer.ensure_running()
end
