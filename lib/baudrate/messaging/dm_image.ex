defmodule Baudrate.Messaging.DmImage do
  @moduledoc """
  An image attached to a direct message (ADR 0071).

  A private file: it lives in `uploads/dm_images`, is served only through
  `/messages/images/:id` after a participant check, and its `filename` never
  leaves the server. `message_id` is empty until the message is sent — the
  composer uploads first, so a description can be saved against the row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.ImageAlt

  @max_per_message 4

  schema "dm_images" do
    field :filename, :string
    field :width, :integer
    field :height, :integer
    field :alt, :string

    belongs_to :user, Baudrate.Setup.User
    belongs_to :message, Baudrate.Messaging.DirectMessage

    timestamps(type: :utc_datetime)
  end

  @doc "The most images one message may carry."
  def max_per_message, do: @max_per_message

  @doc "Changeset for a freshly processed upload. Never casts `message_id`."
  def changeset(image, attrs) do
    image
    |> cast(attrs, [:filename, :width, :height, :user_id])
    |> validate_required([:filename, :width, :height, :user_id])
    |> validate_format(:filename, ~r/\A[0-9a-f]{64}\.webp\z/)
    |> unique_constraint(:filename)
    |> foreign_key_constraint(:user_id)
  end

  @doc "Changeset for the image's description (ADR 0061's rule)."
  def alt_changeset(image, attrs) do
    image
    |> cast(attrs, ImageAlt.fields())
    |> ImageAlt.validate()
  end
end
