defmodule Baudrate.AccountDeletion.Deletion do
  @moduledoc """
  A member's request to delete their own account (ADR 0072).

  ## Lifecycle

      pending ──(execute_after = requested_at + 7 days, sweep claims it)──▶ executing ──▶ completed
         │
         └── signing in, or a staff role gained meanwhile ──▶ cancelled

  `executing` is a state of its own so a sweep that crashes part-way leaves a
  row the next sweep resumes: every step of the execution queries only what
  is still live, and `completed` is written in the same transaction as the
  tombstone. Transitions are driven by `Baudrate.AccountDeletion`, never by
  changesets from user input.

  ## Fields

    * `withdraw_content` — withdraw the member's articles and comments too,
      instead of keeping them under "deleted account"
    * `requested_at`, `execute_after`, `claimed_at`, `completed_at`
    * `cancelled_at`, `cancel_reason` — `signed_in` or `staff`
    * `requested_user_agent_family` — coarse browser family for the notice.
      No IP address or full user agent is stored.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @statuses ~w(pending executing completed cancelled)
  @cancel_reasons ~w(signed_in staff)

  schema "account_deletions" do
    field :status, :string, default: "pending"
    field :withdraw_content, :boolean, default: false
    field :requested_at, :utc_datetime
    field :execute_after, :utc_datetime
    field :claimed_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :cancelled_at, :utc_datetime
    field :cancel_reason, :string
    field :requested_user_agent_family, :string

    belongs_to :user, Baudrate.Setup.User

    timestamps(type: :utc_datetime)
  end

  @doc "All status values."
  def statuses, do: @statuses

  @doc "Valid cancellation reasons."
  def cancel_reasons, do: @cancel_reasons

  @doc """
  Changeset for inserting a pending deletion. Every field is set by
  `Baudrate.AccountDeletion`, never cast from user input.
  """
  def create_changeset(deletion, attrs) do
    deletion
    |> cast(attrs, [
      :user_id,
      :status,
      :withdraw_content,
      :requested_at,
      :execute_after,
      :requested_user_agent_family
    ])
    |> validate_required([:user_id, :status, :requested_at, :execute_after])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:requested_user_agent_family, max: 100)
    |> check_constraint(:status, name: :account_deletions_status_check)
    |> unique_constraint(:user_id, name: :account_deletions_one_open_per_user_index)
  end
end
