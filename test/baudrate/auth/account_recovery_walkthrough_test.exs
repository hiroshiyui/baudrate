defmodule Baudrate.Auth.AccountRecoveryWalkthroughTest do
  @moduledoc """
  The whole account-recovery procedure, act by act, in the order
  [`doc/sysop.md`](../../../doc/sysop.md#account-recovery-when-the-codes-are-gone-too)
  tells an operator to perform it.

  `account_recovery_test.exs` is the acceptance gate for
  [ADR 0058](../../../doc/adr/0058-account-recovery-is-anchored-outside-the-instance.md):
  it tests each rule in isolation, and every one of those tests would still
  pass if the steps no longer fitted together. This file tests that they do —
  that a member can enrol, lose everything, be verified, be issued a link, and
  get back in, with the right things happening at each step and nothing
  happening at the wrong one.

  It exists because the rules are enforced in four places (a schema, a context,
  an admin page and a public page) and the failure mode that matters is not a
  rule being wrong, it is the sequence being broken at a seam.

  ## Where this test stops

  **At the OpenPGP boundary, deliberately.** Acts 2 and 4 contain the step
  where an admin verifies a signature in their own mail client, and this suite
  does not shell out to `gpg`: Baudrate parses no OpenPGP and depends on no
  library for it, which is the decision, so a test that ran GnuPG would be
  testing GnuPG. What is asserted here is everything the instance does *around*
  that check — what it refuses before the verdict, what it records after, and
  that an admin can only ever supply a verdict about an anchor the member put
  there themselves.

  The signature check itself is prose in the sysop guide, and it is the one
  part of this procedure no code can hold to.
  """

  use Baudrate.DataCase

  alias Baudrate.Auth
  alias Baudrate.Auth.{AccountReset, Recovery, RecoveryContact}
  alias Baudrate.Moderation
  alias Baudrate.Notification.Notification
  alias Baudrate.Setup
  alias Baudrate.Setup.{Role, User}

  # Stands in for the armored block a member pastes in. The instance
  # shape-checks it and never parses it; what the admin verifies against is
  # this exact text, copied off the profile page.
  @rita_key """
  -----BEGIN PGP PUBLIC KEY BLOCK-----

  mDMEritaKeyNotARealKeyUsedOnlyToStandInForOneInTheseTests0123456
  -----END PGP PUBLIC KEY BLOCK-----\
  """

  @impostor_key String.replace(@rita_key, "0123456", "6543210")

  setup do
    Setup.seed_roles_and_permissions()
    %{rita: member("rita"), admin: member("admin", "admin")}
  end

  defp member(name, role_name \\ "user") do
    role = Repo.one!(from r in Role, where: r.name == ^role_name)

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "#{name}_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp notice_types(%User{id: id}) do
    Repo.all(from n in Notification, where: n.user_id == ^id, order_by: n.id, select: n.type)
  end

  defp audit_actions(%User{id: id}) do
    Repo.all(
      from l in Moderation.Log,
        where: l.target_type == "user" and l.target_id == ^id,
        order_by: l.id,
        select: l.action
    )
  end

  defp burn_every_code(user) do
    for code <- Auth.generate_recovery_codes(user),
        do: :ok = Auth.verify_recovery_code(user, code)

    :ok
  end

  describe "the whole recovery, act by act" do
    test "from enrolment to signing back in", %{rita: rita, admin: admin} do
      # ---- Act 1. Enrolment, in calm times -----------------------------
      #
      # Rita registers an address and the key she signs with, from her own
      # signed-in session. It arrives as a claim, not a fact.
      Auth.generate_recovery_codes(rita)

      {:ok, contact} =
        Auth.add_recovery_contact(rita, %{
          "email" => "rita@example.org",
          "pgp_public_key" => @rita_key,
          "label" => "Laptop"
        })

      assert contact.status == "pending"
      refute Auth.verified_recovery_contact?(rita)
      assert "recovery_contact_added" in notice_types(rita)

      # The anchor is worth nothing until somebody has checked it. An admin
      # asking for a link now is refused, and that refusal is what keeps the
      # OpenPGP proof from being optional.
      assert {:error, :no_verified_contact} = Auth.issue_account_reset(admin, rita, contact.id)

      # ---- Act 2. The admin verifies -----------------------------------
      #
      # Out of band: Rita sends a signed message from rita@example.org, and the
      # admin checks it against the key **from the profile page** — not one
      # attached to the mail, not one from a keyserver. That check is the
      # admin's, in their own client (sysop.md §2). What the instance records
      # is the verdict.
      #
      # What it must *not* offer is a way to create the anchor. An admin can
      # confirm a key a member put there; there is no function that puts one
      # there, and the address is encrypted against its owner so a row moved
      # between accounts does not even read back.
      assert {:ok, "rita@example.org"} =
               RecoveryContact.email(Repo.get!(RecoveryContact, contact.id), rita)

      {:ok, contact} = Auth.set_recovery_contact_verification(admin, contact.id, "verified")

      assert contact.status == "verified"
      assert contact.verified_by_id == admin.id
      assert "verify_recovery_contact" in audit_actions(rita)
      assert "recovery_contact_verified" in notice_types(rita)

      # ---- Act 3. Rita loses everything --------------------------------
      #
      # The password is gone and every recovery code is spent. Without the
      # anchor this is where the account ends, because there is no email in
      # this system to fall back on.
      burn_every_code(rita)

      assert Auth.unused_recovery_code_count(rita) == 0

      assert Auth.recovery_arranged?(rita),
             "the verified contact is the only thing standing between her and a lost account"

      # ---- Act 4. The request ------------------------------------------
      #
      # Rita mails the admin from the verified address, signed by the verified
      # key. The admin replies with a fresh nonce and has her sign that too,
      # because an old signed message can be replayed by anyone who saw one
      # (sysop.md §3). Again: their client, not ours.
      #
      # ---- Act 5. Issue -------------------------------------------------
      #
      # She asked for the password only — her second factors are fine — so the
      # tick stays off, and the audit log has to show that as a decision.
      {:ok, _} = Auth.enable_totp(rita, Auth.generate_totp_secret())
      {:ok, phone_session, _refresh} = Auth.create_user_session(rita.id)

      {:ok, token, reset} =
        Auth.issue_account_reset(admin, rita, contact.id, clear_second_factors: false)

      assert reset.contact_id == contact.id, "the log says which anchor the decision rested on"
      refute reset.clear_second_factors

      actions = audit_actions(rita)
      assert "issue_account_reset" in actions
      refute "clear_second_factors" in actions

      # Only the hash is kept: reading this table later yields nothing anybody
      # can redeem.
      stored = Repo.get!(AccountReset, reset.id)
      refute stored.token_hash == token
      assert stored.token_hash == AccountReset.hash(token)

      # And she is told while it is still outstanding — useless to her if she
      # really is locked out, and the whole point if she never asked.
      assert "account_reset_issued" in notice_types(rita)

      # ---- Act 6. Redemption --------------------------------------------
      assert {:ok, rita, fresh_codes} =
               Auth.redeem_account_reset(token, "RitasNewPass1!", "RitasNewPass1!")

      assert {:ok, _} = Auth.authenticate_by_password(rita.username, "RitasNewPass1!")
      assert length(fresh_codes) == 10
      assert Auth.unused_recovery_code_count(rita) == 10

      assert rita.totp_enabled, "she asked us not to touch her second factor, and we did not"

      assert {:error, :not_found} = Auth.get_user_by_session_token(phone_session),
             "recovery takes the account back from anyone else holding it"

      assert "account_reset_used" in notice_types(rita)

      # The link is spent. A second attempt is refused exactly as an unknown
      # token would be.
      assert {:error, :invalid} =
               Auth.redeem_account_reset(token, "Another123!xy", "Another123!xy")

      # ---- Act 7. Afterwards ---------------------------------------------
      #
      # The admin comes back to ask "did she actually use it?". Before this was
      # fixed the page fell silent once a link was redeemed, and a spent link
      # looked exactly like one that had never been issued.
      assert is_nil(Auth.live_account_reset(rita)), "nothing left to revoke"

      last = Auth.last_account_reset(rita)
      assert Auth.account_reset_state(last) == :used
      assert last.used_at
    end
  end

  describe "the acts that must not happen" do
    test "an impostor cannot move the anchor, even holding Rita's session", %{
      rita: rita,
      admin: admin
    } do
      {:ok, contact} =
        Auth.add_recovery_contact(rita, %{
          "email" => "rita@example.org",
          "pgp_public_key" => @rita_key
        })

      {:ok, _} = Auth.set_recovery_contact_verification(admin, contact.id, "verified")

      # Somebody with a stolen session points the anchor at their own key.
      {:ok, changed} =
        Auth.update_recovery_contact(rita, contact.id, %{"pgp_public_key" => @impostor_key})

      assert changed.status == "pending",
             """
             This is the property the whole scheme rests on. The new anchor is
             a claim again, and confirming it means an admin checking a
             signature against a key the real member never published — so a
             session compromise cannot become a permanent takeover.
             """

      assert {:error, :no_verified_contact} = Auth.issue_account_reset(admin, rita, contact.id)
    end

    test "an admin cannot originate an anchor on somebody else's account", %{
      rita: rita,
      admin: admin
    } do
      # Asserted as an absence, because it is the absence that matters: the
      # only function that creates a contact takes the owner and encrypts
      # against them, so an admin calling it writes on their own account.
      {:ok, contact} =
        Auth.add_recovery_contact(admin, %{
          "email" => "admin@example.org",
          "pgp_public_key" => @impostor_key
        })

      assert contact.user_id == admin.id
      assert Auth.list_recovery_contacts(rita) == []
      assert {:error, :no_verified_contact} = Auth.issue_account_reset(admin, rita, contact.id)
    end

    test "a peer admin is refused, and the console is the documented way round it", %{
      admin: admin
    } do
      peer = member("peer", "admin")
      other = member("other", "admin")

      {:ok, contact} =
        Auth.add_recovery_contact(peer, %{
          "email" => "peer@example.org",
          "pgp_public_key" => @rita_key
        })

      {:ok, _} = Auth.set_recovery_contact_verification(other, contact.id, "verified")

      assert {:error, :role_too_high} = Auth.issue_account_reset(admin, peer, contact.id)
      refute Auth.can_issue_account_reset?(admin, peer)

      # sysop.md §7: recovering staff needs shell access to the host, which
      # cannot be talked into anything. That path is this function, reached
      # through `bin/baudrate remote`.
      assert length(Auth.regenerate_recovery_codes(peer)) == 10
    end

    test "clearing second factors is a decision of its own, with its own line", %{
      rita: rita,
      admin: admin
    } do
      {:ok, contact} =
        Auth.add_recovery_contact(rita, %{
          "email" => "rita@example.org",
          "pgp_public_key" => @rita_key
        })

      {:ok, contact} = Auth.set_recovery_contact_verification(admin, contact.id, "verified")
      {:ok, _} = Auth.enable_totp(rita, Auth.generate_totp_secret())

      {:ok, token, _} =
        Auth.issue_account_reset(admin, rita, contact.id, clear_second_factors: true)

      assert "clear_second_factors" in audit_actions(rita),
             "\"take my 2FA off\" is the ask a social engineer makes; the log must say it was made"

      {:ok, rita, _} = Auth.redeem_account_reset(token, "RitasNewPass1!", "RitasNewPass1!")
      refute rita.totp_enabled
      assert Auth.list_webauthn_credentials(rita) == []
    end

    test "a link issued before a ban does not survive it", %{rita: rita, admin: admin} do
      {:ok, contact} =
        Auth.add_recovery_contact(rita, %{
          "email" => "rita@example.org",
          "pgp_public_key" => @rita_key
        })

      {:ok, contact} = Auth.set_recovery_contact_verification(admin, contact.id, "verified")
      {:ok, token, _} = Auth.issue_account_reset(admin, rita, contact.id)

      Repo.update!(Ecto.Changeset.change(rita, status: "banned"))

      assert {:error, :invalid} =
               Auth.redeem_account_reset(token, "RitasNewPass1!", "RitasNewPass1!")

      assert {:error, :invalid_credentials} =
               Auth.authenticate_by_password(rita.username, "RitasNewPass1!"),
             "the password was never set — the link bought its holder nothing"
    end

    test "an outstanding link can be called back before it is used", %{rita: rita, admin: admin} do
      {:ok, contact} =
        Auth.add_recovery_contact(rita, %{
          "email" => "rita@example.org",
          "pgp_public_key" => @rita_key
        })

      {:ok, contact} = Auth.set_recovery_contact_verification(admin, contact.id, "verified")
      {:ok, token, _} = Auth.issue_account_reset(admin, rita, contact.id)

      assert {:ok, 1} = Auth.revoke_account_reset(admin, rita)
      assert "revoke_account_reset" in audit_actions(rita)

      assert {:error, :invalid} =
               Auth.redeem_account_reset(token, "RitasNewPass1!", "RitasNewPass1!")

      assert Auth.account_reset_state(Auth.last_account_reset(rita)) == :revoked
    end

    test "a link nobody used expires on its own", %{rita: rita, admin: admin} do
      {:ok, contact} =
        Auth.add_recovery_contact(rita, %{
          "email" => "rita@example.org",
          "pgp_public_key" => @rita_key
        })

      {:ok, contact} = Auth.set_recovery_contact_verification(admin, contact.id, "verified")
      {:ok, token, reset} = Auth.issue_account_reset(admin, rita, contact.id)

      Repo.update_all(
        from(r in AccountReset, where: r.id == ^reset.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -60, :second)]
      )

      assert {:error, :invalid} =
               Auth.redeem_account_reset(token, "RitasNewPass1!", "RitasNewPass1!")

      assert Auth.account_reset_state(Auth.last_account_reset(rita)) == :expired
      assert is_nil(Auth.live_account_reset(rita))
    end
  end

  describe "what the member is told, in order" do
    test "every step of the procedure reaches them", %{rita: rita, admin: admin} do
      {:ok, contact} =
        Auth.add_recovery_contact(rita, %{
          "email" => "rita@example.org",
          "pgp_public_key" => @rita_key
        })

      {:ok, contact} = Auth.set_recovery_contact_verification(admin, contact.id, "verified")
      {:ok, token, _} = Auth.issue_account_reset(admin, rita, contact.id)
      {:ok, _, _} = Auth.redeem_account_reset(token, "RitasNewPass1!", "RitasNewPass1!")

      assert notice_types(rita) == [
               "recovery_contact_added",
               "recovery_contact_verified",
               "account_reset_issued",
               "account_reset_used"
             ]

      # All four are always-delivered: a member cannot switch off being told
      # that the way back into their account changed.
      always = Notification.always_delivered_types()
      for type <- notice_types(rita), do: assert(type in always)
    end
  end
end
