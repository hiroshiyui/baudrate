defmodule BaudrateWeb.TotpCodeHintTest do
  @moduledoc """
  Acceptance gate for decision 6 of
  [ADR 0024](../../doc/adr/0024-totp-codes-are-single-use-with-a-one-period-grace-window.md):
  every TOTP code field says the code works only once, always — never only
  after a reuse, which would tell whoever is guessing that the rest of the form
  was right.

  Eight templates carried the hint and `totp_setup_live.html.heex` did not,
  which is the one place it is least avoidable: enrolment *consumes* the code
  (`enable_totp/3` with `used_step:`), so an admin who enrols and goes straight
  to `/admin/verify` inside the same 30 seconds is refused with nothing having
  warned them. Nothing noticed for eight templates' worth of drift, so this is
  the thing that notices.
  """

  use ExUnit.Case, async: true

  @web_root "lib/baudrate_web"

  # A TOTP code field is one the browser fills from an authenticator.
  @code_field ~S(autocomplete="one-time-code")

  # The `aria-describedby` that points at the hint, and the hint's own `id`.
  # Both are written the same way — a quoted literal or a `{...}` expression —
  # so the two can be compared as text without parsing HEEx.
  @describedby_re ~r/aria-describedby=(\{[^\n]*?\}|"[^"]*")/
  @hint_re ~r/<\.totp_code_hint\s+id=(\{[^\n]*?\}|"[^"]*")/

  # How far below the `autocomplete` attribute the describedby may sit. The
  # attribute order is a style choice; the association is not.
  @lookahead 8

  test "every TOTP code field is described by a single-use hint" do
    files = template_files()

    assert files != [], "found no web templates to check"

    fields =
      for path <- files,
          source = File.read!(path),
          String.contains?(source, @code_field) do
        {path, source}
      end

    assert length(fields) >= 8,
           "expected the known TOTP forms; found #{length(fields)}. " <>
             "If a form was removed, update this gate deliberately."

    for {path, source} <- fields do
      lines = String.split(source, "\n")
      described = describedby_for_each_code_field(lines, path)
      hints = Regex.scan(@hint_re, source, capture: :all_but_first) |> List.flatten()

      assert length(described) == length(hints),
             "#{path}: #{length(described)} TOTP code field(s) but #{length(hints)} " <>
               "<.totp_code_hint> — ADR 0024 decision 6 wants one hint per field."

      for target <- described do
        assert target in hints,
               "#{path}: a TOTP code field is described by #{target}, which no " <>
                 "<.totp_code_hint id=…> in this file renders."
      end
    end
  end

  defp describedby_for_each_code_field(lines, path) do
    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, _} -> String.contains?(line, @code_field) end)
    |> Enum.map(fn {_, index} ->
      window =
        lines
        |> Enum.slice(index + 1, @lookahead)
        |> Enum.join("\n")

      case Regex.run(@describedby_re, window, capture: :all_but_first) do
        [target] ->
          target

        nil ->
          flunk(
            "#{path}:#{index + 1}: a TOTP code field with no aria-describedby " <>
              "within #{@lookahead} lines. ADR 0024 decision 6: the hint is " <>
              "always shown, and the field points at it."
          )
      end
    end)
  end

  defp template_files do
    Path.wildcard(Path.join(@web_root, "**/*.{ex,heex}"))
  end
end
