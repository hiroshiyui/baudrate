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

  # Every action name passed to `Baudrate.Moderation.log_action/3` must be
  # listed here, or the insert fails. `test/baudrate/moderation/log_test.exs`
  # checks every call site.
  @valid_actions ~w(
    ban_user unban_user update_role approve_user
    warn_user silence_user suspend_user lift_sanction reject_user
    resolve_report dismiss_report send_flag
    delete_article delete_comment edit_article remove_article_from_board
    pin_article unpin_article lock_article unlock_article
    create_board update_board delete_board toggle_board_federation update_board_accept_policy
    add_board_moderator remove_board_moderator
    verify_recovery_contact unverify_recovery_contact issue_recovery_challenge
    issue_account_reset revoke_account_reset clear_second_factors
    block_user unblock_user block_domain unblock_domain rotate_keys
    ban_ip unban_ip ban_invite_chain
    suspend_remote_actor unsuspend_remote_actor
    update_settings update_eua update_privacy publish_terms_version generate_vapid_keys
    create_rule update_rule retire_rule restore_rule reorder_rules
    create_bot update_bot delete_bot toggle_bot reset_bot_errors refresh_bot_favicon
    approve_held_post reject_held_post create_filter update_filter delete_filter
    abandon_deliveries close_delivery_circuit
  )

  schema "moderation_logs" do
    field :action, :string
    field :target_type, :string
    field :target_id, :integer
    field :details, :map, default: %{}

    belongs_to :actor, User

    timestamps(updated_at: false)
  end

  @doc "Casts and validates fields for creating a moderation log entry."
  def changeset(log, attrs) do
    log
    |> cast(attrs, [:action, :actor_id, :target_type, :target_id, :details])
    |> validate_required([:action, :actor_id])
    |> validate_inclusion(:action, @valid_actions)
  end

  @doc "Returns the list of valid moderation action strings."
  def valid_actions, do: @valid_actions
end
