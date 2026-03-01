defmodule Baudrate.TimezoneTest do
  use ExUnit.Case, async: true

  alias Baudrate.Timezone

  describe "identifiers/0" do
    test "returns a non-empty list" do
      ids = Timezone.identifiers()
      assert is_list(ids)
      assert length(ids) > 100
    end

    test "list is sorted" do
      ids = Timezone.identifiers()
      assert ids == Enum.sort(ids)
    end

    test "contains well-known timezones" do
      ids = Timezone.identifiers()
      assert "UTC" in ids
      assert "America/New_York" in ids
      assert "Asia/Tokyo" in ids
      assert "Asia/Taipei" in ids
      assert "Europe/London" in ids
    end

    test "all entries are strings" do
      ids = Timezone.identifiers()
      assert Enum.all?(ids, &is_binary/1)
    end

    test "returns the same list on repeated calls" do
      assert Timezone.identifiers() == Timezone.identifiers()
    end
  end
end
