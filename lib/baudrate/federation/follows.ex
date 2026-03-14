defmodule Baudrate.Federation.Follows do
  @moduledoc """
  Follow relationship management for the Federation context.

  Handles four categories:

  - **Inbound followers** — remote actors following local user/board actors
    (stored in the `followers` table via `Follower` schema).
  - **User follows (outbound)** — local users following remote actors or other
    local users (stored in `user_follows`; local follows auto-accept, remote
    follows are pending until an `Accept` activity arrives).
  - **Board follows (outbound)** — local boards following remote actors
    (stored in `user_follows` with a `board_id` discriminator via `BoardFollow`).
  - **Local follows** — user-to-user follows on the same instance, auto-accepted
    with no AP delivery required.
  """

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Federation.{BoardFollow, Follower, RemoteActor, UserFollow}

  @state_pending "pending"
  @state_accepted "accepted"
  @state_rejected "rejected"

  # --- Inbound Followers ---

  @doc """
  Creates a follower record for a remote actor following a local actor.
  """
  @spec create_follower(String.t(), RemoteActor.t(), String.t()) ::
          {:ok, Follower.t()} | {:error, Ecto.Changeset.t()}
  def create_follower(actor_uri, remote_actor, activity_id) do
    %Follower{}
    |> Follower.changeset(%{
      actor_uri: actor_uri,
      follower_uri: remote_actor.ap_id,
      remote_actor_id: remote_actor.id,
      activity_id: activity_id,
      accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert()
  end

  @doc """
  Deletes a follower record matching the given actor and follower URIs.
  """
  def delete_follower(actor_uri, follower_uri) do
    from(f in Follower,
      where: f.actor_uri == ^actor_uri and f.follower_uri == ^follower_uri
    )
    |> Repo.delete_all()
  end

  @doc """
  Deletes all follower records where the remote actor matches the given AP ID.
  Used when a remote actor is deleted.
  """
  def delete_followers_by_remote(remote_actor_ap_id) do
    from(f in Follower, where: f.follower_uri == ^remote_actor_ap_id)
    |> Repo.delete_all()
  end

  @doc """
  Returns true if the given follower relationship exists.
  """
  def follower_exists?(actor_uri, follower_uri) do
    Repo.exists?(
      from(f in Follower,
        where: f.actor_uri == ^actor_uri and f.follower_uri == ^follower_uri
      )
    )
  end

  @doc """
  Lists all followers of the given local actor URI.
  """
  def list_followers(actor_uri) do
    from(f in Follower,
      where: f.actor_uri == ^actor_uri,
      preload: [:remote_actor],
      order_by: [desc: f.inserted_at, desc: f.id]
    )
    |> Repo.all()
  end

  @doc """
  Returns the count of followers for the given local actor URI.
  """
  def count_followers(actor_uri) do
    Repo.one(from(f in Follower, where: f.actor_uri == ^actor_uri, select: count(f.id))) || 0
  end

  # --- User Follows (Outbound) ---

  @doc """
  Creates a user follow record and returns the generated Follow AP ID.

  Inserts a `UserFollow` with state `"pending"`. The caller is responsible
  for building and delivering the Follow activity using the returned AP ID.

  Returns `{:ok, %UserFollow{}}` or `{:error, changeset}`.
  """
  @spec create_user_follow(Baudrate.Setup.User.t(), RemoteActor.t()) ::
          {:ok, UserFollow.t()} | {:error, Ecto.Changeset.t()}
  def create_user_follow(user, remote_actor) do
    ap_id =
      "#{Baudrate.Federation.actor_uri(:user, user.username)}#follow-#{System.unique_integer([:positive])}"

    %UserFollow{}
    |> UserFollow.changeset(%{
      user_id: user.id,
      remote_actor_id: remote_actor.id,
      state: @state_pending,
      ap_id: ap_id
    })
    |> Repo.insert()
  end

  @doc """
  Marks an outbound follow as accepted by matching the Follow activity's AP ID.

  Called when an `Accept(Follow)` activity is received from the remote actor.
  Returns `{:ok, %UserFollow{}}` or `{:error, :not_found}`.
  """
  def accept_user_follow(follow_ap_id) when is_binary(follow_ap_id) do
    case Repo.one(from(uf in UserFollow, where: uf.ap_id == ^follow_ap_id)) do
      nil ->
        {:error, :not_found}

      %UserFollow{} = follow ->
        follow
        |> UserFollow.changeset(%{
          state: @state_accepted,
          accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()
    end
  end

  @doc """
  Marks an outbound follow as rejected by matching the Follow activity's AP ID.

  Called when a `Reject(Follow)` activity is received from the remote actor.
  Returns `{:ok, %UserFollow{}}` or `{:error, :not_found}`.
  """
  def reject_user_follow(follow_ap_id) when is_binary(follow_ap_id) do
    case Repo.one(from(uf in UserFollow, where: uf.ap_id == ^follow_ap_id)) do
      nil ->
        {:error, :not_found}

      %UserFollow{} = follow ->
        follow
        |> UserFollow.changeset(%{
          state: @state_rejected,
          rejected_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()
    end
  end

  @doc """
  Deletes a user follow record (for unfollow).

  Returns `{:ok, %UserFollow{}}` or `{:error, :not_found}`.
  """
  def delete_user_follow(user, remote_actor) do
    case Repo.one(
           from(uf in UserFollow,
             where: uf.user_id == ^user.id and uf.remote_actor_id == ^remote_actor.id
           )
         ) do
      nil -> {:error, :not_found}
      %UserFollow{} = follow -> Repo.delete(follow)
    end
  end

  @doc """
  Returns the user follow record for the given user and remote actor pair, or nil.
  """
  @spec get_user_follow(integer(), integer()) :: UserFollow.t() | nil
  def get_user_follow(user_id, remote_actor_id) do
    Repo.one(
      from(uf in UserFollow,
        where: uf.user_id == ^user_id and uf.remote_actor_id == ^remote_actor_id
      )
    )
  end

  @doc """
  Returns the user follow with remote_actor preloaded, or nil.
  """
  @spec get_user_follow_with_actor(integer(), integer()) :: UserFollow.t() | nil
  def get_user_follow_with_actor(user_id, remote_actor_id) do
    Repo.one(
      from(uf in UserFollow,
        where: uf.user_id == ^user_id and uf.remote_actor_id == ^remote_actor_id,
        preload: :remote_actor
      )
    )
  end

  @doc """
  Returns the user follow record matching the given Follow activity AP ID, or nil.
  """
  def get_user_follow_by_ap_id(ap_id) do
    Repo.one(from(uf in UserFollow, where: uf.ap_id == ^ap_id))
  end

  @doc """
  Returns true if a follow record exists for the user/remote_actor pair (any state).
  """
  @spec user_follows?(integer(), integer()) :: boolean()
  def user_follows?(user_id, remote_actor_id) do
    Repo.exists?(
      from(uf in UserFollow,
        where: uf.user_id == ^user_id and uf.remote_actor_id == ^remote_actor_id
      )
    )
  end

  @doc """
  Returns true if an accepted follow record exists for the user/remote_actor pair.
  """
  def user_follows_accepted?(user_id, remote_actor_id) do
    Repo.exists?(
      from(uf in UserFollow,
        where:
          uf.user_id == ^user_id and uf.remote_actor_id == ^remote_actor_id and
            uf.state == @state_accepted
      )
    )
  end

  @doc """
  Lists followed remote actors for a user with optional state filter.

  ## Options

    * `:state` — filter by state (e.g., `"accepted"`, `"pending"`)

  Returns a list of `%UserFollow{}` structs with `:remote_actor` preloaded.
  """
  def list_user_follows(user_id, opts \\ []) do
    state = Keyword.get(opts, :state)

    query =
      from(uf in UserFollow,
        where: uf.user_id == ^user_id,
        order_by: [desc: uf.inserted_at, desc: uf.id],
        preload: [:remote_actor, followed_user: :role]
      )

    query =
      if state do
        from(uf in query, where: uf.state == ^state)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Returns the count of accepted outbound follows for the given user.
  """
  def count_user_follows(user_id) do
    Repo.one(
      from(uf in UserFollow,
        where: uf.user_id == ^user_id and uf.state == @state_accepted,
        select: count(uf.id)
      )
    ) || 0
  end

  # --- Board Follows ---

  @doc """
  Creates a board follow record and returns the generated Follow AP ID.

  Inserts a `BoardFollow` with state `"pending"`. The caller is responsible
  for building and delivering the Follow activity using the returned AP ID.

  Returns `{:ok, %BoardFollow{}}` or `{:error, changeset}`.
  """
  @spec create_board_follow(Baudrate.Content.Board.t(), RemoteActor.t()) ::
          {:ok, BoardFollow.t()} | {:error, Ecto.Changeset.t()}
  def create_board_follow(board, remote_actor) do
    ap_id =
      "#{Baudrate.Federation.actor_uri(:board, board.slug)}#follow-#{System.unique_integer([:positive])}"

    %BoardFollow{}
    |> BoardFollow.changeset(%{
      board_id: board.id,
      remote_actor_id: remote_actor.id,
      state: @state_pending,
      ap_id: ap_id
    })
    |> Repo.insert()
  end

  @doc """
  Marks a board follow as accepted by matching the Follow activity's AP ID.

  Called when an `Accept(Follow)` activity is received from the remote actor.
  Returns `{:ok, %BoardFollow{}}` or `{:error, :not_found}`.
  """
  def accept_board_follow(follow_ap_id) when is_binary(follow_ap_id) do
    case Repo.one(from(bf in BoardFollow, where: bf.ap_id == ^follow_ap_id)) do
      nil ->
        {:error, :not_found}

      %BoardFollow{} = follow ->
        follow
        |> BoardFollow.changeset(%{
          state: @state_accepted,
          accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()
    end
  end

  @doc """
  Marks a board follow as rejected by matching the Follow activity's AP ID.

  Called when a `Reject(Follow)` activity is received from the remote actor.
  Returns `{:ok, %BoardFollow{}}` or `{:error, :not_found}`.
  """
  def reject_board_follow(follow_ap_id) when is_binary(follow_ap_id) do
    case Repo.one(from(bf in BoardFollow, where: bf.ap_id == ^follow_ap_id)) do
      nil ->
        {:error, :not_found}

      %BoardFollow{} = follow ->
        follow
        |> BoardFollow.changeset(%{
          state: @state_rejected,
          rejected_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()
    end
  end

  @doc """
  Deletes a board follow record (for unfollow).

  Returns `{:ok, %BoardFollow{}}` or `{:error, :not_found}`.
  """
  def delete_board_follow(board, remote_actor) do
    case Repo.one(
           from(bf in BoardFollow,
             where: bf.board_id == ^board.id and bf.remote_actor_id == ^remote_actor.id
           )
         ) do
      nil -> {:error, :not_found}
      %BoardFollow{} = follow -> Repo.delete(follow)
    end
  end

  @doc """
  Returns the board follow record for the given board and remote actor pair, or nil.
  """
  @spec get_board_follow(integer(), integer()) :: BoardFollow.t() | nil
  def get_board_follow(board_id, remote_actor_id) do
    Repo.one(
      from(bf in BoardFollow,
        where: bf.board_id == ^board_id and bf.remote_actor_id == ^remote_actor_id
      )
    )
  end

  @doc """
  Returns the board follow with remote_actor preloaded, or nil.
  """
  @spec get_board_follow_with_actor(integer(), integer()) :: BoardFollow.t() | nil
  def get_board_follow_with_actor(board_id, remote_actor_id) do
    Repo.one(
      from(bf in BoardFollow,
        where: bf.board_id == ^board_id and bf.remote_actor_id == ^remote_actor_id,
        preload: :remote_actor
      )
    )
  end

  @doc """
  Returns the board follow record matching the given Follow activity AP ID, or nil.
  """
  def get_board_follow_by_ap_id(ap_id) do
    Repo.one(from(bf in BoardFollow, where: bf.ap_id == ^ap_id))
  end

  @doc """
  Returns true if an accepted follow record exists for the board/remote_actor pair.
  """
  def board_follows_actor?(board_id, remote_actor_id) do
    Repo.exists?(
      from(bf in BoardFollow,
        where:
          bf.board_id == ^board_id and bf.remote_actor_id == ^remote_actor_id and
            bf.state == @state_accepted
      )
    )
  end

  @doc """
  Returns boards with accepted follows for a given remote actor.

  Used for auto-routing: when a followed actor sends a Create activity
  that doesn't explicitly address a board, this determines which boards
  should receive it.
  """
  def boards_following_actor(remote_actor_id) do
    from(bf in BoardFollow,
      where: bf.remote_actor_id == ^remote_actor_id and bf.state == @state_accepted,
      join: b in assoc(bf, :board),
      where: b.ap_enabled == true and b.min_role_to_view == "guest",
      select: b
    )
    |> Repo.all()
  end

  @doc """
  Lists board follows with optional state filter, preloading remote actors.

  ## Options

    * `:state` — filter by state (e.g., `"accepted"`, `"pending"`)

  Returns a list of `%BoardFollow{}` structs with `:remote_actor` preloaded.
  """
  def list_board_follows(board_id, opts \\ []) do
    state = Keyword.get(opts, :state)

    query =
      from(bf in BoardFollow,
        where: bf.board_id == ^board_id,
        order_by: [desc: bf.inserted_at, desc: bf.id],
        preload: [:remote_actor]
      )

    query =
      if state do
        from(bf in query, where: bf.state == ^state)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Returns the count of accepted board follows for the given board.
  """
  def count_board_follows(board_id) do
    Repo.one(
      from(bf in BoardFollow,
        where: bf.board_id == ^board_id and bf.state == @state_accepted,
        select: count(bf.id)
      )
    ) || 0
  end

  # --- Local User Follows ---

  @doc """
  Returns user IDs of local users with accepted follows for the given remote actor.
  """
  def local_followers_of_remote_actor(remote_actor_id) do
    from(uf in UserFollow,
      where: uf.remote_actor_id == ^remote_actor_id and uf.state == @state_accepted,
      select: uf.user_id
    )
    |> Repo.all()
  end

  @doc """
  Creates a local follow (user → user on same instance).

  The follow is auto-accepted immediately with no AP delivery required.
  Returns `{:ok, %UserFollow{}}` or `{:error, changeset}`.
  """
  def create_local_follow(%{id: follower_id} = follower, %{id: followed_id}) do
    if follower_id == followed_id do
      {:error, :self_follow}
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      ap_id =
        "#{Baudrate.Federation.actor_uri(:user, follower.username)}#follow-#{System.unique_integer([:positive])}"

      result =
        %UserFollow{}
        |> UserFollow.changeset(%{
          user_id: follower_id,
          followed_user_id: followed_id,
          state: @state_accepted,
          ap_id: ap_id,
          accepted_at: now
        })
        |> Repo.insert()

      with {:ok, _follow} <- result do
        Baudrate.Notification.Hooks.notify_local_follow(follower_id, followed_id)
        result
      end
    end
  end

  @doc """
  Deletes a local follow record (user → user unfollow).

  Returns `{:ok, %UserFollow{}}` or `{:error, :not_found}`.
  """
  def delete_local_follow(%{id: follower_id}, %{id: followed_id}) do
    case Repo.one(
           from(uf in UserFollow,
             where: uf.user_id == ^follower_id and uf.followed_user_id == ^followed_id
           )
         ) do
      nil -> {:error, :not_found}
      %UserFollow{} = follow -> Repo.delete(follow)
    end
  end

  @doc """
  Returns the local follow record for the given follower/followed user pair, or nil.
  """
  def get_local_follow(follower_user_id, followed_user_id) do
    Repo.one(
      from(uf in UserFollow,
        where: uf.user_id == ^follower_user_id and uf.followed_user_id == ^followed_user_id
      )
    )
  end

  @doc """
  Returns a map of `%{followed_user_id => state}` for all follow records
  from `follower_user_id` to any of the given `followed_user_ids`.

  Users not present in the result map have no follow relationship.
  """
  def batch_local_follow_states(_follower_user_id, []), do: %{}

  def batch_local_follow_states(follower_user_id, followed_user_ids) do
    from(uf in UserFollow,
      where: uf.user_id == ^follower_user_id and uf.followed_user_id in ^followed_user_ids,
      select: {uf.followed_user_id, uf.state}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Returns true if a local follow record exists for the user pair (any state).
  """
  def local_follows?(user_id, followed_user_id) do
    Repo.exists?(
      from(uf in UserFollow,
        where: uf.user_id == ^user_id and uf.followed_user_id == ^followed_user_id
      )
    )
  end

  @doc """
  Returns user IDs of local users with accepted follows for the given local user.
  """
  def local_followers_of_user(followed_user_id) do
    from(uf in UserFollow,
      where: uf.followed_user_id == ^followed_user_id and uf.state == @state_accepted,
      select: uf.user_id
    )
    |> Repo.all()
  end

  @doc """
  Migrates user follows from one remote actor to another (for Move activity).

  Updates all follows pointing to `old_actor_id` to point to `new_actor_id`.
  If a user already follows the new actor, the duplicate follow is deleted.

  Returns `{migrated_count, deleted_count}`.
  """
  def migrate_user_follows(old_actor_id, new_actor_id) do
    follows = Repo.all(from(uf in UserFollow, where: uf.remote_actor_id == ^old_actor_id))

    {migrated, deleted} =
      Enum.reduce(follows, {0, 0}, fn follow, {m, d} ->
        if user_follows?(follow.user_id, new_actor_id) do
          Repo.delete!(follow)
          {m, d + 1}
        else
          follow
          |> UserFollow.changeset(%{remote_actor_id: new_actor_id})
          |> Repo.update!()

          {m + 1, d}
        end
      end)

    {migrated, deleted}
  end

end
