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
    (stored in their own `board_follows` table via `BoardFollow`).
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

  ## Options

    * `:system` — `true` when the follow is not the user's own act. An
      account migration re-points a follow the user already had
      (`AccountMigration.follow_on_behalf/2`), so a sanction on the follower
      must not erase the relationship. User-initiated follows leave this
      unset and go through `Auth.ensure_can_interact/1` (ADR 0029).

  Returns `{:ok, %UserFollow{}}` or `{:error, changeset}`.
  """
  @spec create_user_follow(Baudrate.Setup.User.t(), RemoteActor.t(), keyword()) ::
          {:ok, UserFollow.t()} | {:error, :blocked | atom() | Ecto.Changeset.t()}
  def create_user_follow(user, remote_actor, opts \\ []) do
    gate =
      if Keyword.get(opts, :system, false),
        do: :ok,
        else: Baudrate.Auth.ensure_can_interact(user, moved: :allow)

    cond do
      gate != :ok -> gate
      Baudrate.Auth.remote_actor_blocked_by?(remote_actor.id, user.id) -> {:error, :blocked}
      true -> insert_user_follow(user, remote_actor)
    end
  end

  defp insert_user_follow(user, remote_actor) do
    ap_id =
      "#{Baudrate.Federation.actor_uri(:user, user.username)}#follow-#{Ecto.UUID.generate()}"

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
  Follows `remote_actor` as `user`: inserts the pending follow and queues the
  `Follow` activity in one transaction, so a follow never waits for an
  `Accept` that was never asked for (Phase 2C).

  Takes the options of `create_user_follow/3`. Returns `{:ok, %UserFollow{}}`
  or `{:error, reason}` as `create_user_follow/3` does.
  """
  @spec follow_remote_actor(Baudrate.Setup.User.t(), RemoteActor.t(), keyword()) ::
          {:ok, UserFollow.t()} | {:error, term()}
  def follow_remote_actor(user, %RemoteActor{} = remote_actor, opts \\ []) do
    alias Baudrate.Federation.{Delivery, KeyStore, Publisher}

    with {:ok, user} <- KeyStore.ensure_user_keypair(user) do
      Baudrate.Federation.federate(
        fn -> create_user_follow(user, remote_actor, opts) end,
        fn follow ->
          {activity, actor_uri} = Publisher.build_follow(user, remote_actor, follow.ap_id)
          Delivery.deliver_follow(activity, remote_actor, actor_uri)
        end
      )
    end
  end

  @doc """
  Stops `user` following `remote_actor`: deletes the follow and queues
  `Undo(Follow)` in one transaction.

  Returns `{:ok, %UserFollow{}}` or `{:error, :not_found}`.
  """
  @spec unfollow_remote_actor(Baudrate.Setup.User.t(), RemoteActor.t()) ::
          {:ok, UserFollow.t()} | {:error, term()}
  def unfollow_remote_actor(user, %RemoteActor{} = remote_actor) do
    alias Baudrate.Federation.{Delivery, KeyStore, Publisher}

    with %UserFollow{} = follow <- get_user_follow_with_actor(user.id, remote_actor.id),
         {:ok, user} <- KeyStore.ensure_user_keypair(user) do
      Baudrate.Federation.federate(
        fn -> Repo.delete(follow) end,
        fn _deleted ->
          {activity, actor_uri} = Publisher.build_undo_follow(user, follow)
          Delivery.deliver_follow(activity, remote_actor, actor_uri)
        end
      )
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # Looks up a follow by its Follow activity ap_id. When `signer` (the remote
  # actor that sent the Accept/Reject) is given, the row must also belong to
  # that actor — follow ap_ids are minted locally and are not secret, so an
  # unscoped lookup let any verified actor accept or reject someone else's
  # follow of a third party. `nil` keeps the internal/test callers working.
  defp scoped_follow_query(schema, follow_ap_id, nil) do
    from(f in schema, where: f.ap_id == ^follow_ap_id)
  end

  defp scoped_follow_query(schema, follow_ap_id, %{id: signer_id}) do
    from(f in schema, where: f.ap_id == ^follow_ap_id and f.remote_actor_id == ^signer_id)
  end

  @doc """
  Marks an outbound follow as accepted by matching the Follow activity's AP ID.

  Called when an `Accept(Follow)` activity is received from the remote actor.
  Returns `{:ok, %UserFollow{}}` or `{:error, :not_found}`.
  """
  def accept_user_follow(follow_ap_id, signer \\ nil) when is_binary(follow_ap_id) do
    case Repo.one(scoped_follow_query(UserFollow, follow_ap_id, signer)) do
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
  def reject_user_follow(follow_ap_id, signer \\ nil) when is_binary(follow_ap_id) do
    case Repo.one(scoped_follow_query(UserFollow, follow_ap_id, signer)) do
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
  Removes every follow between a local user and a remote actor, in both
  directions, and tells the remote server. Used when the user blocks the actor.

    * The user's follow of the actor (pending or accepted) is deleted and an
      `Undo(Follow)` is queued.
    * The actor's follow of the user is deleted and a `Reject(Follow)` is
      queued, the standard way to remove a follower. No `Block` is sent
      (P1-D1).

  Returns `:ok`.
  """
  @spec sever_remote_follows(Baudrate.Setup.User.t(), RemoteActor.t()) :: :ok
  def sever_remote_follows(user, %RemoteActor{} = remote_actor) do
    alias Baudrate.Federation.{KeyStore, Publisher}

    outbound =
      Repo.one(
        from(uf in UserFollow,
          where: uf.user_id == ^user.id and uf.remote_actor_id == ^remote_actor.id,
          preload: :remote_actor
        )
      )

    actor_uri = Baudrate.Federation.actor_uri(:user, user.username)

    inbound =
      Repo.one(
        from(f in Follower,
          where: f.actor_uri == ^actor_uri and f.remote_actor_id == ^remote_actor.id
        )
      )

    signer =
      with true <- not is_nil(outbound || inbound),
           {:ok, user} <- KeyStore.ensure_user_keypair(user) do
        user
      else
        _ -> nil
      end

    # The deletions and their Undo/Reject jobs commit together (Phase 2C).
    {:ok, _} =
      Repo.transaction(fn ->
        if outbound do
          notify_remote(signer, remote_actor, &Publisher.build_undo_follow(&1, outbound))
          Repo.delete(outbound, allow_stale: true)
        end

        if inbound do
          notify_remote(signer, remote_actor, &Publisher.build_reject_follow(&1, inbound))
          Repo.delete(inbound, allow_stale: true)
        end
      end)

    :ok
  end

  @doc """
  A member's own followers (ADR 0070): `%{local: [%User{}], remote:
  [%Follower{}]}`, newest first, with each remote row's `remote_actor`
  preloaded. Shown to the member on `/followers` and nowhere else.
  """
  def list_followers_of_user(%{id: user_id, username: username}) do
    local =
      from(uf in UserFollow,
        join: u in assoc(uf, :user),
        where: uf.followed_user_id == ^user_id and uf.state == @state_accepted,
        order_by: [desc: uf.inserted_at, desc: uf.id],
        select: u
      )
      |> Repo.all()
      |> Repo.preload(:role)

    actor_uri = Baudrate.Federation.actor_uri(:user, username)

    remote =
      from(f in Follower,
        where: f.actor_uri == ^actor_uri,
        order_by: [desc: f.inserted_at, desc: f.id],
        preload: :remote_actor
      )
      |> Repo.all()

    %{local: local, remote: remote}
  end

  @doc """
  Removes a member of this instance from `user`'s followers. The follower's
  id comes from the client, so the row is matched on `user` as the one
  followed, in the query. Nothing is sent and nobody is told, as with the
  local half of a block. Returns `{:ok, follow}` or `{:error, :not_found}`.
  """
  def remove_local_follower(%{id: user_id}, follower_user_id) do
    case Repo.one(
           from(uf in UserFollow,
             where: uf.followed_user_id == ^user_id and uf.user_id == ^follower_user_id
           )
         ) do
      nil -> {:error, :not_found}
      follow -> Repo.delete(follow)
    end
  end

  @doc """
  Removes an account on another server from `user`'s followers: the
  `followers` row is deleted and a `Reject(Follow)` naming the Follow it
  accepted is queued in the same transaction (ADR 0034). `Reject(Follow)` is
  the standard way to remove a follower and says nothing about why
  (ADR 0026). The row id comes from the client, so it is matched on the
  member's own actor URI in the query. Returns `:ok` or `{:error, :not_found}`.

  They may follow again; stopping that is what a block is for.
  """
  def remove_remote_follower(user, follower_row_id) do
    alias Baudrate.Federation.{KeyStore, Publisher}

    actor_uri = Baudrate.Federation.actor_uri(:user, user.username)

    case Repo.one(
           from(f in Follower,
             where: f.id == ^follower_row_id and f.actor_uri == ^actor_uri,
             preload: :remote_actor
           )
         ) do
      nil ->
        {:error, :not_found}

      %Follower{remote_actor: remote_actor} = follower ->
        signer =
          case KeyStore.ensure_user_keypair(user) do
            {:ok, user} -> user
            _ -> nil
          end

        {:ok, _} =
          Repo.transaction(fn ->
            notify_remote(signer, remote_actor, &Publisher.build_reject_follow(&1, follower))
            Repo.delete(follower, allow_stale: true)
          end)

        :ok
    end
  end

  @doc """
  Deletes every follow, in both directions, between this instance and any actor
  on the given domain. Used when an admin blocks the domain (ADR 0030).

  Nothing is sent. This differs deliberately from `sever_remote_follows/2`,
  where a member's block queues `Undo(Follow)` and `Reject(Follow)`: delivery
  to a blocked domain is refused by our own gate (`Delivery` checks
  `domain_blocked?/1`), so those activities could only sit in the queue and
  fail. The peers learn the follows are gone the next time they try to use
  them.

  Returns `%{user_follows: n, board_follows: n, followers: n}`.
  """
  @spec sever_domain_follows(String.t()) :: %{
          user_follows: non_neg_integer(),
          board_follows: non_neg_integer(),
          followers: non_neg_integer()
        }
  def sever_domain_follows(domain) when is_binary(domain) do
    domain = String.downcase(domain)

    actor_ids =
      from(ra in RemoteActor, where: ra.domain == ^domain, select: ra.id)
      |> Repo.all()

    if actor_ids == [] do
      %{user_follows: 0, board_follows: 0, followers: 0}
    else
      {user_follows, _} =
        from(uf in UserFollow, where: uf.remote_actor_id in ^actor_ids) |> Repo.delete_all()

      {board_follows, _} =
        from(bf in BoardFollow, where: bf.remote_actor_id in ^actor_ids) |> Repo.delete_all()

      {followers, _} =
        from(f in Follower, where: f.remote_actor_id in ^actor_ids) |> Repo.delete_all()

      %{user_follows: user_follows, board_follows: board_follows, followers: followers}
    end
  end

  defp notify_remote(nil, _remote_actor, _build), do: :ok

  defp notify_remote(signer, remote_actor, build) do
    {activity, actor_uri} = build.(signer)
    Baudrate.Federation.Delivery.deliver_follow(activity, remote_actor, actor_uri)
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
      "#{Baudrate.Federation.actor_uri(:board, board.slug)}#follow-#{Ecto.UUID.generate()}"

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
  def accept_board_follow(follow_ap_id, signer \\ nil) when is_binary(follow_ap_id) do
    case Repo.one(scoped_follow_query(BoardFollow, follow_ap_id, signer)) do
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
  def reject_board_follow(follow_ap_id, signer \\ nil) when is_binary(follow_ap_id) do
    case Repo.one(scoped_follow_query(BoardFollow, follow_ap_id, signer)) do
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
  Follows `remote_actor` as `board`: inserts the pending board follow and
  queues the `Follow` activity in one transaction (Phase 2C).

  Returns `{:ok, %BoardFollow{}}` or `{:error, reason}`.
  """
  @spec follow_remote_actor_as_board(Baudrate.Content.Board.t(), RemoteActor.t()) ::
          {:ok, BoardFollow.t()} | {:error, term()}
  def follow_remote_actor_as_board(board, %RemoteActor{} = remote_actor) do
    alias Baudrate.Federation.{Delivery, KeyStore, Publisher}

    with {:ok, board} <- KeyStore.ensure_board_keypair(board) do
      Baudrate.Federation.federate(
        fn -> create_board_follow(board, remote_actor) end,
        fn follow ->
          {activity, actor_uri} = Publisher.build_board_follow(board, remote_actor, follow.ap_id)
          Delivery.deliver_follow(activity, remote_actor, actor_uri)
        end
      )
    end
  end

  @doc """
  Stops `board` following `remote_actor`: deletes the board follow and queues
  `Undo(Follow)` in one transaction.

  Returns `{:ok, %BoardFollow{}}` or `{:error, :not_found}`.
  """
  @spec unfollow_remote_actor_as_board(Baudrate.Content.Board.t(), RemoteActor.t()) ::
          {:ok, BoardFollow.t()} | {:error, term()}
  def unfollow_remote_actor_as_board(board, %RemoteActor{} = remote_actor) do
    alias Baudrate.Federation.{Delivery, KeyStore, Publisher}

    with %BoardFollow{} = follow <- get_board_follow_with_actor(board.id, remote_actor.id),
         {:ok, board} <- KeyStore.ensure_board_keypair(board) do
      Baudrate.Federation.federate(
        fn -> Repo.delete(follow) end,
        fn _deleted ->
          {activity, actor_uri} = Publisher.build_board_undo_follow(board, follow)
          Delivery.deliver_follow(activity, remote_actor, actor_uri)
        end
      )
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
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
  Returns `{:ok, %UserFollow{}}`, `{:error, :self_follow}`,
  `{:error, :account_moved}` (the followed account has moved, ADR 0025),
  `{:error, :blocked}` (either user has blocked the other) or
  `{:error, changeset}`.
  """
  def create_local_follow(%{id: follower_id} = follower, %{id: followed_id}) do
    # Following is an interaction, so a silenced or suspended follower is
    # refused (ADR 0029). A *moved* account may still follow: a move is a
    # redirect, not a punishment, and ADR 0025 lets the person carry their
    # reading list to their new home.
    gate = Baudrate.Auth.ensure_can_interact(follower_id, moved: :allow)

    cond do
      follower_id == followed_id ->
        {:error, :self_follow}

      Baudrate.Auth.blocked_between?(follower_id, followed_id) ->
        {:error, :blocked}

      gate != :ok ->
        gate

      # An account that deleted itself is gone (ADR 0072).
      Repo.exists?(
        from(u in Baudrate.Setup.User, where: u.id == ^followed_id and u.status == "deleted")
      ) ->
        {:error, :not_found}

      # The *target* side of a move, which is a different rule: a moved
      # account is followed at its new address (ADR 0025).
      Baudrate.AccountMigration.ensure_not_moved(followed_id) != :ok ->
        {:error, :account_moved}

      true ->
        insert_local_follow(follower, followed_id)
    end
  end

  defp insert_local_follow(%{id: follower_id} = follower, followed_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ap_id =
      "#{Baudrate.Federation.actor_uri(:user, follower.username)}#follow-#{Ecto.UUID.generate()}"

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
end
