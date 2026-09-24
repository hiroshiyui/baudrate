defmodule Baudrate.Announcements.Announcement do
  @moduledoc """
  A notice an admin shows on every page (Phase 7B).

  It is live from `inserted_at` until `ends_at` (or for good when `ends_at`
  is nil), and an admin can end it early, which sets `ends_at` to now. Ended
  announcements are kept: they are the record of what the site told its
  readers. The body is plain text, rendered escaped.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @max_body 500

  @type t :: %__MODULE__{}

  schema "announcements" do
    field :body, :string
    field :ends_at, :utc_datetime

    belongs_to :created_by, Baudrate.Setup.User

    timestamps(type: :utc_datetime)
  end

  @doc "The longest body an announcement may have, in characters."
  def max_body, do: @max_body

  @doc """
  Changeset for a new announcement. `created_by_id` is set by
  `Baudrate.Announcements`, never cast from the form.
  """
  def create_changeset(announcement, attrs) do
    announcement
    |> cast(attrs, [:body, :ends_at])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body])
    |> validate_length(:body, max: @max_body)
  end
end
