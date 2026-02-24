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
end
