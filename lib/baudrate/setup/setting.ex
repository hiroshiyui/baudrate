defmodule Baudrate.Setup.Setting do
  @moduledoc """
  Key-value settings stored in the `settings` table.

  Known keys:

    * `"site_name"` — the forum's display name, set during initial setup
    * `"setup_completed"` — `"true"` once the setup wizard finishes;
      checked by `EnsureSetup` plug to gate access
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "settings" do
    field :key, :string
    field :value, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Casts and validates key-value fields for a setting record."
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
    |> unique_constraint(:key)
  end
end
