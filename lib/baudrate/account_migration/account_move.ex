defmodule Baudrate.AccountMigration.AccountMove do
  @moduledoc """
  A user's request to move their account to another server (ADR 0025).

  ## Lifecycle

      pending ──(send_after = requested_at + 24 h, sweep)──▶ sent
         │                                    │
         │                                    └──(re-check fails)──▶ failed
         └──── cancel / auto-cancel ────▶ cancelled

  Transitions are driven by `Baudrate.AccountMigration`, never by changesets
  from user input. Rows are an immutable history.

  ## Fields

    * `target_ap_id` — actor id of the destination account
    * `status` — `pending`, `sent`, `cancelled` or `failed`
    * `requested_at`, `send_after`, `sent_at`
    * `cancelled_at`, `cancel_reason` — `user`, `password_changed`,
      `totp_changed`, `banned` or `signed_out_everywhere`
    * `failure_reason` — why the send-time re-check refused it
    * `requested_session_id` — the session that requested it (nilified when
      that session ends)
    * `requested_user_agent_family` — coarse browser family for the banner.
      No IP address or full user agent is stored.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending sent cancelled failed)
  @cancel_reasons ~w(user password_changed totp_changed banned suspended signed_out_everywhere account_reset account_deleted)

  schema "account_moves" do
    field :target_ap_id, :string
    field :status, :string, default: "pending"
    field :requested_at, :utc_datetime
    field :send_after, :utc_datetime
    field :sent_at, :utc_datetime
    field :cancelled_at, :utc_datetime
    field :cancel_reason, :string
    field :failure_reason, :string
    field :requested_user_agent_family, :string

    belongs_to :user, Baudrate.Setup.User
    belongs_to :requested_session, Baudrate.Auth.UserSession

    timestamps(type: :utc_datetime)
  end

  @doc "All status values."
  def statuses, do: @statuses

  @doc "Valid cancellation reasons."
  def cancel_reasons, do: @cancel_reasons

  @doc """
  Changeset for inserting a pending move. All fields are set by
  `Baudrate.AccountMigration`, never cast from user input.
  """
  def create_changeset(move, attrs) do
    move
    |> cast(attrs, [
      :user_id,
      :target_ap_id,
      :status,
      :requested_at,
      :send_after,
      :requested_session_id,
      :requested_user_agent_family
    ])
    |> validate_required([:user_id, :target_ap_id, :status, :requested_at, :send_after])
    |> validate_inclusion(:status, @statuses)
    |> validate_format(:target_ap_id, ~r{\Ahttps://})
    |> validate_length(:target_ap_id, max: 2048)
    |> validate_length(:requested_user_agent_family, max: 100)
    |> check_constraint(:status, name: :account_moves_status_check)
    |> unique_constraint(:user_id, name: :account_moves_one_pending_per_user_index)
  end
end
