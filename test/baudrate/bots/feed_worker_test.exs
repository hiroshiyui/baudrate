defmodule Baudrate.Bots.FeedWorkerTest do
  @moduledoc """
  Pure-function coverage for `Baudrate.Bots.FeedWorker`.

  The end-to-end polling loop is integration-tested implicitly through the
  Bots context (`already_posted?`, `mark_fetch_success`, etc.). The slug
  builder is the only piece of internal logic that's worth pinning in
  isolation — it determines the URL of every article a bot creates, so a
  regression that produces colliding or invalid slugs would silently
  break federation discovery and de-duplication.
  """

  use ExUnit.Case, async: true

  alias Baudrate.Bots.FeedWorker

  describe "build_slug/2" do
    test "produces a slug that is title-derived plus an 8-char guid hash" do
      slug = FeedWorker.build_slug("Hello World", "guid-1")
      assert slug =~ ~r/\Ahello-world-[a-f0-9]{8}\z/
    end

    test "lowercases and replaces non-alphanumeric characters with hyphens" do
      slug = FeedWorker.build_slug("Foo, Bar! Baz?", "g")
      assert slug =~ ~r/\Afoo-bar-baz-[a-f0-9]{8}\z/
    end

    test "collapses runs of separators into a single hyphen" do
      slug = FeedWorker.build_slug("a   b---c", "g")
      assert slug =~ ~r/\Aa-b-c-[a-f0-9]{8}\z/
    end

    test "trims leading and trailing hyphens" do
      slug = FeedWorker.build_slug("---hello---", "g")
      assert slug =~ ~r/\Ahello-[a-f0-9]{8}\z/
    end

    test "truncates the title portion to 60 characters before appending the hash" do
      long_title = String.duplicate("a", 200)
      slug = FeedWorker.build_slug(long_title, "g")

      [base, hash] = String.split(slug, "-")
      assert String.length(base) == 60
      assert String.length(hash) == 8
    end

    test "deterministic — same title + guid yields the same slug" do
      assert FeedWorker.build_slug("Title", "abc") == FeedWorker.build_slug("Title", "abc")
    end

    test "different guids yield different slugs even for the same title" do
      a = FeedWorker.build_slug("Title", "guid-a")
      b = FeedWorker.build_slug("Title", "guid-b")
      refute a == b
      # Title prefix is identical, only the hash suffix changes
      assert String.starts_with?(a, "title-")
      assert String.starts_with?(b, "title-")
    end

    test "falls back to the bare hash when the title contains no slug-safe characters" do
      slug = FeedWorker.build_slug("！？@#$", "guid-fallback")
      assert slug =~ ~r/\A[a-f0-9]{8}\z/
    end

    test "falls back to the bare hash for an empty title" do
      slug = FeedWorker.build_slug("", "guid-empty")
      assert slug =~ ~r/\A[a-f0-9]{8}\z/
    end

    test "non-ASCII titles fall through to the hash since they contain no [a-z0-9]" do
      # CJK / Cyrillic input is stripped down to nothing by the [a-z0-9]+
      # filter, so the fallback hash carries uniqueness on its own.
      slug_ja = FeedWorker.build_slug("こんにちは", "guid-ja")
      slug_zh = FeedWorker.build_slug("你好", "guid-zh")

      assert slug_ja =~ ~r/\A[a-f0-9]{8}\z/
      assert slug_zh =~ ~r/\A[a-f0-9]{8}\z/
      refute slug_ja == slug_zh
    end

    test "matches the slug format expected by Article.changeset" do
      slug = FeedWorker.build_slug("Whatever", "guid-format")
      # Article slugs must be lowercase alphanumeric segments separated by hyphens.
      assert slug =~ ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/
    end
  end
end
