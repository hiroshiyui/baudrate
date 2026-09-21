defmodule BaudrateWeb.Features.AccountRecoveryTest do
  @moduledoc """
  The Phase 4D pages in a real browser: the first-visit step, and the
  recovery-contact form on `/profile`.

  Both are forms that re-render while being filled in, which is the class of
  bug only a browser catches — LiveView patches every input back to the value
  the server rendered, so a field that does not carry its own value is wiped
  as soon as anything else on the page changes.
  """

  use BaudrateWeb.FeatureCase, async: false

  alias Baudrate.Repo

  @moduletag :feature

  @key """
  -----BEGIN PGP PUBLIC KEY BLOCK-----

  mDMEZfakeKeyForTestingOnlyNotARealKeyAtAll0123456789abcdefghijkl
  -----END PGP PUBLIC KEY BLOCK-----\
  """

  feature "the first-visit step takes a display name and gets out of the way", %{
    session: session
  } do
    user = setup_user("user")
    Repo.update!(Ecto.Changeset.change(user, onboarded_at: nil))

    session
    |> log_in_via_browser(user)
    |> visit("/welcome")
    |> assert_has(Query.css("#welcome-page"))
    |> fill_in(Query.css("#welcome-display-name"), with: "Hedy")
    |> click(Query.css("#welcome-save"))
    |> assert_has(Query.css("#home-page, #main-content"))

    # Shown once: coming back lands on the home page rather than asking again.
    session
    |> visit("/welcome")
    |> refute_has(Query.css("#welcome-page"))
  end

  feature "the recovery-contact form keeps a pasted key while the page re-renders", %{
    session: session
  } do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/profile")
    |> assert_has(Query.css("#profile-recovery-codes"))
    # The form is behind step-up re-authentication, so the fields are not
    # rendered until identity is confirmed — which is the point.
    |> refute_has(Query.css("#profile-recovery-contact-form"))
    |> fill_in(Query.css("#security_reauth_password"), with: "Password123!x")
    |> click(Query.css("#profile-security-reauth-submit"))
    |> assert_has(Query.css("#profile-recovery-contact-form"))
    |> fill_in(Query.css("#profile-recovery-contact-email"), with: "owner@example.com")
    |> fill_in(Query.css("#profile-recovery-contact-key"), with: @key)
    |> fill_in(Query.css("#profile-recovery-contact-label"), with: "Laptop")
    |> click(Query.css("#profile-recovery-contact-submit"))
    |> assert_has(Query.text("owner@example.com"))
    |> assert_has(Query.text("Waiting for an admin"))
  end
end
