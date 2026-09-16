defmodule Baudrate.Auth.Sanctions do
  # A sanction issued by a global moderator lasts at most this long. An
  # indefinite restriction is an admin decision (ADR 0029).
  @moderator_max_days 30

  @moduledoc """
  Sanctions short of a ban, and the single gate that enforces them (ADR 0029).

  ## One gate

  `ensure_can_interact/1` is the only check a context function needs before it
  lets an account create content or interact. It **replaces**
  `Baudrate.AccountMigration.ensure_not_moved/1` at every call site: a moved
  account, a silenced account, a suspended account and a banned account are
  all refused by the same function, so a new posting path cannot enforce one
  rule and forget the others.

  `test/baudrate/auth/sanctions_gate_test.exs` fails if `ensure_not_moved/1`
  is called anywhere outside this module.

  ## What a silence stops, and what it leaves alone

  Refused: articles, article edits, comments, feed replies, likes, boosts,
  forwards, poll votes, follows, direct messages, invites, and profile changes
  (display name, bio, avatar, links) — a bio is a billboard, and silencing
  someone who is then free to rewrite theirs at their target achieves nothing.

  Still allowed, deliberately: undoing an earlier like or boost, deleting
  their own content, **reporting abuse** (a silenced member must still be able
  to report), and everything about account security — password, second
  factors, sessions and data export.

  A suspension is enforced at sign-in (`Baudrate.Auth.authenticate_by_password/2`)
  rather than per interaction, and re-checked in `BaudrateWeb.AuthHooks`.

  ## Terms the member has not accepted

  The same gate carries the pause that published terms put on posting (P1-D8,
  ADR 0031), as `{:error, :terms_not_accepted}`. It is not a sanction — the
  member clears it themselves on `/terms` — but it stops the same things, and
  putting it here is what makes that true of every posting path at once rather
  than of whichever ones someone remembered.

  It is checked **last**, so a member who is silenced *and* behind on the terms
  is told about the silence: that is the one they cannot lift alone. And bot
  accounts are exempt, because they cannot sign in to accept and their posts go
  through this gate too.

  ## Who may sanction whom

  The power is the `moderator.sanction_user` permission, so P1-D3 is
  configuration rather than a hard-coded role name. Two rules hold whatever
  the roles are configured to be, and both are checked here rather than in a
  LiveView:

    * **Nobody sanctions themselves**, as `ban_user/3` already refuses.
    * **Nobody sanctions an account whose role level is at or above their
      own**, so a moderator cannot silence another moderator or an admin.

  A sanction issued without `admin.manage_users` is capped at
  #{@moderator_max_days} days, measured server-side from `issued_at` and never
  trusted from the form.
  """

  import Ecto.Query

  require Logger

  alias Baudrate.Auth.Sanction
  alias Baudrate.Moderation
  alias Baudrate.Notification.Hooks
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.User

  @restricting_kinds Sanction.restricting_kinds()

  # The permission that lets a role warn, silence and suspend, and refuse a
  # pending registration.
  @sanction_permission "moderator.sanction_user"
  # The permission that lifts the duration cap and carries ban/unban.
  @unrestricted_permission "admin.manage_users"

  @typedoc """
  Why an account may not act. `:account_moved` keeps the shape callers and
  flashes already handle (ADR 0025).
  """
  @type refusal ::
          :banned
          | :account_suspended
          | :account_silenced
          | :account_moved
          | :terms_not_accepted

  @doc """
  Returns `:ok` unless the account may not create content or interact.

  Takes a `User` (or any struct with an integer `id`), a user id, or `nil`.
  An unknown id and `nil` return `:ok`: there is no account to restrict, and
  the caller's own existence checks decide what that means.

  Refusals are returned strongest first — `:banned`, then
  `:account_suspended`, `:account_silenced`, `:account_moved` — so the message
  a member sees names the reason that actually has to be lifted first.

  ## Options

    * `:moved` — `:refuse` (the default) or `:allow`. A move is a redirect,
      not a punishment: ADR 0025 stops a moved account publishing anything,
      but deliberately lets it keep *following* accounts, so that the person
      can carry their reading list to their new home. A sanction has no such
      exception. Only the follow paths pass `moved: :allow`, and they are the
      only place the two rules differ.
  """
  @spec ensure_can_interact(User.t() | map() | integer() | nil, keyword()) ::
          :ok | {:error, refusal()}
  def ensure_can_interact(user, opts \\ [])

  def ensure_can_interact(%{id: id}, opts) when is_integer(id), do: ensure_can_interact(id, opts)

  def ensure_can_interact(user_id, opts) when is_integer(user_id) do
    refuse_moved? = Keyword.get(opts, :moved, :refuse) == :refuse

    case account_state(user_id) do
      nil ->
        :ok

      %{status: "banned"} ->
        {:error, :banned}

      state ->
        cond do
          "suspend" in state.kinds -> {:error, :account_suspended}
          "silence" in state.kinds -> {:error, :account_silenced}
          refuse_moved? and state.moved -> {:error, :account_moved}
          terms_pending?(state) -> {:error, :terms_not_accepted}
          true -> :ok
        end
    end
  end

  def ensure_can_interact(_, _), do: :ok

  # Published terms the account has not accepted yet (P1-D8). Last of the
  # refusals because it is the mildest and the only one the member can clear
  # themselves — someone who is silenced *and* behind on the terms should be
  # told about the silence, which is what actually has to be lifted.
  #
  # Bots are exempt. A bot user cannot sign in, so it can never accept, and
  # `Content.create_article/3` puts bot posts through this same gate: without
  # this, publishing new terms would quietly stop every RSS feed on the site.
  defp terms_pending?(%{is_bot: true}), do: false

  defp terms_pending?(%{terms_version: accepted}) do
    accepted < Setup.current_terms_version()
  end

  # One query: the account's status and redirect, plus the kinds of sanction
  # active on it right now. "Active" is read from the clock here rather than
  # from a flag some job maintains.
  defp account_state(user_id) do
    now = DateTime.utc_now()

    from(u in User,
      left_join: s in Sanction,
      on:
        s.user_id == u.id and s.kind in ^@restricting_kinds and is_nil(s.lifted_at) and
          (is_nil(s.expires_at) or s.expires_at > ^now),
      where: u.id == ^user_id,
      group_by: [u.id, u.status, u.moved_to, u.terms_version, u.is_bot],
      select: %{
        status: u.status,
        moved: not is_nil(u.moved_to),
        terms_version: u.terms_version,
        is_bot: u.is_bot,
        kinds: fragment("array_remove(array_agg(DISTINCT ?), NULL)", s.kind)
      }
    )
    |> Repo.one()
  end

  @doc """
  Returns `true` when the account may create content and interact. The
  boolean form of `ensure_can_interact/1`, for templates that hide a control
  the context would refuse anyway.
  """
  @spec can_interact?(User.t() | map() | integer() | nil, keyword()) :: boolean()
  def can_interact?(user, opts \\ []), do: ensure_can_interact(user, opts) == :ok

  @doc """
  Returns the account's active sanctions, strongest kind first and, within a
  kind, the one that ends furthest away.

  Several active rows of the same kind are allowed and harmless: the account
  is restricted while *any* of them is active, and the end shown is the
  furthest away (ADR 0029). So issuing can only extend a sanction; to shorten
  one, lift it.
  """
  @spec active_sanctions(User.t() | integer()) :: [Sanction.t()]
  def active_sanctions(%{id: id}) when is_integer(id), do: active_sanctions(id)

  def active_sanctions(user_id) when is_integer(user_id) do
    user_id
    |> active_query()
    |> Repo.all()
    |> Enum.sort_by(&{kind_rank(&1.kind), expiry_rank(&1.expires_at)})
  end

  @doc """
  Returns the active sanction of `kind` that ends furthest away, or `nil`.

  This is what a refusal message quotes: a member told "you cannot post" must
  also be told why and until when.
  """
  @spec active_sanction(User.t() | integer(), String.t()) :: Sanction.t() | nil
  def active_sanction(user, kind) when kind in @restricting_kinds do
    user
    |> active_sanctions()
    |> Enum.filter(&(&1.kind == kind))
    |> List.first()
  end

  @doc """
  Returns `true` when an active silence stands against the account.
  """
  @spec silenced?(User.t() | integer()) :: boolean()
  def silenced?(user), do: active?(user, "silence")

  @doc """
  Returns `true` when an active suspension stands against the account.
  """
  @spec suspended?(User.t() | integer()) :: boolean()
  def suspended?(user), do: active?(user, "suspend")

  defp active?(%{id: id}, kind) when is_integer(id), do: active?(id, kind)

  defp active?(user_id, kind) when is_integer(user_id) do
    user_id
    |> active_query()
    |> where([s], s.kind == ^kind)
    |> Repo.exists?()
  end

  defp active?(_, _), do: false

  @doc """
  Lists every sanction ever issued against the account, newest first, with
  the issuing and lifting moderators preloaded. Rows are never deleted, so
  this is the account's full record.
  """
  @spec list_sanctions(User.t() | integer()) :: [Sanction.t()]
  def list_sanctions(%{id: id}) when is_integer(id), do: list_sanctions(id)

  def list_sanctions(user_id) when is_integer(user_id) do
    from(s in Sanction,
      where: s.user_id == ^user_id,
      order_by: [desc: s.issued_at, desc: s.id],
      preload: [:issued_by, :lifted_by]
    )
    |> Repo.all()
  end

  @doc """
  Returns the query for the account's currently active **restricting**
  sanctions, for callers that want to compose further. Active is decided by
  the clock, never by a stored flag.

  A warning is never "active": it restricts nothing and has no duration, so
  it is history the moment it is issued. It appears in `list_sanctions/1`.
  """
  @spec active_query(integer()) :: Ecto.Query.t()
  def active_query(user_id) when is_integer(user_id) do
    now = DateTime.utc_now()

    from(s in Sanction,
      where:
        s.user_id == ^user_id and s.kind in ^@restricting_kinds and is_nil(s.lifted_at) and
          (is_nil(s.expires_at) or s.expires_at > ^now)
    )
  end

  # ---------------------------------------------------------------------------
  # Issuing and lifting
  # ---------------------------------------------------------------------------

  @doc """
  Issues a sanction against `target` on behalf of `actor`.

  `kind` is `"warn"`, `"silence"` or `"suspend"`. Options:

    * `:reason` — shown to the member, so it should read as an explanation
    * `:expires_at` — when the sanction ends. Required for `"suspend"`,
      optional for `"silence"`, ignored for `"warn"`
    * `:report_id` — the report that prompted it, when there was one

  Suspending also revokes every session (so open LiveViews disconnect) and
  cancels active data exports and account moves, as a ban does. It
  deliberately leaves invite codes alone: they expire in seven days by
  themselves, a suspended account cannot generate more, and a temporary
  sanction should leave nothing to put back by hand.

  The member is always told (P1-D4), the action is audited, and a stolen
  moderator session cannot issue them in bulk
  (`BaudrateWeb.RateLimits.check_sanction/1` is the caller's responsibility at
  the web boundary; the authority rules below are enforced here).

  Returns `{:ok, sanction}`, or `{:error, reason}` where reason is
  `:self_action`, `:unauthorized`, `:role_too_high`, `:duration_too_long`,
  `:cannot_sanction_banned` or a changeset.
  """
  @spec issue(User.t(), User.t(), String.t(), keyword()) ::
          {:ok, Sanction.t()} | {:error, term()}
  def issue(%User{} = actor, %User{} = target, kind, opts \\ []) when is_binary(kind) do
    expires_at = Keyword.get(opts, :expires_at)

    with :ok <- authorize(actor, target, kind),
         :ok <- check_duration(actor, kind, expires_at),
         {:ok, sanction} <- insert_sanction(actor, target, kind, opts) do
      apply_side_effects(sanction, target)
      audit(actor, sanction, target)
      notify_applied(sanction, target)
      {:ok, sanction}
    end
  end

  @doc """
  Lifts every active sanction of `kind` against `target`, recording who lifted
  them and why.

  Issuing can only extend a sanction, because any active row restricts the
  account; shortening one is therefore always a lift. Returns
  `{:ok, count}` — `0` when there was nothing active to lift — or
  `{:error, reason}`.
  """
  @spec lift(User.t(), User.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def lift(%User{} = actor, %User{} = target, kind, opts \\ [])
      when kind in @restricting_kinds do
    with :ok <- authorize(actor, target, kind) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {count, _} =
        target.id
        |> active_query()
        |> where([s], s.kind == ^kind)
        |> Repo.update_all(
          set: [
            lifted_at: now,
            lifted_by_id: actor.id,
            lift_reason: Keyword.get(opts, :lift_reason),
            updated_at: now
          ]
        )

      if count > 0 do
        Moderation.log_action(actor.id, "lift_sanction",
          target_type: "user",
          target_id: target.id,
          details: %{"kind" => kind, "count" => count}
        )

        Hooks.notify_account_security(target.id, "sanction_lifted", %{
          "kind" => kind,
          "reason" => Keyword.get(opts, :lift_reason)
        })
      end

      {:ok, count}
    end
  end

  @doc """
  Tells members whose sanction has just ended that it has, and returns how
  many were told.

  This is the *only* thing a background run does with sanctions: enforcement
  already stopped by the clock the moment `expires_at` passed, so a missed run
  delays a courtesy notice and nothing else (ADR 0029). Rows are marked with
  `ended_notified_at` so a member is told once.
  """
  @spec notify_ended_sanctions() :: non_neg_integer()
  def notify_ended_sanctions do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(s in Sanction,
      where:
        s.kind in ^@restricting_kinds and is_nil(s.lifted_at) and is_nil(s.ended_notified_at) and
          not is_nil(s.expires_at) and s.expires_at <= ^now,
      select: s
    )
    |> Repo.all()
    |> Enum.count(fn sanction ->
      {count, _} =
        from(s in Sanction, where: s.id == ^sanction.id and is_nil(s.ended_notified_at))
        |> Repo.update_all(set: [ended_notified_at: now, updated_at: now])

      if count == 1 do
        Hooks.notify_account_security(sanction.user_id, "sanction_ended", %{
          "kind" => sanction.kind
        })

        true
      else
        false
      end
    end)
  end

  @doc """
  Refuses a registration that is still waiting to be let in, with a reason.

  A refused account must not sign in, which is exactly what `banned` already
  means and enforces everywhere. Adding a `rejected` status would have to be
  learned by every `status != "banned"` check in the codebase, and the ones
  that forgot would admit the account — so refusing is a ban, recorded as
  `reject_user` so the two are told apart in the log (ADR 0029).

  Authorization is on the act, not the state: `#{@sanction_permission}` is
  enough to refuse an account that is still `pending`, while banning an active
  member stays with `#{@unrestricted_permission}`. The row is not deleted:
  there is no user-deletion path yet, and building one as a side effect of
  this would decide account deletion by accident.

  Returns `{:ok, user}`, or `{:error, :not_pending | :unauthorized |
  :self_action | :role_too_high | changeset}`.
  """
  @spec reject_pending(User.t(), User.t(), String.t() | nil) ::
          {:ok, User.t()} | {:error, term()}
  def reject_pending(%User{} = actor, %User{} = target, reason \\ nil) do
    with :ok <- ensure_pending(target),
         :ok <- authorize(actor, target, "reject") do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      result =
        target
        |> User.ban_changeset(%{status: "banned", banned_at: now, ban_reason: reason})
        |> Repo.update()

      with {:ok, rejected} <- result do
        Baudrate.Auth.Sessions.delete_all_sessions_for_user(rejected.id)

        Moderation.log_action(actor.id, "reject_user",
          target_type: "user",
          target_id: rejected.id,
          details: %{"reason" => reason}
        )

        Logger.info("auth.registration_rejected: user_id=#{rejected.id} by=#{actor.id}")

        {:ok, rejected}
      end
    end
  end

  defp ensure_pending(%User{status: "pending"}), do: :ok
  defp ensure_pending(_user), do: {:error, :not_pending}

  @doc """
  Returns `:ok` when `actor` may sanction `target`, or `{:error, reason}`.

  Exposed so a LiveView can hide a control it would otherwise offer and then
  refuse; the context checks it again regardless.
  """
  @spec authorize(User.t(), User.t(), String.t()) :: :ok | {:error, atom()}
  def authorize(%User{} = actor, %User{} = target, _kind) do
    cond do
      actor.id == target.id -> {:error, :self_action}
      not permitted?(actor, @sanction_permission) -> {:error, :unauthorized}
      outranks_or_equals?(target, actor) -> {:error, :role_too_high}
      target.status == "banned" -> {:error, :cannot_sanction_banned}
      true -> :ok
    end
  end

  @doc """
  Returns the furthest expiry `actor` may set, or `nil` when they may issue an
  indefinite sanction. The cap is #{@moderator_max_days} days without
  `#{@unrestricted_permission}`.
  """
  @spec max_expiry(User.t()) :: DateTime.t() | nil
  def max_expiry(%User{} = actor) do
    if permitted?(actor, @unrestricted_permission) do
      nil
    else
      DateTime.utc_now()
      |> DateTime.add(@moderator_max_days * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)
    end
  end

  @doc "The cap, in days, on a sanction issued without `#{@unrestricted_permission}`."
  def moderator_max_days, do: @moderator_max_days

  defp check_duration(_actor, "warn", _expires_at), do: :ok

  defp check_duration(actor, _kind, expires_at) do
    case {max_expiry(actor), expires_at} do
      # An admin may issue an indefinite silence.
      {nil, _} ->
        :ok

      # Everyone else must set an end, within the cap.
      {_cap, nil} ->
        {:error, :duration_too_long}

      {cap, %DateTime{} = at} ->
        if DateTime.compare(at, cap) == :gt, do: {:error, :duration_too_long}, else: :ok
    end
  end

  defp insert_sanction(actor, target, kind, opts) do
    %Sanction{}
    |> Sanction.issue_changeset(%{
      user_id: target.id,
      kind: kind,
      reason: Keyword.get(opts, :reason),
      issued_by_id: actor.id,
      expires_at: Keyword.get(opts, :expires_at),
      report_id: Keyword.get(opts, :report_id)
    })
    |> Repo.insert()
  end

  # A suspension has to reach the sessions that are already open, or it is
  # only a sign-in check the member never meets.
  defp apply_side_effects(%Sanction{kind: "suspend"}, %User{} = target) do
    Baudrate.Auth.Sessions.delete_all_sessions_for_user(target.id)
    Baudrate.DataPortability.cancel_active_exports(target.id, "suspended")
    Baudrate.AccountMigration.cancel_active_moves(target.id, "suspended")
    :ok
  end

  defp apply_side_effects(_sanction, _target), do: :ok

  # Each action name is written out, never interpolated from `kind`:
  # `test/baudrate/moderation/log_test.exs` walks these call sites for literal
  # names and cannot check one that is built at runtime.
  defp audit(actor, %Sanction{kind: "warn"} = sanction, target) do
    Moderation.log_action(actor.id, "warn_user", log_opts(sanction, target))
  end

  defp audit(actor, %Sanction{kind: "silence"} = sanction, target) do
    Moderation.log_action(actor.id, "silence_user", log_opts(sanction, target))
  end

  defp audit(actor, %Sanction{kind: "suspend"} = sanction, target) do
    Moderation.log_action(actor.id, "suspend_user", log_opts(sanction, target))
  end

  defp log_opts(%Sanction{} = sanction, target) do
    [
      target_type: "user",
      target_id: target.id,
      details: %{
        "sanction_id" => sanction.id,
        "reason" => sanction.reason,
        "expires_at" => sanction.expires_at && DateTime.to_iso8601(sanction.expires_at),
        "report_id" => sanction.report_id
      }
    ]
  end

  # Always delivered, like an account security notice: nobody may switch off
  # being told what was done to their account and until when (P1-D4).
  defp notify_applied(%Sanction{} = sanction, target) do
    Hooks.notify_account_security(target.id, "sanction_applied", %{
      "kind" => sanction.kind,
      "reason" => sanction.reason,
      "expires_at" => sanction.expires_at && DateTime.to_iso8601(sanction.expires_at)
    })
  end

  defp permitted?(%User{} = actor, permission) do
    case actor do
      %User{role: %{name: name}} when is_binary(name) -> Setup.has_permission?(name, permission)
      _ -> permitted?(Repo.preload(actor, :role).role, permission)
    end
  end

  defp permitted?(%{name: name}, permission) when is_binary(name),
    do: Setup.has_permission?(name, permission)

  defp permitted?(_, _), do: false

  # Never act on an account at or above your own level, however the roles are
  # configured: a moderator cannot silence another moderator or an admin.
  defp outranks_or_equals?(target, actor) do
    Setup.role_level(role_name(target)) >= Setup.role_level(role_name(actor))
  end

  defp role_name(%User{role: %{name: name}}) when is_binary(name), do: name
  defp role_name(%User{} = user), do: Repo.preload(user, :role).role.name

  defp kind_rank("suspend"), do: 0
  defp kind_rank("silence"), do: 1
  defp kind_rank(_), do: 2

  # An indefinite sanction (no end) outranks every dated one.
  defp expiry_rank(nil), do: {0, 0}
  defp expiry_rank(%DateTime{} = at), do: {1, -DateTime.to_unix(at)}
end
