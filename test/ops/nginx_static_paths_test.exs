defmodule Ops.NginxStaticPathsTest do
  @moduledoc """
  Keeps nginx's serve-from-disk rules from outliving the files they serve.

  nginx sits in front of the application and answers some paths from disk so
  the request never reaches Phoenix. That is a performance choice, and it
  quietly becomes a correctness one the moment a path stops being a file: the
  `location` block still matches, `root` finds nothing, and **nginx answers its
  own 404** before the router is ever consulted. The application is correct,
  every test passes, and the endpoint is dead in production only.

  That is not hypothetical. `robots.txt` became a route in v1.33.0 — its
  `Sitemap:` directive needs an absolute URL, which only the application knows
  ([ADR 0057](../../doc/adr/0057-a-sitemap-invites-only-what-a-guest-sees.md))
  — and `priv/static/robots.txt` was deleted with it. The nginx template still
  matched `robots[^/]*\\.txt`, so the deploy left the instance serving a 404
  there: no sitemap advertised, and no `Disallow` for `/ap/`, `/api/` or
  `/exports/` at all.

  The rule this enforces: **every path any static `location` claims must be
  something `BaudrateWeb.static_paths/0` actually serves as a file.** Anything
  the application generates belongs in `location /`.

  It reads *every* block that serves from `{{ static_path }}`, not one named
  block, because the fix for the manifest's MIME type moved a path into a
  `location` of its own — and a gate that knows about one block would have
  stopped covering it at exactly the moment it grew a second home.

  The converse is deliberately not checked. A static path with no nginx rule is
  proxied to Phoenix, which is slower but correct.
  """

  use ExUnit.Case, async: true

  @template "ansible/roles/nginx/templates/baudrate.conf.j2"

  # `location [modifier] <pattern> {` — the modifier is optional (`~`, `~*`,
  # `^~`, `=`).
  @location_re ~r/^\s*location\s+(?:(?<mod>=|~\*|~|\^~)\s+)?(?<pattern>\S+)\s*\{/

  setup_all do
    blocks =
      @template
      |> File.read!()
      |> locations()
      |> Enum.filter(&serves_from_static_root?/1)

    {:ok, blocks: blocks}
  end

  test "the template still has static locations to check", %{blocks: blocks} do
    refute blocks == [], """
    no `location` in #{@template} serves from `{{ static_path }}`.

    If static serving moved or was restructured, update this test — do not
    delete it. It is the only thing standing between a path that stops being
    a file and a production-only 404.
    """
  end

  test "every path a static location claims is one the app serves as a file", %{blocks: blocks} do
    served = Enum.map(BaudrateWeb.static_paths(), &("/" <> &1))

    for %{mod: mod, pattern: pattern} <- blocks,
        claim <- claims(mod, pattern) do
      assert covered?(mod, claim, served), """
      the nginx block `location #{mod} #{pattern}` claims #{inspect(claim)},
      but nothing in BaudrateWeb.static_paths/0 matches it:

        #{Enum.join(served, "\n  ")}

      nginx serves this from disk, so if the file no longer exists it answers
      its own 404 and the request never reaches the router. If this path
      became a route, take it out of #{@template}; if it is still a file, add
      it to static_paths/0.
      """
    end
  end

  # --- reading the template ---

  # Each `location` header, paired with the body up to its matching brace.
  defp locations(conf) do
    conf
    |> String.split("\n")
    |> Enum.reduce({[], nil}, &scan_line/2)
    |> elem(0)
    |> Enum.reverse()
  end

  defp scan_line(line, {done, nil}) do
    case Regex.named_captures(@location_re, line) do
      %{"mod" => mod, "pattern" => pattern} ->
        {done, %{mod: mod, pattern: pattern, body: [], depth: 1}}

      nil ->
        {done, nil}
    end
  end

  defp scan_line(line, {done, open}) do
    depth = open.depth + count(line, "{") - count(line, "}")
    open = %{open | body: [line | open.body], depth: depth}

    if depth <= 0,
      do: {[%{open | body: Enum.join(Enum.reverse(open.body), "\n")} | done], nil},
      else: {done, open}
  end

  defp count(line, char), do: line |> String.graphemes() |> Enum.count(&(&1 == char))

  defp serves_from_static_root?(%{body: body}),
    do: Regex.match?(~r/^\s*(root|alias)\s+\{\{\s*static_path\s*\}\}/m, body)

  # --- what a block claims ---

  # A regex location claims each top-level alternative of its pattern; a
  # prefix location claims its literal prefix.
  defp claims(mod, pattern) when mod in ["~", "~*"] do
    body = String.trim_leading(pattern, "^")

    case outer_group(body) do
      {:ok, prefix, inner, suffix} ->
        Enum.map(split_top_level(inner), &(prefix <> &1 <> suffix))

      :error ->
        [body]
    end
  end

  defp claims(_mod, pattern), do: [pattern]

  defp covered?(mod, claim, served) when mod in ["~", "~*"] do
    case Regex.compile("^" <> claim) do
      {:ok, re} -> Enum.any?(served, &Regex.match?(re, &1))
      :error -> flunk("`location #{mod} #{claim}` is not a valid regex")
    end
  end

  # A prefix location: the claim must sit at or under a served path. Matching
  # it as a regex would be wrong in both directions — `/assets/` would fail
  # against the served `/assets`, and a prefix containing regex metacharacters
  # would silently match something else.
  defp covered?(_mod, claim, served),
    do: Enum.any?(served, &(claim == &1 or String.starts_with?(claim, &1 <> "/")))

  # `/(a|b|c)` → {:ok, "/", "a|b|c", ""}; anything else → :error. Only a single
  # group spanning the rest of the pattern is descended into, which is the one
  # shape that would otherwise hide a dead alternative behind a live sibling.
  defp outer_group(body) do
    with [prefix, rest] <- String.split(body, "(", parts: 2),
         {inner, suffix} when inner != nil <- take_group(rest) do
      {:ok, prefix, inner, suffix}
    else
      _ -> :error
    end
  end

  defp take_group(rest) do
    rest
    |> String.graphemes()
    |> Enum.reduce_while({[], 0, false}, fn
      char, {acc, depth, true} -> {:cont, {[char | acc], depth, false}}
      "\\", {acc, depth, _} -> {:cont, {["\\" | acc], depth, true}}
      "(", {acc, depth, _} -> {:cont, {["(" | acc], depth + 1, false}}
      ")", {acc, 0, _} -> {:halt, {acc, :closed}}
      ")", {acc, depth, _} -> {:cont, {[")" | acc], depth - 1, false}}
      char, {acc, depth, _} -> {:cont, {[char | acc], depth, false}}
    end)
    |> case do
      {acc, :closed} -> {acc |> Enum.reverse() |> Enum.join(), ""}
      _ -> {nil, nil}
    end
  end

  # Split an alternation on its top-level `|` only, so a nested group such as
  # `favicon[^/]*\.(ico|svg)` stays in one piece.
  defp split_top_level(alts) do
    alts
    |> String.graphemes()
    |> Enum.reduce({[], [], 0, 0, false}, &scan_char/2)
    |> close()
  end

  defp scan_char(char, {done, current, parens, brackets, escaped}) do
    cond do
      escaped -> {done, [char | current], parens, brackets, false}
      char == "\\" -> {done, [char | current], parens, brackets, true}
      char == "[" -> {done, [char | current], parens, brackets + 1, false}
      char == "]" -> {done, [char | current], parens, brackets - 1, false}
      char == "(" and brackets == 0 -> {done, [char | current], parens + 1, brackets, false}
      char == ")" and brackets == 0 -> {done, [char | current], parens - 1, brackets, false}
      char == "|" and parens == 0 and brackets == 0 -> {[finish(current) | done], [], 0, 0, false}
      true -> {done, [char | current], parens, brackets, false}
    end
  end

  defp close({done, current, _parens, _brackets, _escaped}) do
    [finish(current) | done]
    |> Enum.reverse()
    |> Enum.reject(&(&1 == ""))
  end

  defp finish(current), do: current |> Enum.reverse() |> Enum.join() |> String.trim()
end
