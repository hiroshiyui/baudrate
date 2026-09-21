defmodule Baudrate.Content.ArticleDraft do
  @moduledoc """
  Schema for an unfinished article, kept on the server.

  The composer already autosaved to `localStorage`, and that hook stays — it
  is what survives losing the network, and it is the only half that works at
  all when the socket is down. What it cannot do is follow a member to another
  device, because `localStorage` is scoped to one browser on one machine: a
  post started on a phone was simply not there on a laptop.

  ## It holds the whole composer, not two fields

  The hook can only reach inputs with a `name` attribute, so it saved the
  title and the body and nothing else. A draft row carries the content warning,
  the visibility, the forwardable flag, the selected boards, the uploaded
  images and the poll — so resuming restores what was actually being written
  rather than a fragment of it that then has to be rebuilt by hand.

  `board_ids` and `image_ids` are plain integer arrays rather than join
  tables. A draft is one member's private scratch state, never queried by
  board or by image, and a join table would need a cascade and a purge of its
  own. They are **validated at resume, not at save**: a board can be deleted,
  or the member's right to post in it withdrawn, between the two.

  ## What it is not

  A draft is not content. It has no `ap_id`, it is in no listing, it federates
  nowhere, and only its owner can read it — every read is scoped by `user_id`
  in `Baudrate.Content.Drafts`. Publishing is what turns one into an article,
  and the draft is deleted in the same breath.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.ContentWarning
  alias Baudrate.Setup.User

  # The same ceiling as `Article` and as inbound federation. A draft that
  # could hold more than an article can would refuse to publish at the end,
  # which is the worst moment to find out.
  @max_body_length 65_536
  @max_title_length 255

  schema "article_drafts" do
    field :title, :string
    field :body, :string
    field :summary, :string
    field :sensitive, :boolean, default: false
    field :visibility, :string
    field :forwardable, :boolean, default: true

    field :board_ids, {:array, :integer}, default: []
    field :image_ids, {:array, :integer}, default: []

    field :poll_enabled, :boolean, default: false
    field :poll_options, {:array, :string}, default: []
    field :poll_mode, :string
    field :poll_expires, :string

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @castable [
    :title,
    :body,
    :visibility,
    :forwardable,
    :board_ids,
    :image_ids,
    :poll_enabled,
    :poll_options,
    :poll_mode,
    :poll_expires
  ]

  @doc """
  Changeset for creating or updating a draft.

  `user_id` is deliberately not castable: it is set by
  `Baudrate.Content.Drafts` from the session's own user, never from params.
  Casting it would make one member's autosave able to name another member as
  the owner of what they are typing.
  """
  def changeset(draft, attrs) do
    draft
    |> cast(attrs, @castable ++ ContentWarning.fields())
    |> ContentWarning.validate()
    |> validate_length(:title, max: @max_title_length)
    |> validate_length(:body, max: @max_body_length)
    |> validate_inclusion(:visibility, ~w(public unlisted), message: "must be public or unlisted")
    |> validate_poll_options()
    |> foreign_key_constraint(:user_id)
  end

  # A poll option is bounded for the same reason the body is: a draft that
  # accepts more than the composer will submit fails at publication instead of
  # at the keystroke.
  defp validate_poll_options(changeset) do
    validate_change(changeset, :poll_options, fn :poll_options, options ->
      cond do
        length(options) > 20 -> [poll_options: "has too many options"]
        Enum.any?(options, &(String.length(&1) > 255)) -> [poll_options: "option is too long"]
        true -> []
      end
    end)
  end

  @doc "The longest body a draft may hold, matching `Article`."
  def max_body_length, do: @max_body_length

  @doc "The longest title a draft may hold, matching `Article`."
  def max_title_length, do: @max_title_length
end
