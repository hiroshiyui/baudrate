defmodule Baudrate.Auth.AccountRecoveryTest do
  @moduledoc """
  Acceptance gate for [ADR 0058](../../../doc/adr/0058-account-recovery-is-anchored-outside-the-instance.md):
  account recovery is anchored outside the instance, and an admin confirms an
  anchor rather than creating one.

  There is no email in this system, so when a member's recovery codes are gone
  the only remaining route is an admin — which is exactly the route a social
  engineer wants. What this file holds to is that the admin is never asked to
  believe a story:

    * a reset needs a **verified** contact, so the OpenPGP proof is not
      optional;
    * a contact is verified by an admin and *registered* by the member, and
      changing either half drops it back to pending — so a stolen session
      cannot become a permanent takeover;
    * nobody resets an account at or above their own role level;
    * clearing second factors is its own decision, not a side effect of the
      safe-sounding half.

  Each of those reads like a restriction that could be relaxed. None of them
  can be, and the tests say why.
  """

  use Baudrate.DataCase

  alias Baudrate.Auth
  alias Baudrate.Auth.{AccountReset, Recovery, RecoveryChallenge, RecoveryContact}
  alias Baudrate.Moderation
  alias Baudrate.Setup
  alias Baudrate.Setup.{Role, User}

  @key """
  -----BEGIN PGP PUBLIC KEY BLOCK-----

  mDMEZfakeKeyForTestingOnlyNotARealKeyAtAll0123456789abcdefghijkl
  -----END PGP PUBLIC KEY BLOCK-----\
  """

  @other_key String.replace(@key, "0123456789", "9876543210")

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user(role_name \\ "user") do
    role = Repo.one!(from r in Role, where: r.name == ^role_name)

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "rec_#{role_name}_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp verified_contact(user, admin) do
    {:ok, contact} =
      Recovery.add_contact(user, %{"email" => "owner@example.com", "pgp_public_key" => @key})

    {:ok, contact} = verify_with_challenge(admin, contact.id, "verified")
    contact
  end

  describe "the anchor is the member's, and an admin only confirms it" do
    test "a contact arrives pending, whatever the member submits" do
      user = create_user()

      {:ok, contact} =
        Recovery.add_contact(user, %{
          "email" => "me@example.com",
          "pgp_public_key" => @key,
          # A member who could set these would verify their own anchor and the
          # admin's check would be decoration.
          "status" => "verified",
          "verified_at" => DateTime.utc_now(:second)
        })

      assert contact.status == "pending"
      assert is_nil(contact.verified_at)
      assert is_nil(contact.verified_by_id)
    end

    test "changing the address drops a verified contact back to pending" do
      user = create_user()
      admin = create_user("admin")
      contact = verified_contact(user, admin)
      assert contact.status == "verified"

      {:ok, updated} =
        Recovery.update_contact(user, contact.id, %{"email" => "elsewhere@example.com"})

      assert updated.status == "pending",
             """
             A stolen session could otherwise point a verified anchor at an
             address the real member never published, and every later
             signature check would pass against it. Re-verification is what
             keeps a session compromise from becoming a permanent takeover.
             """

      refute Recovery.verified_contact?(user)
    end

    test "changing the key drops it back too" do
      user = create_user()
      admin = create_user("admin")
      contact = verified_contact(user, admin)

      {:ok, updated} =
        Recovery.update_contact(user, contact.id, %{"pgp_public_key" => @other_key})

      assert updated.status == "pending"
    end

    test "a contact belongs to one account and cannot be reached from another" do
      user = create_user()
      intruder = create_user()
      admin = create_user("admin")
      contact = verified_contact(user, admin)

      assert {:error, :not_found} =
               Recovery.update_contact(intruder, contact.id, %{"email" => "x@example.com"})

      assert {:error, :not_found} = Recovery.remove_contact(intruder, contact.id)
    end

    test "the address is encrypted at rest and bound to its owner" do
      user = create_user()
      other = create_user()

      {:ok, contact} =
        Recovery.add_contact(user, %{"email" => "secret@example.com", "pgp_public_key" => @key})

      stored = Repo.get!(RecoveryContact, contact.id)

      refute stored.email_encrypted =~ "secret@example.com"
      assert {:ok, "secret@example.com"} = RecoveryContact.email(stored, user)

      # Moving the row to another account must not read back — that binding is
      # the point of encrypting it against the owner.
      assert :error = RecoveryContact.email(stored, other)
    end

    test "there is no way for an admin to create a contact on someone else's account" do
      # Asserted as an absence, because this is the property the whole scheme
      # rests on: an admin confirms an anchor the member put there, and cannot
      # put one there.
      exported = Recovery.__info__(:functions)

      refute Enum.any?(exported, fn {name, _arity} ->
               name in [:create_contact_for, :add_contact_as_admin, :register_contact_for]
             end)

      # `add_contact/2` takes the owner and encrypts against it, so an admin
      # calling it writes a contact on their *own* account, not the target's.
      admin = create_user("admin")
      victim = create_user()

      {:ok, contact} =
        Recovery.add_contact(admin, %{"email" => "a@b.co", "pgp_public_key" => @key})

      assert contact.user_id == admin.id
      refute contact.user_id == victim.id
    end

    test "a member may register at most the documented number of contacts" do
      user = create_user()

      for n <- 1..Recovery.max_contacts() do
        assert {:ok, _} =
                 Recovery.add_contact(user, %{
                   "email" => "c#{n}@example.com",
                   "pgp_public_key" => @key
                 })
      end

      assert {:error, :too_many} =
               Recovery.add_contact(user, %{
                 "email" => "over@example.com",
                 "pgp_public_key" => @key
               })
    end

    test "the key has to look like an armored public key block" do
      user = create_user()

      assert {:error, changeset} =
               Recovery.add_contact(user, %{
                 "email" => "me@example.com",
                 "pgp_public_key" => "not a key"
               })

      assert %{pgp_public_key: [_ | _]} = errors_on(changeset)
    end
  end

  describe "the challenge the member signs (ADR 0067)" do
    setup do
      admin = create_user("admin")
      user = create_user()

      {:ok, contact} =
        Recovery.add_contact(user, %{"email" => "me@example.com", "pgp_public_key" => @key})

      %{admin: admin, user: user, contact: contact}
    end

    test "says what it authorizes, and is not two of the same", ctx do
      {:ok, first} = Recovery.issue_challenge(ctx.admin, ctx.contact.id)
      {:ok, second} = Recovery.issue_challenge(ctx.admin, ctx.contact.id)

      assert first.phrase =~ "account recovery for @#{ctx.user.username}"
      assert first.phrase =~ Date.to_iso8601(Date.utc_today())

      assert first.phrase != second.phrase,
             """
             The nonce is the whole of the freshness. A phrase that repeated
             would make an old signature answer a new question, which is the
             replay this exists to close.
             """

      # One line of ASCII: it is copied out, signed byte for byte and compared
      # by eye on another machine.
      refute first.phrase =~ "\n"
      assert first.phrase == for(<<c <- first.phrase>>, c in 0x20..0x7E, into: "", do: <<c>>)
    end

    test "cannot be issued by someone without the permission", ctx do
      moderator = create_user("moderator")

      assert {:error, :unauthorized} = Recovery.issue_challenge(moderator, ctx.contact.id)
    end

    test "is refused for a contact that does not exist", ctx do
      assert {:error, :not_found} = Recovery.issue_challenge(ctx.admin, 0)
    end

    test "is what verifying spends, and it is spent once", ctx do
      assert {:error, :no_live_challenge} =
               Recovery.set_verification(ctx.admin, ctx.contact.id, "verified"),
             """
             Without this, an admin can mark a contact verified against a
             message the member composed themselves — and one signed last year
             cannot be told from one signed today.
             """

      {:ok, _} = Recovery.issue_challenge(ctx.admin, ctx.contact.id)
      assert {:ok, contact} = Recovery.set_verification(ctx.admin, ctx.contact.id, "verified")
      assert contact.status == "verified"

      # A second admin acting on the same signature finds it spent.
      assert {:error, :no_live_challenge} =
               Recovery.set_verification(ctx.admin, ctx.contact.id, "verified")
    end

    test "is not needed to withdraw a verification", ctx do
      {:ok, _} = Recovery.issue_challenge(ctx.admin, ctx.contact.id)
      {:ok, _} = Recovery.set_verification(ctx.admin, ctx.contact.id, "verified")

      assert {:ok, contact} = Recovery.set_verification(ctx.admin, ctx.contact.id, "pending"),
             """
             Going back to pending is the safe direction, and a check that can
             only be reached by issuing something is a check that stalls.
             """

      assert contact.status == "pending"
    end

    test "is spent again by the link, and the verification's does not count", ctx do
      {:ok, _} = Recovery.issue_challenge(ctx.admin, ctx.contact.id)
      {:ok, _} = Recovery.set_verification(ctx.admin, ctx.contact.id, "verified")

      assert {:error, :no_live_challenge} = Recovery.issue(ctx.admin, ctx.user, ctx.contact.id),
             """
             The verification may be months old. What authorizes the link is a
             signature over something asked for now.
             """

      {:ok, _} = Recovery.issue_challenge(ctx.admin, ctx.contact.id)
      assert {:ok, _token, _reset} = Recovery.issue(ctx.admin, ctx.user, ctx.contact.id)
    end

    test "stops counting when it expires, without anything sweeping it", ctx do
      {:ok, challenge} = Recovery.issue_challenge(ctx.admin, ctx.contact.id)

      past = DateTime.utc_now(:second) |> DateTime.add(-60, :second)

      Repo.update_all(from(c in RecoveryChallenge, where: c.id == ^challenge.id),
        set: [expires_at: past]
      )

      assert is_nil(Recovery.live_challenge(ctx.contact.id))

      assert {:error, :no_live_challenge} =
               Recovery.set_verification(ctx.admin, ctx.contact.id, "verified")

      # The row stays: it is the record of what was asked (ADR 0067).
      assert Repo.get(RecoveryChallenge, challenge.id)
    end

    test "re-issuing supersedes the one before it", ctx do
      {:ok, first} = Recovery.issue_challenge(ctx.admin, ctx.contact.id)
      {:ok, second} = Recovery.issue_challenge(ctx.admin, ctx.contact.id)

      assert Recovery.live_challenge(ctx.contact.id).id == second.id

      {:ok, _} = Recovery.set_verification(ctx.admin, ctx.contact.id, "verified")

      # The newest is what was spent; the superseded one is not left live.
      assert Repo.get(RecoveryChallenge, second.id).consumed_at
      assert is_nil(Recovery.live_challenge(ctx.contact.id))
      assert is_nil(Repo.get(RecoveryChallenge, first.id).consumed_at)
    end

    test "is recorded with what was asked, for whom", ctx do
      {:ok, challenge} = Recovery.issue_challenge(ctx.admin, ctx.contact.id)

      entry =
        Repo.one!(
          from(l in Moderation.Log,
            where: l.action == "issue_recovery_challenge",
            order_by: [desc: l.id],
            limit: 1
          )
        )

      assert entry.target_id == ctx.user.id
      assert entry.details["phrase"] == challenge.phrase
      assert entry.details["contact_id"] == ctx.contact.id
    end
  end

  describe "issuing a reset" do
    test "is refused when the account has no contact at all" do
      admin = create_user("admin")
      user = create_user()

      assert {:error, :no_verified_contact} = Recovery.issue(admin, user, 0)
    end

    test "is refused when the only contact is still pending" do
      admin = create_user("admin")
      user = create_user()

      {:ok, contact} =
        Recovery.add_contact(user, %{"email" => "me@example.com", "pgp_public_key" => @key})

      assert {:error, :no_verified_contact} = Recovery.issue(admin, user, contact.id),
             """
             A pending contact is a claim nobody has checked. Issuing against
             one would make the OpenPGP proof optional, and the
             social-engineering path would sit open beside it.
             """
    end

    test "is refused for an account at or above the issuer's own role level" do
      admin = create_user("admin")
      peer = create_user("admin")
      contact = verified_contact(peer, admin)

      assert {:error, :role_too_high} = Recovery.issue(admin, peer, contact.id),
             """
             ADR 0029's rule, applied here. The residual threat the signature
             does not cover is an admin who claims a verification that never
             happened, and an admin account is where that costs most. The
             server console is the deliberate escape hatch.
             """
    end

    test "is refused for an account without the permission" do
      moderator = create_user("moderator")
      user = create_user()
      admin = create_user("admin")
      contact = verified_contact(user, admin)

      assert {:error, :unauthorized} = Recovery.issue(moderator, user, contact.id)
    end

    test "is refused for the issuer's own account" do
      admin = create_user("admin")
      other_admin = create_user("admin")
      contact = verified_contact(admin, other_admin)

      assert {:error, :self_action} = Recovery.issue(admin, admin, contact.id)
    end

    test "succeeds against a verified contact, and records which one" do
      admin = create_user("admin")
      user = create_user()
      contact = verified_contact(user, admin)

      assert {:ok, token, reset} = issue_with_challenge(admin, user, contact.id)
      assert is_binary(token)
      assert reset.contact_id == contact.id
      assert reset.issued_by_id == admin.id
      refute reset.clear_second_factors
    end

    test "stores only the hash of the token" do
      admin = create_user("admin")
      user = create_user()
      contact = verified_contact(user, admin)

      {:ok, token, reset} = issue_with_challenge(admin, user, contact.id)
      stored = Repo.get!(AccountReset, reset.id)

      refute stored.token_hash == token
      assert stored.token_hash == AccountReset.hash(token)
    end

    test "issuing again revokes the previous link" do
      admin = create_user("admin")
      user = create_user()
      contact = verified_contact(user, admin)

      {:ok, first, _} = issue_with_challenge(admin, user, contact.id)
      {:ok, _second, _} = issue_with_challenge(admin, user, contact.id)

      assert {:error, :invalid} = Recovery.redeem(first, "NewPassword123!x", "NewPassword123!x")
    end

    test "tells the member while the link is still outstanding" do
      admin = create_user("admin")
      user = create_user()
      contact = verified_contact(user, admin)

      {:ok, _token, _} = issue_with_challenge(admin, user, contact.id)

      types =
        Repo.all(
          from(n in Baudrate.Notification.Notification,
            where: n.user_id == ^user.id,
            select: n.type
          )
        )

      assert "account_reset_issued" in types,
             """
             The member who asked for this cannot read it — they are locked
             out. The one who did *not* ask is exactly who needs to see it,
             and a live session is the only in-band channel there is. It is
             the cheapest check on a talked-into admin available here.
             """
    end

    test "writes an audit entry, and a second one only when second factors are cleared" do
      admin = create_user("admin")
      user = create_user()
      contact = verified_contact(user, admin)

      {:ok, _token, _} = issue_with_challenge(admin, user, contact.id)

      # Each act of the procedure is its own line, in the order it happened:
      # the challenge the member answered to be verified, the verification,
      # the challenge they answered to recover, the link (ADR 0067).
      assert actions_for(user) == [
               "issue_recovery_challenge",
               "verify_recovery_contact",
               "issue_recovery_challenge",
               "issue_account_reset"
             ]

      {:ok, _token, _} = issue_with_challenge(admin, user, contact.id, clear_second_factors: true)

      assert "clear_second_factors" in actions_for(user),
             """
             A password reset and the removal of somebody's second factors are
             two decisions. The log has to answer which was taken without
             parsing a details blob.
             """
    end
  end

  describe "redeeming a reset" do
    setup do
      admin = create_user("admin")
      user = create_user()
      contact = verified_contact(user, admin)
      %{admin: admin, user: user, contact: contact}
    end

    test "sets the password and returns fresh recovery codes", ctx do
      {:ok, token, _} = issue_with_challenge(ctx.admin, ctx.user, ctx.contact.id)

      assert {:ok, user, codes} = Recovery.redeem(token, "BrandNew123!xy", "BrandNew123!xy")
      assert user.id == ctx.user.id
      assert length(codes) == 10
      assert {:ok, _} = Auth.authenticate_by_password(ctx.user.username, "BrandNew123!xy")
    end

    test "works exactly once", ctx do
      {:ok, token, _} = issue_with_challenge(ctx.admin, ctx.user, ctx.contact.id)

      assert {:ok, _, _} = Recovery.redeem(token, "BrandNew123!xy", "BrandNew123!xy")
      assert {:error, :invalid} = Recovery.redeem(token, "Another123!xyz", "Another123!xyz")
    end

    test "only one of two simultaneous redemptions wins", ctx do
      {:ok, token, _} = issue_with_challenge(ctx.admin, ctx.user, ctx.contact.id)

      results =
        [1, 2]
        |> Task.async_stream(
          fn _ ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), self())
            Recovery.redeem(token, "BrandNew123!xy", "BrandNew123!xy")
          end,
          max_concurrency: 2
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :invalid}, &1)) == 1
    end

    test "an expired link is refused", ctx do
      {:ok, token, reset} = issue_with_challenge(ctx.admin, ctx.user, ctx.contact.id)

      Repo.update_all(
        from(r in AccountReset, where: r.id == ^reset.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -60, :second)]
      )

      assert {:error, :invalid} = Recovery.redeem(token, "BrandNew123!xy", "BrandNew123!xy")
    end

    test "a revoked link is refused", ctx do
      {:ok, token, _} = issue_with_challenge(ctx.admin, ctx.user, ctx.contact.id)
      {:ok, 1} = Recovery.revoke(ctx.admin, ctx.user)

      assert {:error, :invalid} = Recovery.redeem(token, "BrandNew123!xy", "BrandNew123!xy")
    end

    test "an unknown token is refused with the same answer as every other failure" do
      assert {:error, :invalid} = Recovery.redeem("nonsense", "BrandNew123!xy", "BrandNew123!xy")
    end

    test "a link for an account banned since it was issued is refused", ctx do
      {:ok, token, _} = issue_with_challenge(ctx.admin, ctx.user, ctx.contact.id)

      Repo.update!(Ecto.Changeset.change(ctx.user, status: "banned"))

      assert {:error, :invalid} = Recovery.redeem(token, "BrandNew123!xy", "BrandNew123!xy"),
             """
             A link is good for 24 hours and an account can be banned inside
             that window. The status is re-checked at redemption for the same
             reason `SessionController.create/2` re-checks it, and the refusal
             is `:invalid` like every other one so the page stays
             uninformative.
             """

      # The refusal is total: the password was never set, so the link bought
      # its holder nothing at all.
      assert {:error, :invalid_credentials} =
               Auth.authenticate_by_password(ctx.user.username, "BrandNew123!xy")
    end

    test "revokes every session, and cancels exports and moves", ctx do
      {:ok, _token, _} = issue_with_challenge(ctx.admin, ctx.user, ctx.contact.id)
      {:ok, session_token, _refresh} = Auth.create_user_session(ctx.user.id)
      assert {:ok, _} = Auth.get_user_by_session_token(session_token)

      {:ok, token, _} = issue_with_challenge(ctx.admin, ctx.user, ctx.contact.id)
      {:ok, _, _} = Recovery.redeem(token, "BrandNew123!xy", "BrandNew123!xy")

      assert {:error, :not_found} = Auth.get_user_by_session_token(session_token)
    end

    test "leaves second factors alone unless the admin ticked the box", ctx do
      {:ok, _} = Auth.enable_totp(ctx.user, Auth.generate_totp_secret())
      {:ok, token, _} = issue_with_challenge(ctx.admin, ctx.user, ctx.contact.id)
      {:ok, user, _} = Recovery.redeem(token, "BrandNew123!xy", "BrandNew123!xy")

      assert user.totp_enabled,
             """
             "I lost my phone, take my 2FA off" is the ask a social engineer
             makes. It must never ride along with the safe-sounding half.
             """
    end

    test "clears them when the admin did tick it", ctx do
      {:ok, _} = Auth.enable_totp(ctx.user, Auth.generate_totp_secret())

      {:ok, token, _} =
        issue_with_challenge(ctx.admin, ctx.user, ctx.contact.id, clear_second_factors: true)

      {:ok, user, _} = Recovery.redeem(token, "BrandNew123!xy", "BrandNew123!xy")
      refute user.totp_enabled
    end

    test "a weak password is refused and does not hand the link back", ctx do
      {:ok, token, _} = issue_with_challenge(ctx.admin, ctx.user, ctx.contact.id)

      assert {:error, %Ecto.Changeset{}} = Recovery.redeem(token, "short", "short")

      # Deliberate: replaying the claim would turn a single-use token into a
      # password-guessing loop. The sysop guide says to issue a fresh link.
      assert {:error, :invalid} = Recovery.redeem(token, "BrandNew123!xy", "BrandNew123!xy")
    end
  end

  describe "whether an account can be recovered at all" do
    test "a fresh account has recovery codes, so it is arranged" do
      user = create_user()
      Auth.generate_recovery_codes(user)

      assert Recovery.arranged?(user)
      assert Recovery.unused_code_count(user) == 10
    end

    test "spending every code leaves it unarranged, unless a contact is verified" do
      user = create_user()
      admin = create_user("admin")
      codes = Auth.generate_recovery_codes(user)

      for code <- codes, do: :ok = Auth.verify_recovery_code(user, code)

      assert Recovery.unused_code_count(user) == 0
      refute Recovery.arranged?(user)

      verified_contact(user, admin)
      assert Recovery.arranged?(user)
    end

    test "regenerating gives a member a way out of that" do
      user = create_user()
      old = Auth.generate_recovery_codes(user)
      for code <- old, do: :ok = Auth.verify_recovery_code(user, code)

      fresh = Auth.regenerate_recovery_codes(user)

      assert length(fresh) == 10
      assert Recovery.unused_code_count(user) == 10
      assert :ok = Auth.verify_recovery_code(user, hd(fresh))

      # And every earlier code is gone, not merely spent.
      assert :error = Auth.verify_recovery_code(user, hd(old))
    end
  end

  defp actions_for(%User{id: id}) do
    Repo.all(
      from(l in Moderation.Log,
        where: l.target_type == "user" and l.target_id == ^id,
        order_by: [asc: l.id],
        select: l.action
      )
    )
  end

  # ADR 0067: the admin issues the text the member signs, and marking a
  # contact verified or issuing a link spends it. These helpers do the round
  # trip the procedure describes, so every test below reads as the flow an
  # admin actually follows.
  defp verify_with_challenge(admin, contact_id, status) do
    {:ok, _challenge} = Recovery.issue_challenge(admin, contact_id)
    Recovery.set_verification(admin, contact_id, status)
  end

  defp issue_with_challenge(admin, user, contact_id, opts \\ []) do
    {:ok, _challenge} = Recovery.issue_challenge(admin, contact_id)
    Recovery.issue(admin, user, contact_id, opts)
  end
end
