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
      assert actions == Enum.uniq(actions)
    end
  end

  describe "call sites" do
    # An action name missing from `@valid_actions` makes the insert fail, and
    # callers ignore the result, so the entry silently disappears. Walk every
    # `log_action/2,3` call in lib/ and check each literal action name,
    # including both branches of `if(..., do: "a", else: "b")`.
    test "every action name passed to Moderation.log_action is valid" do
      used = Enum.flat_map(Path.wildcard("lib/**/*.ex"), &action_names/1)

      assert length(used) > 20, "expected to find the log_action call sites"
      assert Enum.uniq(used) -- Log.valid_actions() == []
    end
  end

  defp action_names(path) do
    {_ast, names} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {{:., _, [_module, :log_action]}, _, [_actor, action | _]} = node, acc ->
          {node, acc ++ string_literals(action)}

        node, acc ->
          {node, acc}
      end)

    names
  end

  defp string_literals(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        literal, acc when is_binary(literal) -> {literal, [literal | acc]}
        node, acc -> {node, acc}
      end)

    found
  end
end
