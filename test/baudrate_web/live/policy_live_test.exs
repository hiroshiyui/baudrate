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

  describe "reading a policy" do
    test "a guest can read all three", %{conn: conn} do
      Setup.update_eua("The **terms** of service.")
      Setup.update_policy(:rules, "Be kind.")
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
      Setup.update_policy(:rules, "Rule **one**.")

      {:ok, _lv, html} = live(conn, "/rules")

      assert html =~ "<strong>one</strong>"
      refute html =~ "Rule **one**"
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
      Setup.update_policy(:rules, "Be kind.")

      {:ok, lv, _html} = live(conn, "/rules")

      assert has_element?(lv, "#site-footer-rules")
    end

    test "does not link a document nobody has written", %{conn: conn} do
      Setup.update_policy(:rules, "Be kind.")

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

  describe "the admin editor" do
    test "saves the rules and the privacy policy, and logs both", %{conn: conn} do
      admin = setup_user("admin")
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, "/admin/settings")

      assert lv
             |> form("#rules-form", rules_policy: %{text: "Rule one."})
             |> render_submit() =~ "Site rules saved"

      assert lv
             |> form("#privacy-form", privacy_policy: %{text: "We log for a year."})
             |> render_submit() =~ "Privacy policy saved"

      assert Setup.get_policy(:rules) == "Rule one."
      assert Setup.get_policy(:privacy) == "We log for a year."

      actions =
        Baudrate.Moderation.list_moderation_logs().logs
        |> Enum.map(& &1.action)

      assert "update_rules" in actions
      assert "update_privacy" in actions
    end

    test "is refused to a non-admin", %{conn: conn} do
      user = setup_user("user")
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, _}} = live(conn, "/admin/settings")
    end
  end
end
