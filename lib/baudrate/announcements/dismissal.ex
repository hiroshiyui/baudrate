defmodule Baudrate.Announcements.Dismissal do
  @moduledoc """
  A member having dismissed an announcement, so it stays dismissed on every
  device they use. Guests dismiss in their own browser instead.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "announcement_dismissals" do
    belongs_to :announcement, Baudrate.Announcements.Announcement
    belongs_to :user, Baudrate.Setup.User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
