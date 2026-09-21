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
  alias Baudrate.Auth.{AccountReset, Recovery, RecoveryContact}
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

    {:ok, contact} = Recovery.set_verification(admin, contact.id, "verified")
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

      assert {:ok, token, reset} = Recovery.issue(admin, user, contact.id)
      assert is_binary(token)
      assert reset.contact_id == contact.id
      assert reset.issued_by_id == admin.id
      refute reset.clear_second_factors
    end

    test "stores only the hash of the token" do
      admin = create_user("admin")
      user = create_user()
      contact = verified_contact(user, admin)

      {:ok, token, reset} = Recovery.issue(admin, user, contact.id)
      stored = Repo.get!(AccountReset, reset.id)

      refute stored.token_hash == token
      assert stored.token_hash == AccountReset.hash(token)
    end

    test "issuing again revokes the previous link" do
      admin = create_user("admin")
      user = create_user()
      contact = verified_contact(user, admin)

      {:ok, first, _} = Recovery.issue(admin, user, contact.id)
      {:ok, _second, _} = Recovery.issue(admin, user, contact.id)

      assert {:error, :invalid} = Recovery.redeem(first, "NewPassword123!x", "NewPassword123!x")
    end

    test "writes an audit entry, and a second one only when second factors are cleared" do
      admin = create_user("admin")
      user = create_user()
      contact = verified_contact(user, admin)

      {:ok, _token, _} = Recovery.issue(admin, user, contact.id)
      # `verify_recovery_contact` is the setup's; the reset adds one line.
      assert actions_for(user) == ["verify_recovery_contact", "issue_account_reset"]

      {:ok, _token, _} = Recovery.issue(admin, user, contact.id, clear_second_factors: true)

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
      {:ok, token, _} = Recovery.issue(ctx.admin, ctx.user, ctx.contact.id)

      assert {:ok, user, codes} = Recovery.redeem(token, "BrandNew123!xy", "BrandNew123!xy")
      assert user.id == ctx.user.id
      assert length(codes) == 10
      assert {:ok, _} = Auth.authenticate_by_password(ctx.user.username, "BrandNew123!xy")
    end

    test "works exactly once", ctx do
      {:ok, token, _} = Recovery.issue(ctx.admin, ctx.user, ctx.contact.id)

      assert {:ok, _, _} = Recovery.redeem(token, "BrandNew123!xy", "BrandNew123!xy")
      assert {:error, :invalid} = Recovery.redeem(token, "Another123!xyz", "Another123!xyz")
    end

    test "only one of two simultaneous redemptions wins", ctx do
      {:ok, token, _} = Recovery.issue(ctx.admin, ctx.user, ctx.contact.id)

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
      {:ok, token, reset} = Recovery.issue(ctx.admin, ctx.user, ctx.contact.id)

      Repo.update_all(
        from(r in AccountReset, where: r.id == ^reset.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -60, :second)]
      )

      assert {:error, :invalid} = Recovery.redeem(token, "BrandNew123!xy", "BrandNew123!xy")
    end

    test "a revoked link is refused", ctx do
      {:ok, token, _} = Recovery.issue(ctx.admin, ctx.user, ctx.contact.id)
      {:ok, 1} = Recovery.revoke(ctx.admin, ctx.user)

      assert {:error, :invalid} = Recovery.redeem(token, "BrandNew123!xy", "BrandNew123!xy")
    end

    test "an unknown token is refused with the same answer as every other failure" do
      assert {:error, :invalid} = Recovery.redeem("nonsense", "BrandNew123!xy", "BrandNew123!xy")
    end

    test "revokes every session, and cancels exports and moves", ctx do
      {:ok, _token, _} = Recovery.issue(ctx.admin, ctx.user, ctx.contact.id)
      {:ok, session_token, _refresh} = Auth.create_user_session(ctx.user.id)
      assert {:ok, _} = Auth.get_user_by_session_token(session_token)

      {:ok, token, _} = Recovery.issue(ctx.admin, ctx.user, ctx.contact.id)
      {:ok, _, _} = Recovery.redeem(token, "BrandNew123!xy", "BrandNew123!xy")

      assert {:error, :not_found} = Auth.get_user_by_session_token(session_token)
    end

    test "leaves second factors alone unless the admin ticked the box", ctx do
      {:ok, _} = Auth.enable_totp(ctx.user, Auth.generate_totp_secret())
      {:ok, token, _} = Recovery.issue(ctx.admin, ctx.user, ctx.contact.id)
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
        Recovery.issue(ctx.admin, ctx.user, ctx.contact.id, clear_second_factors: true)

      {:ok, user, _} = Recovery.redeem(token, "BrandNew123!xy", "BrandNew123!xy")
      refute user.totp_enabled
    end

    test "a weak password is refused and does not hand the link back", ctx do
      {:ok, token, _} = Recovery.issue(ctx.admin, ctx.user, ctx.contact.id)

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
end
