defmodule BaudrateWeb.FeedXMLTest do
  use ExUnit.Case, async: true

  alias BaudrateWeb.SyndicationFeedXML

  describe "escape_cdata/1" do
    test "passes through normal text unchanged" do
      assert SyndicationFeedXML.escape_cdata("Hello world") == "Hello world"
    end

    test "escapes ]]> to prevent CDATA injection" do
      assert SyndicationFeedXML.escape_cdata("before]]>after") == "before]]]]><![CDATA[>after"
    end

    test "escapes multiple ]]> occurrences" do
      input = "a]]>b]]>c"
      result = SyndicationFeedXML.escape_cdata(input)
      assert result == "a]]]]><![CDATA[>b]]]]><![CDATA[>c"
    end

    test "returns empty string for nil" do
      assert SyndicationFeedXML.escape_cdata(nil) == ""
    end

    test "drops characters XML 1.0 forbids" do
      assert SyndicationFeedXML.escape_cdata("a\x01b\x1Fc\td\ne") == "abc\td\ne"
    end
  end

  # No escape makes a C0 control legal in XML 1.0 (`&#1;` is as invalid as the
  # byte), so one in a member's title made the whole feed malformed.
  describe "XML.escape/1 and strip_invalid/1" do
    test "drop C0 controls but keep tab, newline and carriage return" do
      assert BaudrateWeb.XML.escape("T\x00i\x08t\x0Bl\x0Ce\x7F <b>") ==
               "Title\x7F &lt;b&gt;"

      assert BaudrateWeb.XML.strip_invalid("a\tb\nc\rd") == "a\tb\nc\rd"
    end

    test "the result parses as XML" do
      title = BaudrateWeb.XML.escape("Bad\x01title & more")
      doc = ~c"<t>" ++ String.to_charlist(title) ++ ~c"</t>"
      assert {{:xmlElement, :t, _, _, _, _, _, _, _, _, _, _}, _} = :xmerl_scan.string(doc)
    end
  end

  describe "xml_escape/1" do
    test "escapes ampersand" do
      assert SyndicationFeedXML.xml_escape("A & B") == "A &amp; B"
    end

    test "escapes angle brackets" do
      assert SyndicationFeedXML.xml_escape("<tag>") == "&lt;tag&gt;"
    end

    test "escapes quotes" do
      assert SyndicationFeedXML.xml_escape(~s|She said "hi"|) == ~s|She said &quot;hi&quot;|
    end

    test "escapes apostrophe" do
      assert SyndicationFeedXML.xml_escape("it's") == "it&apos;s"
    end

    test "returns empty string for nil" do
      assert SyndicationFeedXML.xml_escape(nil) == ""
    end

    test "passes through plain text unchanged" do
      assert SyndicationFeedXML.xml_escape("Hello world") == "Hello world"
    end
  end

  describe "rfc822/1" do
    test "formats a UTC datetime in RFC 822 format" do
      dt = ~U[2026-02-23 05:57:22Z]
      result = SyndicationFeedXML.rfc822(dt)
      assert result == "Mon, 23 Feb 2026 05:57:22 +0000"
    end
  end

  describe "rfc3339/1" do
    test "formats a UTC datetime in RFC 3339 format" do
      dt = ~U[2026-02-23 05:57:22Z]
      result = SyndicationFeedXML.rfc3339(dt)
      assert result == "2026-02-23T05:57:22Z"
    end
  end
end
