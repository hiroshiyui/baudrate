defmodule Baudrate.Content.TitleDeriverTest do
  use ExUnit.Case, async: true

  alias Baudrate.Content.TitleDeriver

  describe "derive_title/2" do
    test "uses name field from AP object" do
      assert "My Article" == TitleDeriver.derive_title(%{"name" => "My Article"}, "body text")
    end

    test "extracts first line from body when no name" do
      assert "First line" == TitleDeriver.derive_title(%{}, "First line\nSecond line")
    end

    test "truncates long first line" do
      long = String.duplicate("word ", 20)
      title = TitleDeriver.derive_title(%{}, long)
      assert String.length(title) <= 85
      assert String.ends_with?(title, "…")
    end

    test "returns Untitled for empty body" do
      assert "Untitled" == TitleDeriver.derive_title(%{}, "")
    end

    test "returns Untitled for nil body" do
      assert "Untitled" == TitleDeriver.derive_title(%{}, nil)
    end
  end

  describe "derive_title_from_body/1" do
    test "extracts title from body string" do
      assert "Hello world" == TitleDeriver.derive_title_from_body("Hello world\nMore text")
    end
  end

  describe "truncate_title/2" do
    test "returns short text unchanged" do
      assert "Short" == TitleDeriver.truncate_title("Short", 80)
    end

    test "truncates at word boundary for English" do
      text = "This is a longer text that should be truncated at a word boundary"
      result = TitleDeriver.truncate_title(text, 30)
      assert String.ends_with?(result, "…")
      refute String.length(result) > 35
    end

    test "truncates CJK text at character boundary" do
      text = String.duplicate("漢", 100)
      result = TitleDeriver.truncate_title(text, 10)
      assert String.length(result) == 11
      assert String.ends_with?(result, "…")
    end
  end
end
