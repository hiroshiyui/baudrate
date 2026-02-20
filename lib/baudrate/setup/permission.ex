defmodule Baudrate.Setup.Permission do
  @moduledoc """
  Schema for permissions stored in the `permissions` table.

  Permission names follow a `scope.action` convention where the scope matches
  the minimum role that natively owns the permission. Examples:

    * `"admin.manage_users"` — admin-level capability
    * `"moderator.manage_content"` — moderator-level capability
    * `"user.create_content"` — user-level capability
    * `"guest.view_content"` — guest-level capability

  See `Setup.default_permissions/0` for the full matrix.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "permissions" do
    field :name, :string
    field :description, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(permission, attrs) do
    permission
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
