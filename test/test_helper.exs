ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Baudrate.Repo, :manual)

Mox.defmock(BaudrateWeb.RateLimiterMock, for: BaudrateWeb.RateLimiter)
