defmodule BaudrateWeb.AccountRecoveryWebTest do
  @moduledoc """
  The pages Phase 4D added or changed: the first-visit step, the way a guest
  is brought back to a private page, the recovery sections on `/profile`, the
  admin's side of a recovery request, and the link that redeems it.

  `Baudrate.Auth.AccountRecoveryTest` is the gate for the rules themselves —
  this file is about whether the rules are reachable, and whether the pages
  that must not leak do not.
  """

  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  @key """
  -----BEGIN PGP PUBLIC KEY BLOCK-----

  mDMEZfakeKeyForTestingOnlyNotARealKeyAtAll0123456789abcdefghijkl
  -----END PGP PUBLIC KEY BLOCK-----\
  """

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  defp new_member(attrs \\ %{}) do
    user = setup_user("user", attrs)
    # `setup_user/2` marks an established member; a newly registered one has
    # not been through the first-visit step.
    Repo.update!(Ecto.Changeset.change(user, onboarded_at: nil))
  end

  describe "/welcome" do
    test "a new member sees it, and it says what a pending account can do" do
      user = new_member(%{status: "pending"})
      conn = log_in_user(build_conn(), user)

      {:ok, _lv, html} = live(conn, "/welcome")

      assert html =~ ~s(id="welcome-page")
      assert html =~ ~s(id="welcome-pending-notice")
      # The registration flash used to be the only place this was said.
      assert html =~ "waiting for approval"
    end

    test "an active member sees no pending notice" do
      conn = log_in_user(build_conn(), new_member())
      {:ok, _lv, html} = live(conn, "/welcome")

      assert html =~ ~s(id="welcome-page")
      refute html =~ ~s(id="welcome-pending-notice")
    end

    test "skipping counts as having seen it" do
      user = new_member()
      conn = log_in_user(build_conn(), user)

      {:ok, lv, _html} = live(conn, "/welcome")
      lv |> element("#welcome-skip") |> render_click()
      assert_redirect(lv, "/")

      assert Auth.onboarded?(Auth.get_user(user.id)),
             """
             A first-visit step that comes back until it is filled in is the
             manufactured urgency ADR 0056 refuses. Skipping is an answer.
             """
    end

    test "saving a display name counts too, and keeps the name" do
      user = new_member()
      conn = log_in_user(build_conn(), user)

      {:ok, lv, _html} = live(conn, "/welcome")
      lv |> form("#welcome-form", user: %{display_name: "Hedy"}) |> render_submit()
      assert_redirect(lv, "/")

      reloaded = Auth.get_user(user.id)
      assert reloaded.display_name == "Hedy"
      assert Auth.onboarded?(reloaded)
    end

    test "is shown once and then redirects" do
      conn = log_in_user(build_conn(), setup_user("user"))
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/welcome")
    end

    test "carries noindex and no canonical" do
      conn = log_in_user(build_conn(), new_member())
      {:ok, _lv, html} = live(conn, "/welcome")

      assert html =~ ~s(name="robots" content="noindex, follow")
      refute html =~ ~s(rel="canonical")
    end

    test "survives the interaction gate refusing the save" do
      user = new_member()
      admin = setup_user("admin")
      conn = log_in_user(build_conn(), user)

      {:ok, lv, _html} = live(conn, "/welcome")

      # A brand-new account can be silenced between registering and reaching
      # this page. `update_display_name/2` then refuses with an atom, which
      # used to fall out of the `with` and take the LiveView down with it.
      {:ok, _sanction} = Auth.issue_sanction(admin, user, "silence", reason: "spam")

      html = lv |> form("#welcome-form", user: %{display_name: "Hedy"}) |> render_submit()

      assert html =~ "silenced" or html =~ "Could not save"
      assert Process.alive?(lv.pid)
    end
  end

  describe "a private page brings you back" do
    test "a guest is told why, and where they were going is remembered" do
      assert {:error, {:redirect, %{to: to, flash: flash}}} = live(build_conn(), "/profile")

      assert to == "/login?return_to=%2Fprofile"
      assert flash["error"] =~ "sign in"
    end

    test "the query string survives" do
      assert {:error, {:redirect, %{to: to}}} = live(build_conn(), "/bookmarks?page=3")
      assert to == "/login?" <> URI.encode_query(%{"return_to" => "/bookmarks?page=3"})
    end

    test "the login form carries it, and only when it is local" do
      {:ok, _lv, html} = live(build_conn(), "/login?return_to=%2Fbookmarks")
      assert html =~ ~s(name="return_to" value="/bookmarks")

      # `Helpers.local_path/2` is the one open-redirect guard, and it is asked
      # on the way in as well as on the way out.
      {:ok, _lv, html} = live(build_conn(), "/login?return_to=//evil.example/x")
      refute html =~ "evil.example"
    end

    test "an off-site return_to posted straight at the controller is refused" do
      user = setup_user("user")
      token = Phoenix.Token.sign(BaudrateWeb.Endpoint, "user_auth", user.id)

      conn =
        build_conn()
        |> post("/auth/session", %{"token" => token, "return_to" => "//evil.example/x"})

      assert redirected_to(conn) == "/"
    end

    test "a local return_to is honoured" do
      user = setup_user("user")
      token = Phoenix.Token.sign(BaudrateWeb.Endpoint, "user_auth", user.id)

      conn = post(build_conn(), "/auth/session", %{"token" => token, "return_to" => "/bookmarks"})
      assert redirected_to(conn) == "/bookmarks"
    end
  end

  describe "/profile recovery sections" do
    setup do
      user = setup_user("user")
      Auth.generate_recovery_codes(user)
      %{user: user, conn: log_in_user(build_conn(), user)}
    end

    test "show how many codes are left, but never the codes", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/profile")

      assert html =~ ~s(id="profile-recovery-codes")
      assert html =~ "10 unused codes left"
      refute html =~ ~s(id="profile-fresh-recovery-codes")
    end

    test "refuse to regenerate without step-up re-authentication", %{conn: conn, user: user} do
      {:ok, lv, html} = live(conn, "/profile")

      # The button is not rendered, and the handler refuses anyway — hiding a
      # control is presentation, and the server is what decides (ADR 0022).
      refute html =~ ~s(id="profile-regenerate-recovery-codes")

      html = render_click(lv, "regenerate_recovery_codes", %{})
      assert html =~ "confirm your identity"

      assert Auth.unused_recovery_code_count(Auth.get_user(user.id)) == 10
    end

    test "refuse to register a contact without step-up", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, "/profile")

      render_click(lv, "add_recovery_contact", %{
        "contact" => %{"email" => "me@example.com", "pgp_public_key" => @key}
      })

      assert Auth.list_recovery_contacts(Auth.get_user(user.id)) == []
    end

    test "show a registered contact as waiting for an admin", %{conn: conn, user: user} do
      {:ok, _} =
        Auth.add_recovery_contact(user, %{"email" => "me@example.com", "pgp_public_key" => @key})

      {:ok, _lv, html} = live(conn, "/profile")

      assert html =~ ~s(id="profile-recovery-contacts")
      assert html =~ "me@example.com"
      assert html =~ "Waiting for an admin"
    end
  end

  describe "the recovery notice" do
    test "is absent while the account still has codes" do
      user = setup_user("user")
      Auth.generate_recovery_codes(user)

      {:ok, _lv, html} = live(log_in_user(build_conn(), user), "/")
      refute html =~ ~s(id="recovery-notice")
    end

    test "appears once there is no way back in" do
      user = setup_user("user")
      codes = Auth.generate_recovery_codes(user)
      for code <- codes, do: :ok = Auth.verify_recovery_code(user, code)

      {:ok, _lv, html} = live(log_in_user(build_conn(), user), "/")

      assert html =~ ~s(id="recovery-notice")
      # No count, no badge: ADR 0056's question 3 rules out anything whose
      # job is urgency, and this is safety work under decision 5.
      refute html =~ ~s(id="recovery-notice-count")
    end

    test "stays dismissed" do
      user = setup_user("user")
      codes = Auth.generate_recovery_codes(user)
      for code <- codes, do: :ok = Auth.verify_recovery_code(user, code)

      conn = log_in_user(build_conn(), user)
      {:ok, lv, _html} = live(conn, "/")

      html = lv |> element("#recovery-notice-dismiss") |> render_click()
      refute html =~ ~s(id="recovery-notice")

      {:ok, _lv, html} = live(conn, "/")
      refute html =~ ~s(id="recovery-notice")
    end

    test "a verified contact counts as a way back in" do
      user = setup_user("user")
      admin = setup_user("admin")
      codes = Auth.generate_recovery_codes(user)
      for code <- codes, do: :ok = Auth.verify_recovery_code(user, code)

      {:ok, contact} =
        Auth.add_recovery_contact(user, %{"email" => "a@b.co", "pgp_public_key" => @key})

      {:ok, _} = verify_with_challenge(admin, contact.id, "verified")

      {:ok, _lv, html} = live(log_in_user(build_conn(), user), "/")
      refute html =~ ~s(id="recovery-notice")
    end
  end

  describe "/account-reset/:token" do
    setup do
      admin = setup_user("admin")
      user = setup_user("user")

      {:ok, contact} =
        Auth.add_recovery_contact(user, %{
          "email" => "owner@example.com",
          "pgp_public_key" => @key
        })

      {:ok, contact} = verify_with_challenge(admin, contact.id, "verified")
      {:ok, token, _reset} = issue_with_challenge(admin, user, contact.id)

      %{admin: admin, user: user, token: token}
    end

    test "sets a new password and shows fresh codes once", %{conn: conn, user: user, token: token} do
      {:ok, lv, _html} = live(conn, "/account-reset/#{token}")

      html =
        lv
        |> form("#account-reset-form",
          reset: %{password: "BrandNew123!xy", password_confirmation: "BrandNew123!xy"}
        )
        |> render_submit()

      assert html =~ ~s(id="account-reset-codes")
      assert html =~ "will not be able to see these codes again"
      assert {:ok, _} = Auth.authenticate_by_password(user.username, "BrandNew123!xy")
    end

    test "every failure looks the same, so the page is no oracle", %{conn: conn, token: token} do
      # Spend it, then compare a spent link with one that never existed.
      {:ok, lv, _html} = live(conn, "/account-reset/#{token}")

      lv
      |> form("#account-reset-form",
        reset: %{password: "BrandNew123!xy", password_confirmation: "BrandNew123!xy"}
      )
      |> render_submit()

      spent = refusal(conn, token)
      unknown = refusal(conn, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

      assert spent == unknown,
             """
             A spent link and one that never existed must be indistinguishable,
             or the page answers "did this account ever have a reset issued"
             for anybody who asks.
             """

      assert spent =~ "not valid"
    end

    test "mounting tells a scanner nothing", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/account-reset/definitely-not-a-real-token")

      # The form renders either way: checking the token on mount would answer
      # "did this link ever exist" for anybody who asked.
      assert html =~ ~s(id="account-reset-form")
      refute html =~ "not valid"
    end

    test "a member who still has a session elsewhere can redeem their own link", %{
      conn: conn,
      user: user,
      token: token
    } do
      # The person being handed a recovery link is the one locked out of their
      # password — not necessarily out of every session. `:redirect_if_authenticated`
      # used to bounce them to `/` with no explanation.
      signed_in = log_in_user(conn, user)

      {:ok, lv, html} = live(signed_in, "/account-reset/#{token}")
      assert html =~ ~s(id="account-reset-form")

      html =
        lv
        |> form("#account-reset-form",
          reset: %{password: "BrandNew123!xy", password_confirmation: "BrandNew123!xy"}
        )
        |> render_submit()

      assert html =~ ~s(id="account-reset-codes")
    end

    test "carries noindex and no canonical", %{conn: conn, token: token} do
      {:ok, _lv, html} = live(conn, "/account-reset/#{token}")

      # The token is in the path. An indexed copy would publish it.
      assert html =~ ~s(name="robots" content="noindex, follow")
      refute html =~ ~s(rel="canonical")
    end

    defp refusal(conn, token) do
      {:ok, lv, _html} = live(conn, "/account-reset/#{token}")

      lv
      |> form("#account-reset-form",
        reset: %{password: "BrandNew123!xy", password_confirmation: "BrandNew123!xy"}
      )
      |> render_submit()
      |> flash_text()
    end

    # The layout carries a CSRF token and other per-render values, so two
    # mounts never produce byte-identical pages. What has to match is the
    # answer.
    defp flash_text(html) do
      case Regex.run(~r/id="flash-error".*?<p[^>]*>(.*?)<\/p>/s, html) do
        [_, text] -> text |> String.replace(~r/\s+/, " ") |> String.trim()
        nil -> nil
      end
    end
  end

  describe "the admin's side" do
    setup do
      admin = setup_user("admin")
      user = setup_user("user")

      {:ok, contact} =
        Auth.add_recovery_contact(user, %{
          "email" => "owner@example.com",
          "pgp_public_key" => @key
        })

      %{admin: admin, user: user, contact: contact, conn: log_in_admin(build_conn(), admin)}
    end

    test "lists a contact and offers to verify it", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, "/admin/users/#{user.id}")

      assert html =~ ~s(id="admin-user-detail-recovery")
      assert html =~ "owner@example.com"
      assert html =~ "Not verified"
      # No reset until the signature has been checked.
      refute html =~ "admin-user-detail-recovery-issue-"
    end

    test "verifying then issuing shows the link exactly once", %{
      conn: conn,
      user: user,
      contact: contact
    } do
      {:ok, lv, _html} = live(conn, "/admin/users/#{user.id}")

      # Nothing can be acted on until a challenge has been asked for and the
      # signature over it checked elsewhere (ADR 0067).
      html = lv |> element("#admin-user-detail-recovery-verify-#{contact.id}") |> render_click()
      assert html =~ "Issue a challenge first"
      refute html =~ ">Verified<"

      html =
        lv
        |> element("#admin-user-detail-recovery-challenge-issue-#{contact.id}")
        |> render_click()

      assert html =~ "account recovery for @#{user.username}"

      html = lv |> element("#admin-user-detail-recovery-verify-#{contact.id}") |> render_click()
      assert html =~ "Verified"

      # The verification spent it, so the link needs one of its own.
      html = lv |> element("#admin-user-detail-recovery-issue-#{contact.id}") |> render_click()
      assert html =~ "Issue a challenge first"
      refute html =~ ~s(id="admin-user-detail-recovery-token")

      lv
      |> element("#admin-user-detail-recovery-challenge-issue-#{contact.id}")
      |> render_click()

      html = lv |> element("#admin-user-detail-recovery-issue-#{contact.id}") |> render_click()
      assert html =~ ~s(id="admin-user-detail-recovery-token")
      assert html =~ "/account-reset/"

      html = lv |> element("#admin-user-detail-recovery-token-done") |> render_click()
      refute html =~ ~s(id="admin-user-detail-recovery-token")
    end

    test "offers a mail to send, carrying the challenge and the warning", %{
      conn: conn,
      user: user,
      contact: contact
    } do
      {:ok, lv, html} = live(conn, "/admin/users/#{user.id}")

      # Nothing to send until something has been asked.
      refute html =~ ~s(id="admin-user-detail-recovery-mail-#{contact.id}")

      html =
        lv
        |> element("#admin-user-detail-recovery-challenge-issue-#{contact.id}")
        |> render_click()

      challenge = Auth.live_recovery_challenge(contact.id)

      assert html =~ ~s(id="admin-user-detail-recovery-mail-#{contact.id}")
      assert html =~ challenge.phrase

      assert html =~ "Never send your private key",
             """
             Writing the message from scratch while somebody is locked out is
             how this line gets left out, and `doc/sysop.md` says a member
             under stress does offer their private key.
             """
    end

    test "writes that mail in the member's own language", %{
      conn: conn,
      user: user,
      contact: contact
    } do
      {:ok, _} = Auth.update_preferred_locales(user, ["ja_JP"])

      {:ok, lv, _html} = live(conn, "/admin/users/#{user.id}")

      html =
        lv
        |> element("#admin-user-detail-recovery-challenge-issue-#{contact.id}")
        |> render_click()

      assert html =~ "日本語",
             "the admin is told which language they are about to send"

      assert html =~ "秘密鍵",
             """
             The member is who reads this, so it is written in the language
             they asked for — not the one the admin happens to be using.
             """
    end

    test "a moderator sees no recovery contacts at all", %{user: user} do
      moderator = setup_user("moderator")
      conn = log_in_admin(build_conn(), moderator)

      {:ok, _lv, html} = live(conn, "/admin/users/#{user.id}")

      # Personal data, and the anchor a reset rests on.
      refute html =~ ~s(id="admin-user-detail-recovery")
      refute html =~ "owner@example.com"
    end

    test "and cannot verify one by sending the event anyway", %{user: user, contact: contact} do
      moderator = setup_user("moderator")
      conn = log_in_admin(build_conn(), moderator)

      {:ok, lv, _html} = live(conn, "/admin/users/#{user.id}")

      # A moderator can reach this page, so hiding the control is presentation.
      # The refusal has to be in the context (ADR 0016), and this is what says
      # it is.
      render_click(lv, "verify_contact", %{"id" => to_string(contact.id), "status" => "verified"})

      assert Repo.get!(Baudrate.Auth.RecoveryContact, contact.id).status == "pending"
    end

    test "a peer admin cannot be reset from the page", %{conn: conn, admin: admin} do
      peer = setup_user("admin")
      other = setup_user("admin")

      {:ok, contact} =
        Auth.add_recovery_contact(peer, %{"email" => "peer@example.com", "pgp_public_key" => @key})

      {:ok, _} = verify_with_challenge(other, contact.id, "verified")

      {:ok, _lv, html} = live(conn, "/admin/users/#{peer.id}")

      assert html =~ "peer@example.com"

      refute html =~ "admin-user-detail-recovery-issue-#{contact.id}",
             """
             ADR 0029's rank rule. Recovering an account at or above your own
             level is the server console's job, not this page's.
             """

      # And the handler refuses too, not merely the template.
      assert {:error, :role_too_high} = Auth.issue_account_reset(admin, peer, contact.id)
    end
  end

  # ADR 0067: the admin issues the text the member signs, and marking a
  # contact verified or issuing a link spends it.
  defp verify_with_challenge(admin, contact_id, status) do
    {:ok, _challenge} = Auth.issue_recovery_challenge(admin, contact_id)
    Auth.set_recovery_contact_verification(admin, contact_id, status)
  end

  defp issue_with_challenge(admin, user, contact_id, opts \\ []) do
    {:ok, _challenge} = Auth.issue_recovery_challenge(admin, contact_id)
    Auth.issue_account_reset(admin, user, contact_id, opts)
  end
end
