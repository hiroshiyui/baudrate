defmodule Baudrate.Auth.ReservedHandle do
  @moduledoc """
  Tracks handles (usernames and board slugs) that have been freed by
  deletion of a user or board, so they cannot be re-registered.

  This prevents identity fraud: if a well-known user or board is deleted,
  nobody else should be able to claim the same fediverse handle
  (`@handle@instance`) and impersonate them.

  All handles are stored in lowercase so comparisons are case-insensitive.
  The reservation is permanent — once reserved, a handle can only be
  unreserved by an admin via direct database action.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "reserved_handles" do
    field :handle, :string
    field :handle_type, :string
    field :reserved_at, :utc_datetime

    timestamps(updated_at: false)
  end

  @doc """
  Changeset for inserting a newly reserved handle.

  `handle_type` must be `"user"` or `"board"`.
  `handle` is always stored in lowercase.
  """
  def changeset(reserved_handle, attrs) do
    reserved_handle
    |> cast(attrs, [:handle, :handle_type, :reserved_at])
    |> validate_required([:handle, :handle_type, :reserved_at])
    |> validate_inclusion(:handle_type, ~w(user board))
    |> update_change(:handle, &String.downcase/1)
    |> unique_constraint(:handle)
  end
end
