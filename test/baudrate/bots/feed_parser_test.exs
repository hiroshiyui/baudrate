defmodule Baudrate.Bots.FeedParserTest do
  use ExUnit.Case, async: true

  alias Baudrate.Bots.FeedParser

  @rss_feed """
  <?xml version="1.0" encoding="UTF-8"?>
  <rss version="2.0">
    <channel>
      <title>Test Feed</title>
      <link>https://example.com</link>
      <item>
        <title>First Post</title>
        <link>https://example.com/posts/1</link>
        <guid>https://example.com/posts/1</guid>
        <description>&lt;p&gt;Hello world&lt;/p&gt;</description>
        <pubDate>Mon, 01 Jan 2024 12:00:00 +0000</pubDate>
      </item>
      <item>
        <title>Second Post</title>
        <link>https://example.com/posts/2</link>
        <guid>post-2-unique-id</guid>
        <description>Simple text description</description>
        <pubDate>Tue, 02 Jan 2024 12:00:00 +0000</pubDate>
      </item>
    </channel>
  </rss>
  """

  @atom_feed """
  <?xml version="1.0" encoding="UTF-8"?>
  <feed xmlns="http://www.w3.org/2005/Atom">
    <title>Atom Test Feed</title>
    <link href="https://atom.example.com"/>
    <entry>
      <title>Atom Entry One</title>
      <id>https://atom.example.com/entry/1</id>
      <link href="https://atom.example.com/entry/1"/>
      <summary>Summary text here</summary>
      <updated>2024-03-01T10:00:00Z</updated>
    </entry>
  </feed>
  """

  describe "parse/1 with RSS feed" do
    test "parses entries successfully" do
      assert {:ok, entries} = FeedParser.parse(@rss_feed)
      assert length(entries) == 2
    end

    test "extracts guid correctly" do
      {:ok, entries} = FeedParser.parse(@rss_feed)
      first = Enum.find(entries, &(&1.guid == "https://example.com/posts/1"))
      assert first != nil
    end

    test "extracts title as plain text" do
      {:ok, entries} = FeedParser.parse(@rss_feed)
      [first | _] = entries
      assert first.title == "First Post"
    end

    test "extracts link" do
      {:ok, entries} = FeedParser.parse(@rss_feed)
      [first | _] = entries
      assert first.link == "https://example.com/posts/1"
    end

    test "sanitizes HTML in description" do
      {:ok, entries} = FeedParser.parse(@rss_feed)
      [first | _] = entries
      # Should contain sanitized content
      assert is_binary(first.body)
    end

    test "parses RFC 2822 date" do
      {:ok, entries} = FeedParser.parse(@rss_feed)
      [first | _] = entries
      assert %DateTime{} = first.published_at
      assert first.published_at.year == 2024
      assert first.published_at.month == 1
      assert first.published_at.day == 1
    end
  end

  describe "parse/1 with Atom feed" do
    test "parses Atom entries" do
      assert {:ok, entries} = FeedParser.parse(@atom_feed)
      assert length(entries) == 1
    end

    test "uses entry id as guid" do
      {:ok, [entry]} = FeedParser.parse(@atom_feed)
      assert entry.guid == "https://atom.example.com/entry/1"
    end

    test "parses ISO 8601 date" do
      {:ok, [entry]} = FeedParser.parse(@atom_feed)
      assert %DateTime{} = entry.published_at
      assert entry.published_at.year == 2024
    end
  end

  describe "parse/1 with HTML-in-title RSS feed (Drupal-style)" do
    @drupal_rss_feed """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Drupal Feed</title>
        <link>https://example.com</link>
        <item>
          <title><a href="/news/123" hreflang="zh-hant">Some Article Title</a></title>
          <link>https://example.com/news/123</link>
          <guid>https://example.com/news/123</guid>
          <description><![CDATA[<p>Article body text here.</p>]]></description>
          <pubDate>Mon, 01 Jan 2024 12:00:00 +0000</pubDate>
        </item>
        <item>
          <title><a href="/news/456">Title with &amp; ampersand</a></title>
          <link>https://example.com/news/456</link>
          <guid>https://example.com/news/456</guid>
          <description><![CDATA[<p>Second article.</p>]]></description>
          <pubDate>Tue, 02 Jan 2024 12:00:00 +0000</pubDate>
        </item>
      </channel>
    </rss>
    """

    test "extracts title from nested <a> tag without CDATA" do
      {:ok, entries} = FeedParser.parse(@drupal_rss_feed)
      first = Enum.find(entries, &(&1.guid == "https://example.com/news/123"))
      assert first.title == "Some Article Title"
    end

    test "preserves XML entities in title text" do
      {:ok, entries} = FeedParser.parse(@drupal_rss_feed)
      second = Enum.find(entries, &(&1.guid == "https://example.com/news/456"))
      assert second.title == "Title with & ampersand"
    end

    test "still extracts CDATA body correctly" do
      {:ok, entries} = FeedParser.parse(@drupal_rss_feed)
      first = Enum.find(entries, &(&1.guid == "https://example.com/news/123"))
      assert first.body =~ "Article body text here."
    end
  end

  describe "parse/1 with RSS 1.0 (RDF) feed" do
    @rss1_feed """
    <?xml version="1.0" encoding="UTF-8"?>
    <rdf:RDF xmlns="http://purl.org/rss/1.0/"
             xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
             xmlns:dc="http://purl.org/dc/elements/1.1/"
             xmlns:content="http://purl.org/rss/1.0/modules/content/"
             xml:lang="ja">
      <channel rdf:about="https://example.com/feed.rdf">
        <title>RSS 1.0 Test Feed</title>
        <link>https://example.com</link>
      </channel>
      <item rdf:about="https://example.com/articles/1">
        <title>First RSS 1.0 Article</title>
        <link>https://example.com/articles/1</link>
        <dc:date>2024-03-01T10:00:00+09:00</dc:date>
        <description><![CDATA[<p>Article body text.</p>]]></description>
      </item>
      <item rdf:about="https://example.com/articles/2">
        <title>Second Article with &amp; ampersand</title>
        <link>https://example.com/articles/2</link>
        <dc:date>2024-03-02T10:00:00+09:00</dc:date>
        <content:encoded><![CDATA[<p>Full content body.</p>]]></content:encoded>
        <description><![CDATA[<p>Summary only.</p>]]></description>
      </item>
    </rdf:RDF>
    """

    test "parses entries successfully" do
      assert {:ok, entries} = FeedParser.parse(@rss1_feed)
      assert length(entries) == 2
    end

    test "uses rdf:about as guid" do
      {:ok, entries} = FeedParser.parse(@rss1_feed)
      first = Enum.find(entries, &(&1.guid == "https://example.com/articles/1"))
      assert first != nil
    end

    test "extracts title as plain text" do
      {:ok, entries} = FeedParser.parse(@rss1_feed)
      first = Enum.find(entries, &(&1.guid == "https://example.com/articles/1"))
      assert first.title == "First RSS 1.0 Article"
    end

    test "decodes XML entities in title" do
      {:ok, entries} = FeedParser.parse(@rss1_feed)
      second = Enum.find(entries, &(&1.guid == "https://example.com/articles/2"))
      assert second.title == "Second Article with & ampersand"
    end

    test "extracts link" do
      {:ok, entries} = FeedParser.parse(@rss1_feed)
      first = Enum.find(entries, &(&1.guid == "https://example.com/articles/1"))
      assert first.link == "https://example.com/articles/1"
    end

    test "prefers content:encoded over description for body" do
      {:ok, entries} = FeedParser.parse(@rss1_feed)
      second = Enum.find(entries, &(&1.guid == "https://example.com/articles/2"))
      assert second.body =~ "Full content body."
      refute second.body =~ "Summary only."
    end

    test "falls back to description when content:encoded is absent" do
      {:ok, entries} = FeedParser.parse(@rss1_feed)
      first = Enum.find(entries, &(&1.guid == "https://example.com/articles/1"))
      assert first.body =~ "Article body text."
    end

    test "parses dc:date as ISO 8601" do
      {:ok, entries} = FeedParser.parse(@rss1_feed)
      first = Enum.find(entries, &(&1.guid == "https://example.com/articles/1"))
      assert %DateTime{} = first.published_at
      assert first.published_at.year == 2024
      assert first.published_at.month == 3
      assert first.published_at.day == 1
    end
  end

  describe "parse/1 error handling" do
    test "returns error for invalid XML" do
      assert {:error, _reason} = FeedParser.parse("this is not xml")
    end

    test "filters out entries with no guid" do
      feed = """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0">
        <channel>
          <title>Test</title>
          <item>
            <title>No guid or link</title>
          </item>
        </channel>
      </rss>
      """

      assert {:ok, entries} = FeedParser.parse(feed)
      assert entries == []
    end
  end

  describe "clamp_published_at" do
    test "rejects dates more than 10 years in the past" do
      feed = """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0">
        <channel>
          <title>Test</title>
          <item>
            <title>Old Post</title>
            <link>https://example.com/old</link>
            <guid>old-guid-1</guid>
            <pubDate>Mon, 01 Jan 2000 00:00:00 +0000</pubDate>
          </item>
        </channel>
      </rss>
      """

      {:ok, [entry]} = FeedParser.parse(feed)
      assert is_nil(entry.published_at)
    end

    test "rejects dates in the future" do
      # 2 years in the future
      future_year = Date.utc_today().year + 2

      feed = """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0">
        <channel>
          <title>Test</title>
          <item>
            <title>Future Post</title>
            <link>https://example.com/future</link>
            <guid>future-guid-1</guid>
            <pubDate>Mon, 01 Jan #{future_year} 00:00:00 +0000</pubDate>
          </item>
        </channel>
      </rss>
      """

      {:ok, [entry]} = FeedParser.parse(feed)
      assert is_nil(entry.published_at)
    end
  end
end
