defmodule Baudrate.Auth.Users do
  @moduledoc """
  Handles user registration, lifecycle (approval, status), search, and retrieval.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.{Role, User}
  alias Baudrate.Auth.{SecondFactor, Invites}
  alias Baudrate.Pagination

  @user_search_per_page 20
  @max_user_search_pages 5

  @doc """
  Gets a user by ID with role preloaded.
  """
  @spec get_user(integer()) :: User.t() | nil
  def get_user(id) do
    Repo.one(from u in User, where: u.id == ^id, preload: :role)
  end

  @doc """
  Gets a user by username with role preloaded, or nil if not found.
  """
  @spec get_user_by_username(String.t()) :: User.t() | nil
  def get_user_by_username(username) when is_binary(username) do
    Repo.one(from u in User, where: u.username == ^username, preload: :role)
  end

  @doc """
  Gets a user by username (case-insensitive) with role preloaded, or nil if not found.

  Used by mention parsing where `@Username` and `@username` should resolve to
  the same user.
  """
  def get_user_by_username_ci(username) when is_binary(username) do
    downcased = String.downcase(username)

    Repo.one(
      from u in User,
        where: fragment("lower(?)", u.username) == ^downcased,
        order_by: [asc: u.id],
        limit: 1,
        preload: :role
    )
  end

  @doc """
  Records that a member accepts the terms as they stand right now.

  The version is read here rather than taken from the caller: a form carrying
  the version could be submitted from a page left open since before the terms
  changed, recording acceptance of something the member never saw.
  """
  @spec accept_current_terms(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def accept_current_terms(%User{} = user) do
    user
    |> Ecto.Changeset.change(
      terms_accepted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      terms_version: Setup.current_terms_version()
    )
    |> Repo.update()
  end

  @doc """
  Returns true when published terms are waiting for this member's acceptance.

  The boolean form of the gate's own check, for pages that show a banner.
  """
  @spec terms_pending?(User.t() | nil) :: boolean()
  def terms_pending?(%User{is_bot: true}), do: false

  def terms_pending?(%User{terms_version: accepted}),
    do: accepted < Setup.current_terms_version()

  def terms_pending?(_), do: false

  @doc """
  Registers a new user with the `"user"` role.

  The account status depends on `Setup.registration_mode/0`:
    * `"open"` → status `"active"` (immediately usable)
    * `"approval_required"` → status `"pending"` (can log in but restricted)
  """
  @spec register_user(map()) ::
          {:ok, User.t(), [String.t()]}
          | {:error, Ecto.Changeset.t() | {:invalid_invite, atom()} | :invite_required}
  def register_user(attrs) do
    mode = Setup.registration_mode()

    case mode do
      "invite_only" -> register_with_invite(attrs)
      _ -> register_standard(attrs, mode)
    end
  end

  defp register_standard(attrs, mode) do
    role = Repo.one!(from r in Role, where: r.name == "user")

    status =
      case mode do
        "open" -> "active"
        _ -> "pending"
      end

    attrs =
      attrs
      |> Map.put("role_id", role.id)
      |> Map.put("status", status)

    result =
      %User{}
      |> User.registration_changeset(Map.delete(attrs, "status"))
      |> User.accept_terms()
      |> Ecto.Changeset.put_change(:status, status)
      |> Repo.insert()

    with {:ok, user} <- result do
      # Staff cannot act on a queue they do not know has anything in it.
      if user.status == "pending" do
        Baudrate.Notification.Hooks.notify_pending_registration(user)
      end

      codes = SecondFactor.generate_recovery_codes(user)
      {:ok, user, codes}
    end
  end

  defp register_with_invite(attrs) do
    invite_code = attrs["invite_code"] || attrs[:invite_code]

    if is_nil(invite_code) || invite_code == "" do
      {:error, :invite_required}
    else
      case Invites.validate_invite_code(invite_code) do
        {:ok, invite} ->
          role = Repo.one!(from r in Role, where: r.name == "user")

          attrs =
            attrs
            |> Map.put("role_id", role.id)
            |> Map.put("status", "active")

          reg_attrs =
            attrs
            |> Map.delete("status")
            |> Map.delete("invite_code")
            |> Map.delete("invited_by_id")

          changeset =
            %User{}
            |> User.registration_changeset(reg_attrs)
            |> User.accept_terms()
            |> Ecto.Changeset.put_change(:status, "active")
            # From the validated invite, never from the form.
            |> Ecto.Changeset.put_change(:invited_by_id, invite.created_by_id)

          Repo.transaction(fn ->
            case Repo.insert(changeset) do
              {:ok, user} ->
                Invites.use_invite_code(invite, user.id)
                codes = SecondFactor.generate_recovery_codes(user)
                {user, codes}

              {:error, changeset} ->
                Repo.rollback(changeset)
            end
          end)
          |> case do
            {:ok, {user, codes}} -> {:ok, user, codes}
            {:error, changeset} -> {:error, changeset}
          end

        {:error, reason} ->
          {:error, {:invalid_invite, reason}}
      end
    end
  end

  @doc """
  Approves a pending user by setting their status to `"active"`, and tells
  them.

  The notice is sent from here rather than from the admin LiveView because
  that is where every other account notice comes from — a second approval path
  must not be able to skip it. Until Phase 4D approval was silent, and a member
  discovered it by trying to post and finding they now could.
  """
  def approve_user(user) do
    user
    |> User.status_changeset(%{status: "active"})
    |> Repo.update()
    |> tap(fn
      {:ok, approved} ->
        Baudrate.Notification.Hooks.notify_account_security(approved.id, "registration_approved")

      _ ->
        :ok
    end)
  end

  @doc """
  Whether this account has been through the first-visit step.

  Existing accounts were backfilled when the column was added, so a `nil` here
  means "registered since Phase 4D and has not finished /welcome" rather than
  "old account".
  """
  @spec onboarded?(User.t()) :: boolean()
  def onboarded?(%User{onboarded_at: nil}), do: false
  def onboarded?(%User{}), do: true

  @doc """
  Marks the first-visit step done, whether the member filled it in or skipped
  it. Idempotent, and stamped here rather than cast from a form.
  """
  @spec mark_onboarded(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def mark_onboarded(%User{onboarded_at: nil} = user) do
    user
    |> Ecto.Changeset.change(onboarded_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  def mark_onboarded(%User{} = user), do: {:ok, user}

  @doc """
  Dismisses the recovery notice for this account, for good.

  Dismissal is remembered rather than re-asked, because a notice that comes
  back is the manufactured urgency ADR 0056 refuses — and because the member
  may have deliberate reasons for arranging recovery their own way.
  """
  @spec dismiss_recovery_notice(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def dismiss_recovery_notice(%User{} = user) do
    user
    |> Ecto.Changeset.change(recovery_notice_dismissed_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  @doc """
  Returns all users with `status: "pending"`, ordered by registration date.
  """
  def list_pending_users do
    from(u in User,
      where: u.status == "pending",
      order_by: [asc: u.inserted_at, asc: u.id],
      preload: :role
    )
    |> Repo.all()
  end

  @doc """
  Returns the accounts this user invited, newest first.

  The invite chain is part of the record on a user detail page: an account
  that invited five spammers is a different case from one that invited none
  (ADR 0029).
  """
  @spec list_invitees(integer(), pos_integer()) :: [User.t()]
  def list_invitees(user_id, limit \\ 20) when is_integer(user_id) do
    from(u in User,
      where: u.invited_by_id == ^user_id,
      order_by: [desc: u.inserted_at, desc: u.id],
      limit: ^limit,
      preload: :role
    )
    |> Repo.all()
  end

  @max_tree_depth 5
  @max_tree_accounts 200

  @doc """
  The accounts `user_id` invited, and the accounts they invited, and so on —
  for the ban dialog on the user detail page (Phase 5A).

  Returns `%{nodes: [...], truncated: boolean}`, where each node is
  `%{user: user, depth: n, inviter_id: id, post_count: n}` and `depth` is 1 for
  the accounts the root invited directly.

  **Bounded two ways**, because the page renders whatever this returns and an
  invite chain is data somebody else chose the shape of: at most
  #{@max_tree_depth} levels and at most #{@max_tree_accounts} accounts, with
  `truncated: true` when either stopped the walk. A visited set guards against
  a cycle — `invited_by_id` cannot form one through registration, but this
  must not hang if a manual repair ever made one.

  `post_count` is articles plus comments not soft-deleted, so the moderator
  choosing what to ban can tell an account that has written nothing from one
  that has a history.
  """
  @spec invite_tree(integer()) :: %{nodes: [map()], truncated: boolean()}
  def invite_tree(user_id) when is_integer(user_id) do
    {nodes, truncated} = walk_invites([user_id], MapSet.new([user_id]), 1, [])
    counts = post_counts(Enum.map(nodes, & &1.user.id))

    %{
      nodes: Enum.map(nodes, &Map.put(&1, :post_count, Map.get(counts, &1.user.id, 0))),
      truncated: truncated
    }
  end

  defp walk_invites([], _seen, _depth, acc), do: {Enum.reverse(acc), false}

  defp walk_invites(_frontier, _seen, depth, acc) when depth > @max_tree_depth,
    do: {Enum.reverse(acc), true}

  defp walk_invites(frontier, seen, depth, acc) do
    room = @max_tree_accounts - length(acc)

    children =
      from(u in User,
        where: u.invited_by_id in ^frontier,
        order_by: [asc: u.inserted_at, asc: u.id],
        # One past the room left, so a full batch can be told from a batch
        # that exactly fits.
        limit: ^(room + 1),
        preload: :role
      )
      |> Repo.all()
      |> Enum.reject(&MapSet.member?(seen, &1.id))

    {taken, overflow} = Enum.split(children, room)

    nodes = Enum.map(taken, &%{user: &1, depth: depth, inviter_id: &1.invited_by_id})
    acc = Enum.reverse(nodes, acc)

    cond do
      overflow != [] ->
        {Enum.reverse(acc), true}

      taken == [] ->
        {Enum.reverse(acc), false}

      true ->
        seen = Enum.reduce(taken, seen, &MapSet.put(&2, &1.id))
        walk_invites(Enum.map(taken, & &1.id), seen, depth + 1, acc)
    end
  end

  defp post_counts([]), do: %{}

  defp post_counts(ids) do
    articles =
      from(a in Baudrate.Content.Article,
        where: a.user_id in ^ids and is_nil(a.deleted_at),
        group_by: a.user_id,
        select: {a.user_id, count(a.id)}
      )
      |> Repo.all()
      |> Map.new()

    comments =
      from(c in Baudrate.Content.Comment,
        where: c.user_id in ^ids and is_nil(c.deleted_at),
        group_by: c.user_id,
        select: {c.user_id, count(c.id)}
      )
      |> Repo.all()
      |> Map.new()

    Map.merge(articles, comments, fn _id, a, c -> a + c end)
  end

  @doc """
  Returns `true` if the user's account is active.
  """
  def user_active?(user), do: user.status == "active"

  @doc """
  Returns `true` if the user can create content.

  Requires all of:
    1. Account status is `"active"` (pending users cannot post)
    2. The account is unrestricted — not moved, silenced or suspended
       (`Auth.ensure_can_interact/1`, ADR 0029)
    3. Role has the `"user.create_content"` permission
  """
  @spec can_create_content?(User.t()) :: boolean()
  def can_create_content?(user) do
    user_active?(user) && Baudrate.Auth.Sanctions.can_interact?(user) &&
      Setup.has_permission?(user.role.name, "user.create_content")
  end

  @doc """
  Returns `true` if the user can upload an avatar.

  Authenticated users (including pending) are allowed to upload
  avatars to personalize their profile.
  """
  @spec can_upload_avatar?(User.t()) :: boolean()
  def can_upload_avatar?(user) do
    user.status in ["active", "pending"]
  end

  @doc """
  Searches active users by partial username match.

  Used for recipient selection in DMs and other user pickers.
  Sanitizes the search term to prevent SQL wildcard injection.

  ## Options

    * `:limit` — max results to return (default 10)
    * `:exclude_id` — exclude a specific user ID from results (e.g. current user)
  """
  def search_users(term, opts \\ []) when is_binary(term) do
    limit = Keyword.get(opts, :limit, 10)
    exclude_id = Keyword.get(opts, :exclude_id)

    sanitized = Repo.sanitize_like(term)

    query =
      from(u in User,
        where: u.status == "active" and ilike(u.username, ^"%#{sanitized}%"),
        order_by: u.username,
        limit: ^limit,
        preload: :role
      )

    query = if exclude_id, do: from(u in query, where: u.id != ^exclude_id), else: query
    Repo.all(query)
  end

  @doc """
  The same search as `search_users/2`, paginated, for the Users tab on
  `/search`.

  `search_users/2` is kept as it is: its four other callers (the autocomplete
  hook, the DM recipient picker, two admin pickers) want a short list, not a
  page of one.

  ## The cap

  `total_pages` is capped at #{@max_user_search_pages} pages
  (#{@max_user_search_pages * @user_search_per_page} matches) and the result
  carries `capped: true` when there was more, so the page can ask the reader
  to narrow the search. `total` stays honest.

  The cap is the reason this is not simply `search_users/2` with an offset.
  A member's profile is public and linked from every byline — that is
  [ADR 0057](../../../doc/adr/0057-a-sitemap-invites-only-what-a-guest-sees.md)'s
  decision, and so is the other half of it: the member list is never
  *enumerated*, because nobody opted into a machine-readable list of everyone
  here. Uncapped paging walks the whole membership at a few hundred accounts a
  minute, including members who have never posted and so appear in no byline.
  Nobody looking for a person needs page six.

  Only `status == "active"` is listed, so pending and banned accounts are
  absent — and a banned account must stay indistinguishable from one that
  never existed.

  ## Options

    * `:page` — page number (default 1)
    * `:per_page` — users per page (default #{@user_search_per_page})
    * `:exclude_id` — exclude a specific user ID (e.g. the viewer)

  Returns `%{users, total, page, per_page, total_pages, capped}`.
  """
  @spec search_users_page(String.t(), keyword()) :: map()
  def search_users_page(term, opts \\ []) when is_binary(term) do
    pagination = Pagination.paginate_opts(opts, @user_search_per_page)
    exclude_id = Keyword.get(opts, :exclude_id)
    sanitized = Repo.sanitize_like(term)

    # A member who opted out of discovery is not listed here (ADR 0073). The
    # short lists `search_users/2` serves — mentions, the message picker, the
    # admin pickers — still find them: those are someone asking for them by
    # name, not browsing.
    base_query =
      from(u in User,
        where: u.status == "active" and u.discoverable and ilike(u.username, ^"%#{sanitized}%")
      )

    base_query =
      if exclude_id, do: from(u in base_query, where: u.id != ^exclude_id), else: base_query

    result =
      Pagination.paginate_query(base_query, pagination,
        result_key: :users,
        order_by: [asc: dynamic([u], u.username)],
        preloads: [:role]
      )

    capped_pages = min(result.total_pages, @max_user_search_pages)

    %{result | total_pages: capped_pages}
    |> Map.put(:capped, result.total_pages > capped_pages)
  end

  # --- User Management ---

  @users_per_page 20

  @doc """
  Lists users with optional filters.

  ## Options

    * `:status` — filter by status (e.g. `"active"`, `"pending"`, `"banned"`)
    * `:role` — filter by role name
    * `:search` — ILIKE search on username
  """
  def list_users(opts \\ []) do
    Repo.all(users_base_query(opts))
  end

  @doc """
  Returns a paginated list of users with optional filters.

  ## Options

    * `:status` — filter by status (e.g. `"active"`, `"pending"`, `"banned"`)
    * `:role` — filter by role name
    * `:search` — ILIKE search on username
    * `:page` — page number (default 1)
    * `:per_page` — users per page (default #{@users_per_page})

  Returns `%{users: [...], total: N, page: N, per_page: N, total_pages: N}`.
  """
  def paginate_users(opts \\ []) do
    alias Baudrate.Pagination

    pagination = Pagination.paginate_opts(opts, @users_per_page)

    users_filter_query(opts)
    |> Pagination.paginate_query(pagination,
      result_key: :users,
      order_by: [desc: dynamic([u], u.inserted_at), desc: dynamic([u], u.id)],
      preloads: [:role]
    )
  end

  defp users_base_query(opts) do
    from(u in users_filter_query(opts),
      order_by: [desc: u.inserted_at, desc: u.id],
      preload: :role
    )
  end

  defp users_filter_query(opts) do
    query = from(u in User)

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> from(u in query, where: u.status == ^status)
      end

    query =
      case Keyword.get(opts, :role) do
        nil -> query
        role_name -> from(u in query, join: r in assoc(u, :role), where: r.name == ^role_name)
      end

    case Keyword.get(opts, :search) do
      nil ->
        query

      "" ->
        query

      term ->
        sanitized = Repo.sanitize_like(term)
        from(u in query, where: ilike(u.username, ^"%#{sanitized}%"))
    end
  end

  @doc """
  The accounts counted as members: people, not bots, and neither banned nor
  deleted — a ban is a removal and a tombstone is nobody. NodeInfo's
  `users.total` and the admin dashboard both count this, so the two cannot
  disagree about how many members the site has.
  """
  @spec counted_members_query() :: Ecto.Query.t()
  def counted_members_query do
    from(u in User, where: not u.is_bot and u.status not in ["banned", "deleted"])
  end

  @doc """
  Returns a map of status counts, e.g. `%{"active" => 5, "pending" => 2, "banned" => 1}`.
  """
  def count_users_by_status do
    from(u in User, group_by: u.status, select: {u.status, count(u.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Updates a user's role. Returns `{:error, :self_action}` on self-role-change.
  """
  @spec update_user_role(User.t(), integer(), integer()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | :self_action}
  def update_user_role(%User{id: id}, _role_id, admin_id) when id == admin_id do
    {:error, :self_action}
  end

  def update_user_role(%User{} = user, role_id, admin_id)
      when is_integer(admin_id) do
    # Checked here rather than only in the LiveView (ADR 0016), and expressed
    # as the `admin.manage_roles` permission that already existed and until
    # now enforced nothing (ADR 0029).
    if can_manage_roles?(admin_id) do
      user
      |> User.role_changeset(%{role_id: role_id})
      |> Repo.update()
      |> case do
        {:ok, user} ->
          # Revoked like a ban, and for the same reason: authority is read from
          # the user struct loaded at mount, and `on_mount` never runs again.
          # A demoted admin's open `/admin/users` and `/invites` tabs went on
          # banning accounts and minting unlimited invite codes until they
          # happened to reload. `delete_all_sessions_for_user/1` broadcasts
          # "disconnect" to `live_socket_id`, so those sockets die at once.
          Baudrate.Auth.Sessions.delete_all_sessions_for_user(user.id)

          {:ok, Repo.preload(user, :role, force: true)}

        error ->
          error
      end
    else
      {:error, :unauthorized}
    end
  end

  defp can_manage_roles?(admin_id) do
    case get_user(admin_id) do
      %User{role: %{name: name}} -> Setup.has_permission?(name, "admin.manage_roles")
      _ -> false
    end
  end
end
