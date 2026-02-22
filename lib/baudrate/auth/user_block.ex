defmodule Baudrate.Auth.UserBlock do
  @moduledoc """
  Schema for user-level blocks.

  Supports blocking both local users (`blocked_user_id`) and remote actors
  (`blocked_actor_ap_id`). Exactly one of the two must be set, enforced by
  a database check constraint.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Setup.User

  schema "user_blocks" do
    belongs_to :user, User
    belongs_to :blocked_user, User
    field :blocked_actor_ap_id, :string

    timestamps(updated_at: false)
  end

  @doc """
  Changeset for blocking a local user.
  """
  def local_changeset(block, attrs) do
    block
    |> cast(attrs, [:user_id, :blocked_user_id])
    |> validate_required([:user_id, :blocked_user_id])
    |> unique_constraint([:user_id, :blocked_user_id], name: :user_blocks_local_unique)
    |> check_constraint(:blocked_user_id, name: :must_block_something)
    |> validate_not_self_block()
  end

  @doc """
  Changeset for blocking a remote actor by AP ID.
  """
  def remote_changeset(block, attrs) do
    block
    |> cast(attrs, [:user_id, :blocked_actor_ap_id])
    |> validate_required([:user_id, :blocked_actor_ap_id])
    |> unique_constraint([:user_id, :blocked_actor_ap_id], name: :user_blocks_remote_unique)
    |> check_constraint(:blocked_actor_ap_id, name: :must_block_something)
  end

  defp validate_not_self_block(changeset) do
    user_id = get_field(changeset, :user_id)
    blocked_id = get_field(changeset, :blocked_user_id)

    if user_id && blocked_id && user_id == blocked_id do
      add_error(changeset, :blocked_user_id, "cannot block yourself")
    else
      changeset
    end
  end
end
