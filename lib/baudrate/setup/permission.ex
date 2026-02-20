defmodule Baudrate.Setup.Permission do
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
