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
    * `timeline_item_id` — a reported timeline item (its author is `remote_actor_id`)
    * `evidence_body` and `evidence_taken_at` — a copy of the reported article
      or comment, taken when a moderator removed it, so the report still
      explains itself afterwards. Purged 90 days after the report was closed
      (P1-D6); never cast from attributes.
    * `message_id` and `message_body` — a reported direct message and a copy
      of its text taken when the report was made. Only that one message is
      copied, never the rest of the conversation. The sender is
      `reported_user_id` or `remote_actor_id`. `message_body` is never cast
      from attributes; only `Moderation.report_message/3` sets it, from the
      stored message.
    * `content_filter_id` — set when a content filter opened the report rather
      than a person (ADR 0065). `reason` then holds the filter's pattern as it
      stood, so the report still reads if the filter is edited or deleted.
      Never cast from attributes; only `ContentFilters.flag/3` sets it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "reports" do
    field :reason, :string
    field :category, :string
    field :status, :string, default: "open"
    field :resolved_at, :utc_datetime
    field :resolution_note, :string
    field :message_body, :string
    # A copy of removed content, kept for staff for 90 days (P1-D6). Like
    # `message_body`, set by the context and never cast from attributes.
    field :evidence_body, :string
    field :evidence_taken_at, :utc_datetime

    belongs_to :reporter, Baudrate.Setup.User
    belongs_to :reporter_remote_actor, Baudrate.Federation.RemoteActor
    belongs_to :article, Baudrate.Content.Article
    belongs_to :comment, Baudrate.Content.Comment
    belongs_to :remote_actor, Baudrate.Federation.RemoteActor
    belongs_to :reported_user, Baudrate.Setup.User
    belongs_to :timeline_item, Baudrate.Federation.TimelineItem
    belongs_to :message, Baudrate.Messaging.DirectMessage
    belongs_to :resolved_by, Baudrate.Setup.User
    # Which rule the reporter says was broken (P1-D9). Optional even when the
    # category is "rule_violation": a reporter who cannot find the right number
    # must still be able to report, and rules are retired rather than deleted
    # so an old citation keeps resolving.
    belongs_to :rule, Baudrate.Setup.Rule
    # A report a content filter opened, not a person (ADR 0065).
    belongs_to :content_filter, Baudrate.Moderation.ContentFilter

    timestamps(type: :utc_datetime)
  end

  @valid_statuses ~w(open resolved dismissed)
  # P1-D9. "rule_violation" may carry a `rule_id` naming which rule; inbound
  # federated Flags carry no category at all, so it stays optional for them and
  # for reports made before this field existed.
  @valid_categories ~w(spam harassment illegal rule_violation other)

  @doc "Casts and validates fields for creating or updating a report."
  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :reason,
      :category,
      :status,
      :reporter_id,
      :article_id,
      :comment_id,
      :remote_actor_id,
      :reported_user_id,
      :timeline_item_id,
      :message_id,
      :resolved_by_id,
      :resolved_at,
      :resolution_note,
      :rule_id
    ])
    |> validate_required([:reason])
    |> validate_length(:reason, min: 1, max: 2000)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:category, @valid_categories)
    |> validate_local_category()
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

  @doc "The reason categories a member picks from (P1-D9)."
  def categories, do: @valid_categories

  # A report made on this site always has a category; one that arrived as a
  # federated Flag has whatever the remote instance sent, which is nothing.
  defp validate_local_category(changeset) do
    if get_field(changeset, :reporter_id),
      do: validate_required(changeset, [:category]),
      else: changeset
  end

  defp foreign_key_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:reporter_id)
    |> foreign_key_constraint(:reporter_remote_actor_id)
    |> foreign_key_constraint(:article_id)
    |> foreign_key_constraint(:comment_id)
    |> foreign_key_constraint(:remote_actor_id)
    |> foreign_key_constraint(:reported_user_id)
    |> foreign_key_constraint(:timeline_item_id)
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:resolved_by_id)
    |> foreign_key_constraint(:rule_id)
  end

  @target_fields ~w(article_id comment_id remote_actor_id reported_user_id timeline_item_id message_id)a

  defp validate_has_target(changeset) do
    if Enum.all?(@target_fields, &is_nil(get_field(changeset, &1))) do
      add_error(
        changeset,
        :base,
        "must target at least one of: article, comment, remote actor, user, timeline item, or message"
      )
    else
      changeset
    end
  end
end
