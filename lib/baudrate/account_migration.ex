defmodule Baudrate.AccountMigration do
  @moduledoc """
  Account migration: aliases, and moving an account to another server with
  ActivityPub `Move` (ADR 0025).

  ## Aliases

  `users.also_known_as` lists the actor ids of other accounts this user claims.
  It is published as `alsoKnownAs` on the actor document. Another server only
  accepts a `Move` of a remote account to this one if the remote account is
  listed here, and a `Move` away from here needs the destination to list this
  account in its own `alsoKnownAs`.

  Callers must have confirmed the user's identity with step-up
  re-authentication (`Baudrate.Auth.verify_reauthentication/5`, ADR 0022)
  before calling `add_alias/2` or `remove_alias/2`. Every change sends an
  always-delivered `account_alias_added` / `account_alias_removed` notice.

  ## Moving away

  A move is a request (`AccountMove`) that waits out a 24-hour cooling-off
  before the `Move` is sent, so a user whose account was taken over can cancel
  it. Authorization lives here, not in the web layer:

    * **Eligibility** (`move_eligibility/1`): the data export gate (active,
      non-bot, TOTP enabled for 7 days), not already moved, no admin or
      moderator role, not a board moderator, and no move sent in the last
      30 days.
    * **Target**: resolved like an alias, force-refreshed, a `Person` that
      lists this account in `alsoKnownAs` and has not moved itself.
    * **Step-up re-authentication** inside `request_move/4`, after the checks
      that cannot be retried, so a request that could never succeed does not
      use up attempts.
    * **Automatic cancellation** (`cancel_active_moves/2`) on password change,
      TOTP disable, sign out everywhere and ban.

  Every step sends an always-delivered notice, and a pending move shows a
  banner on every page.
  """

  import Ecto.Query

  require Logger

  alias Baudrate.{Auth, DataPortability, Federation}
  alias Baudrate.AccountMigration.AccountMove
  alias Baudrate.Content.BoardModerator
  alias Baudrate.DataPortability.UserAgent

  alias Baudrate.Federation.{
    ActorResolver,
    BoardFollow,
    Delivery,
    KeyStore,
    Publisher,
    RemoteActor,
    UserFollow,
    Validator
  }

  alias Baudrate.Notification.Hooks
  alias Baudrate.Repo
  alias Baudrate.Setup.User

  @max_aliases 5
  @max_input_length 2048
  @cooling_off_seconds 24 * 3600
  @move_interval_days 30
  @staff_roles ~w(admin moderator)
  @sweep_batch 20
  @inbound_move_interval_days 30
  @cancel_reasons AccountMove.cancel_reasons()

  @doc "Seconds between requesting a move and sending it."
  def cooling_off_seconds, do: @cooling_off_seconds

  @doc "Days that must pass after a sent move before another one."
  def move_interval_days, do: @move_interval_days

  @doc "The maximum number of aliases an account can have."
  def max_aliases, do: @max_aliases

  @doc """
  Returns `true` while the account has moved away (`users.moved_to` is set).
  A moved account is read-only (ADR 0025).
  """
  @spec moved?(User.t() | nil) :: boolean()
  def moved?(%User{moved_to: moved_to}) when is_binary(moved_to), do: true
  def moved?(_), do: false

  @doc """
  Adds an alias to `user`.

  `input` is an `@user@domain` handle or an `https://` actor URI. It is resolved
  through `Federation.lookup_remote_actor/1` (WebFinger, then `ActorResolver`,
  which is HTTPS-only and SSRF-guarded), and the resolved actor id is stored,
  never the raw input.

  Returns `{:ok, user, remote_actor}` or `{:error, reason}`, where `reason` is
  one of `:invalid_input`, `:not_found`, `:not_a_person`, `:already_added`,
  `:too_many_aliases` or `:moved`.
  """
  @spec add_alias(User.t(), String.t()) ::
          {:ok, User.t(), RemoteActor.t()} | {:error, atom()}
  def add_alias(%User{} = user, input) when is_binary(input) do
    with {:ok, query} <- normalize_input(input),
         {:ok, actor} <- resolve_actor(query),
         :ok <- check_person(actor) do
      Repo.transaction(fn ->
        locked = lock_user(user.id)

        cond do
          moved?(locked) -> Repo.rollback(:moved)
          actor.ap_id in locked.also_known_as -> Repo.rollback(:already_added)
          length(locked.also_known_as) >= @max_aliases -> Repo.rollback(:too_many_aliases)
          true -> update_aliases!(locked, locked.also_known_as ++ [actor.ap_id])
        end
      end)
      |> case do
        {:ok, updated} ->
          Logger.info("account_migration.alias_added: user_id=#{user.id} alias=#{actor.ap_id}")

          Hooks.notify_account_security(user.id, "account_alias_added", %{
            "label" => handle(actor)
          })

          {:ok, updated, actor}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def add_alias(_user, _input), do: {:error, :invalid_input}

  @doc """
  Removes the alias `ap_id` from `user`.

  Returns `{:ok, user}` or `{:error, :not_found}`.
  """
  @spec remove_alias(User.t(), String.t()) :: {:ok, User.t()} | {:error, :not_found}
  def remove_alias(%User{} = user, ap_id) when is_binary(ap_id) do
    Repo.transaction(fn ->
      locked = lock_user(user.id)

      if ap_id in locked.also_known_as do
        update_aliases!(locked, List.delete(locked.also_known_as, ap_id))
      else
        Repo.rollback(:not_found)
      end
    end)
    |> case do
      {:ok, updated} ->
        Logger.info("account_migration.alias_removed: user_id=#{user.id} alias=#{ap_id}")

        Hooks.notify_account_security(user.id, "account_alias_removed", %{
          "label" => alias_label(ap_id)
        })

        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def remove_alias(_user, _ap_id), do: {:error, :not_found}

  @doc """
  Returns the user's aliases as `%{ap_id: uri, actor: %RemoteActor{} | nil}`
  maps, in the order they were added. The actor is the cached copy, if any; no
  network request is made.
  """
  @spec list_aliases(User.t()) :: [%{ap_id: String.t(), actor: RemoteActor.t() | nil}]
  def list_aliases(%User{} = user) do
    aliases = Repo.get!(User, user.id).also_known_as

    actors =
      from(r in RemoteActor, where: r.ap_id in ^aliases)
      |> Repo.all()
      |> Map.new(&{&1.ap_id, &1})

    Enum.map(aliases, &%{ap_id: &1, actor: Map.get(actors, &1)})
  end

  @doc """
  Returns a display label for an alias: `@user@domain` when the actor is
  cached, otherwise the URI.
  """
  @spec alias_label(String.t()) :: String.t()
  def alias_label(ap_id) when is_binary(ap_id) do
    case Repo.one(from(r in RemoteActor, where: r.ap_id == ^ap_id)) do
      %RemoteActor{} = actor -> handle(actor)
      nil -> ap_id
    end
  end

  # ---------------------------------------------------------------------------
  # Moving away
  # ---------------------------------------------------------------------------

  @doc """
  Returns `:ok` when `user` may request a move, or `{:error, reason}`:

    * the data export reasons: `:bot`, `:not_active`, `:totp_required`,
      `{:totp_too_new, days_left}`
    * `:moved` — the account has already moved
    * `:staff` — admin or moderator role
    * `:board_moderator` — moderates at least one board
    * `{:recently_moved, %DateTime{}}` — a move was sent less than 30 days
      ago; the date is when another is allowed
  """
  @spec move_eligibility(User.t()) :: :ok | {:error, term()}
  def move_eligibility(%User{} = user) do
    user = Repo.preload(user, :role)

    with :ok <- DataPortability.eligibility(user) do
      cond do
        moved?(user) -> {:error, :moved}
        user.role && user.role.name in @staff_roles -> {:error, :staff}
        board_moderator?(user.id) -> {:error, :board_moderator}
        next_move_at = next_move_allowed_at(user.id) -> {:error, {:recently_moved, next_move_at}}
        true -> :ok
      end
    end
  end

  defp board_moderator?(user_id) do
    Repo.exists?(from(m in BoardModerator, where: m.user_id == ^user_id))
  end

  defp next_move_allowed_at(user_id) do
    cutoff = DateTime.add(now(), -@move_interval_days * 86_400, :second)

    from(m in AccountMove,
      where: m.user_id == ^user_id and m.status == "sent" and m.sent_at > ^cutoff,
      select: max(m.sent_at)
    )
    |> Repo.one()
    |> case do
      nil -> nil
      sent_at -> DateTime.add(sent_at, @move_interval_days * 86_400, :second)
    end
  end

  @doc """
  Resolves and checks a move target for `user`.

  `input` is a handle or actor URI, resolved like an alias. The actor is
  force-refreshed so its current `alsoKnownAs` is checked. Returns
  `{:ok, remote_actor}` or `{:error, reason}`: an alias input error,
  `:alias_not_claimed` (the target does not list this account), or
  `:target_moved`.
  """
  @spec verify_move_target(User.t(), String.t()) :: {:ok, RemoteActor.t()} | {:error, atom()}
  def verify_move_target(%User{} = user, input) when is_binary(input) do
    with {:ok, query} <- normalize_input(input),
         {:ok, actor} <- resolve_actor(query),
         {:ok, actor} <- refresh_actor(actor),
         :ok <- check_person(actor) do
      local_uri = Federation.actor_uri(:user, user.username)

      cond do
        actor.moved_to_ap_id -> {:error, :target_moved}
        local_uri not in (actor.also_known_as || []) -> {:error, :alias_not_claimed}
        true -> {:ok, actor}
      end
    end
  end

  def verify_move_target(_user, _input), do: {:error, :invalid_input}

  defp refresh_actor(%RemoteActor{ap_id: ap_id}) do
    case ActorResolver.refresh(ap_id) do
      {:ok, actor} ->
        {:ok, actor}

      {:error, reason} ->
        Logger.info("account_migration.target_refresh_failed: reason=#{inspect(reason)}")
        {:error, :not_found}
    end
  end

  @doc """
  Requests a move of `user` to the account `target_input`, after step-up
  re-authentication.

  `credentials` is `%{password: _, code: _}`. Options:

    * `:ip_address` — recorded with failed re-authentication (required)
    * `:session_id` — the requesting `user_sessions` row id
    * `:user_agent` — the raw User-Agent header; only its family is stored

  Checks run in this order: eligibility, no pending move, the target
  (network), then step-up re-authentication. The `Move` is sent after
  #{div(@cooling_off_seconds, 3600)} hours by `sweep_due_moves/0`.

  Returns `{:ok, move}` or `{:error, reason}`: an eligibility or target
  error, `:pending_move_exists`, `:invalid_credentials`, or
  `{:throttled, seconds}`.
  """
  @spec request_move(User.t(), String.t(), map(), keyword()) ::
          {:ok, AccountMove.t()} | {:error, term()}
  def request_move(%User{} = user, target_input, credentials, opts) do
    user = Repo.get!(User, user.id)

    with :ok <- move_eligibility(user),
         :ok <- ensure_no_pending_move(user.id),
         {:ok, target} <- verify_move_target(user, target_input),
         :ok <-
           Auth.verify_reauthentication(
             user,
             credential(credentials, :password),
             credential(credentials, :code),
             Keyword.fetch!(opts, :ip_address),
             :account_move
           ),
         {:ok, move} <- insert_move(user, target, opts) do
      Hooks.notify_account_security(user.id, "account_move_requested", %{
        "label" => handle(target),
        "send_after" => DateTime.to_iso8601(move.send_after),
        "browser" => move.requested_user_agent_family || ""
      })

      Logger.warning(
        "account_migration.move_requested: user_id=#{user.id} move_id=#{move.id} target=#{target.ap_id} send_after=#{move.send_after}"
      )

      {:ok, move}
    end
  end

  defp ensure_no_pending_move(user_id) do
    if active_move(user_id), do: {:error, :pending_move_exists}, else: :ok
  end

  defp insert_move(user, target, opts) do
    now = now()

    %AccountMove{}
    |> AccountMove.create_changeset(%{
      user_id: user.id,
      target_ap_id: target.ap_id,
      status: "pending",
      requested_at: now,
      send_after: DateTime.add(now, @cooling_off_seconds, :second),
      requested_session_id: Keyword.get(opts, :session_id),
      requested_user_agent_family: UserAgent.family(Keyword.get(opts, :user_agent))
    })
    |> Repo.insert()
    |> case do
      {:ok, move} ->
        {:ok, move}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        # The partial unique index lost a race with a concurrent request.
        case errors[:user_id] do
          {_msg, meta} when is_list(meta) ->
            if meta[:constraint] == :unique,
              do: {:error, :pending_move_exists},
              else: {:error, changeset}

          _ ->
            {:error, changeset}
        end
    end
  end

  @doc "Returns the user's pending move, or `nil`. Never writes."
  @spec active_move(integer()) :: AccountMove.t() | nil
  def active_move(user_id) when is_integer(user_id) do
    Repo.one(
      from(m in AccountMove, where: m.user_id == ^user_id and m.status == "pending", limit: 1)
    )
  end

  @doc """
  Returns `%{move: move, label: label}` for the user's pending move, or `nil`,
  in one query. Used by the warning banner on every page. Never writes.
  """
  @spec active_move_summary(integer()) :: %{move: AccountMove.t(), label: String.t()} | nil
  def active_move_summary(user_id) when is_integer(user_id) do
    from(m in AccountMove,
      left_join: r in RemoteActor,
      on: r.ap_id == m.target_ap_id,
      where: m.user_id == ^user_id and m.status == "pending",
      select: {m, r.username, r.domain},
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> nil
      {move, nil, _} -> %{move: move, label: move.target_ap_id}
      {move, username, domain} -> %{move: move, label: "@#{username}@#{domain}"}
    end
  end

  @doc "Returns the user's moves, newest first."
  @spec list_move_history(integer()) :: [AccountMove.t()]
  def list_move_history(user_id) when is_integer(user_id) do
    Repo.all(
      from(m in AccountMove,
        where: m.user_id == ^user_id,
        order_by: [desc: m.requested_at, desc: m.id]
      )
    )
  end

  @doc """
  Cancels the user's pending move `move_id`. Any of the user's sessions may
  cancel. Returns `{:ok, move}` or `{:error, :not_found}` (also for another
  user's move or one that is no longer pending).
  """
  @spec cancel_move(integer(), integer(), String.t()) ::
          {:ok, AccountMove.t()} | {:error, :not_found}
  def cancel_move(user_id, move_id, reason \\ "user")
      when is_integer(user_id) and is_integer(move_id) do
    case cancel(from(m in AccountMove, where: m.id == ^move_id), user_id, reason) do
      [move] -> {:ok, move}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Cancels every pending move of the user. Called when the account's
  credentials or sessions change, and on ban. Returns the number cancelled.
  """
  @spec cancel_active_moves(integer(), String.t()) :: non_neg_integer()
  def cancel_active_moves(user_id, reason) when is_integer(user_id) do
    AccountMove |> cancel(user_id, reason) |> length()
  end

  defp cancel(queryable, user_id, reason) when reason in @cancel_reasons do
    now = now()

    {_count, cancelled} =
      from(m in queryable,
        where: m.user_id == ^user_id and m.status == "pending",
        select: m,
        update: [
          set: [status: "cancelled", cancelled_at: ^now, cancel_reason: ^reason, updated_at: ^now]
        ]
      )
      |> Repo.update_all([])

    Enum.each(cancelled, fn move ->
      Hooks.notify_account_security(user_id, "account_move_cancelled", %{
        "reason" => reason,
        "label" => alias_label(move.target_ap_id)
      })

      Logger.info(
        "account_migration.move_cancelled: user_id=#{user_id} move_id=#{move.id} reason=#{reason}"
      )
    end)

    cancelled
  end

  # ---------------------------------------------------------------------------
  # Sending
  # ---------------------------------------------------------------------------

  @doc """
  Sends every pending move whose cooling-off has passed (at most
  #{@sweep_batch} per run), via `send_move/1`. Called hourly by
  `Baudrate.Auth.SessionCleaner`. Returns the number processed.
  """
  @spec sweep_due_moves() :: non_neg_integer()
  def sweep_due_moves do
    now = now()

    due =
      Repo.all(
        from(m in AccountMove,
          where: m.status == "pending" and m.send_after <= ^now,
          order_by: [asc: m.send_after, asc: m.id],
          limit: @sweep_batch
        )
      )

    Enum.each(due, &send_move/1)
    length(due)
  end

  @doc """
  Re-checks a due move and sends it, or marks it failed.

  Everything is checked again at send time: the account must still be
  eligible, and the destination must still resolve, list this account in
  `alsoKnownAs`, and not have moved. A move cancelled while the check ran is
  left alone: the `pending → sent` update is conditional.

  On success, in order:

    1. the move is marked `sent` and `users.moved_to` / `moved_at` are set,
       in one transaction;
    2. an `Update` of the actor (now carrying `movedTo`) and the `Move` are
       queued for the account's remote followers;
    3. local followers are moved to the destination
       (`migrate_local_followers/2`);
    4. the owner gets an always-delivered `account_moved` notice.

  Returns `:sent`, `:failed` or `:skipped`.
  """
  @spec send_move(AccountMove.t()) :: :sent | :failed | :skipped
  def send_move(%AccountMove{status: "pending"} = move) do
    user = Repo.get(User, move.user_id)

    result =
      with %User{} <- user || {:error, :user_missing},
           :ok <- move_eligibility(user),
           {:ok, target} <- verify_move_target(user, move.target_ap_id) do
        {:ok, target}
      end

    case result do
      {:ok, target} -> complete_move(move, user, target)
      {:error, reason} -> fail_move(move, reason)
    end
  end

  def send_move(%AccountMove{}), do: :skipped

  defp complete_move(move, user, target) do
    now = now()

    Repo.transaction(fn ->
      {count, _} =
        from(m in AccountMove, where: m.id == ^move.id and m.status == "pending")
        |> Repo.update_all(set: [status: "sent", sent_at: now, updated_at: now])

      if count != 1, do: Repo.rollback(:not_pending)

      user |> User.moved_changeset(target.ap_id, now) |> Repo.update!()
    end)
    |> case do
      {:ok, moved_user} ->
        publish_move(moved_user, target)
        migrated = migrate_local_followers(moved_user, target)

        Hooks.notify_account_security(user.id, "account_moved", %{"label" => handle(target)})

        Logger.warning(
          "account_migration.move_sent: user_id=#{user.id} move_id=#{move.id} target=#{target.ap_id} local_followers=#{migrated}"
        )

        :sent

      {:error, :not_pending} ->
        :skipped
    end
  end

  defp publish_move(moved_user, target) do
    {:ok, moved_user} = KeyStore.ensure_user_keypair(moved_user)
    {update, actor_uri} = Publisher.build_update_actor(:user, moved_user)
    Delivery.enqueue_for_followers(update, actor_uri)
    {move_activity, ^actor_uri} = Publisher.build_move(moved_user, target.ap_id)
    Delivery.enqueue_for_followers(move_activity, actor_uri)
  end

  defp fail_move(move, reason) do
    code = failure_code(reason)
    now = now()

    {count, _} =
      from(m in AccountMove, where: m.id == ^move.id and m.status == "pending")
      |> Repo.update_all(set: [status: "failed", failure_reason: code, updated_at: now])

    if count == 1 do
      Hooks.notify_account_security(move.user_id, "account_move_failed", %{
        "reason" => code,
        "label" => alias_label(move.target_ap_id)
      })

      Logger.warning(
        "account_migration.move_failed: user_id=#{move.user_id} move_id=#{move.id} reason=#{code}"
      )

      :failed
    else
      :skipped
    end
  end

  defp failure_code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_code(_), do: "unknown"

  @doc """
  Moves the local followers of `moved_user` to `target`.

  For each active local follower: remove the local follow, create a pending
  follow of the destination and deliver `Follow` on their behalf (skipped when
  they already follow it), and send an `actor_moved` notice. Returns the
  number of followers moved.
  """
  @spec migrate_local_followers(User.t(), RemoteActor.t()) :: non_neg_integer()
  def migrate_local_followers(%User{} = moved_user, %RemoteActor{} = target) do
    moved_user.id
    |> Federation.local_followers_of_user()
    |> Enum.map(&Repo.get(User, &1))
    |> Enum.filter(&match?(%User{status: "active", is_bot: false}, &1))
    |> Enum.count(fn follower ->
      Federation.delete_local_follow(follower, moved_user)
      follow_on_behalf(follower, target)

      Hooks.notify_actor_moved(follower.id, %{actor_user_id: moved_user.id}, %{
        "label" => handle(target),
        "url" => target.url || target.ap_id
      })

      true
    end)
  end

  @doc """
  Creates a pending follow of `target` for `follower` and delivers the
  `Follow`. Does nothing when `follower` already follows `target`.
  """
  @spec follow_on_behalf(User.t(), RemoteActor.t()) :: :followed | :already_following | :error
  def follow_on_behalf(%User{} = follower, %RemoteActor{} = target) do
    if Federation.user_follows?(follower.id, target.id) do
      :already_following
    else
      with {:ok, follower} <- KeyStore.ensure_user_keypair(follower),
           {:ok, follow} <- Federation.create_user_follow(follower, target) do
        {activity, actor_uri} = Publisher.build_follow(follower, target, follow.ap_id)
        Delivery.deliver_follow(activity, target, actor_uri)
        :followed
      else
        _ -> :error
      end
    end
  end

  # ---------------------------------------------------------------------------
  # After a move
  # ---------------------------------------------------------------------------

  @doc """
  Returns `:ok` unless the account (a `User` or user id) has moved, in which
  case `{:error, :account_moved}`. Context functions that create content or
  interactions call it, so a moved account is read-only however it is
  reached (ADR 0025).
  """
  @spec ensure_not_moved(User.t() | integer() | nil) :: :ok | {:error, :account_moved}
  def ensure_not_moved(%User{id: id}), do: ensure_not_moved(id)

  def ensure_not_moved(user_id) when is_integer(user_id) do
    moved =
      Repo.exists?(from(u in User, where: u.id == ^user_id and not is_nil(u.moved_to)))

    if moved, do: {:error, :account_moved}, else: :ok
  end

  def ensure_not_moved(_), do: :ok

  @doc """
  Returns `%{label: "@user@domain", url: "https://…"}` for the account a moved
  user moved to, or `nil` when the user has not moved. Uses the cached remote
  actor; falls back to the actor id.
  """
  @spec moved_target(User.t()) :: %{label: String.t(), url: String.t()} | nil
  def moved_target(%User{moved_to: moved_to}) when is_binary(moved_to) do
    case Repo.one(from(r in RemoteActor, where: r.ap_id == ^moved_to)) do
      %RemoteActor{} = actor -> %{label: handle(actor), url: actor.url || actor.ap_id}
      nil -> %{label: moved_to, url: moved_to}
    end
  end

  def moved_target(_user), do: nil

  @doc """
  Removes the redirect of a moved account after step-up re-authentication:
  clears `moved_to` / `moved_at`, publishes an `Update` of the actor without
  `movedTo`, and restores posting. Followers already moved stay moved, and the
  30-day limit still counts the move.

  Returns `{:ok, user}` or `{:error, reason}`: `:not_moved`,
  `:invalid_credentials` or `{:throttled, seconds}`.
  """
  @spec remove_redirect(User.t(), map(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def remove_redirect(%User{} = user, credentials, opts) do
    user = Repo.get!(User, user.id)

    with :ok <- if(moved?(user), do: :ok, else: {:error, :not_moved}),
         :ok <-
           Auth.verify_reauthentication(
             user,
             credential(credentials, :password),
             credential(credentials, :code),
             Keyword.fetch!(opts, :ip_address),
             :account_redirect
           ),
         {:ok, updated} <- user |> User.moved_changeset(nil, nil) |> Repo.update() do
      {:ok, updated} = KeyStore.ensure_user_keypair(updated)
      {update, actor_uri} = Publisher.build_update_actor(:user, updated)
      Delivery.enqueue_for_followers(update, actor_uri)

      Hooks.notify_account_security(user.id, "account_redirect_removed", %{
        "label" => alias_label(user.moved_to)
      })

      Logger.warning(
        "account_migration.redirect_removed: user_id=#{user.id} was=#{user.moved_to}"
      )

      {:ok, updated}
    end
  end

  # ---------------------------------------------------------------------------
  # Inbound: a followed remote account moves
  # ---------------------------------------------------------------------------

  @doc """
  Handles a verified inbound `Move` of `origin` (the signing remote actor) to
  `target_uri` (ADR 0025).

  The destination must claim `origin` in `alsoKnownAs` (a local destination:
  in `users.also_known_as`), otherwise `{:error, :move_not_authorized}`.
  A `Move` is ignored (`:ok`) when the destination cannot be resolved or has
  moved itself, or when `origin` already had a `Move` processed in the last
  #{@inbound_move_interval_days} days. That bound stops an actor bouncing between accounts it
  controls from making every local follower send a stream of `Follow`s.

  For each active local follower of `origin`:

    * `Undo(Follow)` is sent to `origin` and the old follow removed;
    * a remote destination gets a pending follow and a `Follow` on the
      follower's behalf (accepted when it answers); a local destination gets a
      local follow;
    * the follower gets an `actor_moved` notice.

  Feed items are repointed to a remote destination
  (`Federation.migrate_feed_items/2`), so the history shows again once the
  new follow is accepted. Board follows are never repointed: admins get a
  `board_actor_moved` notice instead.
  """
  @spec handle_inbound_move(RemoteActor.t(), String.t()) ::
          :ok | {:error, :move_not_authorized}
  def handle_inbound_move(%RemoteActor{} = origin, target_uri) when is_binary(target_uri) do
    if Validator.local_actor?(target_uri) do
      move_to_local(origin, target_uri)
    else
      move_to_remote(origin, target_uri)
    end
  end

  defp move_to_remote(origin, target_uri) do
    # Force-refresh so the alias check reflects the destination's current state.
    case ActorResolver.refresh(target_uri) do
      {:ok, target} ->
        cond do
          origin.ap_id not in (target.also_known_as || []) ->
            log_move_rejected(origin, target_uri, "alias_not_claimed")
            {:error, :move_not_authorized}

          target.id == origin.id or target.moved_to_ap_id ->
            log_move_ignored(origin, target_uri, "target_moved")
            :ok

          not claim_inbound_move(origin, target.ap_id) ->
            log_move_ignored(origin, target_uri, "recently_moved")
            :ok

          true ->
            label = handle(target)
            data = %{"label" => label, "url" => target.url || target.ap_id}

            migrated =
              refollow(origin, data, fn follower ->
                follow_on_behalf(follower, target)
              end)

            {authored, boosted} = Federation.migrate_feed_items(origin.id, target.id)
            notify_board_admins(origin, label)

            Logger.info(
              "federation.move_complete: from=#{origin.ap_id} to=#{target.ap_id} followers=#{migrated} feed_items_authored=#{authored} feed_items_boosted=#{boosted}"
            )

            :ok
        end

      {:error, reason} ->
        log_move_ignored(origin, target_uri, "unresolvable #{inspect(reason)}")
        :ok
    end
  end

  defp move_to_local(origin, target_uri) do
    case local_user_for_actor_uri(target_uri) do
      %User{status: "active", moved_to: nil} = target ->
        cond do
          origin.ap_id not in (target.also_known_as || []) ->
            log_move_rejected(origin, target_uri, "alias_not_claimed")
            {:error, :move_not_authorized}

          not claim_inbound_move(origin, target_uri) ->
            log_move_ignored(origin, target_uri, "recently_moved")
            :ok

          true ->
            data = %{"label" => "@#{target.username}", "url" => "/users/#{target.username}"}

            migrated =
              refollow(origin, data, fn follower ->
                if follower.id != target.id, do: Federation.create_local_follow(follower, target)
              end)

            notify_board_admins(origin, "@#{target.username}")

            Logger.info(
              "federation.move_complete: from=#{origin.ap_id} to=#{target_uri} local=true followers=#{migrated}"
            )

            :ok
        end

      _ ->
        log_move_ignored(origin, target_uri, "local_target_unavailable")
        :ok
    end
  end

  defp local_user_for_actor_uri(uri) do
    prefix = Federation.actor_uri(:user, "")
    username = String.replace_prefix(uri, prefix, "")

    if String.starts_with?(uri, prefix) and username =~ ~r/\A[A-Za-z0-9_]+\z/ do
      Repo.one(from(u in User, where: u.username == ^username))
    end
  end

  # One conditional UPDATE, so duplicate deliveries of the same Move (user and
  # shared inbox) are processed once.
  defp claim_inbound_move(origin, target_ap_id) do
    now = now()
    cutoff = DateTime.add(now, -@inbound_move_interval_days * 86_400, :second)

    {count, _} =
      from(r in RemoteActor,
        where: r.id == ^origin.id and (is_nil(r.moved_at) or r.moved_at < ^cutoff)
      )
      |> Repo.update_all(set: [moved_to_ap_id: target_ap_id, moved_at: now, updated_at: now])

    count == 1
  end

  defp refollow(origin, data, follow_new) do
    from(uf in UserFollow,
      where: uf.remote_actor_id == ^origin.id,
      preload: [:user, :remote_actor]
    )
    |> Repo.all()
    |> Enum.filter(&match?(%User{status: "active"}, &1.user))
    |> Enum.count(fn follow ->
      follower = follow.user
      undo_remote_follow(follower, follow, origin)
      Repo.delete(follow)
      follow_new.(follower)
      Hooks.notify_actor_moved(follower.id, %{actor_remote_actor_id: origin.id}, data)
      true
    end)
  end

  defp undo_remote_follow(follower, follow, origin) do
    case KeyStore.ensure_user_keypair(follower) do
      {:ok, follower} ->
        {activity, actor_uri} = Publisher.build_undo_follow(follower, follow)
        Delivery.deliver_follow(activity, origin, actor_uri)

      _ ->
        :error
    end
  end

  defp notify_board_admins(origin, label) do
    boards =
      Repo.all(
        from(bf in BoardFollow,
          join: b in assoc(bf, :board),
          where: bf.remote_actor_id == ^origin.id,
          order_by: [asc: b.name],
          select: b.name
        )
      )

    if boards != [] do
      Hooks.notify_board_actor_moved(origin.id, %{"label" => label, "boards" => boards})
    end
  end

  defp log_move_rejected(origin, target_uri, reason) do
    Logger.warning(
      "federation.move_rejected: from=#{origin.ap_id} to=#{target_uri} reason=#{reason}"
    )
  end

  defp log_move_ignored(origin, target_uri, reason) do
    Logger.info("federation.move_ignored: from=#{origin.ap_id} to=#{target_uri} reason=#{reason}")
  end

  defp credential(credentials, key) when is_map(credentials),
    do: Map.get(credentials, key) || Map.get(credentials, Atom.to_string(key))

  defp credential(_credentials, _key), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc """
  Returns a map of actor id to display label (`@user@domain` when cached,
  otherwise the URI) for `ap_ids`, in one query.
  """
  @spec target_labels([String.t()]) :: %{String.t() => String.t()}
  def target_labels(ap_ids) when is_list(ap_ids) do
    cached =
      from(r in RemoteActor, where: r.ap_id in ^ap_ids, select: {r.ap_id, r.username, r.domain})
      |> Repo.all()
      |> Map.new(fn {ap_id, username, domain} -> {ap_id, "@#{username}@#{domain}"} end)

    Map.new(ap_ids, &{&1, Map.get(cached, &1, &1)})
  end

  defp handle(%RemoteActor{username: username, domain: domain}), do: "@#{username}@#{domain}"

  defp normalize_input(input) do
    query = String.trim(input)

    if query == "" or String.length(query) > @max_input_length or
         String.match?(query, ~r/[\s[:cntrl:]]/u) do
      {:error, :invalid_input}
    else
      {:ok, query}
    end
  end

  # Local actors are refused by ActorResolver (`:self_referencing`) and a
  # local handle resolves to a local actor, so both end up as `:not_found`.
  defp resolve_actor(query) do
    case Federation.lookup_remote_actor(query) do
      {:ok, %RemoteActor{} = actor} ->
        {:ok, actor}

      {:error, :invalid_query} ->
        {:error, :invalid_input}

      {:error, reason} ->
        Logger.info("account_migration.alias_lookup_failed: reason=#{inspect(reason)}")
        {:error, :not_found}
    end
  end

  # Only person accounts can be move targets or sources; boards (Group),
  # instance actors and bots (Service) cannot.
  defp check_person(%RemoteActor{actor_type: "Person"}), do: :ok
  defp check_person(_), do: {:error, :not_a_person}

  defp lock_user(user_id) do
    Repo.one!(from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE"))
  end

  defp update_aliases!(user, aliases) do
    case user |> User.aliases_changeset(aliases) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, _changeset} -> Repo.rollback(:too_many_aliases)
    end
  end
end
