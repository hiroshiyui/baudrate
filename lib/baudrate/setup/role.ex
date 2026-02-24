defmodule Baudrate.Setup.Role do
  @moduledoc """
  Schema for roles stored in the `roles` table.

  Built-in roles seeded by `Setup.seed_roles_and_permissions/0`:

    * `"admin"` — full system access
    * `"moderator"` — content and user moderation
    * `"user"` — standard user access
    * `"guest"` — read-only access
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "roles" do
    field :name, :string
    field :description, :string

    has_many :role_permissions, Baudrate.Setup.RolePermission
    many_to_many :permissions, Baudrate.Setup.Permission, join_through: "role_permissions"

    timestamps(type: :utc_datetime)
  end

  @doc "Casts and validates fields for creating or updating a role."
  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
