defmodule BaudrateWeb.TranslationCoverageTest do
  @moduledoc """
  Every string the site shows is translated in zh_TW and ja_JP.

  `doc/TODOs.md` carried "fill the 5 empty strings in each of zh_TW and ja_JP"
  as a task, which is the shape of a chore that comes back: the count was
  already wrong when it was written (it counted the PO header), and a merge
  that adds ten strings makes it wrong again the same afternoon. A number in a
  TODO cannot tell anyone *which* strings, and nobody reads a `.po` file for
  pleasure. So the count becomes a test, and the task stops existing.

  **`en` is excluded, and that is not an oversight.** Its `msgid`s *are* the
  source text; Gettext falls back to the `msgid` when a translation is empty,
  so roughly 1,470 empty entries there are correct and filling them in would
  be 1,470 lines of duplication. `zh_TW` and `ja_JP` have no such fallback: an
  empty entry renders English to a reader who asked for neither.

  A string whose translation genuinely *is* the English — an example value in
  a placeholder, like `abcd-ef23` or `https://example.com/feed.xml` — is
  written out in full with a translator comment saying so. That is a decision
  someone made; an empty `msgstr` is indistinguishable from nobody having
  looked.
  """
  use ExUnit.Case, async: true

  @locales ~w(zh_TW ja_JP)
  @domains ~w(default errors)

  test "no message in zh_TW or ja_JP is left untranslated" do
    missing =
      for locale <- @locales,
          domain <- @domains,
          path = Path.join(["priv/gettext", locale, "LC_MESSAGES", "#{domain}.po"]),
          File.exists?(path),
          {msgid, translations} <- entries(File.read!(path)),
          # The PO header is `msgid ""`; it carries metadata, not a message.
          msgid != "",
          Enum.any?(translations, &(&1 == "")) do
        "#{locale}/#{domain}: #{inspect(msgid)}"
      end

    assert missing == [],
           """
           These messages have no #{Enum.join(@locales, " / ")} translation:

           #{Enum.join(missing, "\n")}

           Write them by hand. Do not run `mix gettext.extract --merge` and
           assume it filled them: its fuzzy matcher attaches a translation
           from a *similar* string and reports it only as "N reworded", so the
           file ends up with a plausible wrong answer rather than an empty one.

           If a string's translation really is the English — an example value
           in a placeholder — write it out and say why in a translator
           comment above the entry.
           """
  end

  # Blocks are separated by blank lines. Within a block, a msgid or msgstr can
  # span several quoted lines, which gettext concatenates.
  defp entries(source) do
    source
    |> String.split("\n\n")
    |> Enum.flat_map(fn block ->
      case capture(block, ~r/^msgid ((?:"(?:[^"\\]|\\.)*"\n?)+)/m) do
        [] -> []
        [msgid] -> [{msgid, capture(block, ~r/^msgstr(?:\[\d+\])? ((?:"(?:[^"\\]|\\.)*"\n?)+)/m)}]
      end
    end)
  end

  defp capture(block, regex) do
    regex
    |> Regex.scan(block)
    |> Enum.map(fn [_whole, quoted] -> join(quoted) end)
  end

  defp join(block) do
    ~r/"((?:[^"\\]|\\.)*)"/
    |> Regex.scan(block)
    |> Enum.map_join(fn [_, part] -> part end)
  end
end
