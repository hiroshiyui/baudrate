defmodule BaudrateWeb.FeatureCase do
  @moduledoc """
  Test case for browser-based feature tests using Wallaby + Selenium.

  Uses `import Wallaby.Feature` + `use Wallaby.DSL` instead of
  `use Wallaby.Feature` to control session creation ourselves. This is
  necessary because `Wallaby.Feature.__using__` registers a `setup` that
  runs before our setup, causing the W3C `create_session_fn` to be nil.

  ## Usage

      defmodule BaudrateWeb.Features.SmokeTest do
        use BaudrateWeb.FeatureCase, async: false

        @moduletag :feature

        feature "visits the home page", %{session: session} do
          session
          |> visit("/")
          |> assert_has(Query.css("body"))
        end
      end
  """

  use ExUnit.CaseTemplate
  use Wallaby.DSL

  using do
    quote do
      use Wallaby.DSL

      import Wallaby.Feature
      import BaudrateWeb.ConnCase, only: [setup_user: 1, log_in_user: 2]

      import BaudrateWeb.FeatureCase,
        only: [
          log_in_via_browser: 2,
          submit_login_form: 3,
          log_out_via_browser: 1,
          start_another_session: 0,
          wait_for_path: 2,
          log_in_with_totp_via_browser: 3,
          log_in_admin_via_browser: 1,
          visit_admin: 3,
          enable_totp!: 1,
          totp_code: 2,
          create_board: 1,
          create_article: 3,
          js_value: 2,
          add_virtual_authenticator: 1
        ]
    end
  end

  setup _tags do
    # Checkout Ecto sandbox in shared mode for browser tests
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Baudrate.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Baudrate.Repo, {:shared, self()})

    # Always allow rate limit checks in browser tests — all requests come from
    # 127.0.0.1 so real Hammer rate limiting would trigger across sequential tests
    BaudrateWeb.RateLimiter.Sandbox.set_global_response({:allow, 1})

    # Reset the real Hammer store between tests as a backstop (all rate checks
    # route through the sandbox above, but this keeps the store clean if a test
    # opts into the real backend).
    BaudrateWeb.RateLimit.reset_all()

    # Ensure setup wizard doesn't redirect — insert setup_completed setting
    ensure_setup_completed()

    {:ok, session: start_another_session()}
  end

  @doc """
  Starts a browser session that shares the test's database sandbox and ends
  when the test does. The setup creates the first one; call this for a second
  browser, e.g. to watch another signed-in device.
  """
  def start_another_session do
    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(Baudrate.Repo, self())

    {:ok, session} =
      Wallaby.start_session(
        create_session_fn: &BaudrateWeb.W3CWebDriver.create_session/2,
        metadata: metadata
      )

    ExUnit.Callbacks.on_exit(fn -> Wallaby.end_session(session) end)
    session
  end

  @doc """
  Logs in a user via the browser login form.

  Only works for role "user" — admin/moderator require TOTP which needs
  a separate flow. The password must be "Password123!x" (the default from
  `setup_user/1`).
  """
  def log_in_via_browser(session, user) do
    session
    |> submit_login_form(user, "Password123!x")
    # Wait for redirect to complete — the home page h1 confirms full auth
    |> assert_has(Query.css("h1", text: "Welcome, #{user.username}!"))
  end

  @doc """
  Fills in and submits the login form, without waiting for the outcome.
  """
  def submit_login_form(session, user, password) do
    session
    |> visit("/login")
    |> fill_in(Query.css("#login_username"), with: user.username)
    |> fill_in(Query.css("#login_password"), with: password)
    |> click(Query.button("Sign In"))
  end

  @doc """
  Signs out with the navigation's Sign Out link and waits for the login page.
  The link sits in a menu that may be closed, so it is clicked from script.
  """
  def log_out_via_browser(session) do
    session
    |> execute_script("document.querySelector(\"a[href='/logout']\").click()")
    |> wait_for_path("/login")
  end

  @doc """
  Enables TOTP for `user` with a fresh secret and returns `{user, secret}`.

  Admins and moderators must have TOTP to sign in; the raw `secret` is what
  `totp_code/2` needs to compute codes in the test.
  """
  def enable_totp!(user) do
    secret = Baudrate.Auth.generate_totp_secret()
    {:ok, user} = Baudrate.Auth.enable_totp(user, secret)
    {Baudrate.Repo.preload(user, :role, force: true), secret}
  end

  @doc """
  Returns a current TOTP code for `secret`, first clearing the user's
  single-use marker (ADR 0024) so a second verification within the same
  30-second period is accepted, as `forget_totp_use/1` does in LiveView tests.
  """
  def totp_code(user, secret) do
    Baudrate.DataCase.forget_totp_use(user)
    NimbleTOTP.verification_code(secret)
  end

  @doc """
  Signs in through the login form and the TOTP verification page, for a user
  whose TOTP is enabled (`enable_totp!/1`). Works for every role.
  """
  def log_in_with_totp_via_browser(session, user, secret) do
    session
    |> submit_login_form(user, "Password123!x")
    |> assert_has(Query.css("#totp_code"))
    |> fill_in(Query.css("#totp_code"), with: totp_code(user, secret))
    |> click(Query.css("#totp-verify-submit"))
    |> assert_has(Query.css("#home-welcome-heading"))
  end

  @doc """
  Creates an admin with TOTP, signs in through the browser, and returns
  `{session, admin, secret}` for `visit_admin/3`.
  """
  def log_in_admin_via_browser(session) do
    {admin, secret} = enable_totp!(BaudrateWeb.ConnCase.setup_user("admin"))
    {log_in_with_totp_via_browser(session, admin, secret), admin, secret}
  end

  @doc """
  Visits an `/admin` page, passing the admin sudo verification (`/admin/verify`)
  with a TOTP code when the page asks for it. `who` is `{user, secret}`.
  """
  def visit_admin(session, path, {user, secret}) do
    session = visit(session, path)

    if String.starts_with?(current_path(session), "/admin/verify") do
      session
      |> fill_in(Query.css("#admin_totp_code"), with: totp_code(user, secret))
      |> click(Query.css("#admin-totp-verify-submit"))
      # Sudo verification returns to the page that was asked for.
      |> wait_for_path(path)
    else
      session
    end
  end

  @doc """
  Waits up to 5 seconds for the browser to reach `path` (query string
  ignored), for redirects that leave nothing on the page to assert on.
  """
  def wait_for_path(session, path), do: wait_for_path(session, URI.parse(path).path, 50)

  defp wait_for_path(session, path, 0),
    do: raise("not redirected to #{path}, at #{current_path(session)}")

  defp wait_for_path(session, path, tries) do
    if current_path(session) == path do
      session
    else
      Process.sleep(100)
      wait_for_path(session, path, tries - 1)
    end
  end

  @doc """
  Runs `script` (which must `return` a value) in the browser and returns the
  value.
  """
  def js_value(session, script) do
    parent = self()
    ref = make_ref()
    execute_script(session, script, fn value -> send(parent, {ref, value}) end)

    receive do
      {^ref, value} -> value
    after
      5_000 -> raise "no value returned from script"
    end
  end

  @doc """
  Adds a WebDriver virtual authenticator (CTAP2, user present and verified) to
  the browser session, so WebAuthn registration and assertions complete
  without a physical key. Needs the WebAuthn prefs in `config/test.exs`.
  """
  def add_virtual_authenticator(session) do
    {:ok, %{"value" => id}} =
      Wallaby.HTTPClient.request(:post, "#{session.session_url}/webauthn/authenticator", %{
        protocol: "ctap2",
        transport: "usb",
        hasResidentKey: true,
        hasUserVerification: true,
        isUserConsenting: true,
        isUserVerified: true
      })

    {session, id}
  end

  @doc """
  Creates a board with sensible defaults for feature tests.

  Always sets `ap_enabled: false` to prevent federation delivery attempts.
  Uses a unique slug to avoid conflicts between tests.
  """
  def create_board(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{
      name: "Test Board #{unique}",
      slug: "test-board-#{unique}",
      ap_enabled: false
    }

    {:ok, board} = Baudrate.Content.create_board(Map.merge(defaults, attrs))
    board
  end

  @doc """
  Creates an article in the given board for the given user.

  Returns the article struct.
  """
  def create_article(user, board, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{
      title: "Test Article #{unique}",
      body: "This is a test article body.",
      slug: "test-article-#{unique}",
      user_id: user.id
    }

    {:ok, %{article: article}} =
      Baudrate.Content.create_article(Map.merge(defaults, attrs), [board.id])

    article
  end

  defp ensure_setup_completed do
    alias Baudrate.Repo
    alias Baudrate.Setup.Setting

    unless Repo.get_by(Setting, key: "setup_completed") do
      Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    end
  end
end
