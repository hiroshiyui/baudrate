defmodule Baudrate.AccountDeletion do
  @moduledoc """
  A member deleting their own account (ADR 0072).

  ## The shape of it

    * **Requested** from `/profile/account` behind step-up
      re-authentication (`request/3`). Two-factor authentication is not
      required: anyone may leave. Bots, staff and board moderators are
      refused — the admin deletes a bot, and a moderator must be removed
      first, the same refusals an account move makes.
    * **It waits 7 days**, and **signing in cancels it**
      (`cancel_pending/2`, called from the one function every sign-in
      reaches). Requesting signs out every other session straight away and
      cancels a data export or account move in progress.
    * **Then the hourly sweep carries it out** (`sweep/0`), resumably:
      the row is claimed (`executing`), the member's content is withdrawn
      if they chose that, their direct messages are blanked, and finally —
      in one transaction — the account is unfollowed from everywhere, the
      row becomes a tombstone, `Delete(Person)` is queued and the request
      is marked `completed`.

  ## The row is never deleted

  `articles.user_id` cascades to other members' comments, the direct
  message check constraints refuse the delete outright, reports would lose
  their evidence, and a queued `Delete(Person)` could not be signed once
  the row was gone. So the user row becomes a tombstone
  (`Baudrate.Setup.User.tombstone_changeset/1`): everything personal is
  cleared, the username stays reserved, and content kept under it renders as
  "deleted account".

  ## The keys go last

  The account's signing keys stay until its last deliveries are out: the
  `Undo`s, `Delete(Tombstone)`s and `Delete(Person)` are delivered after the
  tombstone, and a server that never cached this actor has to fetch the key
  to verify them. `sweep_keys/0` clears them once no pending or failed
  delivery job carries the actor and 30 days have passed.
  `Baudrate.Federation.KeyStore` never generates a key for a deleted account.
  """

  import Ecto.Query
  require Logger

  alias Baudrate.AccountDeletion.Deletion
  alias Baudrate.{Auth, Repo}
  alias Baudrate.Content.{Article, Comment}
  alias Baudrate.DataPortability.UserAgent
  alias Baudrate.Federation
  alias Baudrate.Federation.{Delivery, Follower, Publisher, RemoteActor, UserFollow}
  alias Baudrate.Messaging.DirectMessage
  alias Baudrate.Notification.Hooks
  alias Baudrate.Setup.User

  @wait_seconds 7 * 86_400
  @key_grace_seconds 30 * 86_400
  @staff_roles ~w(admin moderator)
  # Items (articles, comments, messages) withdrawn per sweep, so one
  # prolific account cannot stall the hourly cleaner's other steps.
  @batch 300

  @doc "Seconds between requesting a deletion and carrying it out."
  def wait_seconds, do: @wait_seconds

  # ---------------------------------------------------------------------------
  # Requesting
  # ---------------------------------------------------------------------------

  @doc """
  Returns `:ok` when `user` may delete their own account, otherwise
  `{:error, :bot | :staff | :board_moderator | :deleted}`.
  """
  @spec eligibility(User.t()) :: :ok | {:error, atom()}
  def eligibility(%User{} = user) do
    user = Repo.preload(user, :role)

    cond do
      user.status == "deleted" -> {:error, :deleted}
      user.is_bot -> {:error, :bot}
      user.role && user.role.name in @staff_roles -> {:error, :staff}
      board_moderator?(user.id) -> {:error, :board_moderator}
      true -> :ok
    end
  end

  @doc """
  Requests the deletion of `user`'s own account.

  `credentials` carries `:password` and, when TOTP is on, `:code`; they are
  verified here, inside the context, like every other step-up action.

  ## Options

    * `:ip_address` — recorded with a failed re-authentication (required)
    * `:session_id` — the requesting session, which the caller signs out
      itself; every other session is revoked here (all of them when `nil`)
    * `:user_agent` — the raw User-Agent header; only its family is stored
    * `:withdraw_content` — withdraw articles and comments too

  Returns `{:ok, deletion}` or `{:error, reason}`: an eligibility error,
  `:pending_deletion_exists`, `:invalid_credentials` or `{:throttled, s}`.
  """
  @spec request(User.t(), map(), keyword()) :: {:ok, Deletion.t()} | {:error, term()}
  def request(%User{} = user, credentials, opts) do
    user = Repo.get!(User, user.id)

    with :ok <- eligibility(user),
         :ok <- ensure_none_open(user.id),
         :ok <-
           Auth.verify_reauthentication(
             user,
             credential(credentials, :password),
             credential(credentials, :code),
             Keyword.fetch!(opts, :ip_address),
             :account_deletion
           ),
         {:ok, deletion} <- insert(user, opts) do
      case Keyword.get(opts, :session_id) do
        id when is_integer(id) -> Auth.delete_other_sessions_for_user(user.id, id)
        _ -> Auth.delete_all_sessions_for_user(user.id)
      end

      Baudrate.DataPortability.cancel_active_exports(user.id, "account_deleted")
      Baudrate.AccountMigration.cancel_active_moves(user.id, "account_deleted")
      Auth.revoke_invite_codes_for_user(user.id)

      Hooks.notify_account_security(user.id, "account_deletion_requested", %{
        "execute_after" => DateTime.to_iso8601(deletion.execute_after),
        "browser" => deletion.requested_user_agent_family || ""
      })

      Logger.warning(
        "account_deletion.requested: user_id=#{user.id} deletion_id=#{deletion.id} " <>
          "withdraw_content=#{deletion.withdraw_content} execute_after=#{deletion.execute_after}"
      )

      {:ok, deletion}
    end
  end

  defp credential(credentials, key),
    do: Map.get(credentials, key) || Map.get(credentials, to_string(key))

  defp ensure_none_open(user_id) do
    if open(user_id), do: {:error, :pending_deletion_exists}, else: :ok
  end

  defp insert(user, opts) do
    now = now()

    %Deletion{}
    |> Deletion.create_changeset(%{
      user_id: user.id,
      status: "pending",
      withdraw_content: Keyword.get(opts, :withdraw_content, false) == true,
      requested_at: now,
      execute_after: DateTime.add(now, @wait_seconds, :second),
      requested_user_agent_family: UserAgent.family(Keyword.get(opts, :user_agent))
    })
    |> Repo.insert()
    |> case do
      {:ok, deletion} ->
        {:ok, deletion}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        # The partial unique index lost a race with a concurrent request.
        case errors[:user_id] do
          {_msg, meta} when is_list(meta) ->
            if meta[:constraint] == :unique,
              do: {:error, :pending_deletion_exists},
              else: {:error, changeset}

          _ ->
            {:error, changeset}
        end
    end
  end

  @doc "The member's pending or executing deletion, or `nil`. Never writes."
  @spec open(integer()) :: Deletion.t() | nil
  def open(user_id) when is_integer(user_id) do
    Repo.one(
      from(d in Deletion,
        where: d.user_id == ^user_id and d.status in ["pending", "executing"],
        limit: 1
      )
    )
  end

  # ---------------------------------------------------------------------------
  # Cancelling
  # ---------------------------------------------------------------------------

  @doc """
  Cancels `user_id`'s pending deletion, as signing in does.

  Returns `:cancelled` (and sends the always-delivered notice), `:none` when
  there was nothing to cancel, or `:executing` when the sweep has already
  claimed it — the caller must then refuse the sign-in, because the account
  is being turned into a tombstone.
  """
  @spec cancel_pending(integer(), String.t()) :: :cancelled | :none | :executing
  def cancel_pending(user_id, reason) when is_integer(user_id) do
    true = reason in Deletion.cancel_reasons()
    now = now()

    {count, _} =
      from(d in Deletion, where: d.user_id == ^user_id and d.status == "pending")
      |> Repo.update_all(set: [status: "cancelled", cancelled_at: now, cancel_reason: reason])

    cond do
      count > 0 ->
        Hooks.notify_account_security(user_id, "account_deletion_cancelled", %{
          "reason" => reason
        })

        Logger.warning("account_deletion.cancelled: user_id=#{user_id} reason=#{reason}")
        :cancelled

      Repo.exists?(from(d in Deletion, where: d.user_id == ^user_id and d.status == "executing")) ->
        :executing

      true ->
        :none
    end
  end

  # ---------------------------------------------------------------------------
  # Carrying it out
  # ---------------------------------------------------------------------------

  @doc """
  The hourly step: claims every due `pending` request, then works on every
  `executing` one — including any a crashed run left behind. Returns the
  number of deletions completed in this run.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    now = now()

    due =
      Repo.all(
        from(d in Deletion,
          where: d.status == "pending" and d.execute_after <= ^now,
          select: d.id,
          limit: 20
        )
      )

    Enum.each(due, &claim/1)

    from(d in Deletion, where: d.status == "executing", order_by: [asc: d.id], limit: 20)
    |> Repo.all()
    |> Enum.count(&(execute(&1) == :completed))
  end

  # pending → executing, conditionally, so a deletion starts exactly once and
  # a sign-in that cancels it at the same moment wins or loses cleanly.
  defp claim(id) do
    now = now()

    {count, _} =
      from(d in Deletion,
        where: d.id == ^id and d.status == "pending" and d.execute_after <= ^now
      )
      |> Repo.update_all(set: [status: "executing", claimed_at: now])

    if count == 1 do
      deletion = Repo.get!(Deletion, id)
      # Whatever sessions exist die now; the tombstone can take a few runs.
      Auth.delete_all_sessions_for_user(deletion.user_id)
      Logger.warning("account_deletion.claimed: deletion_id=#{id} user_id=#{deletion.user_id}")
    end
  end

  @doc """
  Works on one `executing` deletion. Every step selects only what is still
  live, so running it again after a crash continues where it stopped.

  Returns `:completed`, `:in_progress` (the withdrawal batch ran out; the
  next sweep continues), or `:cancelled` (the member gained a staff role).
  """
  @spec execute(Deletion.t()) :: :completed | :in_progress | :cancelled
  def execute(%Deletion{status: "executing"} = deletion) do
    user = Repo.get!(User, deletion.user_id) |> Repo.preload(:role)

    cond do
      user.status == "deleted" ->
        # Tombstoned by an earlier run whose last write was lost; finish it.
        mark_completed(deletion)
        :completed

      eligibility(user) in [{:error, :staff}, {:error, :board_moderator}] ->
        cancel_executing(deletion, "staff")
        :cancelled

      true ->
        with :done <- withdraw(deletion, user),
             :done <- blank_messages(user) do
          tombstone(deletion, user)
        end
    end
  end

  defp cancel_executing(deletion, reason) do
    from(d in Deletion, where: d.id == ^deletion.id and d.status == "executing")
    |> Repo.update_all(set: [status: "cancelled", cancelled_at: now(), cancel_reason: reason])

    Hooks.notify_account_security(deletion.user_id, "account_deletion_cancelled", %{
      "reason" => reason
    })

    Logger.warning("account_deletion.cancelled: user_id=#{deletion.user_id} reason=#{reason}")
  end

  # Step 2: the member's own articles and comments, when they asked for it —
  # through the ordinary soft-delete paths, so each publishes its
  # `Delete(Tombstone)` and Retention purges it after 90 days (anything a
  # report points at is kept, ADR 0040).
  defp withdraw(%Deletion{withdraw_content: false}, _user), do: :done

  defp withdraw(%Deletion{}, user) do
    articles =
      Repo.all(
        from(a in Article,
          where: a.user_id == ^user.id and is_nil(a.deleted_at),
          order_by: [asc: a.id],
          limit: @batch
        )
      )

    Enum.each(articles, &Baudrate.Content.soft_delete_article(&1, deleted_by: user.id))
    left = @batch - length(articles)

    comments =
      if left > 0 do
        Repo.all(
          from(c in Comment,
            where: c.user_id == ^user.id and is_nil(c.deleted_at),
            order_by: [asc: c.id],
            limit: ^left
          )
        )
      else
        []
      end

    Enum.each(comments, &Baudrate.Content.soft_delete_comment(&1, deleted_by: user.id))

    if length(articles) + length(comments) < @batch, do: :done, else: :in_progress
  end

  # Step 3: the text of every message the member sent, always — through the
  # ordinary path, which removes images and link previews and federates the
  # deletion to a remote conversation.
  defp blank_messages(user) do
    messages =
      Repo.all(
        from(m in DirectMessage,
          where: m.sender_user_id == ^user.id and is_nil(m.deleted_at),
          order_by: [asc: m.id],
          limit: @batch
        )
      )

    Enum.each(messages, &Baudrate.Messaging.soft_delete_message(&1, user))

    if length(messages) < @batch, do: :done, else: :in_progress
  end

  # Steps 4–6, in one transaction (ADR 0034): unfollow everyone, tombstone the
  # row, drop its followers, queue `Delete(Person)`, mark the request done.
  defp tombstone(deletion, user) do
    {:ok, user} = ensure_keys(user)
    audience = audience_inboxes(user)
    remote_follows = remote_follows(user.id)

    result =
      Federation.federate(
        fn ->
          delete_local_follows(user.id)

          for follow <- remote_follows do
            Repo.delete!(follow)
          end

          actor_uri = Federation.actor_uri(:user, user.username)
          Repo.delete_all(from(f in Follower, where: f.actor_uri == ^actor_uri))
          delete_own_rows(user.id)

          tombstoned = user |> User.tombstone_changeset() |> Repo.update!()
          mark_completed(deletion)
          {:ok, tombstoned}
        end,
        fn _tombstoned ->
          for follow <- remote_follows do
            {activity, actor_uri} = Publisher.build_undo_follow(user, follow)
            Delivery.deliver_follow(activity, follow.remote_actor, actor_uri)
          end

          Publisher.publish_actor_deleted(user, audience)
        end
      )

    case result do
      {:ok, _} ->
        Baudrate.Avatar.delete_avatar(user.avatar_id)
        Logger.warning("account_deletion.completed: user_id=#{user.id}")
        :completed

      {:error, reason} ->
        Logger.error(
          "account_deletion.tombstone_failed: user_id=#{user.id} reason=#{inspect(reason)}"
        )

        :in_progress
    end
  end

  # The keys must exist to sign the Undo(Follow)s and Delete(Person); an
  # account that never federated gets one now, while it is still active.
  defp ensure_keys(user), do: Federation.KeyStore.ensure_user_keypair(user)

  defp mark_completed(deletion) do
    from(d in Deletion, where: d.id == ^deletion.id and d.status == "executing")
    |> Repo.update_all(set: [status: "completed", completed_at: now()])
  end

  defp remote_follows(user_id) do
    Repo.all(
      from(f in UserFollow,
        where: f.user_id == ^user_id and not is_nil(f.remote_actor_id),
        preload: :remote_actor
      )
    )
  end

  defp delete_local_follows(user_id) do
    Repo.delete_all(
      from(f in UserFollow,
        where:
          (f.user_id == ^user_id and not is_nil(f.followed_user_id)) or
            f.followed_user_id == ^user_id
      )
    )
  end

  # Everyone on another server who has this account on record: its
  # followers, the accounts it follows, the other side of its conversations, and the
  # authors of posts it replied to. Collected before the rows go.
  defp audience_inboxes(user) do
    followed =
      from(f in UserFollow,
        join: ra in assoc(f, :remote_actor),
        where: f.user_id == ^user.id,
        select: ra
      )

    counterparts =
      from(c in Baudrate.Messaging.Conversation,
        join: ra in RemoteActor,
        on: ra.id == c.remote_actor_b_id or ra.id == c.remote_actor_a_id,
        where: c.user_a_id == ^user.id or c.user_b_id == ^user.id,
        select: ra
      )

    replied_to =
      from(r in Baudrate.Federation.TimelineItemReply,
        join: t in assoc(r, :timeline_item),
        join: ra in RemoteActor,
        on: ra.id == t.remote_actor_id,
        where: r.user_id == ^user.id,
        select: ra
      )

    # The followers are resolved here too, not by the publisher: their rows
    # are deleted in the same transaction, before the publish step runs.
    followers = Delivery.resolve_follower_inboxes(Federation.actor_uri(:user, user.username))

    [followed, counterparts, replied_to]
    |> Enum.flat_map(&Repo.all/1)
    |> Enum.map(fn ra ->
      if ra.shared_inbox && ra.shared_inbox != "", do: ra.shared_inbox, else: ra.inbox
    end)
    |> Enum.concat(followers)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # What the member owns and a kept row would not cascade. Records — reports,
  # the moderation log, sanctions, filter matches, invite codes and other
  # members' `invited_by` — stay, and so do likes, boosts and poll votes,
  # whose counters would otherwise drift. Blocks and mutes are removed only
  # where this account made them.
  defp delete_own_rows(user_id) do
    alias Baudrate.Auth.{RecoveryCode, RecoveryContact, UserBlock, UserMute, WebAuthnCredential}
    alias Baudrate.Content.{ArticleDraft, ArticleRead, Bookmark, BoardRead, Watch}
    alias Baudrate.DataPortability.ExportRequest
    alias Baudrate.Messaging.ConversationReadCursor
    alias Baudrate.Moderation.HeldPost
    alias Baudrate.Notification.{Notification, PushSubscription}

    for schema <- [
          WebAuthnCredential,
          RecoveryCode,
          # Its challenges go with each contact (ON DELETE CASCADE).
          RecoveryContact,
          PushSubscription,
          ArticleDraft,
          Watch,
          Bookmark,
          ArticleRead,
          BoardRead,
          ConversationReadCursor,
          ExportRequest,
          UserBlock,
          UserMute,
          Notification
        ] do
      Repo.delete_all(from(r in schema, where: field(r, :user_id) == ^user_id))
    end

    Repo.delete_all(from(h in HeldPost, where: h.user_id == ^user_id and h.status == "pending"))
  end

  # ---------------------------------------------------------------------------
  # The keys
  # ---------------------------------------------------------------------------

  @doc """
  Clears the signing keys of accounts deleted more than 30 days ago whose
  deliveries are all out (none pending or failed). Returns how many.
  """
  @spec sweep_keys() :: non_neg_integer()
  def sweep_keys do
    cutoff = DateTime.add(now(), -@key_grace_seconds, :second)

    from(u in User,
      join: d in Deletion,
      on: d.user_id == u.id and d.status == "completed",
      where:
        u.status == "deleted" and d.completed_at <= ^cutoff and
          (not is_nil(u.ap_public_key) or not is_nil(u.ap_private_key_encrypted)),
      select: u
    )
    |> Repo.all()
    |> Enum.count(fn user ->
      actor_uri = Federation.actor_uri(:user, user.username)

      waiting? =
        Repo.exists?(
          from(j in Baudrate.Federation.DeliveryJob,
            where: j.actor_uri == ^actor_uri and j.status in ["pending", "failed"]
          )
        )

      if waiting? do
        false
      else
        from(u in User, where: u.id == ^user.id)
        |> Repo.update_all(set: [ap_public_key: nil, ap_private_key_encrypted: nil])

        true
      end
    end)
  end

  @doc "Whether a deleted account still holds its public key (served in its Tombstone)."
  @spec key_retained?(User.t()) :: boolean()
  def key_retained?(%User{ap_public_key: key}), do: is_binary(key)

  defp board_moderator?(user_id) do
    Repo.exists?(from(m in Baudrate.Content.BoardModerator, where: m.user_id == ^user_id))
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
