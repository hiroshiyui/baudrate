defmodule BaudrateWeb.Router do
  @moduledoc """
  Router defining the request pipeline and route scopes.

  ## Route Structure

  Five main scopes, each with different auth requirements:

    1. **Public** (`/login`, `/setup`) — `live_session :public` with
       `:redirect_if_authenticated` hook. `/setup` is outside any live_session
       and uses the `:setup` layout.

    2. **TOTP** (`/totp/*`) — `live_session :totp` with `:require_password_auth`
       hook. For users who passed password auth but need TOTP verification/setup.

    3. **Session controller** (`/auth/*`) — POST-only endpoints for session
       mutations. Split into two scopes with separate rate-limit pipelines
       (`:rate_limit_login` for `/auth/session`, `:rate_limit_totp` for TOTP).

    4. **Authenticated** (`/articles/new`, `/profile`, `/admin/*`) —
       `live_session :authenticated` with `:require_auth` hook. All pages
       requiring full authentication. Defined before public_browsable to
       ensure literal paths match before wildcard `:slug` patterns.

    5. **Public browsable** (`/`, `/boards/:slug`, `/articles/:slug`) —
       `live_session :public_browsable` with `:optional_auth` hook. Accessible
       to both guests and authenticated users. Private boards redirect guests
       to `/login`.

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

  pipeline :activity_pub do
    plug BaudrateWeb.Plugs.RateLimit, action: :activity_pub
  end

  pipeline :activity_pub_inbox do
    plug BaudrateWeb.Plugs.RateLimit, action: :activity_pub
    plug BaudrateWeb.Plugs.CacheBody
    plug BaudrateWeb.Plugs.VerifyHTTPSignature
    plug BaudrateWeb.Plugs.RateLimitDomain
  end

  pipeline :rate_limit_login do
    plug BaudrateWeb.Plugs.RateLimit, action: :login
  end

  pipeline :rate_limit_totp do
    plug BaudrateWeb.Plugs.RateLimit, action: :totp
  end

  # ActivityPub / Federation (content-negotiated, no session)
  scope "/.well-known", BaudrateWeb do
    pipe_through :activity_pub

    get "/webfinger", ActivityPubController, :webfinger
    get "/nodeinfo", ActivityPubController, :nodeinfo_redirect
  end

  scope "/nodeinfo", BaudrateWeb do
    pipe_through :activity_pub

    get "/2.1", ActivityPubController, :nodeinfo
  end

  scope "/ap", BaudrateWeb do
    pipe_through :activity_pub

    get "/users/:username", ActivityPubController, :user_actor
    get "/users/:username/outbox", ActivityPubController, :user_outbox
    get "/boards/:slug", ActivityPubController, :board_actor
    get "/boards/:slug/outbox", ActivityPubController, :board_outbox
    get "/site", ActivityPubController, :site_actor
    get "/articles/:slug", ActivityPubController, :article
  end

  scope "/ap", BaudrateWeb do
    pipe_through :activity_pub_inbox

    post "/inbox", ActivityPubController, :shared_inbox
    post "/users/:username/inbox", ActivityPubController, :user_inbox
    post "/boards/:slug/inbox", ActivityPubController, :board_inbox
  end

  # Public (redirect if already authenticated)
  scope "/", BaudrateWeb do
    pipe_through :browser

    live_session :public,
      layout: {BaudrateWeb.Layouts, :app},
      on_mount: [{BaudrateWeb.AuthHooks, :redirect_if_authenticated}] do
      live "/login", LoginLive
      live "/register", RegisterLive
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

  # Authenticated routes (defined before public_browsable to ensure literal
  # paths like /articles/new match before wildcard /articles/:slug)
  scope "/", BaudrateWeb do
    pipe_through :browser

    live_session :authenticated,
      layout: {BaudrateWeb.Layouts, :app},
      on_mount: [{BaudrateWeb.AuthHooks, :require_auth}] do
      live "/boards/:slug/articles/new", ArticleNewLive
      live "/articles/new", ArticleNewLive
      live "/profile", ProfileLive
      live "/profile/totp-reset", TotpResetLive
      live "/profile/recovery-codes", RecoveryCodesLive
      live "/admin/settings", Admin.SettingsLive
      live "/admin/pending-users", Admin.PendingUsersLive
    end

    delete "/logout", SessionController, :delete
  end

  # Public browsable routes (accessible to guests and authenticated users)
  scope "/", BaudrateWeb do
    pipe_through :browser

    live_session :public_browsable,
      layout: {BaudrateWeb.Layouts, :app},
      on_mount: [{BaudrateWeb.AuthHooks, :optional_auth}] do
      live "/", HomeLive
      live "/boards/:slug", BoardLive
      live "/articles/:slug", ArticleLive
    end
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
