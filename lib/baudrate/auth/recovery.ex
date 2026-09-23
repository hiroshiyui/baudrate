defmodule Baudrate.Auth.Recovery do
  @moduledoc """
  Account recovery: the out-of-band anchor, and the admin-issued reset link
  that rests on it ([ADR 0058](../../../doc/adr/0058-account-recovery-is-anchored-outside-the-instance.md)).

  There is no email in this system. Recovery codes are the only self-service
  way back in, and when those are gone the remaining path is an admin — which
  is exactly the path a social engineer wants. So the admin is not asked to
  believe a story:

    * A member registers one or more recovery addresses and an **OpenPGP public
      key** from their own signed-in session, behind step-up
      re-authentication (ADR 0022).
    * An admin confirms, out of band, that a signed message from that address
      verifies against that key, and marks the contact verified.
    * To recover, the member mails the admin from that address, signed by that
      key. The admin verifies the signature **in their own client** and issues
      a link.

  **Baudrate sends no mail, verifies no signature and fetches no key.** It
  holds the anchor and records the verdict; every cryptographic check is the
  admin's, and `doc/sysop.md` is the procedure. That keeps a mail server from
  becoming a dependency of this instance and keeps the anchor a key the
  instance never holds.

  ## What the checks here are actually defending

    * **The member registers the anchor; the admin only confirms it.** There is
      no path for an admin to *create* a contact on someone else's account, and
      changing an address or a key drops it back to `pending`
      (`RecoveryContact`). Forging the anchor therefore needs the member's own
      session or their own private key.
    * **A reset needs a verified contact.** `issue/4` refuses otherwise. If an
      admin could reset an account that registered nothing, the proof would be
      optional and the social-engineering path would sit open beside it. The
      cost is real: recovery must be arranged in advance, and a member who
      arranged nothing has no way back.
    * **Never an account at or above the issuer's own role level** — ADR 0029's
      rule for sanctions, applied here. The residual threat the signature does
      not cover is an admin who claims a verification that never happened, and
      an admin account is where that costs most. Recovering an admin means the
      server console, which needs shell access and cannot be talked into
      anything.
    * **Clearing second factors is a separate decision.** `issue/4` takes it as
      its own flag with its own audit line, because "I lost my phone, take my
      2FA off" is the ask, and it must not ride along with the safe-sounding
      half.

  Authorization lives here and not in the LiveView, per ADR 0016.
  """

  import Ecto.Query

  alias Baudrate.Auth.{
    AccountReset,
    RecoveryChallenge,
    RecoveryCode,
    RecoveryContact,
    SecondFactor,
    Sessions,
    WebAuthn
  }

  alias Baudrate.Notification.Hooks
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.User

  @permission "admin.manage_users"
  @max_contacts 3

  @doc "How many recovery contacts one account may register."
  def max_contacts, do: @max_contacts

  # --- Contacts: the member's side ---

  @doc """
  Every recovery contact on an account, oldest first.

  Addresses come back decrypted as `:email` on each struct; one that cannot be
  read is left `nil` rather than raising, so a key problem shows up as a
  contact an admin cannot act on instead of a 500 on the profile page.
  """
  @spec list_contacts(User.t()) :: [RecoveryContact.t()]
  def list_contacts(%User{} = user) do
    from(c in RecoveryContact, where: c.user_id == ^user.id, order_by: [asc: c.id])
    |> Repo.all()
    |> Enum.map(&with_email(&1, user))
  end

  @doc """
  Registers a recovery contact for `user`.

  Arrives `pending`: an address and a key are a claim until an admin has
  checked a signature against them.
  """
  @spec add_contact(User.t(), map()) ::
          {:ok, RecoveryContact.t()} | {:error, :too_many | Ecto.Changeset.t()}
  def add_contact(%User{} = user, attrs) do
    if count_contacts(user) >= @max_contacts do
      {:error, :too_many}
    else
      %RecoveryContact{}
      |> RecoveryContact.changeset(attrs, user)
      |> Repo.insert()
      |> notify_contact_change(user, "recovery_contact_added")
    end
  end

  @doc """
  Replaces the address or key on one of `user`'s own contacts.

  Scoped to the owner, so a client-supplied id cannot reach anybody else's row.
  The changeset drops it back to `pending`.
  """
  @spec update_contact(User.t(), integer(), map()) ::
          {:ok, RecoveryContact.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_contact(%User{} = user, contact_id, attrs) do
    case own_contact(user, contact_id) do
      nil ->
        {:error, :not_found}

      contact ->
        contact
        |> RecoveryContact.changeset(attrs, user)
        |> Repo.update()
        |> notify_contact_change(user, "recovery_contact_added")
    end
  end

  @doc """
  Removes one of `user`'s own contacts.

  Any reset link issued against it keeps working: the link was authorised by a
  signature the admin already checked, and revoking it silently on an unrelated
  edit would give an attacker with a session a way to cancel a genuine
  recovery. Use `revoke/2` to stop a link.
  """
  @spec remove_contact(User.t(), integer()) :: {:ok, RecoveryContact.t()} | {:error, :not_found}
  def remove_contact(%User{} = user, contact_id) do
    case own_contact(user, contact_id) do
      nil ->
        {:error, :not_found}

      contact ->
        case Repo.delete(contact) do
          {:ok, deleted} ->
            Hooks.notify_account_security(user.id, "recovery_contact_removed", %{
              "label" => label_of(deleted)
            })

            {:ok, deleted}

          error ->
            error
        end
    end
  end

  @doc """
  Whether this account could be recovered at all today.

  True when it has a verified contact, or at least one unused recovery code.
  This is what the recovery notice asks, and it is deliberately an *or*: either
  route is a way back, and nagging someone who has one of them would be the
  site deciding how they should arrange their own safety.
  """
  @spec arranged?(User.t()) :: boolean()
  def arranged?(%User{} = user), do: verified_contact?(user) or unused_code_count(user) > 0

  @doc "How many of this account's recovery codes are still unused."
  @spec unused_code_count(User.t()) :: non_neg_integer()
  def unused_code_count(%User{} = user) do
    Repo.aggregate(
      from(c in RecoveryCode, where: c.user_id == ^user.id and is_nil(c.used_at)),
      :count
    )
  end

  @doc "Whether the account has at least one verified recovery contact."
  @spec verified_contact?(User.t()) :: boolean()
  def verified_contact?(%User{} = user) do
    Repo.exists?(
      from(c in RecoveryContact, where: c.user_id == ^user.id and c.status == "verified")
    )
  end

  # --- Contacts: the admin's side ---

  @doc """
  Issues the text the member is asked to sign for `contact` (ADR 0067).

  Re-issuing supersedes by recency rather than by a column: `live_challenge/1`
  reads the newest row and nothing older, so the phrase an admin sent before
  this one stops being the answer they will accept — and does not come back
  when this one is spent. Nothing is deleted — the row is the
  record of what was asked, beside the log entry that names it.
  """
  @spec issue_challenge(User.t(), integer()) ::
          {:ok, RecoveryChallenge.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def issue_challenge(%User{} = admin, contact_id) do
    with :ok <- authorize_verify(admin),
         %RecoveryContact{} = contact <- Repo.get(RecoveryContact, contact_id),
         %User{} = owner <- Repo.get(User, contact.user_id) do
      contact
      |> RecoveryChallenge.build(owner, admin, Setup.get_setting("site_name"))
      |> Repo.insert()
      |> case do
        {:ok, challenge} ->
          Baudrate.Moderation.log_action(admin.id, "issue_recovery_challenge",
            target_type: "user",
            target_id: owner.id,
            details: %{"contact_id" => contact.id, "phrase" => challenge.phrase}
          )

          {:ok, challenge}

        error ->
          error
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The challenge `contact_id` is waiting on, or `nil`.

  **Only the newest row is ever considered**, and only while it is unconsumed
  and unexpired. Reading "the newest *live* row" instead would resurrect a
  superseded challenge the moment its successor was spent — an admin would be
  back to accepting a phrase they had already told the member to ignore, which
  is the replay this whole mechanism closes.

  Live is decided by the clock at read, never by a sweep (ADR 0029): an expired
  row stays in the table and stops counting by itself.
  """
  @spec live_challenge(integer()) :: RecoveryChallenge.t() | nil
  def live_challenge(contact_id) do
    newest =
      Repo.one(
        from(c in RecoveryChallenge,
          where: c.recovery_contact_id == ^contact_id,
          order_by: [desc: c.id],
          limit: 1
        )
      )

    if newest && RecoveryChallenge.live?(newest, DateTime.utc_now(:second)), do: newest
  end

  @doc """
  Marks a contact verified, or puts it back to pending.

  An admin can only ever confirm a contact the member registered themselves —
  there is no function here that creates one on somebody else's account, and
  that absence is the point.

  Verifying **consumes a live challenge** and refuses with
  `:no_live_challenge` when there is none (ADR 0067). That does not prove the
  admin checked anything; it does mean the text they asked for was this
  instance's and was answerable once. Withdrawing a verification needs no
  challenge: going back to `pending` is the safe direction, and a check that
  can only be reached by issuing something is a check that stalls.
  """
  @spec set_verification(User.t(), integer(), String.t()) ::
          {:ok, RecoveryContact.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def set_verification(%User{} = admin, contact_id, status)
      when status in ["pending", "verified"] do
    with :ok <- authorize_verify(admin),
         %RecoveryContact{} = contact <- Repo.get(RecoveryContact, contact_id),
         :ok <- consume_challenge_for(status, contact, admin) do
      contact
      |> RecoveryContact.verification_changeset(status, admin)
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          audit_verification(admin, updated, status)

          if status == "verified" do
            Hooks.notify_account_security(updated.user_id, "recovery_contact_verified", %{
              "label" => label_of(updated)
            })
          end

          {:ok, updated}

        error ->
          error
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- The reset link ---

  @doc """
  Issues a single-use reset link for `user`, returning the token once.

  `contact_id` names the verified contact whose signature the admin checked —
  it is recorded on the row, so the audit trail says *which* anchor the
  decision rested on rather than merely that one existed.

  Refuses with `:unauthorized` (no permission), `:self_action`,
  `:role_too_high` (ADR 0029's rule), `:no_verified_contact`, or
  `:no_live_challenge` when no challenge for that contact is waiting to be
  answered (ADR 0067). Any earlier live link for the account is revoked, so
  there is never more than one.
  """
  @spec issue(User.t(), User.t(), integer(), keyword()) ::
          {:ok, String.t(), AccountReset.t()} | {:error, atom() | Ecto.Changeset.t()}
  def issue(%User{} = admin, %User{} = user, contact_id, opts \\ []) do
    clear_second_factors? = Keyword.get(opts, :clear_second_factors, false)

    with :ok <- authorize_issue(admin, user),
         %RecoveryContact{} = contact <- verified_contact(user, contact_id),
         :ok <- consume_challenge(contact, admin) do
      revoke_live_resets(user)
      {token, changeset} = AccountReset.build(user, admin, contact, clear_second_factors?)

      case Repo.insert(changeset) do
        {:ok, reset} ->
          audit_issue(admin, user, reset)

          # Told at *issue* time, not only after redemption. The member who
          # asked for this cannot read it — they are locked out — but the one
          # who did not asked is exactly who needs to see it, and a live
          # session is the only in-band channel there is. It is the cheapest
          # check on a talked-into admin that exists here.
          Hooks.notify_account_security(user.id, "account_reset_issued", %{
            "expires_at" => DateTime.to_iso8601(reset.expires_at),
            "second_factors_cleared" => reset.clear_second_factors
          })

          {:ok, token, reset}

        error ->
          error
      end
    else
      nil -> {:error, :no_verified_contact}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Whether `admin` could issue a reset for `user` right now — the same checks
  `issue/4` runs, without issuing anything.

  A separate predicate rather than a dry run of `issue/4`: a UI asking "may I
  show this button" must not be one refactor away from calling the thing the
  button does.
  """
  @spec can_issue?(User.t(), User.t()) :: boolean()
  def can_issue?(%User{} = admin, %User{} = user) do
    authorize_issue(admin, user) == :ok and verified_contact?(user)
  end

  @doc """
  Revokes any live reset link for `user`. Returns how many were revoked.
  """
  @spec revoke(User.t(), User.t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def revoke(%User{} = admin, %User{} = user) do
    with :ok <- authorize_issue(admin, user) do
      count = revoke_live_resets(user)

      if count > 0 do
        Baudrate.Moderation.log_action(admin.id, "revoke_account_reset",
          target_type: "user",
          target_id: user.id
        )
      end

      {:ok, count}
    end
  end

  @doc "The live reset link for an account, if there is one."
  @spec live_reset(User.t()) :: AccountReset.t() | nil
  def live_reset(%User{} = user) do
    now = DateTime.utc_now(:second)

    Repo.one(
      from(r in AccountReset,
        where:
          r.user_id == ^user.id and is_nil(r.used_at) and is_nil(r.revoked_at) and
            r.expires_at > ^now,
        order_by: [desc: r.id],
        limit: 1,
        preload: [:issued_by]
      )
    )
  end

  @doc """
  The most recent reset for an account whatever became of it — outstanding,
  used, revoked or expired.

  `live_reset/1` answers "is there one to revoke"; this answers "what happened
  to the one I issued", which is the question an admin comes back with. Without
  it the admin page fell silent the moment a link was redeemed, and a spent
  link looked exactly like a link that was never issued.
  """
  @spec last_reset(User.t()) :: AccountReset.t() | nil
  def last_reset(%User{} = user) do
    Repo.one(
      from(r in AccountReset,
        where: r.user_id == ^user.id,
        order_by: [desc: r.id],
        limit: 1,
        preload: [:issued_by]
      )
    )
  end

  @doc """
  What state a reset is in, for display: `:outstanding`, `:used`, `:revoked`
  or `:expired`.
  """
  @spec reset_state(AccountReset.t()) :: :outstanding | :used | :revoked | :expired
  def reset_state(%AccountReset{used_at: used}) when not is_nil(used), do: :used
  def reset_state(%AccountReset{revoked_at: revoked}) when not is_nil(revoked), do: :revoked

  def reset_state(%AccountReset{expires_at: expires}) do
    if DateTime.compare(expires, DateTime.utc_now()) == :gt, do: :outstanding, else: :expired
  end

  @doc """
  Redeems a reset token: sets the password and takes the account back.

  Single-use is claimed with one conditional `UPDATE`, so two simultaneous
  redemptions cannot both succeed. Every failure — unknown token, expired,
  already used, revoked, weak password — is the caller's to render
  *identically*; this function distinguishes them only so it can be tested.

  On success the account is put back in the member's hands and out of anybody
  else's: every session is revoked, exports and moves are cancelled, and a new
  set of recovery codes is issued. Second factors survive unless the admin
  ticked that box when issuing.
  """
  @spec redeem(String.t(), String.t(), String.t()) ::
          {:ok, User.t(), [String.t()]}
          | {:error, :invalid | :second_factors | Ecto.Changeset.t()}
  def redeem(token, password, password_confirmation) when is_binary(token) do
    now = DateTime.utc_now(:second)

    claim =
      from(r in AccountReset,
        where:
          r.token_hash == ^AccountReset.hash(token) and is_nil(r.used_at) and
            is_nil(r.revoked_at) and r.expires_at > ^now,
        select: r
      )

    case Repo.update_all(claim, set: [used_at: now]) do
      {1, [reset]} -> apply_reset(reset, password, password_confirmation)
      _ -> {:error, :invalid}
    end
  end

  # --- private ---

  defp apply_reset(%AccountReset{} = reset, password, password_confirmation) do
    user = Repo.get!(User, reset.user_id) |> Repo.preload(:role)

    # The status is re-checked at redemption, not only at issue: a link is
    # good for 24 hours and an account can be banned inside that window.
    # `SessionController.create/2` re-checks for the same reason. The refusal
    # is `:invalid`, like every other one, so the page stays uninformative.
    if user.status == "banned" do
      {:error, :invalid}
    else
      do_apply_reset(user, reset, password, password_confirmation)
    end
  end

  defp do_apply_reset(%User{} = user, %AccountReset{} = reset, password, password_confirmation) do
    changeset =
      User.password_reset_changeset(user, %{
        "password" => password,
        "password_confirmation" => password_confirmation
      })

    case Repo.update(changeset) do
      {:ok, updated} ->
        finish_reset(updated, reset)

      {:error, changeset} ->
        # The claim already consumed the link. Putting it back would open a
        # password-guessing loop against a single-use token, so a member who
        # fumbles the confirmation needs a fresh link — which the sysop guide
        # says to issue rather than hunt for the old one.
        {:error, changeset}
    end
  end

  defp finish_reset(%User{} = user, %AccountReset{} = reset) do
    if reset.clear_second_factors do
      SecondFactor.disable_totp(user)
      WebAuthn.delete_all_credentials(user)
    end

    Sessions.delete_all_sessions_for_user(user.id)
    Baudrate.DataPortability.cancel_active_exports(user.id, "account_reset")
    Baudrate.AccountMigration.cancel_active_moves(user.id, "account_reset")

    codes = SecondFactor.generate_recovery_codes(user)

    Hooks.notify_account_security(user.id, "account_reset_used", %{
      "second_factors_cleared" => reset.clear_second_factors
    })

    {:ok, Repo.get!(User, user.id) |> Repo.preload(:role), codes}
  end

  defp revoke_live_resets(%User{} = user) do
    now = DateTime.utc_now(:second)

    {count, _} =
      Repo.update_all(
        from(r in AccountReset,
          where: r.user_id == ^user.id and is_nil(r.used_at) and is_nil(r.revoked_at)
        ),
        set: [revoked_at: now]
      )

    count
  end

  defp verified_contact(%User{} = user, contact_id) do
    Repo.one(
      from(c in RecoveryContact,
        where: c.user_id == ^user.id and c.id == ^contact_id and c.status == "verified"
      )
    )
  end

  defp own_contact(%User{} = user, contact_id) do
    Repo.one(from(c in RecoveryContact, where: c.user_id == ^user.id and c.id == ^contact_id))
  end

  defp count_contacts(%User{} = user) do
    Repo.aggregate(from(c in RecoveryContact, where: c.user_id == ^user.id), :count)
  end

  defp with_email(%RecoveryContact{} = contact, user) do
    case RecoveryContact.email(contact, user) do
      {:ok, email} -> %{contact | email: email}
      :error -> contact
    end
  end

  defp notify_contact_change({:ok, contact}, %User{} = user, type) do
    Hooks.notify_account_security(user.id, type, %{"label" => label_of(contact)})
    {:ok, with_email(contact, user)}
  end

  defp notify_contact_change(error, _user, _type), do: error

  # The notice must not carry the address: a notification is rendered in a
  # list, is pushed to a device, and is exactly the surface this column is
  # encrypted to stay off.
  defp label_of(%RecoveryContact{label: label}) when is_binary(label) and label != "", do: label
  defp label_of(%RecoveryContact{}), do: ""

  defp authorize_verify(%User{} = admin) do
    if permitted?(admin), do: :ok, else: {:error, :unauthorized}
  end

  # Withdrawing a verification is always allowed; confirming one spends the
  # challenge the member answered (ADR 0067).
  defp consume_challenge_for("verified", contact, admin), do: consume_challenge(contact, admin)
  defp consume_challenge_for(_status, _contact, _admin), do: :ok

  # One conditional UPDATE, like `claim_download/2` and `HeldPosts.claim/2`:
  # two admins acting on the same signature spend the same row, and the second
  # one is told there is nothing live rather than both being waved through.
  defp consume_challenge(%RecoveryContact{} = contact, %User{} = admin) do
    now = DateTime.utc_now(:second)

    case live_challenge(contact.id) do
      nil ->
        {:error, :no_live_challenge}

      challenge ->
        {count, _} =
          Repo.update_all(
            from(c in RecoveryChallenge,
              where: c.id == ^challenge.id and is_nil(c.consumed_at) and c.expires_at > ^now
            ),
            set: [consumed_at: now, consumed_by_id: admin.id, updated_at: now]
          )

        if count == 1, do: :ok, else: {:error, :no_live_challenge}
    end
  end

  defp authorize_issue(%User{} = admin, %User{} = user) do
    cond do
      admin.id == user.id -> {:error, :self_action}
      not permitted?(admin) -> {:error, :unauthorized}
      outranks_or_equals?(user, admin) -> {:error, :role_too_high}
      true -> :ok
    end
  end

  defp permitted?(%User{role: %{name: name}}) when is_binary(name),
    do: Setup.has_permission?(name, @permission)

  defp permitted?(%User{} = admin), do: permitted?(Repo.preload(admin, :role))
  defp permitted?(_), do: false

  # Never act on an account at or above your own level, however the roles are
  # configured (ADR 0029). Here it is what keeps a talked-into admin from
  # reaching another admin's account.
  defp outranks_or_equals?(target, actor) do
    Setup.role_level(role_name(target)) >= Setup.role_level(role_name(actor))
  end

  defp role_name(%User{role: %{name: name}}) when is_binary(name), do: name
  defp role_name(%User{} = user), do: Repo.preload(user, :role).role.name

  defp audit_verification(%User{} = admin, %RecoveryContact{} = contact, status) do
    # Literal action names: `Moderation.Log.@valid_actions` is an allow-list
    # and `log_test.exs` walks every call site for them, which a name built at
    # runtime would defeat.
    action =
      case status do
        "verified" -> "verify_recovery_contact"
        "pending" -> "unverify_recovery_contact"
      end

    Baudrate.Moderation.log_action(admin.id, action,
      target_type: "user",
      target_id: contact.user_id,
      details: %{"contact_id" => contact.id}
    )
  end

  defp audit_issue(%User{} = admin, %User{} = user, %AccountReset{} = reset) do
    Baudrate.Moderation.log_action(admin.id, "issue_account_reset",
      target_type: "user",
      target_id: user.id,
      details: %{"contact_id" => reset.contact_id, "expires_at" => reset.expires_at}
    )

    # A second, separate line: a password reset and the removal of somebody's
    # second factors are two decisions, and the log has to be able to answer
    # which one was taken without parsing a details blob.
    if reset.clear_second_factors do
      Baudrate.Moderation.log_action(admin.id, "clear_second_factors",
        target_type: "user",
        target_id: user.id
      )
    end
  end
end
