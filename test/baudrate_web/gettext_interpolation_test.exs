defmodule BaudrateWeb.GettextInterpolationTest do
  @moduledoc """
  Every translation may only interpolate bindings its `msgid` actually provides.

  `mix gettext.extract --merge` attaches an existing translation to any new
  `msgid` that looks similar, and reports it only as "N reworded (fuzzy)". When
  the two strings carry *different* placeholders the result is not merely a bad
  translation, it is a broken one: "Move %{title} up" came back as
  "将 %{locale} 上移", and at runtime Gettext is handed a binding that does not
  exist.

  A wrong translation is caught by reading it. This is caught by nobody, in a
  locale the reviewer may not read, so it gets a test.
  """
  use ExUnit.Case, async: true

  @locales ~w(en zh_TW ja_JP)
  @domains ~w(default errors)

  # `msgid "..."` followed by `msgstr "..."`, both single-line. Multi-line
  # entries are concatenations; they are checked by joining their parts below.
  @entry ~r/^msgid ((?:"(?:[^"\\]|\\.)*"\n)+)msgstr ((?:"(?:[^"\\]|\\.)*"\n)+)/m

  test "no translation interpolates a binding its msgid does not provide" do
    offenders =
      for locale <- @locales,
          domain <- @domains,
          path = Path.join(["priv/gettext", locale, "LC_MESSAGES", "#{domain}.po"]),
          File.exists?(path),
          {msgid, msgstr} <- entries(File.read!(path)),
          msgstr != "",
          extra = MapSet.difference(placeholders(msgstr), placeholders(msgid)),
          MapSet.size(extra) > 0 do
        "#{locale}/#{domain}: #{inspect(msgid)}\n" <>
          "    translation uses #{inspect(Enum.sort(extra))}, " <>
          "msgid provides #{inspect(Enum.sort(placeholders(msgid)))}"
      end

    assert offenders == [],
           "Translations interpolate bindings that do not exist:\n\n" <>
             Enum.join(offenders, "\n\n") <>
             "\n\nThis is what a fuzzy merge does. Fix the translation by hand."
  end

  defp entries(source) do
    Regex.scan(@entry, source)
    |> Enum.map(fn [_whole, msgid, msgstr] -> {join(msgid), join(msgstr)} end)
  end

  # A msgid or msgstr can be several quoted lines; gettext concatenates them.
  defp join(block) do
    Regex.scan(~r/"((?:[^"\\]|\\.)*)"/, block)
    |> Enum.map_join(fn [_, part] -> part end)
  end

  defp placeholders(string) do
    ~r/%\{(\w+)\}/
    |> Regex.scan(string)
    |> Enum.map(fn [_, name] -> name end)
    |> MapSet.new()
  end
end
