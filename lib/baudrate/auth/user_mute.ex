defmodule Baudrate.Auth.UserMute do
  @moduledoc """
  Schema for user-level mutes (local-only soft-mute/ignore).

  Muting is a lighter action than blocking — it hides content from the
  muter's view without preventing interaction or sending any federation
  activity. Supports muting both local users (`muted_user_id`) and
  remote actors (`muted_actor_ap_id`). Exactly one of the two must be
  set, enforced by a database check constraint.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Setup.User

  schema "user_mutes" do
    belongs_to :user, User
    belongs_to :muted_user, User
    field :muted_actor_ap_id, :string

    timestamps(updated_at: false)
  end

  @doc """
  Changeset for muting a local user.
  """
  def local_changeset(mute, attrs) do
    mute
    |> cast(attrs, [:user_id, :muted_user_id])
    |> validate_required([:user_id, :muted_user_id])
    |> unique_constraint([:user_id, :muted_user_id], name: :user_mutes_local_unique)
    |> check_constraint(:muted_user_id, name: :must_mute_something)
    |> validate_not_self_mute()
  end

  @doc """
  Changeset for muting a remote actor by AP ID.
  """
  def remote_changeset(mute, attrs) do
    mute
    |> cast(attrs, [:user_id, :muted_actor_ap_id])
    |> validate_required([:user_id, :muted_actor_ap_id])
    |> unique_constraint([:user_id, :muted_actor_ap_id], name: :user_mutes_remote_unique)
    |> check_constraint(:muted_actor_ap_id, name: :must_mute_something)
  end

  defp validate_not_self_mute(changeset) do
    user_id = get_field(changeset, :user_id)
    muted_id = get_field(changeset, :muted_user_id)

    if user_id && muted_id && user_id == muted_id do
      add_error(changeset, :muted_user_id, "cannot mute yourself")
    else
      changeset
    end
  end
end
