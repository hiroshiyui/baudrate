defmodule Baudrate.Moderation.HeldPost do
  @moduledoc """
  An article or comment waiting for a moderator (Phase 5C, ADR 0065).

  **A held post is a submission, not content.** It is not an article or a
  comment with a flag on it: nothing chokepoints the listings, so a flag would
  have to be excluded by hand from board lists, search and `/ap/search`, tag
  pages, the feeds, the sitemap, the outbox, user pages, bookmarks, the
  timeline and the unread badges — the shape that leaked twice, and left the
  `remote_visibility` and `blocked_domain_hiding` gates behind it. A row here
  has no `ap_id` and no slug, and no listing reads this table.

  It holds what the composer sent, and approval replays creation as the author
  (`Baudrate.Moderation.HeldPosts.approve/2`), so publication — the `ap_id`,
  federation, mentions, notifications, the link preview — happens when a
  moderator approves, which is when it publishes. The approved row is deleted
  in the same transaction as the article or comment is created.

  A rejected row is kept as the record of what was refused, like a report's
  `evidence_body`, and `Baudrate.Retention` removes it 90 days after review.

    * `kind` — `article` or `comment`.
    * `board_ids`, `image_ids` — as the composer sent them. Boards are checked
      again at approval; images are only ever the author's own uploads.
    * `poll` — `mode`, `options` and `open_for` (seconds, or `nil`), so a poll
      held overnight is open for as long as it was meant to be from the
      moment it appears.
    * `reason` — `first_posts` (the `hold_first_posts` setting) or `filter`.
    * `status` — `pending` or `rejected`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Content.{Article, Comment, ContentWarning}
  alias Baudrate.Moderation.ContentFilter
  alias Baudrate.Setup.User

  # The article and comment ceilings, so a submission that could be held
  # could also have been published.
  @max_body_length 65_536
  @max_title_length 255

  schema "held_posts" do
    field :kind, :string
    field :title, :string
    field :body, :string
    field :summary, :string
    field :sensitive, :boolean, default: false
    field :visibility, :string, default: "public"
    field :forwardable, :boolean, default: true
    field :board_ids, {:array, :integer}, default: []
    field :image_ids, {:array, :integer}, default: []
    field :poll, :map
    field :reason, :string
    field :status, :string, default: "pending"
    field :reviewed_at, :utc_datetime
    field :review_note, :string

    belongs_to :user, User
    belongs_to :article, Article
    belongs_to :parent, Comment
    belongs_to :content_filter, ContentFilter
    belongs_to :reviewed_by, User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc """
  Changeset for holding a submission.

  `user_id`, `status`, `reason` and `content_filter_id` are not castable:
  `Baudrate.Moderation.HeldPosts` sets them. A member who could set `status`
  would approve their own post.
  """
  def changeset(held, attrs) do
    held
    |> cast(
      attrs,
      [
        :kind,
        :title,
        :body,
        :visibility,
        :forwardable,
        :board_ids,
        :image_ids,
        :poll,
        :article_id,
        :parent_id
      ] ++ ContentWarning.fields()
    )
    |> ContentWarning.validate()
    |> validate_required([:kind, :body])
    |> validate_inclusion(:kind, ~w(article comment))
    |> validate_length(:title, max: @max_title_length)
    |> validate_length(:body, max: @max_body_length)
    |> validate_inclusion(:visibility, ~w(public unlisted))
    |> validate_poll()
    |> validate_kind()
    |> foreign_key_constraint(:article_id)
    |> foreign_key_constraint(:parent_id)
    |> foreign_key_constraint(:user_id)
  end

  # The bounds a published poll is held to (`Poll`, `PollOption`), applied
  # when the submission is held rather than only when it is approved: the
  # poll is kept as a map, and without this a crafted submission could store
  # any number of options of any length in a row nobody has reviewed yet.
  @max_poll_options 4
  @max_option_length 200
  @max_open_for 30 * 86_400

  defp validate_poll(changeset) do
    validate_change(changeset, :poll, fn :poll, poll ->
      if valid_poll?(poll), do: [], else: [poll: "is not a poll this site accepts"]
    end)
  end

  defp valid_poll?(%{"mode" => mode, "options" => options} = poll)
       when mode in ["single", "multiple"] and is_list(options) do
    length(options) in 2..@max_poll_options and
      Enum.all?(options, &(is_binary(&1) and String.length(&1) <= @max_option_length)) and
      valid_open_for?(poll["open_for"]) and
      map_size(poll) <= 3
  end

  defp valid_poll?(_), do: false

  defp valid_open_for?(nil), do: true

  defp valid_open_for?(seconds) when is_integer(seconds),
    do: seconds > 0 and seconds <= @max_open_for

  defp valid_open_for?(_), do: false

  defp validate_kind(changeset) do
    case get_field(changeset, :kind) do
      "article" -> validate_required(changeset, [:title])
      "comment" -> validate_required(changeset, [:article_id])
      _ -> changeset
    end
  end

  @doc "Changeset for a moderator's rejection."
  def reject_changeset(held, attrs) do
    held
    |> cast(attrs, [:review_note])
    |> validate_length(:review_note, max: 1000)
  end
end
