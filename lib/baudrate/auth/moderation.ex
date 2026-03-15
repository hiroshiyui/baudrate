defmodule Baudrate.Auth.Moderation do
  @moduledoc """
  Handles user banning, blocking, and muting.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Setup.User
  alias Baudrate.Auth.{Sessions, Invites, UserBlock, UserMute}

  @doc """
  Bans a user. Guards against self-ban.

  Sets status to `"banned"`, records `banned_at` and optional `ban_reason`,
  then invalidates all existing sessions and revokes all active invite codes
  for the user. Returns `{:ok, banned_user, revoked_codes_count}`.
  """
  @spec ban_user(User.t(), integer(), String.t() | nil) ::
          {:ok, User.t(), non_neg_integer()} | {:error, :self_action}
  def ban_user(user, admin_id, reason \\ nil)

  def ban_user(%User{id: id}, admin_id, _reason) when id == admin_id do
    {:error, :self_action}
  end

  def ban_user(%User{} = user, admin_id, reason)
      when is_integer(admin_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      user
      |> User.ban_changeset(%{status: "banned", banned_at: now, ban_reason: reason})
      |> Repo.update()

    with {:ok, banned_user} <- result do
      Sessions.delete_all_sessions_for_user(banned_user.id)
      {revoked_count, _} = Invites.revoke_invite_codes_for_user(banned_user.id)
      {:ok, banned_user, revoked_count}
    end
  end

  @doc """
  Unbans a user by setting status back to `"active"` and clearing ban fields.
  """
  def unban_user(%User{} = user) do
    user
    |> User.unban_changeset()
    |> Repo.update()
  end

  # --- User Blocks ---

  @doc """
  Blocks a local user. Returns `{:ok, block}` or `{:error, changeset}`.
  """
  @spec block_user(User.t(), User.t()) :: {:ok, UserBlock.t()} | {:error, Ecto.Changeset.t()}
  def block_user(%User{id: user_id}, %User{id: blocked_id}) do
    %UserBlock{}
    |> UserBlock.local_changeset(%{user_id: user_id, blocked_user_id: blocked_id})
    |> Repo.insert()
  end

  @doc """
  Blocks a remote actor by AP ID. Returns `{:ok, block}` or `{:error, changeset}`.
  """
  def block_remote_actor(%User{id: user_id}, ap_id) when is_binary(ap_id) do
    %UserBlock{}
    |> UserBlock.remote_changeset(%{user_id: user_id, blocked_actor_ap_id: ap_id})
    |> Repo.insert()
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
