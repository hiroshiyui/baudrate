defmodule BaudrateWeb.HelpersTest do
  use ExUnit.Case, async: true

  alias BaudrateWeb.Helpers

  describe "parse_id/1" do
    test "parses valid positive integer strings" do
      assert {:ok, 1} = Helpers.parse_id("1")
      assert {:ok, 42} = Helpers.parse_id("42")
      assert {:ok, 999_999} = Helpers.parse_id("999999")
    end

    test "rejects zero" do
      assert :error = Helpers.parse_id("0")
    end

    test "rejects negative numbers" do
      assert :error = Helpers.parse_id("-1")
      assert :error = Helpers.parse_id("-100")
    end

    test "rejects non-numeric strings" do
      assert :error = Helpers.parse_id("abc")
      assert :error = Helpers.parse_id("")
      assert :error = Helpers.parse_id("12abc")
      assert :error = Helpers.parse_id("1.5")
    end

    test "rejects non-binary input" do
      assert :error = Helpers.parse_id(nil)
      assert :error = Helpers.parse_id(42)
      assert :error = Helpers.parse_id(:atom)
    end
  end
end
