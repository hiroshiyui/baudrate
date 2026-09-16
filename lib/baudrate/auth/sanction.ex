defmodule Baudrate.Auth.Sanction do
  @moduledoc """
  Schema for a moderation sanction short of a ban (ADR 0029).

  A sanction is a **row with an explicit end**, not a `users.status` value.
  `users.status` keeps exactly `active | pending | banned`; anything between a
  warning and a ban lives here, where it can carry an end date, an author, a
  reason and a history.

  ## Kinds

    * `warn` — a notice and an audit entry. Nothing is refused, and no
      acknowledgement is demanded. Carries no `expires_at`: there is nothing
      to expire.
    * `silence` — the account becomes read-only (see
      `Baudrate.Auth.Sanctions` for exactly what stays open). `expires_at` is
      optional; an indefinite silence is allowed.
    * `suspend` — the account cannot sign in. `expires_at` is **required**:
      an indefinite suspension is a ban, and should be recorded as one.

  ## Active

  A sanction is active when `lifted_at IS NULL AND (expires_at IS NULL OR
  expires_at > now())`. Enforcement reads that condition directly; no
  background job sets or clears a flag, so a missed run can neither hold a
  member past their time nor lift one early.

  Rows are append-only: a sanction is lifted, never deleted or rewritten.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Setup.User

  @kinds ~w(warn silence suspend)
  # `warn` restricts nothing, so it is not in the gate's lookup.
  @restricting_kinds ~w(silence suspend)

  @type t :: %__MODULE__{}

  schema "sanctions" do
    field :kind, :string
    field :reason, :string
    field :issued_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :lifted_at, :utc_datetime
    field :lift_reason, :string
    # When the member was told the sanction ran out. Enforcement never reads
    # it: a sanction ends by the clock whether or not the notice was sent.
    field :ended_notified_at, :utc_datetime

    belongs_to :user, User
    belongs_to :issued_by, User
    belongs_to :lifted_by, User
    belongs_to :report, Baudrate.Moderation.Report

    timestamps(type: :utc_datetime)
  end

  @doc "Returns the valid sanction kinds."
  def kinds, do: @kinds

  @doc "Returns the kinds that restrict what an account may do."
  def restricting_kinds, do: @restricting_kinds

  @doc """
  Changeset for issuing a sanction.

  `issued_at` defaults to now. `expires_at` is required for `suspend`,
  forced to `nil` for `warn`, and must be in the future when given — a
  sanction that has already ended is not a sanction.
  """
  def issue_changeset(sanction, attrs) do
    sanction
    |> cast(attrs, [:user_id, :kind, :reason, :issued_by_id, :issued_at, :expires_at, :report_id])
    |> put_default_issued_at()
    |> validate_required([:user_id, :kind, :issued_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:reason, max: 1000)
    |> clear_expiry_for_warning()
    |> require_expiry_for_suspension()
    |> validate_expiry_in_future()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:issued_by_id)
    |> foreign_key_constraint(:report_id)
  end

  @doc """
  Changeset for lifting a sanction early. The issue fields are never
  rewritten — only who lifted it, when, and why.
  """
  def lift_changeset(sanction, attrs) do
    sanction
    |> cast(attrs, [:lifted_at, :lifted_by_id, :lift_reason])
    |> validate_required([:lifted_at])
    |> validate_length(:lift_reason, max: 1000)
    |> foreign_key_constraint(:lifted_by_id)
  end

  defp put_default_issued_at(changeset) do
    case get_field(changeset, :issued_at) do
      nil -> put_change(changeset, :issued_at, DateTime.utc_now() |> DateTime.truncate(:second))
      _ -> changeset
    end
  end

  defp clear_expiry_for_warning(changeset) do
    if get_field(changeset, :kind) == "warn" do
      put_change(changeset, :expires_at, nil)
    else
      changeset
    end
  end

  defp require_expiry_for_suspension(changeset) do
    if get_field(changeset, :kind) == "suspend" do
      validate_required(changeset, [:expires_at])
    else
      changeset
    end
  end

  defp validate_expiry_in_future(changeset) do
    issued_at = get_field(changeset, :issued_at)
    expires_at = get_field(changeset, :expires_at)

    if issued_at && expires_at && DateTime.compare(expires_at, issued_at) != :gt do
      add_error(changeset, :expires_at, "must be after the sanction is issued")
    else
      changeset
    end
  end
end
