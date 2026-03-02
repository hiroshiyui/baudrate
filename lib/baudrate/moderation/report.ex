defmodule Baudrate.Moderation.Report do
  @moduledoc """
  Schema for content reports.

  A report targets at least one of: article, comment, remote actor, or
  local user. It transitions through statuses: open → resolved or dismissed.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "reports" do
    field :reason, :string
    field :status, :string, default: "open"
    field :resolved_at, :utc_datetime
    field :resolution_note, :string

    belongs_to :reporter, Baudrate.Setup.User
    belongs_to :article, Baudrate.Content.Article
    belongs_to :comment, Baudrate.Content.Comment
    belongs_to :remote_actor, Baudrate.Federation.RemoteActor
    belongs_to :reported_user, Baudrate.Setup.User
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
      :resolved_by_id,
      :resolved_at,
      :resolution_note
    ])
    |> validate_required([:reason])
    |> validate_length(:reason, min: 1, max: 2000)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_has_target()
    |> foreign_key_constraint(:reporter_id)
    |> foreign_key_constraint(:article_id)
    |> foreign_key_constraint(:comment_id)
    |> foreign_key_constraint(:remote_actor_id)
    |> foreign_key_constraint(:reported_user_id)
    |> foreign_key_constraint(:resolved_by_id)
  end

  defp validate_has_target(changeset) do
    article_id = get_field(changeset, :article_id)
    comment_id = get_field(changeset, :comment_id)
    remote_actor_id = get_field(changeset, :remote_actor_id)
    reported_user_id = get_field(changeset, :reported_user_id)

    if is_nil(article_id) and is_nil(comment_id) and is_nil(remote_actor_id) and
         is_nil(reported_user_id) do
      add_error(
        changeset,
        :base,
        "must target at least one of: article, comment, remote actor, or user"
      )
    else
      changeset
    end
  end
end
