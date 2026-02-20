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

    test "completes setup and redirects to /", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      # Step 1 -> Step 2
      view |> element("button", "Next") |> render_click()

      # Step 2 -> Step 3
      view |> form("form", site: %{site_name: "My App"}) |> render_submit()

      # Complete setup
      view
      |> form("form",
        admin: %{
          username: "admin_user",
          password: "SecurePass1!xyz",
          password_confirmation: "SecurePass1!xyz"
        }
      )
      |> render_submit()

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
end
