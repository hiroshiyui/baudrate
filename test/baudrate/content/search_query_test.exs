defmodule Baudrate.Content.SearchQueryTest do
  @moduledoc """
  The search box's query string is written by two things — a reader typing,
  and the filter controls on `/search` — so what this module has to get right
  is the round trip between them.
  """

  use ExUnit.Case, async: true

  alias Baudrate.Content.SearchQuery

  doctest Baudrate.Content.SearchQuery

  describe "parse/1" do
    test "splits operators from free text" do
      assert {"phoenix tutorial", operators} =
               SearchQuery.parse("author:alice tag:elixir phoenix tutorial")

      assert operators == %{"author" => ["alice"], "tag" => ["elixir"]}
    end

    test "list operators accumulate in the order written" do
      assert {"", %{"board" => ["one", "two"]}} = SearchQuery.parse("board:one board:two")
    end

    test "date operators overwrite, so the last one wins" do
      assert {"", %{"after" => ~D[2026-02-01]}} =
               SearchQuery.parse("after:2026-01-01 after:2026-02-01")
    end

    test "an unparsable date is dropped, and takes its token with it" do
      # The token leaves the free text either way — it was never a search
      # term — so a typo silently narrows nothing rather than searching for
      # the literal string.
      assert {"hello", %{}} = SearchQuery.parse("before:2026-1-1 hello")
    end

    test "leaves a URL alone" do
      assert {"https://example.com/notes/1", %{}} =
               SearchQuery.parse("https://example.com/notes/1")
    end
  end

  describe "put/3" do
    test "replaces rather than appends" do
      assert SearchQuery.put("phoenix board:general", "board", "elixir") == "phoenix board:elixir"
    end

    test "replaces every occurrence, so a single-choice control cannot leave a stale one" do
      assert SearchQuery.put("board:one board:two x", "board", "three") == "x board:three"
    end

    test "a blank value removes the operator" do
      assert SearchQuery.put("phoenix board:general", "board", "") == "phoenix"
      assert SearchQuery.put("phoenix board:general", "board", nil) == "phoenix"
    end

    test "keeps the reader's free text and the other operators" do
      assert SearchQuery.put("author:alice hello world", "after", ~D[2026-01-01]) ==
               "author:alice hello world after:2026-01-01"
    end

    test "refuses a value that could not survive a round trip" do
      # `parse/1` reads to the next space, so a value with one in it would come
      # back as a different operator plus stray free text.
      assert SearchQuery.put("hello", "board", "two words") == "hello"
    end

    test "round-trips through parse/1" do
      query =
        ""
        |> SearchQuery.put("board", "general")
        |> SearchQuery.put("after", ~D[2026-01-01])
        |> SearchQuery.put("before", ~D[2026-02-01])

      assert {"", operators} = SearchQuery.parse(query)
      assert operators["board"] == ["general"]
      assert operators["after"] == ~D[2026-01-01]
      assert operators["before"] == ~D[2026-02-01]
    end
  end

  describe "scoped?/1" do
    test "free text is a scope" do
      assert SearchQuery.scoped?("elixir")
      assert SearchQuery.scoped?("after:2026-01-01 elixir")
    end

    test "a person, a board or a topic is a scope" do
      assert SearchQuery.scoped?("author:alice")
      assert SearchQuery.scoped?("board:general")
      assert SearchQuery.scoped?("tag:elixir")
    end

    test "time alone is not a scope" do
      refute SearchQuery.scoped?("after:2026-01-01")
      refute SearchQuery.scoped?("before:2026-01-01")
      refute SearchQuery.scoped?("after:2026-01-01 before:2026-06-01")
    end

    test "neither is a property that names nothing" do
      refute SearchQuery.scoped?("has:images")
      refute SearchQuery.scoped?("has:images after:2026-01-01")
    end

    test "nor is an empty query" do
      refute SearchQuery.scoped?("")
      refute SearchQuery.scoped?("   ")
    end
  end

  describe "first/2 and date_value/2" do
    test "read a control's current setting back out" do
      {_text, operators} = SearchQuery.parse("board:one board:two after:2026-01-01")

      assert SearchQuery.first(operators, "board") == "one"
      assert SearchQuery.first(operators, "tag") == nil
      assert SearchQuery.date_value(operators, "after") == "2026-01-01"
      assert SearchQuery.date_value(operators, "before") == ""
    end
  end
end
