defmodule BaudrateWeb.HelpersDatetimeTest do
  use Baudrate.DataCase, async: true

  alias BaudrateWeb.Helpers
  alias Baudrate.Setup

  describe "format_datetime/1" do
    test "returns empty string for nil" do
      assert Helpers.format_datetime(nil) == ""
    end

    test "formats NaiveDateTime with default format (UTC when no setting)" do
      ndt = ~N[2026-03-15 14:30:00]
      assert Helpers.format_datetime(ndt) == "2026-03-15 14:30"
    end

    test "formats DateTime with default format" do
      dt = DateTime.from_naive!(~N[2026-03-15 14:30:00], "Etc/UTC")
      assert Helpers.format_datetime(dt) == "2026-03-15 14:30"
    end

    test "formats with custom format string" do
      ndt = ~N[2026-03-15 14:30:45]
      assert Helpers.format_datetime(ndt, "%Y-%m-%d %H:%M:%S") == "2026-03-15 14:30:45"
    end

    test "converts to configured timezone" do
      # Asia/Taipei is UTC+8
      Setup.set_setting("timezone", "Asia/Taipei")

      ndt = ~N[2026-03-15 02:30:00]
      assert Helpers.format_datetime(ndt) == "2026-03-15 10:30"
    end

    test "converts DateTime to configured timezone" do
      Setup.set_setting("timezone", "Asia/Taipei")

      dt = DateTime.from_naive!(~N[2026-03-15 02:30:00], "Etc/UTC")
      assert Helpers.format_datetime(dt) == "2026-03-15 10:30"
    end

    test "handles date rollover across timezone boundary" do
      # UTC 23:00 on March 15 → March 16 07:00 in Asia/Taipei (UTC+8)
      Setup.set_setting("timezone", "Asia/Taipei")

      ndt = ~N[2026-03-15 23:00:00]
      assert Helpers.format_datetime(ndt) == "2026-03-16 07:00"
    end
  end

  describe "datetime_attr/1" do
    test "returns ISO datetime string" do
      ndt = ~N[2026-03-15 14:30:45]
      assert Helpers.datetime_attr(ndt) == "2026-03-15T14:30:45"
    end

    test "returns empty string for nil" do
      assert Helpers.datetime_attr(nil) == ""
    end

    test "converts to configured timezone" do
      Setup.set_setting("timezone", "Asia/Taipei")

      ndt = ~N[2026-03-15 02:30:45]
      assert Helpers.datetime_attr(ndt) == "2026-03-15T10:30:45"
    end
  end

  describe "format_date/1" do
    test "returns date-only string" do
      ndt = ~N[2026-03-15 14:30:00]
      assert Helpers.format_date(ndt) == "2026-03-15"
    end

    test "returns empty string for nil" do
      assert Helpers.format_date(nil) == ""
    end

    test "converts to configured timezone for date" do
      # UTC 23:00 on March 15 → March 16 in Asia/Taipei (UTC+8)
      Setup.set_setting("timezone", "Asia/Taipei")

      ndt = ~N[2026-03-15 23:00:00]
      assert Helpers.format_date(ndt) == "2026-03-16"
    end
  end
end
