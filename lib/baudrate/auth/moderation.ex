defmodule Baudrate.Auth.Moderation do
  @moduledoc """
  Handles user banning, blocking, and muting.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Setup.User
  alias Baudrate.Auth.{Sanctions, Sessions, Invites, UserBlock, UserMute}

  @doc """
  Bans a user, if `actor` is allowed to.

  Sets status to `"banned"`, records `banned_at` and optional `ban_reason`,
  then invalidates all existing sessions, cancels active exports and moves, and
  revokes all active invite codes. Returns
  `{:ok, banned_user, revoked_codes_count}`.

  Authorization is `Sanctions.authorize_ban/2`, at this boundary rather than in
  the LiveView (ADR 0016). It used to be a bare self-ban guard: a ban is the
  harshest thing this codebase does to an account, and it was the one rung of
  the ladder ADR 0029 built that checked neither the permission nor the rank
  rule, while `Sanctions.issue/4` checked both. The practical shape of that was
  that a moderator could not silence a peer for an hour, but this function
  would permanently ban an admin for anyone who called it.

  `actor` is a `User`, not an id, because authorization needs its role.
  """
  @spec ban_user(User.t(), User.t(), String.t() | nil) ::
          {:ok, User.t(), non_neg_integer()}
          | {:error, :self_action | :unauthorized | :role_too_high}
  def ban_user(user, actor, reason \\ nil)

  def ban_user(%User{} = user, %User{} = actor, reason) do
    with :ok <- Sanctions.authorize_ban(actor, user) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      result =
        user
        |> User.ban_changeset(%{status: "banned", banned_at: now, ban_reason: reason})
        |> Repo.update()

      with {:ok, banned_user} <- result do
        Sessions.delete_all_sessions_for_user(banned_user.id)
        Baudrate.DataPortability.cancel_active_exports(banned_user.id, "banned")
        Baudrate.AccountMigration.cancel_active_moves(banned_user.id, "banned")
        {revoked_count, _} = Invites.revoke_invite_codes_for_user(banned_user.id)
        {:ok, banned_user, revoked_count}
      end
    end
  end

  @doc """
  Unbans a user by setting status back to `"active"` and clearing ban fields.

  Authorized by `Sanctions.authorize_unban/2`: the same permission as a ban,
  deliberately without the rank rule, so a banned account can always be
  restored through the UI.
  """
  @spec unban_user(User.t(), User.t()) ::
          {:ok, User.t()} | {:error, :self_action | :unauthorized | Ecto.Changeset.t()}
  def unban_user(%User{} = user, %User{} = actor) do
    with :ok <- Sanctions.authorize_unban(actor, user) do
      user
      |> User.unban_changeset()
      |> Repo.update()
    end
  end

  # --- User Blocks ---
  #
  # A block is enforced on this site only; no ActivityPub `Block` is sent
  # (P1-D1). Besides hiding the blocked account's content from the blocker,
  # it removes follows in both directions and refuses every new interaction
  # between the two: replies, likes, boosts, forwards, follows and DMs. Undoing
  # an earlier like or boost stays allowed. Content stays publicly visible;
  # a block controls interaction, not visibility.

  @doc """
  Blocks a local user and removes the follows between the two accounts in
  both directions. Returns `{:ok, block}` or `{:error, changeset}`.
  """
  @spec block_user(User.t(), User.t()) :: {:ok, UserBlock.t()} | {:error, Ecto.Changeset.t()}
  def block_user(%User{id: user_id} = user, %User{id: blocked_id} = blocked) do
    result =
      %UserBlock{}
      |> UserBlock.local_changeset(%{user_id: user_id, blocked_user_id: blocked_id})
      |> Repo.insert()

    with {:ok, _block} <- result do
      Baudrate.Federation.delete_local_follow(user, blocked)
      Baudrate.Federation.delete_local_follow(blocked, user)
      result
    end
  end

  @doc """
  Blocks a remote actor by AP ID. Returns `{:ok, block}` or `{:error, changeset}`.

  When the actor is known, the follows between it and the user are removed in
  both directions: the user's follow is undone with `Undo(Follow)` and the
  actor's follow of the user is ended with `Reject(Follow)`
  (`Federation.sever_remote_follows/2`).
  """
  def block_remote_actor(%User{id: user_id} = user, ap_id) when is_binary(ap_id) do
    result =
      %UserBlock{}
      |> UserBlock.remote_changeset(%{user_id: user_id, blocked_actor_ap_id: ap_id})
      |> Repo.insert()

    with {:ok, _block} <- result do
      case Baudrate.Federation.get_remote_actor_by_ap_id(ap_id) do
        nil -> :ok
        remote_actor -> Baudrate.Federation.sever_remote_follows(user, remote_actor)
      end

      result
    end
  end

  @doc """
  Unblocks a local user. Returns `{count, nil}`.
  """
  @spec unblock_user(User.t(), User.t()) :: {non_neg_integer(), nil}
  def unblock_user(%User{id: user_id}, %User{id: blocked_id}) do
    from(b in UserBlock,
      where: b.user_id == ^user_id and b.blocked_user_id == ^blocked_id
    )
    |> Repo.delete_all()
  end

  @doc """
  Unblocks a remote actor by AP ID. Returns `{count, nil}`.
  """
  def unblock_remote_actor(%User{id: user_id}, ap_id) when is_binary(ap_id) do
    from(b in UserBlock,
      where: b.user_id == ^user_id and b.blocked_actor_ap_id == ^ap_id
    )
    |> Repo.delete_all()
  end

  @doc """
  Returns `true` if the user has blocked the given target (local user or AP ID).
  """
  def blocked?(%User{id: user_id}, %User{id: target_id}) do
    Repo.exists?(
      from(b in UserBlock,
        where: b.user_id == ^user_id and b.blocked_user_id == ^target_id
      )
    )
  end

  def blocked?(%User{id: user_id}, ap_id) when is_binary(ap_id) do
    Repo.exists?(
      from(b in UserBlock,
        where: b.user_id == ^user_id and b.blocked_actor_ap_id == ^ap_id
      )
    )
  end

  def blocked?(_, _), do: false

  @doc """
  Returns `true` if `blocker_id` has blocked `user_id`. Reverse check for filtering.
  """
  def user_blocked_by?(user_id, blocker_id) when is_integer(user_id) and is_integer(blocker_id) do
    Repo.exists?(
      from(b in UserBlock,
        where: b.user_id == ^blocker_id and b.blocked_user_id == ^user_id
      )
    )
  end

  @doc """
  Returns `true` if either of the two local users has blocked the other.
  """
  @spec blocked_between?(integer() | nil, integer() | nil) :: boolean()
  def blocked_between?(user_id, other_id) when is_integer(user_id) and is_integer(other_id) do
    Repo.exists?(
      from(b in UserBlock,
        where:
          (b.user_id == ^user_id and b.blocked_user_id == ^other_id) or
            (b.user_id == ^other_id and b.blocked_user_id == ^user_id)
      )
    )
  end

  def blocked_between?(_, _), do: false

  @doc """
  Returns `true` if the local user has blocked the remote actor with the given
  database ID.
  """
  @spec remote_actor_blocked_by?(integer() | nil, integer() | nil) :: boolean()
  def remote_actor_blocked_by?(remote_actor_id, user_id)
      when is_integer(remote_actor_id) and is_integer(user_id) do
    Repo.exists?(
      from(b in UserBlock,
        join: ra in Baudrate.Federation.RemoteActor,
        on: ra.ap_id == b.blocked_actor_ap_id,
        where: b.user_id == ^user_id and ra.id == ^remote_actor_id
      )
    )
  end

  def remote_actor_blocked_by?(_, _), do: false

  @doc """
  Returns `true` if a block stands between the local user and the author of
  `content` (any map with `user_id` and `remote_actor_id`, such as an article,
  comment or timeline item), in either direction for a local author.
  """
  @spec blocked_with_author?(integer(), map()) :: boolean()
  def blocked_with_author?(user_id, %{user_id: author_id}) when is_integer(author_id),
    do: blocked_between?(user_id, author_id)

  def blocked_with_author?(user_id, %{remote_actor_id: actor_id}) when is_integer(actor_id),
    do: remote_actor_blocked_by?(actor_id, user_id)

  def blocked_with_author?(_user_id, _content), do: false

  @doc """
  Lists all blocks for a user, with blocked_user preloaded where applicable.
  """
  def list_blocks(%User{id: user_id}) do
    from(b in UserBlock,
      where: b.user_id == ^user_id,
      order_by: [desc: b.inserted_at, desc: b.id],
      preload: [:blocked_user]
    )
    |> Repo.all()
  end

  @doc """
  Returns a list of blocked user IDs for the given user.
  """
  def blocked_user_ids(%User{id: user_id}) do
    from(b in UserBlock,
      where: b.user_id == ^user_id and not is_nil(b.blocked_user_id),
      select: b.blocked_user_id
    )
    |> Repo.all()
  end

  @doc """
  Returns a list of blocked remote actor AP IDs for the given user.
  """
  def blocked_actor_ap_ids(%User{id: user_id}) do
    from(b in UserBlock,
      where: b.user_id == ^user_id and not is_nil(b.blocked_actor_ap_id),
      select: b.blocked_actor_ap_id
    )
    |> Repo.all()
  end

  # --- User Mutes ---

  @doc """
  Mutes a local user. Returns `{:ok, mute}` or `{:error, changeset}`.
  """
  @spec mute_user(User.t(), User.t()) :: {:ok, UserMute.t()} | {:error, Ecto.Changeset.t()}
  def mute_user(%User{id: user_id}, %User{id: muted_id}) do
    %UserMute{}
    |> UserMute.local_changeset(%{user_id: user_id, muted_user_id: muted_id})
    |> Repo.insert()
  end

  @doc """
  Mutes a remote actor by AP ID. Returns `{:ok, mute}` or `{:error, changeset}`.
  """
  def mute_remote_actor(%User{id: user_id}, ap_id) when is_binary(ap_id) do
    %UserMute{}
    |> UserMute.remote_changeset(%{user_id: user_id, muted_actor_ap_id: ap_id})
    |> Repo.insert()
  end

  @doc """
  Unmutes a local user. Returns `{count, nil}`.
  """
  @spec unmute_user(User.t(), User.t()) :: {non_neg_integer(), nil}
  def unmute_user(%User{id: user_id}, %User{id: muted_id}) do
    from(m in UserMute,
      where: m.user_id == ^user_id and m.muted_user_id == ^muted_id
    )
    |> Repo.delete_all()
  end

  @doc """
  Unmutes a remote actor by AP ID. Returns `{count, nil}`.
  """
  def unmute_remote_actor(%User{id: user_id}, ap_id) when is_binary(ap_id) do
    from(m in UserMute,
      where: m.user_id == ^user_id and m.muted_actor_ap_id == ^ap_id
    )
    |> Repo.delete_all()
  end

  @doc """
  Returns `true` if the user has muted the given target (local user or AP ID).
  """
  def muted?(%User{id: user_id}, %User{id: target_id}) do
    Repo.exists?(
      from(m in UserMute,
        where: m.user_id == ^user_id and m.muted_user_id == ^target_id
      )
    )
  end

  def muted?(%User{id: user_id}, ap_id) when is_binary(ap_id) do
    Repo.exists?(
      from(m in UserMute,
        where: m.user_id == ^user_id and m.muted_actor_ap_id == ^ap_id
      )
    )
  end

  def muted?(_, _), do: false

  @doc """
  Lists all mutes for a user, with muted_user preloaded where applicable.
  """
  def list_mutes(%User{id: user_id}) do
    from(m in UserMute,
      where: m.user_id == ^user_id,
      order_by: [desc: m.inserted_at, desc: m.id],
      preload: [:muted_user]
    )
    |> Repo.all()
  end

  @doc """
  Returns a list of muted user IDs for the given user.
  """
  def muted_user_ids(%User{id: user_id}) do
    from(m in UserMute,
      where: m.user_id == ^user_id and not is_nil(m.muted_user_id),
      select: m.muted_user_id
    )
    |> Repo.all()
  end

  @doc """
  Returns a list of muted remote actor AP IDs for the given user.
  """
  def muted_actor_ap_ids(%User{id: user_id}) do
    from(m in UserMute,
      where: m.user_id == ^user_id and not is_nil(m.muted_actor_ap_id),
      select: m.muted_actor_ap_id
    )
    |> Repo.all()
  end

  @doc """
  Returns combined hidden user IDs and AP IDs from both blocks and mutes
  in a single query using `union_all`.

  Returns `{user_ids, ap_ids}` where both are deduplicated lists.
  """
  @spec hidden_ids(User.t()) :: {[integer()], [String.t()]}
  def hidden_ids(%User{id: user_id}) do
    blocked_q =
      from(b in UserBlock,
        where: b.user_id == ^user_id,
        select: %{user_id: b.blocked_user_id, ap_id: b.blocked_actor_ap_id}
      )

    muted_q =
      from(m in UserMute,
        where: m.user_id == ^user_id,
        select: %{user_id: m.muted_user_id, ap_id: m.muted_actor_ap_id}
      )

    all = blocked_q |> union_all(^muted_q) |> Repo.all()
    user_ids = for(r <- all, r.user_id, do: r.user_id) |> Enum.uniq()
    ap_ids = for(r <- all, r.ap_id, do: r.ap_id) |> Enum.uniq()
    {user_ids, ap_ids}
  end
end
