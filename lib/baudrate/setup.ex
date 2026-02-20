defmodule Baudrate.Setup do
  @moduledoc """
  The Setup context handles first-time application configuration.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Setup.{Permission, Role, RolePermission, Setting, User}

  @doc """
  Returns the permission matrix as a map of role name to list of permission names.
  Pure function, no database access.
  """
  def default_permissions do
    %{
      "admin" => [
        "admin.manage_users",
        "admin.manage_settings",
        "admin.view_dashboard",
        "admin.manage_roles",
        "moderator.manage_content",
        "moderator.manage_comments",
        "moderator.view_reports",
        "moderator.mute_user",
        "user.create_content",
        "user.edit_own_content",
        "user.manage_profile",
        "guest.view_content"
      ],
      "moderator" => [
        "moderator.manage_content",
        "moderator.manage_comments",
        "moderator.view_reports",
        "moderator.mute_user",
        "user.create_content",
        "user.edit_own_content",
        "user.manage_profile",
        "guest.view_content"
      ],
      "user" => [
        "user.create_content",
        "user.edit_own_content",
        "user.manage_profile",
        "guest.view_content"
      ],
      "guest" => [
        "guest.view_content"
      ]
    }
  end

  @role_descriptions %{
    "admin" => "Full system access",
    "moderator" => "Content and user moderation",
    "user" => "Standard user access",
    "guest" => "Read-only access"
  }

  @permission_descriptions %{
    "admin.manage_users" => "Create, edit, and delete users",
    "admin.manage_settings" => "Modify system settings",
    "admin.view_dashboard" => "View admin dashboard",
    "admin.manage_roles" => "Manage roles and permissions",
    "moderator.manage_content" => "Edit and remove content",
    "moderator.manage_comments" => "Manage comments",
    "moderator.view_reports" => "View moderation reports",
    "moderator.mute_user" => "Mute users",
    "user.create_content" => "Create new content",
    "user.edit_own_content" => "Edit own content",
    "user.manage_profile" => "Manage own profile",
    "guest.view_content" => "View published content"
  }

  @doc """
  Returns true if the setup wizard has been completed.
  """
  def setup_completed? do
    Repo.exists?(from s in Setting, where: s.key == "setup_completed" and s.value == "true")
  end

  @doc """
  Checks the database connection and returns version info.
  """
  def check_database do
    case Repo.query("SELECT version(), current_database()") do
      {:ok, %{rows: [[version, database]]}} ->
        {:ok, %{version: version, database: database}}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  @doc """
  Checks if all migrations have been run.
  """
  def check_migrations do
    migrations = Ecto.Migrator.migrations(Repo)

    pending =
      Enum.filter(migrations, fn {status, _version, _name} -> status == :down end)

    if pending == [] do
      {:ok, length(migrations)}
    else
      {:error, pending}
    end
  end

  @doc """
  Returns a changeset for tracking site name changes.
  """
  def change_site_name(attrs \\ %{}) do
    {%{}, %{site_name: :string}}
    |> Ecto.Changeset.cast(attrs, [:site_name])
    |> Ecto.Changeset.validate_required([:site_name])
    |> Ecto.Changeset.validate_length(:site_name, min: 1, max: 255)
  end

  @doc """
  Returns a changeset for tracking user registration changes.
  """
  def change_user_registration(user \\ %User{}, attrs \\ %{}) do
    User.registration_changeset(user, attrs)
  end

  @doc """
  Completes the setup by inserting site name, roles/permissions, admin user,
  and setup_completed flag in a single transaction.
  """
  def complete_setup(site_name, user_attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :site_name,
      Setting.changeset(%Setting{}, %{key: "site_name", value: site_name})
    )
    |> Ecto.Multi.run(:seed_permissions, fn _repo, _changes ->
      seed_roles_and_permissions()
    end)
    |> Ecto.Multi.run(:admin_user, fn _repo, %{seed_permissions: %{roles: roles}} ->
      admin_role = Map.fetch!(roles, "admin")
      attrs = Map.put(user_attrs, "role_id", admin_role.id)
      %User{} |> User.registration_changeset(attrs) |> Repo.insert()
    end)
    |> Ecto.Multi.insert(
      :setup_completed,
      Setting.changeset(%Setting{}, %{key: "setup_completed", value: "true"})
    )
    |> Repo.transaction()
  end

  @doc """
  Seeds all roles, permissions, and role_permission mappings into the database.
  Returns `{:ok, %{roles: roles_map, permissions: permissions_list}}`.
  """
  def seed_roles_and_permissions do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    permissions_matrix = default_permissions()

    # Collect all unique permission names
    all_permission_names =
      permissions_matrix
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()

    # Insert roles
    roles =
      permissions_matrix
      |> Map.keys()
      |> Enum.map(fn name ->
        %Role{}
        |> Role.changeset(%{name: name, description: Map.get(@role_descriptions, name)})
        |> Repo.insert!()
      end)
      |> Map.new(fn role -> {role.name, role} end)

    # Insert permissions
    permissions =
      all_permission_names
      |> Enum.map(fn name ->
        %Permission{}
        |> Permission.changeset(%{
          name: name,
          description: Map.get(@permission_descriptions, name)
        })
        |> Repo.insert!()
      end)

    permissions_by_name = Map.new(permissions, fn p -> {p.name, p} end)

    # Insert role_permissions
    for {role_name, perm_names} <- permissions_matrix,
        perm_name <- perm_names do
      role = Map.fetch!(roles, role_name)
      permission = Map.fetch!(permissions_by_name, perm_name)

      Repo.insert!(%RolePermission{
        role_id: role.id,
        permission_id: permission.id,
        inserted_at: now,
        updated_at: now
      })
    end

    {:ok, %{roles: roles, permissions: permissions}}
  end

  @doc """
  Returns true if the given role has the given permission.
  Queries the database via the 3-table join.
  """
  def has_permission?(role_name, permission_name) do
    query =
      from rp in RolePermission,
        join: r in Role,
        on: rp.role_id == r.id,
        join: p in Permission,
        on: rp.permission_id == p.id,
        where: r.name == ^role_name and p.name == ^permission_name,
        select: true

    Repo.exists?(query)
  end

  @doc """
  Returns a list of permission name strings for the given role name.
  """
  def permissions_for_role(role_name) do
    from(p in Permission,
      join: rp in RolePermission,
      on: rp.permission_id == p.id,
      join: r in Role,
      on: rp.role_id == r.id,
      where: r.name == ^role_name,
      select: p.name,
      order_by: p.name
    )
    |> Repo.all()
  end

  @doc """
  Returns all roles from the database.
  """
  def all_roles do
    Repo.all(from r in Role, order_by: r.name)
  end
end
