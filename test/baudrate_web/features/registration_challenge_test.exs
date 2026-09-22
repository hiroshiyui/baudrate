defmodule BaudrateWeb.Features.RegistrationChallengeTest do
  @moduledoc """
  The registration proof-of-work challenge, in a real browser (P5-D1).

  The test only a browser can run, and the one that matters most: the
  JavaScript SHA-256 in `challenge_solver.js` and Erlang's `:crypto` must agree
  on every bit, the worker must load from its bare-literal path under the
  content security policy's `worker-src 'self'`, and the answer must reach the
  server. A disagreement anywhere shows up as a registration that never
  finishes.

  It asserts that the **worker** solved it, not merely that registration
  worked: the main-thread fallback also registers people, only slower, so a
  worker that failed to load would otherwise pass here unnoticed.
  """
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    Repo.insert!(%Setting{key: "registration_mode", value: "open"})
    # Real work, but quick: about four thousand hashes.
    Repo.insert!(%Setting{key: "registration_challenge_bits", value: "12"})
    :ok
  end

  feature "the worker solves the challenge and the visitor is registered", %{session: session} do
    session
    |> visit("/register")
    |> assert_has(Query.css("#register-challenge .register-challenge-via[data-via='worker']", visible: false))
    |> fill_in(Query.css("#user_username"), with: "solver_#{System.unique_integer([:positive])}")
    |> fill_in(Query.css("#user_password"), with: "Password123!x")
    |> fill_in(Query.css("#user_password_confirmation"), with: "Password123!x")
    |> click(Query.css("#user_terms_accepted"))
    |> click(Query.button("Sign Up"))
    |> assert_has(Query.css("h1", text: "Recovery Codes"))
  end
end
