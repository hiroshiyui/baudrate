defmodule BaudrateWeb.Features.SetupWizardTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  setup do
    # Remove setup_completed setting so the wizard activates
    alias Baudrate.Repo
    alias Baudrate.Setup.Setting

    Repo.delete_all(Setting)
    :ok
  end

  feature "complete setup wizard end-to-end", %{session: session} do
    unique = System.unique_integer([:positive])

    session
    # Visit /setup directly (redirect from / may take time)
    |> visit("/setup")
    |> assert_has(Query.text("Initial Setup"))
    # Step 1: Database — both DB connection and migrations should show success
    |> assert_has(Query.css(".badge.badge-success", count: 2))
    |> click(Query.button("Next"))
    # Step 2: Site Name — use h2 to avoid matching the step indicator
    |> assert_has(Query.css("h2.card-title", text: "Site Name"))
    |> fill_in(Query.css("#site_site_name"), with: "Test BBS #{unique}")
    |> click(Query.button("Next"))
    # Step 3: Admin Account
    |> assert_has(Query.css("h2.card-title", text: "Admin Account"))
    |> fill_in(Query.css("#admin_username"), with: "admin#{unique}")
    |> fill_in(Query.css("#admin_password"), with: "Password123!x")
    |> fill_in(Query.css("#admin_password_confirmation"), with: "Password123!x")
    |> click(Query.button("Complete Setup"))
    # Step 4: Recovery Codes
    |> assert_has(Query.css("h2.card-title", text: "Recovery Codes"))
    |> assert_has(Query.css(".grid.grid-cols-2"))
    |> click(Query.button("I have saved my recovery codes"))
    # Should redirect to home page
    |> assert_has(Query.text("Welcome"))
  end
end
