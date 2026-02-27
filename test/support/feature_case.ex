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

  using do
    quote do
      use Wallaby.DSL

      import Wallaby.Feature
      import BaudrateWeb.ConnCase, only: [setup_user: 1, log_in_user: 2]
    end
  end

  setup _tags do
    # Checkout Ecto sandbox in shared mode for browser tests
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Baudrate.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Baudrate.Repo, {:shared, self()})

    # Allow all rate limit checks through
    BaudrateWeb.RateLimiter.Sandbox.set_global_fun(&BaudrateWeb.RateLimiter.Hammer.check_rate/3)

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

  defp ensure_setup_completed do
    alias Baudrate.Repo
    alias Baudrate.Setup.Setting

    unless Repo.get_by(Setting, key: "setup_completed") do
      Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    end
  end
end
