defmodule Baudrate.Notification.PushSubscription do
  @moduledoc """
  Schema for Web Push subscription records.

  Each subscription represents a browser endpoint that can receive push
  notifications. The `p256dh` and `auth` fields are the client's ECDH public
  key and authentication secret, used for RFC 8291 content encryption.

  Subscriptions are scoped to a user and uniquely identified by their
  `endpoint` URL (provided by the push service).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "push_subscriptions" do
    field :endpoint, :string
    field :p256dh, :binary
    field :auth, :binary
    field :user_agent, :string

    belongs_to :user, Baudrate.Setup.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for a push subscription.
  """
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:endpoint, :p256dh, :auth, :user_agent, :user_id])
    |> validate_required([:endpoint, :p256dh, :auth, :user_id])
    |> validate_length(:endpoint, max: 2048)
    |> unique_constraint(:endpoint)
    |> foreign_key_constraint(:user_id)
  end
end
