defmodule Baudrate.Federation.TimelineItemReply do
  @moduledoc """
  Schema for replies from local users to remote timeline items.

  When a user replies to a post from a followed Fediverse actor, the reply
  body (Markdown source + rendered HTML) is stored here alongside the
  generated ActivityPub ID. The corresponding `Create(Note)` activity is
  delivered to the remote actor's inbox and the replying user's AP followers.

  Replies may include up to 4 attached images (see `TimelineItemReplyImage`).
  Images are displayed in the local reply list and included as `attachment`
  entries in federated `Create(Note)` activities.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.LinkPreview
  alias Baudrate.Federation.TimelineItem
  alias Baudrate.Federation.TimelineItemReplyImage
  alias Baudrate.Setup.User

  schema "timeline_item_replies" do
    belongs_to :timeline_item, TimelineItem
    belongs_to :user, User
    belongs_to :link_preview, LinkPreview

    field :body, :string
    field :body_html, :string
    field :ap_id, :string
    # Content warning (ADR 0052) — see `Baudrate.Content.ContentWarning`.
    field :summary, :string
    field :sensitive, :boolean, default: false

    has_many :images, TimelineItemReplyImage, foreign_key: :reply_id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(body timeline_item_id user_id ap_id)a
  @optional_fields ~w(body_html)a

  @doc """
  Validates a timeline item reply changeset.

  Required: `:body`, `:timeline_item_id`, `:user_id`, `:ap_id`.
  Body max length: 10,000 characters.
  """
  def changeset(reply, attrs) do
    reply
    |> cast(
      attrs,
      @required_fields ++ @optional_fields ++ Baudrate.Content.ContentWarning.fields()
    )
    |> Baudrate.Content.ContentWarning.validate()
    |> validate_required(@required_fields)
    |> validate_length(:body, max: 10_000)
    |> foreign_key_constraint(:timeline_item_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:ap_id)
  end
end
