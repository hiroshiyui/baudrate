defmodule Baudrate.Moderation.ContentFilterMatch do
  @moduledoc """
  One time a content filter matched (ADR 0065).

  Every match is recorded, whatever was done about it, because that is what
  makes a filter that catches the wrong thing findable: `/admin/filters` shows
  each filter's recent count, and a filter blocking a hundred posts a day from
  long-standing members is a filter somebody should read again.

  Who, where and what was done — **never the text**. A blocked post was never
  published, and this table is not where it gets kept. A held post keeps its
  own text in `held_posts`, and a flagged one is the published content the
  report points at.

    * `action` — what happened to the post: `block`, `hold`, `flag`, or `drop`
      for remote content that was not stored.
    * `target_type` — `article`, `comment`, `timeline_reply` or `remote`.
    * `edit` — whether it was an edit rather than a new post.

  Purged after 90 days by `Baudrate.Retention`.
  """

  use Ecto.Schema

  schema "content_filter_matches" do
    field :action, :string
    field :target_type, :string
    field :edit, :boolean, default: false

    belongs_to :content_filter, Baudrate.Moderation.ContentFilter
    belongs_to :user, Baudrate.Setup.User
    belongs_to :remote_actor, Baudrate.Federation.RemoteActor

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
