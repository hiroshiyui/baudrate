defmodule BaudrateWeb.LocaleTest do
  use ExUnit.Case, async: true

  alias BaudrateWeb.Locale

  describe "resolve_from_preferences/1" do
    test "returns first matching known locale" do
      assert Locale.resolve_from_preferences(["zh_TW", "en"]) == "zh_TW"
    end

    test "skips unknown locales and returns first known match" do
      assert Locale.resolve_from_preferences(["xx_YY", "en"]) == "en"
    end

    test "returns nil for empty list" do
      assert Locale.resolve_from_preferences([]) == nil
    end

    test "returns nil when no locales match" do
      assert Locale.resolve_from_preferences(["xx_YY", "zz"]) == nil
    end

    test "returns nil for non-list input" do
      assert Locale.resolve_from_preferences(nil) == nil
      assert Locale.resolve_from_preferences("en") == nil
    end
  end

  describe "locale_display_name/1" do
    test "returns English for 'en'" do
      assert Locale.locale_display_name("en") == "English"
    end

    test "returns 正體中文 for 'zh_TW'" do
      assert Locale.locale_display_name("zh_TW") == "正體中文"
    end

    test "falls back to code for unknown locale" do
      assert Locale.locale_display_name("fr") == "fr"
    end
  end

  describe "available_locales/0" do
    test "returns a list of {code, display_name} tuples" do
      locales = Locale.available_locales()
      assert is_list(locales)
      assert length(locales) > 0

      for {code, name} <- locales do
        assert is_binary(code)
        assert is_binary(name)
      end
    end

    test "includes en and zh_TW" do
      codes = Locale.available_locales() |> Enum.map(&elem(&1, 0))
      assert "en" in codes
      assert "zh_TW" in codes
    end
  end
end
