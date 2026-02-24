defmodule BaudrateWeb.FeedXMLTest do
  use ExUnit.Case, async: true

  alias BaudrateWeb.FeedXML

  describe "escape_cdata/1" do
    test "passes through normal text unchanged" do
      assert FeedXML.escape_cdata("Hello world") == "Hello world"
    end

    test "escapes ]]> to prevent CDATA injection" do
      assert FeedXML.escape_cdata("before]]>after") == "before]]]]><![CDATA[>after"
    end

    test "escapes multiple ]]> occurrences" do
      input = "a]]>b]]>c"
      result = FeedXML.escape_cdata(input)
      assert result == "a]]]]><![CDATA[>b]]]]><![CDATA[>c"
    end

    test "returns empty string for nil" do
      assert FeedXML.escape_cdata(nil) == ""
    end
  end

  describe "xml_escape/1" do
    test "escapes ampersand" do
      assert FeedXML.xml_escape("A & B") == "A &amp; B"
    end

    test "escapes angle brackets" do
      assert FeedXML.xml_escape("<tag>") == "&lt;tag&gt;"
    end

    test "escapes quotes" do
      assert FeedXML.xml_escape(~s|She said "hi"|) == ~s|She said &quot;hi&quot;|
    end

    test "escapes apostrophe" do
      assert FeedXML.xml_escape("it's") == "it&apos;s"
    end

    test "returns empty string for nil" do
      assert FeedXML.xml_escape(nil) == ""
    end

    test "passes through plain text unchanged" do
      assert FeedXML.xml_escape("Hello world") == "Hello world"
    end
  end

  describe "rfc822/1" do
    test "formats a UTC datetime in RFC 822 format" do
      dt = ~U[2026-02-23 05:57:22Z]
      result = FeedXML.rfc822(dt)
      assert result == "Mon, 23 Feb 2026 05:57:22 +0000"
    end
  end

  describe "rfc3339/1" do
    test "formats a UTC datetime in RFC 3339 format" do
      dt = ~U[2026-02-23 05:57:22Z]
      result = FeedXML.rfc3339(dt)
      assert result == "2026-02-23T05:57:22Z"
    end
  end
end
