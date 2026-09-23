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
    test "returns ISO 8601 in UTC, ending in Z" do
      ndt = ~N[2026-03-15 14:30:45]
      assert Helpers.datetime_attr(ndt) == "2026-03-15T14:30:45Z"
    end

    test "drops sub-second precision" do
      assert Helpers.datetime_attr(~U[2026-03-15 14:30:45.123456Z]) == "2026-03-15T14:30:45Z"
    end

    test "returns empty string for nil" do
      assert Helpers.datetime_attr(nil) == ""
    end

    # The attribute is for machines: the site's or the viewer's zone would be
    # wrong for everyone else, because it carried no offset.
    test "stays in UTC whatever the site or the viewer's zone" do
      Setup.set_setting("timezone", "Asia/Taipei")
      BaudrateWeb.TimeZone.put("America/New_York")
      on_exit(fn -> BaudrateWeb.TimeZone.put(nil) end)

      assert Helpers.datetime_attr(~N[2026-03-15 02:30:45]) == "2026-03-15T02:30:45Z"
    end
  end

  describe "the viewer's time zone" do
    setup do
      Setup.set_setting("timezone", "Asia/Taipei")
      on_exit(fn -> BaudrateWeb.TimeZone.put(nil) end)
      :ok
    end

    test "a member's own zone wins over the site's" do
      BaudrateWeb.TimeZone.put("America/New_York")

      # 14:00 UTC is 10:00 in New York (EDT) on this date, 22:00 in Taipei.
      assert Helpers.format_datetime(~N[2026-06-15 14:00:00]) == "2026-06-15 10:00"
    end

    test "clearing it falls back to the site's zone" do
      BaudrateWeb.TimeZone.put("America/New_York")
      BaudrateWeb.TimeZone.put(nil)

      assert Helpers.format_datetime(~N[2026-06-15 14:00:00]) == "2026-06-15 22:00"
    end

    test "a zone the tz database does not know renders in the site's zone" do
      BaudrateWeb.TimeZone.put("Mars/Olympus_Mons")

      assert Helpers.format_datetime(~N[2026-06-15 14:00:00]) == "2026-06-15 22:00"
    end

    test "the label names the zone and its current offset" do
      assert BaudrateWeb.TimeZone.label() == {"Asia/Taipei", "+08:00"}

      BaudrateWeb.TimeZone.put("Asia/Kolkata")
      assert BaudrateWeb.TimeZone.label() == {"Asia/Kolkata", "+05:30"}
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
