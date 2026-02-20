defmodule BaudrateWeb.Router do
  @moduledoc """
  Router defining the request pipeline and route scopes.

  ## Route Structure

  Four main scopes, each with different auth requirements:

    1. **Public** (`/login`, `/setup`) — `live_session :public` with
       `:redirect_if_authenticated` hook. `/setup` is outside any live_session
       and uses the `:setup` layout.

    2. **TOTP** (`/totp/*`) — `live_session :totp` with `:require_password_auth`
       hook. For users who passed password auth but need TOTP verification/setup.

    3. **Session controller** (`/auth/*`) — POST-only endpoints for session
       mutations. Split into two scopes with separate rate-limit pipelines
       (`:rate_limit_login` for `/auth/session`, `:rate_limit_totp` for TOTP).

    4. **Authenticated** (`/`) — `live_session :authenticated` with
       `:require_auth` hook. All pages requiring full authentication.

  ## Browser Pipeline

  All browser requests pass through:

      :accepts → :fetch_session → :fetch_live_flash → :put_root_layout →
      :protect_from_forgery → :put_secure_browser_headers (CSP, Permissions-Policy,
      X-Frame-Options) → SetLocale → EnsureSetup → RefreshSession
  """

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
    plug BaudrateWeb.Plugs.RefreshSession
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

    live_session :public,
      layout: {BaudrateWeb.Layouts, :app},
      on_mount: [{BaudrateWeb.AuthHooks, :redirect_if_authenticated}] do
      live "/login", LoginLive
    end

    live "/setup", SetupLive
  end

  # TOTP pages (require password auth only)
  scope "/totp", BaudrateWeb do
    pipe_through :browser

    live_session :totp,
      layout: {BaudrateWeb.Layouts, :app},
      on_mount: [{BaudrateWeb.AuthHooks, :require_password_auth}] do
      live "/verify", TotpVerifyLive
      live "/setup", TotpSetupLive
      live "/recovery", RecoveryCodeVerifyLive
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
    post "/totp-reset", SessionController, :totp_reset
    post "/recovery-verify", SessionController, :recovery_verify
    post "/ack-recovery-codes", SessionController, :ack_recovery_codes
  end

  # Authenticated routes
  scope "/", BaudrateWeb do
    pipe_through :browser

    live_session :authenticated,
      layout: {BaudrateWeb.Layouts, :app},
      on_mount: [{BaudrateWeb.AuthHooks, :require_auth}] do
      live "/", HomeLive
      live "/boards/:slug", BoardLive
      live "/profile", ProfileLive
      live "/profile/totp-reset", TotpResetLive
      live "/profile/recovery-codes", RecoveryCodesLive
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
