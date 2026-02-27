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
        only: [log_in_via_browser: 2, create_board: 1, create_article: 3]
    end
  end

  setup _tags do
    # Checkout Ecto sandbox in shared mode for browser tests
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Baudrate.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Baudrate.Repo, {:shared, self()})

    # Always allow rate limit checks in browser tests — all requests come from
    # 127.0.0.1 so real Hammer rate limiting would trigger across sequential tests
    BaudrateWeb.RateLimiter.Sandbox.set_global_response({:allow, 1})

    # Ensure setup wizard doesn't redirect — insert setup_completed setting
    ensure_setup_completed()

    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(Baudrate.Repo, self())

    {:ok, session} =
      Wallaby.start_session(
        create_session_fn: &BaudrateWeb.W3CWebDriver.create_session/2,
        metadata: metadata
      )

    on_exit(fn ->
      Wallaby.end_session(session)
    end)

    {:ok, session: session}
  end

  @doc """
  Logs in a user via the browser login form.

  Only works for role "user" — admin/moderator require TOTP which needs
  a separate flow. The password must be "Password123!x" (the default from
  `setup_user/1`).
  """
  def log_in_via_browser(session, user) do
    session
    |> visit("/login")
    |> fill_in(Query.css("#login_username"), with: user.username)
    |> fill_in(Query.css("#login_password"), with: "Password123!x")
    |> click(Query.button("Sign In"))
    # Wait for redirect to complete — the home page h1 confirms full auth
    |> assert_has(Query.css("h1", text: "Welcome, #{user.username}!"))
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
