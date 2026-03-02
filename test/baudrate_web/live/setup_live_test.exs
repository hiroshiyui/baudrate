defmodule BaudrateWeb.SetupLiveTest do
  use BaudrateWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "setup wizard" do
    test "mounts on step 1 (database)", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/setup")
      assert html =~ "Initial Setup"
      assert html =~ "Database Connection"
      assert html =~ "Connected"
      assert has_element?(view, "button", "Next")
    end

    test "can navigate from database to site name step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      html = view |> element("button", "Next") |> render_click()
      assert html =~ "Site Name"
      assert html =~ "Choose a name for your application"
    end

    test "can navigate back from site name to database", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      view |> element("button", "Next") |> render_click()
      html = view |> element("button", "Back") |> render_click()
      assert html =~ "Database Connection"
    end

    test "validates site name is required", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      view |> element("button", "Next") |> render_click()

      html =
        view
        |> form("form", site: %{site_name: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end

    test "can save site name and proceed to admin step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      view |> element("button", "Next") |> render_click()

      html =
        view
        |> form("form", site: %{site_name: "My App"})
        |> render_submit()

      assert html =~ "Admin Account"
      assert html =~ "Create the administrator account"
    end

    test "shows password strength indicators", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      # Navigate to admin step
      view |> element("button", "Next") |> render_click()
      view |> form("form", site: %{site_name: "My App"}) |> render_submit()

      # Type a password with some criteria met
      html =
        view
        |> form("form",
          admin: %{username: "admin", password: "Test1!", password_confirmation: ""}
        )
        |> render_change()

      assert html =~ "Password requirements:"
      assert html =~ "At least 12 characters"
      assert html =~ "Contains a lowercase letter"
      assert html =~ "Contains an uppercase letter"
      assert html =~ "Contains a digit"
      assert html =~ "Contains a special character"
    end

    test "validates admin form errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      # Navigate to admin step
      view |> element("button", "Next") |> render_click()
      view |> form("form", site: %{site_name: "My App"}) |> render_submit()

      # Submit with invalid data
      html =
        view
        |> form("form", admin: %{username: "", password: "short", password_confirmation: "short"})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end

    test "completes setup and shows recovery codes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      # Step 1 -> Step 2
      view |> element("button", "Next") |> render_click()

      # Step 2 -> Step 3
      view |> form("form", site: %{site_name: "My App"}) |> render_submit()

      # Complete setup -> shows recovery codes
      html =
        view
        |> form("form",
          admin: %{
            username: "admin_user",
            password: "SecurePass1!xyz",
            password_confirmation: "SecurePass1!xyz"
          }
        )
        |> render_submit()

      assert html =~ "Recovery Codes"
      assert html =~ "Save these recovery codes"

      # Acknowledge codes -> redirect to /
      view |> render_click("ack_codes")
      flash = assert_redirect(view, "/")
      assert flash["info"] =~ "Setup completed successfully"
    end

    test "can navigate back from admin to site name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      view |> element("button", "Next") |> render_click()
      view |> form("form", site: %{site_name: "My App"}) |> render_submit()

      html = view |> element("button", "Back") |> render_click()
      assert html =~ "Site Name"
    end

    test "retry button re-checks database", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      html = view |> element("button", "Retry") |> render_click()
      assert html =~ "Connected"
    end
  end

  describe "installation key" do
    setup do
      on_exit(fn -> Application.delete_env(:baudrate, :installation_key) end)
    end

    test "wizard starts at :database when key is not configured", %{conn: conn} do
      Application.delete_env(:baudrate, :installation_key)

      {:ok, _view, html} = live(conn, ~p"/setup")
      assert html =~ "Database Connection"
      refute html =~ "Installation Key"
    end

    test "wizard starts at :verify_key when key is configured", %{conn: conn} do
      Application.put_env(:baudrate, :installation_key, "test-secret-key-123")

      {:ok, _view, html} = live(conn, ~p"/setup")
      assert html =~ "Installation Key"
      assert html =~ "Enter the installation key to proceed with setup."
      refute html =~ "Database Connection"
    end

    test "shows Verification step in steps indicator when key is required", %{conn: conn} do
      Application.put_env(:baudrate, :installation_key, "test-secret-key-123")

      {:ok, _view, html} = live(conn, ~p"/setup")
      assert html =~ "Verification"
    end

    test "does not show Verification step when key is not required", %{conn: conn} do
      Application.delete_env(:baudrate, :installation_key)

      {:ok, _view, html} = live(conn, ~p"/setup")
      refute html =~ "Verification"
    end

    test "correct key advances to :database step", %{conn: conn} do
      Application.put_env(:baudrate, :installation_key, "correct-key-abc")

      {:ok, view, _html} = live(conn, ~p"/setup")

      html =
        view
        |> form("form", key: %{installation_key: "correct-key-abc"})
        |> render_submit()

      assert html =~ "Database Connection"
      refute html =~ "Invalid installation key"
    end

    test "wrong key shows error and stays on :verify_key", %{conn: conn} do
      Application.put_env(:baudrate, :installation_key, "correct-key-abc")

      {:ok, view, _html} = live(conn, ~p"/setup")

      html =
        view
        |> form("form", key: %{installation_key: "wrong-key"})
        |> render_submit()

      assert html =~ "Invalid installation key."
      assert html =~ "Installation Key"
      refute html =~ "Database Connection"
    end

    test "lockout after 3 failed attempts", %{conn: conn} do
      Application.put_env(:baudrate, :installation_key, "correct-key-abc")

      {:ok, view, _html} = live(conn, ~p"/setup")

      # Attempt 1
      view
      |> form("form", key: %{installation_key: "wrong1"})
      |> render_submit()

      # Attempt 2
      view
      |> form("form", key: %{installation_key: "wrong2"})
      |> render_submit()

      # Attempt 3 — triggers lockout
      html =
        view
        |> form("form", key: %{installation_key: "wrong3"})
        |> render_submit()

      assert html =~ "Invalid installation key."

      # Attempt 4 — should show lockout message
      html =
        view
        |> form("form", key: %{installation_key: "correct-key-abc"})
        |> render_submit()

      assert html =~ "Too many attempts. Please wait before trying again."
      refute html =~ "Database Connection"
    end
  end
end
