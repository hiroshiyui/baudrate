defmodule BaudrateWeb.Router do
  use BaudrateWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BaudrateWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self' ws: wss:; frame-ancestors 'none'; form-action 'self'; base-uri 'self'",
      "permissions-policy" => "geolocation=(), microphone=(), camera=()",
      "x-frame-options" => "DENY"
    }
    plug BaudrateWeb.Plugs.SetLocale
    plug BaudrateWeb.Plugs.EnsureSetup
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :rate_limit_login do
    plug BaudrateWeb.Plugs.RateLimit, action: :login
  end

  pipeline :rate_limit_totp do
    plug BaudrateWeb.Plugs.RateLimit, action: :totp
  end

  # Public (redirect if already authenticated)
  scope "/", BaudrateWeb do
    pipe_through :browser

    live_session :public, on_mount: [{BaudrateWeb.AuthHooks, :redirect_if_authenticated}] do
      live "/login", LoginLive
    end

    live "/setup", SetupLive
  end

  # TOTP pages (require password auth only)
  scope "/totp", BaudrateWeb do
    pipe_through :browser

    live_session :totp, on_mount: [{BaudrateWeb.AuthHooks, :require_password_auth}] do
      live "/verify", TotpVerifyLive
      live "/setup", TotpSetupLive
    end
  end

  # Session controller routes (POST endpoints for session mutations)
  scope "/auth", BaudrateWeb do
    pipe_through [:browser, :rate_limit_login]

    post "/session", SessionController, :create
  end

  scope "/auth", BaudrateWeb do
    pipe_through [:browser, :rate_limit_totp]

    post "/totp-verify", SessionController, :totp_verify
    post "/totp-enable", SessionController, :totp_enable
  end

  # Authenticated routes
  scope "/", BaudrateWeb do
    pipe_through :browser

    live_session :authenticated, on_mount: [{BaudrateWeb.AuthHooks, :require_auth}] do
      live "/", HomeLive
    end

    delete "/logout", SessionController, :delete
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:baudrate, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BaudrateWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
