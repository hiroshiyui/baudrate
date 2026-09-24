defmodule Baudrate.DataPortability.ExportRequest do
  @moduledoc """
  A user's request to download their data (ADR 0023).

  The row is a **request record, not an archive**: the archive is built at
  download time and deleted right after it is sent. Rows are an immutable
  history. Users can cancel a request but never delete one.

  ## Lifecycle

      pending ──(ready_at = requested_at + 24 h)──▶ ready ──(3rd download)──▶ completed
         │                                           │
         └──────────── cancel / auto-cancel ─────────┴──(expires_at = ready_at + 48 h)──▶ expired

  Transitions are driven by `Baudrate.DataPortability`, never by
  changesets from user input.

  ## Fields

    * `status` — `pending`, `ready`, `completed`, `cancelled`, or `expired`
    * `source` — `self_service` (web) or `sysop` (audited release task)
    * `requested_at`, `ready_at`, `expires_at`
    * `download_count` — 0..3
    * `requested_session_id` — the session that requested it (nilified when
      that session ends)
    * `requested_user_agent_family` — coarse browser/OS family for the banner.
      No IP address or full user agent is stored.
    * `operator` — OS user who ran a SysOp export
    * `cancelled_at`, `cancel_reason` — `user`, `password_changed`,
      `totp_changed`, `banned`, or `signed_out_everywhere`
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @statuses ~w(pending ready completed cancelled expired)
  @active_statuses ~w(pending ready)
  @sources ~w(self_service sysop)
  @cancel_reasons ~w(user password_changed totp_changed banned suspended signed_out_everywhere account_reset account_deleted)

  schema "export_requests" do
    field :status, :string, default: "pending"
    field :source, :string, default: "self_service"
    field :requested_at, :utc_datetime
    field :ready_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :download_count, :integer, default: 0
    field :requested_user_agent_family, :string
    field :operator, :string
    field :cancelled_at, :utc_datetime
    field :cancel_reason, :string

    belongs_to :user, Baudrate.Setup.User
    belongs_to :requested_session, Baudrate.Auth.UserSession

    timestamps(type: :utc_datetime)
  end

  @doc "All status values."
  def statuses, do: @statuses

  @doc "Statuses of a request that has not finished (at most one per user)."
  def active_statuses, do: @active_statuses

  @doc "Valid cancellation reasons."
  def cancel_reasons, do: @cancel_reasons

  @doc """
  Changeset for inserting a request. All fields are set by
  `Baudrate.DataPortability`, never cast from user input.
  """
  def create_changeset(request, attrs) do
    request
    |> cast(attrs, [
      :user_id,
      :status,
      :source,
      :requested_at,
      :ready_at,
      :expires_at,
      :download_count,
      :requested_session_id,
      :requested_user_agent_family,
      :operator
    ])
    |> validate_required([:user_id, :status, :source, :requested_at, :ready_at, :expires_at])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_number(:download_count, greater_than_or_equal_to: 0, less_than_or_equal_to: 3)
    |> validate_length(:requested_user_agent_family, max: 100)
    |> validate_length(:operator, max: 100)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id,
      name: :export_requests_one_active_per_user_index,
      message: "already has an active export request"
    )
    |> check_constraint(:status, name: :export_requests_status_check)
  end
end
