defmodule Baudrate.Auth.Users do
  @moduledoc """
  Handles user registration, lifecycle (approval, status), search, and retrieval.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.{Role, User}
  alias Baudrate.Auth.{SecondFactor, Invites}

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
      from u in User, where: fragment("lower(?)", u.username) == ^downcased, preload: :role
    )
  end

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
      |> User.validate_terms()
      |> Ecto.Changeset.put_change(:status, status)
      |> Repo.insert()

    with {:ok, user} <- result do
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
            |> Map.put("invited_by_id", invite.created_by_id)

          changeset =
            %User{}
            |> User.registration_changeset(reg_attrs)
            |> User.validate_terms()
            |> Ecto.Changeset.put_change(:status, "active")

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
  Approves a pending user by setting their status to `"active"`.
  """
  def approve_user(user) do
    user
    |> User.status_changeset(%{status: "active"})
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
  Returns `true` if the user's account is active.
  """
  def user_active?(user), do: user.status == "active"

  @doc """
  Returns `true` if the user can create content.

  Requires both:
    1. Account status is `"active"` (pending users cannot post)
    2. Role has the `"user.create_content"` permission
  """
  @spec can_create_content?(User.t()) :: boolean()
  def can_create_content?(user) do
    user_active?(user) && Setup.has_permission?(user.role.name, "user.create_content")
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
      order_by: [desc: dynamic([u], u.inserted_at)],
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
    user
    |> User.role_changeset(%{role_id: role_id})
    |> Repo.update()
    |> case do
      {:ok, user} -> {:ok, Repo.preload(user, :role, force: true)}
      error -> error
    end
  end
end
