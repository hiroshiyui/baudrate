defmodule BaudrateWeb.PolicyLiveTest do
  @moduledoc """
  The three public policy documents, and the footer that links them.

  A document that has to be agreed to is worth nothing if it can only be read
  from inside the registration form, so most of what is checked here is who can
  reach the pages rather than how they look.
  """
  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Setup

  setup do
    Repo.insert!(%Setup.Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setup.Setting{key: "site_name", value: "Test Site"})
    :ok
  end

  defp rule(title) do
    {:ok, created} = Setup.create_rule(%{"title" => title})
    created
  end

  describe "reading a policy" do
    test "a guest can read all three", %{conn: conn} do
      Setup.update_eua("The **terms** of service.")
      rule("Be kind.")
      Setup.update_policy(:privacy, "We keep logs for a year.")

      for {path, marker} <- [
            {"/terms", "terms"},
            {"/rules", "Be kind."},
            {"/privacy", "We keep logs for a year."}
          ] do
        {:ok, _lv, html} = live(conn, path)
        assert html =~ marker
      end
    end

    test "a signed-in member can read them too", %{conn: conn} do
      # The regression this guards: `live_session :public` carries
      # `:redirect_if_authenticated`, so putting the policy routes there would
      # bounce a member off the document they are being asked to accept.
      Setup.update_eua("The terms of service.")
      user = setup_user("user")
      conn = log_in_user(conn, user)

      {:ok, _lv, html} = live(conn, "/terms")

      assert html =~ "The terms of service."
    end

    test "renders markdown rather than its source", %{conn: conn} do
      Setup.update_policy(:privacy, "We log **everything**.")

      {:ok, _lv, html} = live(conn, "/privacy")

      assert html =~ "<strong>everything</strong>"
      refute html =~ "log **everything**"
    end

    test "numbers the rules and gives each a stable anchor", %{conn: conn} do
      rule("Be civil")
      rule("Stay on topic")

      {:ok, lv, html} = live(conn, "/rules")

      assert has_element?(lv, "#rule-1")
      assert has_element?(lv, "#rule-2")
      assert html =~ "1. Be civil"
      assert html =~ "2. Stay on topic"
    end

    test "a rule's markdown detail is rendered", %{conn: conn} do
      {:ok, _} = Setup.create_rule(%{"title" => "Be civil", "body" => "No **insults**."})

      {:ok, _lv, html} = live(conn, "/rules")

      assert html =~ "<strong>insults</strong>"
    end

    test "a retired rule leaves the page", %{conn: conn} do
      rule("Stays")
      gone = rule("Goes")
      {:ok, _} = Setup.retire_rule(gone)

      {:ok, _lv, html} = live(conn, "/rules")

      assert html =~ "Stays"
      refute html =~ "Goes"
    end

    test "says so when a document has not been published", %{conn: conn} do
      {:ok, lv, html} = live(conn, "/rules")

      assert has_element?(lv, "#policy-empty")
      assert html =~ "have not been published yet"
      refute has_element?(lv, "#policy-body")
    end

    test "a remote image in a policy is proxied, not hotlinked", %{conn: conn} do
      # ADR 0021: a page must never emit a subresource pointing at a host we do
      # not control. An admin-authored document is no exception — it is read by
      # guests, and an <img> there would disclose every reader's IP.
      Setup.update_policy(:privacy, "![tracker](https://tracker.example/pixel.png)")

      {:ok, _lv, html} = live(conn, "/privacy")

      refute html =~ "tracker.example"
      assert html =~ "/media/"
    end
  end

  describe "the footer" do
    test "links a published policy", %{conn: conn} do
      rule("Be kind.")

      {:ok, lv, _html} = live(conn, "/rules")

      assert has_element?(lv, "#site-footer-rules")
    end

    test "does not link a document nobody has written", %{conn: conn} do
      rule("Be kind.")

      {:ok, lv, _html} = live(conn, "/rules")

      # A link to a page that says "not published yet" is worse than no link.
      refute has_element?(lv, "#site-footer-privacy")
      refute has_element?(lv, "#site-footer-terms")
    end

    test "renders nothing at all while all three are unwritten", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/")

      refute has_element?(lv, "#site-footer-policies")
    end
  end

  describe "the re-acceptance banner" do
    setup do
      Setup.update_eua("Be excellent to each other.")
      :ok
    end

    test "is not shown to a member who is up to date", %{conn: conn} do
      user = setup_user("user")
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, "/terms")

      refute has_element?(lv, "#terms-banner")
      refute has_element?(lv, "#policy-accept")
    end

    test "is not shown to a guest", %{conn: conn} do
      {:ok, _} = Setup.publish_terms_version()

      {:ok, lv, _html} = live(conn, "/terms")

      refute has_element?(lv, "#terms-banner")
    end

    test "appears on every page once a new version is published", %{conn: conn} do
      user = setup_user("user")
      {:ok, _} = Setup.publish_terms_version()
      conn = log_in_user(conn, user)

      {:ok, home, _html} = live(conn, "/")
      assert has_element?(home, "#terms-banner")
      assert has_element?(home, "#terms-banner-link")
    end

    test "accepting on /terms clears it, and posting works again", %{conn: conn} do
      user = setup_user("user")
      {:ok, _} = Setup.publish_terms_version()
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, "/terms")
      assert has_element?(lv, "#policy-accept-button")

      html = lv |> element("#policy-accept-button") |> render_click()

      assert html =~ "You can post again"
      refute has_element?(lv, "#policy-accept")
      refute has_element?(lv, "#terms-banner")
      assert Baudrate.Auth.ensure_can_interact(Repo.reload(user)) == :ok
    end

    test "the composer turns a paused member away, saying which thing stands", %{conn: conn} do
      # It used to say "Your account is pending approval" for every reason
      # `can_create_content?/1` can refuse, which sends a member who only needs
      # to click Accept off to wait for staff who are not coming.
      user = setup_user("user")
      {:ok, _} = Setup.publish_terms_version()
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => message}}}} =
               live(conn, "/articles/new")

      assert message =~ "terms have changed"
      refute message =~ "pending approval"
    end

    test "the accept button is offered only on /terms", %{conn: conn} do
      user = setup_user("user")
      rule("Be kind.")
      {:ok, _} = Setup.publish_terms_version()
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, "/rules")

      # The banner follows them everywhere; accepting happens where the text is.
      assert has_element?(lv, "#terms-banner")
      refute has_element?(lv, "#policy-accept")
    end
  end

  describe "the admin editor" do
    test "saves the privacy policy and logs it", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/settings")

      assert lv
             |> form("#privacy-form", privacy_policy: %{text: "We log for a year."})
             |> render_submit() =~ "Privacy policy saved"

      assert Setup.get_policy(:privacy) == "We log for a year."

      actions = Baudrate.Moderation.list_moderation_logs().logs |> Enum.map(& &1.action)
      assert "update_privacy" in actions
    end

    test "sends an admin to the rules page rather than editing them here", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/settings")

      assert has_element?(lv, "#admin-settings-rules-link")
    end

    test "saving the terms without ticking the box asks nobody to re-accept", %{conn: conn} do
      admin = setup_user("admin")
      member = setup_user("user")
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/settings")

      lv
      |> form("#eua-form", eua_settings: %{eua: "Terms, with a typo fixed."})
      |> render_submit()

      assert Setup.current_terms_version() == 0
      assert Baudrate.Auth.ensure_can_interact(Repo.reload(member)) == :ok
    end

    test "ticking the box publishes a new version and pauses posting", %{conn: conn} do
      admin = setup_user("admin")
      member = setup_user("user")
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/settings")

      html =
        lv
        |> form("#eua-form", eua_settings: %{eua: "Terms, with a new clause.", republish: "true"})
        |> render_submit()

      assert html =~ "Members will be asked to accept"
      assert Setup.current_terms_version() == 1

      assert Baudrate.Auth.ensure_can_interact(Repo.reload(member)) ==
               {:error, :terms_not_accepted}

      assert [%{details: %{"version" => 1}}] =
               Baudrate.Moderation.list_moderation_logs(action: "publish_terms_version").logs
    end

    test "is refused to a non-admin", %{conn: conn} do
      user = setup_user("user")
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, _}} = live(conn, "/admin/settings")
    end
  end
end
