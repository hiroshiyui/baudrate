defmodule Baudrate.Moderation.Log do
  @moduledoc """
  Schema for moderation log entries.

  Each entry records a moderation action taken by an admin or moderator,
  with optional polymorphic target (user, article, comment, board, report)
  and a JSONB details map for context.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Setup.User

  @valid_actions ~w(ban_user unban_user update_role approve_user resolve_report dismiss_report delete_article delete_comment create_board update_board delete_board block_user unblock_user block_domain unblock_domain rotate_keys)

  schema "moderation_logs" do
    field :action, :string
    field :target_type, :string
    field :target_id, :integer
    field :details, :map, default: %{}

    belongs_to :actor, User

    timestamps(updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:action, :actor_id, :target_type, :target_id, :details])
    |> validate_required([:action, :actor_id])
    |> validate_inclusion(:action, @valid_actions)
  end

  def valid_actions, do: @valid_actions
end
