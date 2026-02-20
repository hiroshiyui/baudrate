defmodule Baudrate.Setup.RolePermission do
  use Ecto.Schema
  import Ecto.Changeset

  schema "role_permissions" do
    belongs_to :role, Baudrate.Setup.Role
    belongs_to :permission, Baudrate.Setup.Permission

    timestamps(type: :utc_datetime)
  end

  def changeset(role_permission, attrs) do
    role_permission
    |> cast(attrs, [:role_id, :permission_id])
    |> validate_required([:role_id, :permission_id])
    |> assoc_constraint(:role)
    |> assoc_constraint(:permission)
    |> unique_constraint([:role_id, :permission_id])
  end
end
