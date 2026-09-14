defmodule Baudrate.Moderation.Report do
  @moduledoc """
  Schema for content reports.

  A report targets at least one of: article, comment, remote actor, or
  local user. It transitions through statuses: open → resolved or dismissed.

  ## Who reported, and what

    * `reporter_id` — a local user (reports made on this site)
    * `reporter_remote_actor_id` — the remote actor that sent an inbound
      `Flag`
    * `remote_actor_id` — the **reported** remote actor. Moderators can send
      it a `Flag` ("Send Flag"). Never the reporter.
    * `article_id`, `comment_id`, `reported_user_id` — reported local records
    * `feed_item_id` — a reported feed item (its author is `remote_actor_id`)
    * `message_id` and `message_body` — a reported direct message and a copy
      of its text taken when the report was made. Only that one message is
      copied, never the rest of the conversation. The sender is
      `reported_user_id` or `remote_actor_id`. `message_body` is never cast
      from attributes; only `Moderation.report_message/3` sets it, from the
      stored message.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "reports" do
    field :reason, :string
    field :status, :string, default: "open"
    field :resolved_at, :utc_datetime
    field :resolution_note, :string
    field :message_body, :string

    belongs_to :reporter, Baudrate.Setup.User
    belongs_to :reporter_remote_actor, Baudrate.Federation.RemoteActor
    belongs_to :article, Baudrate.Content.Article
    belongs_to :comment, Baudrate.Content.Comment
    belongs_to :remote_actor, Baudrate.Federation.RemoteActor
    belongs_to :reported_user, Baudrate.Setup.User
    belongs_to :feed_item, Baudrate.Federation.FeedItem
    belongs_to :message, Baudrate.Messaging.DirectMessage
    belongs_to :resolved_by, Baudrate.Setup.User

    timestamps(type: :utc_datetime)
  end

  @valid_statuses ~w(open resolved dismissed)

  @doc "Casts and validates fields for creating or updating a report."
  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :reason,
      :status,
      :reporter_id,
      :article_id,
      :comment_id,
      :remote_actor_id,
      :reported_user_id,
      :feed_item_id,
      :message_id,
      :resolved_by_id,
      :resolved_at,
      :resolution_note
    ])
    |> validate_required([:reason])
    |> validate_length(:reason, min: 1, max: 2000)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_has_target()
    |> foreign_key_constraints()
  end

  @doc """
  Changeset for a report received as an inbound `Flag`.

  The comment is optional (Mastodon may send none), so an empty `reason` is
  kept rather than refused. The reporter is a remote actor, and the targets
  must be local records.
  """
  def remote_flag_changeset(report, attrs) do
    report
    |> cast(
      attrs,
      [:reason, :reporter_remote_actor_id, :article_id, :comment_id, :reported_user_id],
      empty_values: [nil]
    )
    |> validate_required([:reason, :reporter_remote_actor_id])
    |> validate_length(:reason, max: 2000)
    |> validate_has_target()
    |> foreign_key_constraints()
  end

  defp foreign_key_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:reporter_id)
    |> foreign_key_constraint(:reporter_remote_actor_id)
    |> foreign_key_constraint(:article_id)
    |> foreign_key_constraint(:comment_id)
    |> foreign_key_constraint(:remote_actor_id)
    |> foreign_key_constraint(:reported_user_id)
    |> foreign_key_constraint(:feed_item_id)
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:resolved_by_id)
  end

  @target_fields ~w(article_id comment_id remote_actor_id reported_user_id feed_item_id message_id)a

  defp validate_has_target(changeset) do
    if Enum.all?(@target_fields, &is_nil(get_field(changeset, &1))) do
      add_error(
        changeset,
        :base,
        "must target at least one of: article, comment, remote actor, user, feed item, or message"
      )
    else
      changeset
    end
  end
end
