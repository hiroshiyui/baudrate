defmodule Baudrate.Moderation.LogTest do
  use Baudrate.DataCase

  alias Baudrate.Moderation.Log

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = Log.changeset(%Log{}, %{action: "ban_user", actor_id: 1})
      assert changeset.valid?
    end

    test "invalid without action" do
      changeset = Log.changeset(%Log{}, %{actor_id: 1})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).action
    end

    test "invalid without actor_id" do
      changeset = Log.changeset(%Log{}, %{action: "ban_user"})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).actor_id
    end

    test "invalid with unknown action" do
      changeset = Log.changeset(%Log{}, %{action: "invalid_action", actor_id: 1})
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).action
    end

    test "accepts optional fields" do
      changeset =
        Log.changeset(%Log{}, %{
          action: "ban_user",
          actor_id: 1,
          target_type: "user",
          target_id: 42,
          details: %{"reason" => "spam"}
        })

      assert changeset.valid?
    end

    test "valid_actions returns all valid actions" do
      actions = Log.valid_actions()
      assert "ban_user" in actions
      assert "create_board" in actions
      assert length(actions) == 11
    end
  end
end
