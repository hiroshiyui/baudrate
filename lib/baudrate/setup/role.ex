defmodule Baudrate.Setup.Role do
  use Ecto.Schema
  import Ecto.Changeset

  schema "roles" do
    field :name, :string
    field :description, :string

    has_many :role_permissions, Baudrate.Setup.RolePermission
    many_to_many :permissions, Baudrate.Setup.Permission, join_through: "role_permissions"

    timestamps(type: :utc_datetime)
  end

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
